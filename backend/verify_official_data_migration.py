#!/usr/bin/env python
"""
Verify that a CampusSync official-data migration changed ONLY the approved rows.

WHAT IT PROVES
--------------
Reads two SQLite files - the pre-migration BASELINE and the migrated database -
side by side and proves the migration did exactly what the reviewed plan said,
and nothing else:

* compares ``timetable_entries`` ROW BY ROW, matched on the primary key ``id``;
* allows exactly nine approved row ids to change, and checks each allowed
  field's exact old value and exact new value;
* rejects a deleted row, an inserted row, and any change to a field the plan
  does not list;
* allows only the additive columns the plan declares, and each of those must
  hold its declared default on every row it was added to;
* proves the account/record tables were not touched at all;
* proves the official-data tables only gained rows and only had the blank-fill
  edits the seeder actually performs.

OPERATING REQUIREMENTS (read before running)
--------------------------------------------
1. THE BASELINE MUST PREDATE THE ADDITIVE SCHEMA STEP. ``--before`` has to be a
   copy taken BEFORE ``timetable_entries.is_free_period`` exists (see the
   deployment order in AGENTS.md). If it already has that column the script
   refuses to run at all (exit 2) rather than report a misleading result. This
   is a precondition, not a tolerance: the point of the check is that the
   migration CREATED the column.
2. THE BACKEND MUST BE STOPPED. A login or logout writes ``teachers.token`` and
   ``teachers.token_expires_at``; that table must be preserved exactly, so a
   concurrent session write fails the run. That is deliberate: a failure here
   means the backend was not stopped, not that the migration is wrong. There is
   no override flag.
3. It also has to be the right pair of files - the same database before and
   after. Two unrelated databases are rejected (every row looks deleted).

SECRETS
-------
Values of ``password``, ``password_hash``, ``token`` and ``token_expires_at``
are compared internally but never printed: every message shows ``<redacted>``
for those columns (see ``REDACTED_COLUMNS``). The comparison result is
unaffected - only the logging is censored.

HOW IT READS THE DATABASE
-------------------------
Raw ``sqlite3`` in read-only URI mode - deliberately NOT the SQLAlchemy models
and NOT ``main.py``. Before the additive step the file has no
``is_free_period`` column, so importing the ORM would fail on the very database
this check has to read. Read-only mode also means this script cannot write to
either file. The file is checked for existence, size and the SQLite header
first, so a missing, empty, foreign or recovery-needed file produces a clear
message instead of a traceback.

THE ROW IDS
-----------
The nine ids below were read out of the live database (a read-only copy of
``backend/campussync.db``). Because a bare id is easy to mistype,
``APPROVED_ROW_IDENTITY`` records what each id actually is, and the script
re-verifies that identity in BOTH snapshots - so a wrong id fails loudly
instead of silently approving the wrong row.

USAGE
-----
    python verify_official_data_migration.py --before <baseline.db> --after <live.db>

EXIT CODES
----------
    0  every check passed
    1  at least one mismatch (the migration changed something it should not
       have, or failed to make an approved change)
    2  the comparison could not run (bad arguments, missing/empty/foreign file,
       recovery-needed file, or the baseline postdates the schema step)
"""

from __future__ import annotations

import argparse
import sqlite3
import sys
import traceback
from pathlib import Path
from typing import Any, Callable

# ---------------------------------------------------------------------------
# 'column does not exist' marker (a private singleton, never a real value)
# ---------------------------------------------------------------------------


class _Absent:
    """The single marker for a column that is not present in a snapshot.

    It is compared by identity, so no real column value can ever be mistaken
    for it - not even a text column that happens to hold the string
    ``<column-absent>``.
    """

    _instance: "_Absent | None" = None

    def __new__(cls) -> "_Absent":
        if cls._instance is None:
            cls._instance = super().__new__(cls)
        return cls._instance

    def __repr__(self) -> str:
        return "<column-absent>"

    def __eq__(self, other: object) -> bool:
        return other is self

    def __hash__(self) -> int:
        return hash("campusync-absent-sentinel")


ABSENT = _Absent()

# ---------------------------------------------------------------------------
# The approved changes - the single place this script's expectations live
# ---------------------------------------------------------------------------

TIMETABLE_TABLE = "timetable_entries"

# The columns that identify a timetable row to a human reader.
IDENTITY_FIELDS = ("day", "start_time", "end_time", "subject")

# Columns whose values must never reach a log, a terminal, or a report. The
# comparison still uses the real values; only the printed form is censored.
REDACTED_COLUMNS = frozenset(
    {"password", "password_hash", "token", "token_expires_at"}
)

# The subset of redacted columns that a live session can rewrite on its own.
SESSION_COLUMNS = frozenset({"token", "token_expires_at"})

REDACTED_TEXT = "<redacted>"

# id -> (day, start_time, end_time, subject). Verified in both snapshots.
APPROVED_ROW_IDENTITY: dict[int, tuple[str, str, str, str]] = {
    # Saturday CCC-1: the printed Revision 4 has HBW, the old database has DPK.
    # (Wednesday's CCC-1 rows are ids 26/27 and are already correct - they are
    # deliberately NOT part of this plan.)
    50: ("Saturday", "13:00", "14:00", "CCC-1"),
    51: ("Saturday", "14:00", "15:00", "CCC-1"),
    # FPL faculty cell: the sheet prints the LETTER I -> "RVS (CCI)". The cell
    # now runs 13:00-15:00 (Revision 4 of the sheet), already true in the
    # baseline because that correction predates this seed.
    23: ("Wednesday", "13:00", "15:00", "FPL"),
    44: ("Friday", "15:15", "16:15", "FPL"),
    # The five weekly "RELM" rows: free periods, not breaks.
    17: ("Tuesday", "15:15", "16:15", "RELM"),
    18: ("Tuesday", "16:15", "17:15", "RELM"),
    28: ("Thursday", "10:15", "11:15", "RELM"),
    53: ("Saturday", "15:15", "16:15", "RELM"),
    54: ("Saturday", "16:15", "17:15", "RELM"),
}

# id -> {column: (exact old value, exact new value)}. Any column not listed for
# a row must be byte-for-byte identical before and after.
APPROVED_TIMETABLE_CHANGES: dict[int, dict[str, tuple[Any, Any]]] = {
    50: {"faculty": ("DPK", "HBW")},
    51: {"faculty": ("DPK", "HBW")},
    23: {"faculty": ("RVS (CC1)", "RVS (CCI)")},
    44: {"faculty": ("RVS (CC1)", "RVS (CCI)")},
    17: {"is_break": (1, 0), "is_free_period": (ABSENT, 1)},
    18: {"is_break": (1, 0), "is_free_period": (ABSENT, 1)},
    28: {"is_break": (1, 0), "is_free_period": (ABSENT, 1)},
    53: {"is_break": (1, 0), "is_free_period": (ABSENT, 1)},
    54: {"is_break": (1, 0), "is_free_period": (ABSENT, 1)},
}

# The pre-migration row count. Rejects "everything was deleted and re-inserted".
# Update ONLY when a new revision of the sheet genuinely adds/removes a row.
EXPECTED_TIMETABLE_ROWS = 54

# Columns the additive schema step may add, and the value every row of that
# table must then hold (the column's declared DEFAULT in seed_official_data.py).
# Adding any other column, or dropping one, is a mismatch.
APPROVED_NEW_COLUMNS: dict[tuple[str, str], Any] = {
    ("timetable_entries", "is_free_period"): 0,
    ("teachers", "short_code"): None,
    ("teachers", "can_approve_registrations"): 0,
    ("teachers", "plain_password"): None,
    ("assignments", "stored_name"): None,
    ("assignments", "original_name"): None,
    ("assignments", "file_size"): None,
    ("assignments", "uploaded_by"): None,
    ("assignments", "created_at"): None,
    ("attendance_records", "updated_by"): None,
}

# Columns this migration is SUPPOSED to create: the baseline must predate them,
# or the comparison cannot prove anything (operating requirement 1). Only the
# column this deployment adds is listed - the other declared additive columns
# already exist in the live database and were added by earlier revisions.
BASELINE_MUST_PREDATE: tuple[tuple[str, str], ...] = (
    ("timetable_entries", "is_free_period"),
)

# Tables this migration never reads. They are created by the backend for other
# features (announcements, push tokens, in-app notifications, assignment
# attachments) and the seeder must not touch them, so neither must this script.
# They are listed so the tests' "every table is classified" guard keeps failing
# loudly when a new model appears without a deliberate decision.
UNRELATED_TABLES = (
    "announcements",
    "assignment_attachments",
    "fcm_tokens",
    "notifications",
    "class_roster",
)

# Rows in these tables must survive exactly: no deletion, no insertion, no edit.
PRESERVED_TABLES = (
    "students",
    "teachers",
    "assignments",
    "teacher_assignments",
    "attendance_records",
    "free_period_claims",
)

# Official-data tables. Rows may be INSERTED in any of them; only these
# existing-row edits are ever allowed, and only in faculty_directory:
#   * a BLANK full_name  -> a non-blank value   (the sheet confirms the name)
#   * a BLANK role_note  -> a non-blank value
#   * is_verified        0 -> 1                (the sheet confirms the row)
# subjects and lab_directory existing rows must not change at all - the seeder
# only ever inserts into them. Nothing may ever be cleared or overwritten, and
# no official row may be deleted.
OFFICIAL_TABLES = ("subjects", "faculty_directory", "lab_directory")
FACULTY_FILL_COLUMNS = ("full_name", "role_note")
FACULTY_VERIFY_COLUMN = "is_verified"


def is_blank(value: Any) -> bool:
    """True for the values the seeder treats as 'not filled in yet'."""
    if value is None:
        return True
    return isinstance(value, str) and value.strip() == ""


def faculty_change_allowed(column: str, old_value: Any, new_value: Any) -> bool:
    """The only two edits the seeder makes to an existing faculty row."""
    if column in FACULTY_FILL_COLUMNS:
        return is_blank(old_value) and not is_blank(new_value)
    if column == FACULTY_VERIFY_COLUMN:
        return old_value in (0, False) and new_value in (1, True)
    return False


def official_change_allowed(table: str, column: str, old_value: Any, new_value: Any) -> bool:
    """Per-table gate for an existing official row (inserts are handled apart)."""
    if table == "faculty_directory":
        return faculty_change_allowed(column, old_value, new_value)
    return False


def format_value(column: str, value: Any) -> str:
    """A message-safe rendering of one value. Secrets never leave this function."""
    if column in REDACTED_COLUMNS:
        return REDACTED_TEXT
    return repr(value)


# ---------------------------------------------------------------------------
# Reading a database - raw sqlite3, read-only, no ORM
# ---------------------------------------------------------------------------

SQLITE_MAGIC = b"SQLite format 3\x00"


class SnapshotError(RuntimeError):
    """The file cannot be used as a snapshot (missing, empty, foreign, locked)."""


def open_readonly(path: Path) -> sqlite3.Connection:
    """Open a SQLite file read-only through a URI, so a write is impossible."""
    if not path.exists():
        raise SnapshotError(f"file not found: {path}")
    if path.is_dir():
        raise SnapshotError(f"not a file: {path}")

    size = path.stat().st_size
    if size == 0:
        raise SnapshotError(f"the file is empty (0 bytes): {path}")

    with path.open("rb") as handle:
        header = handle.read(len(SQLITE_MAGIC))
    if header != SQLITE_MAGIC:
        raise SnapshotError(f"not a SQLite database (bad header): {path}")

    # as_uri() percent-encodes '?', '#' and spaces, so the URI stays valid even
    # for awkward paths; it requires an absolute path, which the caller ensures.
    try:
        uri = f"{path.as_uri()}?mode=ro"
    except ValueError as exc:
        raise SnapshotError(f"cannot build a file URI for {path}: {exc}") from exc

    try:
        return sqlite3.connect(uri, uri=True)
    except sqlite3.Error as exc:
        raise SnapshotError(f"cannot open {path} read-only: {exc}") from exc


def list_tables(connection: sqlite3.Connection) -> list[str]:
    """Every user table in the file, in a stable order."""
    return sorted(
        row[0]
        for row in connection.execute(
            "SELECT name FROM sqlite_master WHERE type = 'table' "
            "AND name NOT LIKE 'sqlite_%'"
        )
    )


def table_columns(connection: sqlite3.Connection, table: str) -> list[str]:
    """Column names of one table, in declared order."""
    return [row[1] for row in connection.execute(f'PRAGMA table_info("{table}")')]


def row_key(columns: list[str], record: dict[str, Any]) -> Any:
    """The identity of a row: its ``id`` when it has one, else all its values."""
    if "id" in columns:
        return record["id"]
    return tuple(record[column] for column in columns)


def row_label(columns: list[str], record: dict[str, Any]) -> str:
    """A message-safe label for a row (secrets censored even in the fallback)."""
    if "id" in columns:
        return f"id={record.get('id')}"
    parts = ", ".join(f"{c}={format_value(c, record.get(c))}" for c in columns)
    return f"({parts})"


def read_table(
    connection: sqlite3.Connection, table: str, columns: list[str]
) -> dict[Any, dict[str, Any]]:
    """One table as ``{row key: {column: value, ...}}``."""
    if not columns:
        return {}
    quoted = ", ".join(f'"{column}"' for column in columns)
    rows: dict[Any, dict[str, Any]] = {}
    for raw in connection.execute(f'SELECT {quoted} FROM "{table}"'):
        record = dict(zip(columns, raw))
        rows[row_key(columns, record)] = record
    return rows


def snapshot(path: Path) -> dict[str, dict[str, Any]]:
    """One database as ``{table: {"columns": [...], "rows": {...}}}``."""
    connection = open_readonly(path)
    try:
        tables: dict[str, dict[str, Any]] = {}
        for table in list_tables(connection):
            columns = table_columns(connection, table)
            tables[table] = {
                "columns": columns,
                "rows": read_table(connection, table, columns),
            }
        return tables
    except sqlite3.Error as exc:
        detail = str(exc)
        code = getattr(exc, "sqlite_errorcode", None)
        hint = ""
        if "readonly" in detail.lower() or "unable to open" in detail.lower():
            hint = (
                " - the file may need journal/WAL recovery, which read-only mode "
                "cannot perform; stop the writer and copy the file, then compare "
                "the copy."
            )
        raise SnapshotError(
            f"cannot read {path}: {detail}"
            + (f" (sqlite code {code})" if code is not None else "")
            + hint
        ) from exc
    finally:
        connection.close()


# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------


class Report:
    """Collects named checks so the run ends in a pass/fail summary."""

    def __init__(self) -> None:
        self.checks: list[tuple[str, tuple[str, ...]]] = []
        self.notes: list[str] = []

    def check(self, title: str, problems: list[str]) -> None:
        self.checks.append((title, tuple(problems)))

    def note(self, text: str) -> None:
        """An informational line rendered after the checks (never a secret)."""
        self.notes.append(text)

    @property
    def failed(self) -> bool:
        return any(problems for _title, problems in self.checks)

    def render(self) -> str:
        lines: list[str] = []
        for title, problems in self.checks:
            if problems:
                lines.append(f"FAIL  {title}")
                for problem in problems:
                    lines.append(f"        - {problem}")
            else:
                lines.append(f"PASS  {title}")
        passed = sum(1 for _title, problems in self.checks if not problems)
        failed = len(self.checks) - passed
        for text in self.notes:
            lines.append(f"note  {text}")
        lines.append("")
        lines.append(f"{len(self.checks)} checks: {passed} passed, {failed} failed")
        return "\n".join(lines)


# ---------------------------------------------------------------------------
# Row-level comparison
# ---------------------------------------------------------------------------


def differing_columns(
    columns: list[str], before_row: dict[str, Any], after_row: dict[str, Any]
) -> list[str]:
    """Columns whose values change between the two rows (sentinels included)."""
    return sorted(
        column
        for column in columns
        if before_row.get(column, ABSENT) != after_row.get(column, ABSENT)
    )


def compare_row_fields(
    table: str,
    label: str,
    before_columns: list[str],
    after_columns: list[str],
    before_row: dict[str, Any],
    after_row: dict[str, Any],
    approved: dict[str, tuple[Any, Any]],
    change_allowed: Callable[[str, Any, Any], bool] | None = None,
) -> list[str]:
    """Every field of one row must match the plan, or be unchanged."""
    problems: list[str] = []
    columns = sorted(set(before_columns) | set(after_columns))

    for field in sorted(approved):
        if field not in columns:
            problems.append(
                f"{table} {label}: the plan approves {field!r}, "
                "but no such column exists in either snapshot"
            )

    for column in columns:
        before_value = before_row.get(column, ABSENT)
        after_value = after_row.get(column, ABSENT)

        if column in approved:
            expected_old, expected_new = approved[column]
            if before_value != expected_old:
                problems.append(
                    f"{table} {label}.{column}: before is "
                    f"{format_value(column, before_value)}, "
                    f"the plan expects {format_value(column, expected_old)}"
                )
            if after_value != expected_new:
                problems.append(
                    f"{table} {label}.{column}: after is "
                    f"{format_value(column, after_value)}, "
                    f"the plan expects {format_value(column, expected_new)}"
                )
            continue

        if (table, column) in APPROVED_NEW_COLUMNS:
            if before_value is ABSENT:
                # The column was created by this migration: every row it was
                # added to must hold the declared default.
                expected_new = APPROVED_NEW_COLUMNS[(table, column)]
                if after_value != expected_new:
                    problems.append(
                        f"{table} {label}.{column}: the new column holds "
                        f"{format_value(column, after_value)}, its declared "
                        f"default is {format_value(column, expected_new)}"
                    )
            else:
                # The column already existed before the baseline (an earlier
                # revision added it), so it is just an ordinary column that this
                # migration must not touch.
                if before_value != after_value and not (
                    change_allowed and change_allowed(column, before_value, after_value)
                ):
                    if column in REDACTED_COLUMNS:
                        problems.append(
                            f"{table} {label}.{column}: value changed {REDACTED_TEXT}"
                        )
                    else:
                        problems.append(
                            f"{table} {label}.{column}: "
                            f"{format_value(column, before_value)} -> "
                            f"{format_value(column, after_value)} "
                            "(not an approved change)"
                        )
            continue

        if before_value != after_value:
            allowed = change_allowed is not None and change_allowed(
                column, before_value, after_value
            )
            if not allowed:
                if column in REDACTED_COLUMNS:
                    problems.append(
                        f"{table} {label}.{column}: value changed {REDACTED_TEXT}"
                    )
                else:
                    problems.append(
                        f"{table} {label}.{column}: "
                        f"{format_value(column, before_value)} -> "
                        f"{format_value(column, after_value)} "
                        "(not an approved change)"
                    )

    return problems


def check_baseline(before: dict[str, dict[str, Any]]) -> list[str]:
    """Operating requirement 1, enforced before anything is compared."""
    problems: list[str] = []
    for table, column in BASELINE_MUST_PREDATE:
        if table in before and column in before[table]["columns"]:
            problems.append(
                f"{table}.{column} is already present in the baseline"
            )
    return problems


def compare_schema(
    before: dict[str, dict[str, Any]], after: dict[str, dict[str, Any]], report: Report
) -> None:
    """Tables may not appear or disappear; columns may only be the declared ones."""
    before_tables = set(before)
    after_tables = set(after)

    removed = sorted(before_tables - after_tables)
    created = sorted(after_tables - before_tables)
    report.check(
        f"schema: table set unchanged ({len(before_tables)} tables in the baseline)",
        [f"table removed: {name}" for name in removed]
        + [f"unexpected new table: {name}" for name in created],
    )

    dropped_problems: list[str] = []
    added_problems: list[str] = []
    for table in sorted(before_tables & after_tables):
        before_columns = before[table]["columns"]
        after_columns = after[table]["columns"]
        for column in before_columns:
            if column not in after_columns:
                dropped_problems.append(f"{table}.{column} was dropped")
        for column in after_columns:
            if column in before_columns:
                continue
            if (table, column) in APPROVED_NEW_COLUMNS:
                continue
            added_problems.append(f"{table}.{column} was added but is not declared")

    report.check("schema: no column dropped", dropped_problems)
    report.check("schema: added columns are exactly the declared ones", added_problems)

    missing_declared = [
        f"{table}.{column} is created by this migration but is NOT present afterwards"
        for table, column in sorted(BASELINE_MUST_PREDATE)
        if table in before and table in after and column not in after[table]["columns"]
    ]
    report.check(
        "schema: the columns this migration creates are present afterwards",
        missing_declared,
    )


def compare_timetable(
    before: dict[str, dict[str, Any]],
    after: dict[str, dict[str, Any]],
    report: Report,
) -> None:
    """The nine approved rows, and only those, may differ - matched on ``id``."""
    table = TIMETABLE_TABLE
    if table not in before or table not in after:
        missing_from = "before" if table not in before else "after"
        report.check(
            f"timetable: {table} readable in both databases",
            [f"{table} is missing from the {missing_from} database"],
        )
        return

    before_rows = before[table]["rows"]
    after_rows = after[table]["rows"]
    before_ids = set(before_rows)
    after_ids = set(after_rows)

    report.check(
        "timetable: no row deleted",
        [f"row id={key} was deleted" for key in sorted(before_ids - after_ids)],
    )
    report.check(
        "timetable: no row inserted",
        [f"row id={key} was inserted" for key in sorted(after_ids - before_ids)],
    )
    report.check(
        f"timetable: row count is {EXPECTED_TIMETABLE_ROWS}",
        []
        if len(after_rows) == EXPECTED_TIMETABLE_ROWS
        else [f"found {len(after_rows)} rows, expected {EXPECTED_TIMETABLE_ROWS}"],
    )

    identity_problems: list[str] = []
    for key, identity in sorted(APPROVED_ROW_IDENTITY.items()):
        for side, rows in (("before", before_rows), ("after", after_rows)):
            row = rows.get(key)
            if row is None:
                identity_problems.append(f"row id={key} is missing from the {side} database")
                continue
            actual = tuple(row.get(field) for field in IDENTITY_FIELDS)
            if actual != identity:
                identity_problems.append(
                    f"row id={key} in the {side} database is {actual}, expected {identity}"
                )
    report.check(
        "timetable: the nine approved ids are the rows the plan names",
        identity_problems,
    )

    field_problems: list[str] = []
    for key in sorted(before_ids & after_ids):
        field_problems.extend(
            compare_row_fields(
                table,
                row_label(before[table]["columns"], before_rows[key]),
                before[table]["columns"],
                after[table]["columns"],
                before_rows[key],
                after_rows[key],
                APPROVED_TIMETABLE_CHANGES.get(key, {}),
            )
        )
    report.check(
        "timetable: approved fields exact, every other field unchanged "
        f"({len(APPROVED_TIMETABLE_CHANGES)} approved rows, "
        f"{len(before_ids & after_ids)} rows compared)",
        field_problems,
    )

    missing_approved = [
        f"approved row id={key} does not exist after the migration"
        for key in sorted(APPROVED_TIMETABLE_CHANGES)
        if key not in after_ids
    ]
    report.check("timetable: every approved row still exists", missing_approved)


def compare_preserved(
    before: dict[str, dict[str, Any]], after: dict[str, dict[str, Any]], report: Report
) -> None:
    """students/teachers/assignments/attendance/claims: nothing may move."""
    problems: list[str] = []
    checked = 0
    for table in PRESERVED_TABLES:
        if table not in before or table not in after:
            missing_from = "before" if table not in before else "after"
            problems.append(f"{table} is missing from the {missing_from} database")
            continue
        before_rows = before[table]["rows"]
        after_rows = after[table]["rows"]
        before_ids = set(before_rows)
        after_ids = set(after_rows)
        columns = sorted(set(before[table]["columns"]) | set(after[table]["columns"]))
        for key in sorted(before_ids - after_ids):
            problems.append(f"{table} id={key} was deleted")
        for key in sorted(after_ids - before_ids):
            problems.append(f"{table} id={key} was inserted")
        for key in sorted(before_ids & after_ids):
            checked += 1
            row_problems = compare_row_fields(
                table,
                row_label(before[table]["columns"], before_rows[key]),
                before[table]["columns"],
                after[table]["columns"],
                before_rows[key],
                after_rows[key],
                {},
            )
            if row_problems and table == "teachers":
                changed = differing_columns(columns, before_rows[key], after_rows[key])
                if changed and set(changed) <= SESSION_COLUMNS:
                    row_problems.append(
                        f"{table} id={key}: only session columns changed - the backend "
                        "was still running while this comparison ran. Stop it before "
                        "migrating (see OPERATING REQUIREMENTS 2)."
                    )
            problems.extend(row_problems)
    report.check(
        f"records: {len(PRESERVED_TABLES)} account/record tables untouched "
        f"({checked} rows compared)",
        problems,
    )


def compare_official(
    before: dict[str, dict[str, Any]], after: dict[str, dict[str, Any]], report: Report
) -> None:
    """Official tables: inserts allowed, plus the seeder's exact existing-row edits."""
    problems: list[str] = []
    checked = 0
    for table in OFFICIAL_TABLES:
        if table not in before or table not in after:
            missing_from = "before" if table not in before else "after"
            problems.append(f"{table} is missing from the {missing_from} database")
            continue
        before_rows = before[table]["rows"]
        after_rows = after[table]["rows"]
        before_ids = set(before_rows)
        after_ids = set(after_rows)
        for key in sorted(before_ids - after_ids):
            problems.append(f"{table} id={key} was deleted")
        inserted = sorted(after_ids - before_ids)
        for key in sorted(before_ids & after_ids):
            checked += 1
            problems.extend(
                compare_row_fields(
                    table,
                    row_label(before[table]["columns"], before_rows[key]),
                    before[table]["columns"],
                    after[table]["columns"],
                    before_rows[key],
                    after_rows[key],
                    {},
                    change_allowed=lambda column, old, new, _table=table: official_change_allowed(
                        _table, column, old, new
                    ),
                )
            )
        if inserted:
            allowed_note = (
                "inserts allowed, plus the documented blank-fill"
                if table == "faculty_directory"
                else "inserts allowed (existing rows must be identical)"
            )
            report.note(
                f"{table}: {len(inserted)} row(s) inserted - {allowed_note}"
            )
    report.check(
        f"official data: {len(OFFICIAL_TABLES)} tables - inserts only, plus the "
        f"documented faculty blank-fill ({checked} existing rows compared)",
        problems,
    )


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------


def parse_args(argv: list[str] | None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Compare the pre-migration baseline with the migrated database and "
            "prove only the nine approved timetable rows changed."
        )
    )
    parser.add_argument(
        "--before",
        required=True,
        type=Path,
        help="baseline file, captured BEFORE the additive schema step",
    )
    parser.add_argument(
        "--after", required=True, type=Path, help="post-migration database file"
    )
    return parser.parse_args(argv)


def run(args: argparse.Namespace) -> int:
    before = snapshot(args.before.resolve())
    after = snapshot(args.after.resolve())

    baseline_problems = check_baseline(before)
    if baseline_problems:
        print("ERROR - the baseline postdates the additive schema step:")
        for problem in baseline_problems:
            print(f"  - {problem}")
        print(
            "\nCapture --before BEFORE `seed_official_data.py --apply` adds the\n"
            "column (see the deployment order in AGENTS.md), then re-run.\n"
            "Nothing was compared."
        )
        return 2

    report = Report()
    compare_schema(before, after, report)
    compare_timetable(before, after, report)
    compare_preserved(before, after, report)
    compare_official(before, after, report)

    if not report.checks:
        print("ERROR - no checks ran; refusing to report success.")
        return 2

    print("CampusSync official-data migration comparison")
    print(f"  before : {args.before}")
    print(f"  after  : {args.after}")
    print("")
    print(report.render())

    if report.failed:
        print("\nMISMATCH - the migration did not do exactly the approved change.")
        return 1

    print("\nOK - the migration changed exactly the nine approved rows.")
    return 0


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    try:
        return run(args)
    except SnapshotError as exc:
        print(f"ERROR - {exc}")
        return 2
    except (sqlite3.Error, OSError, ValueError) as exc:
        print(f"ERROR - {type(exc).__name__}: {exc}")
        return 2
    except Exception as exc:
        # Deliberate catch-all: an unexpected crash must never be reported as a
        # data mismatch (exit 1) or, worse, as a pass. The traceback still goes
        # to stderr so the cause is visible.
        print(f"ERROR - unexpected failure: {type(exc).__name__}: {exc}")
        traceback.print_exc(file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
