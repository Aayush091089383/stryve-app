#!/usr/bin/env python
"""
Rehearse the CampusSync official-data migration on disposable copies.

WHAT IT PROVES
--------------
``verify_official_data_migration.py`` answers "did this migration change exactly
the nine approved rows?". This script answers the question before it: "would the
reviewed plan still behave correctly against a copy of the live database?" It
does that by replaying the deployment on throwaway copies and then deliberately
trying to break it:

* the live database is snapshotted READ-ONLY with SQLite's online backup API
  (never a raw file copy, which can tear while a writer is active);
* the seeder is run on that copy - never on the live file - to produce the
  pre/post pair the verifier compares;
* control (a) proves the clean migration passes;
* controls (b)-(f) inject one unapproved change each into their OWN ``n-*.db``
  copy, and every one of them must be caught by the verifier;
* each injection is proved to have landed (read-after-write), so a control can
  never "pass" because its UPDATE matched no rows;
* each control compares the verifier's COMPLETE set of failing checks - titles
  and problem lines, in order - not just the exit code, so a verifier that
  missed the change, or that reported an extra unrelated failure, is caught;
* the live database's SHA-256, size and mtime are re-checked at the end.

LIMITATION: SHA-256/SIZE/MTIME CHECK
------------------------------------
The final SHA-256/size/mtime comparison CANNOT rule out a temporary modification
followed by restoration during the rehearsal execution. The check only proves
the file is byte-identical before and after the script runs. A concurrent writer
that modifies and restores the database between the initial snapshot and the
final check would not be detected by this comparison alone. This is why the
preflight writer detection (sidecar files, process scan, listener enumeration)
is the primary safety mechanism - it must establish NO writer is running BEFORE
the rehearsal begins.

SAFETY
------
This script has no flags and no live mode. It refuses to start (exit 3) rather
than guess:

* if a database writer is detected (a ``-wal``/``-journal``/``-shm`` sidecar,
  a process listening on the backend port, or a running ``uvicorn main:app``) -
  see OPERATING REQUIREMENTS 2 in the verifier's docstring. There is no override;
* if the baseline already has ``timetable_entries.is_free_period`` (it would
  postdate the additive step, so the column creation could not be proved);
* if the approved plan is already fully applied (nothing left to rehearse);
* if ADEQUATE evidence cannot be established that the backend is stopped.
  Adequate evidence requires at least one of:
  (A) listener enumeration (netstat/Get-NetTCPConnection) succeeds and finds
      no listeners on ANY local interface (including 0.0.0.0, [::], LAN IPs), OR
  (B) process scan (wmic) succeeds and finds no uvicorn/main:app process
      AND the configured port has no listener on 127.0.0.1.

The live file is opened read-only and is never written, copied over, locked for
writing, or renamed. No process is started, stopped or signalled.

USAGE
-----
    <repo>/backend/venv/Scripts/python.exe <repo>/backend/rehearse_official_data_migration.py

It takes no arguments; anything passed is a usage error (exit 2).

EXIT CODES
----------
    0  REHEARSAL COMPLETE - every control matched, nothing was skipped
    1  a control did not match, or the live database changed during the run
    2  usage/internal error (no result can be claimed)
    3  REFUSED - a precondition failed; nothing was rehearsed
    4  an injection did not land - the control would have been vacuous
    5  REHEARSAL INCOMPLETE - at least one control was skipped
"""

from __future__ import annotations

import hashlib
import os
import re
import shutil
import socket
import sqlite3
import subprocess
import sys
import tempfile
from dataclasses import dataclass, field
from pathlib import Path

BACKEND_DIR = Path(__file__).resolve().parent
if str(BACKEND_DIR) not in sys.path:
    sys.path.insert(0, str(BACKEND_DIR))

import verify_official_data_migration as verifier  # noqa: E402

PYTHON = sys.executable
SEEDER = BACKEND_DIR / "seed_official_data.py"
VERIFIER = BACKEND_DIR / "verify_official_data_migration.py"

# The backend's port (AGENTS.md). Only used to detect a running backend; the
# rehearsal itself never needs the network.
BACKEND_PORT = int(os.environ.get("CAMPUSSYNC_BACKEND_PORT", "8000"))

# --- exit codes (see the docstring) -----------------------------------------
EXIT_OK = 0
EXIT_MISMATCH = 1
EXIT_USAGE = 2
EXIT_REFUSED = 3
EXIT_NOT_LANDED = 4
EXIT_INCOMPLETE = 5

# --- the control set --------------------------------------------------------
CONTROL_LETTERS = ("a", "b", "c", "d", "e", "f")

# The only file names a negative test may ever write to, and the two disposable
# templates it may never write to. The synthetic suite drift-checks these names.
SCRATCH_NAME = re.compile(r"^n-\d+\.db$")
TEMPLATE_NAMES = ("before.db", "after.db")

# Sidecar files that only exist while a writer holds the database open.
SIDECAR_SUFFIXES = ("-wal", "-journal", "-shm")

# The fake values used by control (b). They are never real credentials, and the
# values themselves are never printed - only that the columns changed.
DRIFT_TOKEN = "rehearsal-not-a-real-token"
DRIFT_EXPIRY = "2031-01-01 00:00:00"

# The value control (c) writes over an approved field it is not allowed to touch.
UNAPPROVED_FAULT_VALUE = "XYZ-not-the-plan"
# The value control (d) writes where the plan expects something else.
WRONG_NEW_VALUE = "ZZZ-not-the-plan"

# The column control (f) removes. It is one of the columns the plan never
# approves a change to, so removing it must be caught twice: by the schema check
# and by the row-by-row field comparison.
DROPPED_COLUMN = "room"

# ---------------------------------------------------------------------------
# Every verifier message this script matches against, in ONE place, so the
# synthetic suite can prove each template still exists in the verifier's source
# (test_official_data_migration_verifier.py, "rehearsal templates" section).
# ``{...}`` marks a value the script fills in at run time.
# ---------------------------------------------------------------------------
EXPECTED_TEMPLATES: dict[str, str] = {
    "title.schema_table_set": "schema: table set unchanged ({tables} tables in the baseline)",
    "title.schema_no_column_dropped": "schema: no column dropped",
    "title.schema_added_columns": "schema: added columns are exactly the declared ones",
    "title.schema_created_present": (
        "schema: the columns this migration creates are present afterwards"
    ),
    "title.timetable_row_count": "timetable: row count is {expected}",
    "title.timetable_no_row_deleted": "timetable: no row deleted",
    "title.timetable_no_row_inserted": "timetable: no row inserted",
    "title.timetable_identities": (
        "timetable: the nine approved ids are the rows the plan names"
    ),
    "title.timetable_fields": (
        "timetable: approved fields exact, every other field unchanged "
        "({approved} approved rows, {compared} rows compared)"
    ),
    "title.timetable_approved_present": "timetable: every approved row still exists",
    "title.records_untouched": (
        "records: {tables} account/record tables untouched ({checked} rows compared)"
    ),
    "title.official_data": (
        "official data: {tables} tables - inserts only, plus the documented "
        "faculty blank-fill ({checked} existing rows compared)"
    ),
    "msg.column_dropped": "{table}.{column} was dropped",
    "msg.column_undeclared": "{table}.{column} was added but is not declared",
    "msg.created_missing": (
        "{table}.{column} is created by this migration but is NOT present afterwards"
    ),
    "msg.row_deleted": "row id={key} was deleted",
    "msg.row_inserted": "row id={key} was inserted",
    "msg.row_count": "found {found} rows, expected {expected}",
    "msg.identity_missing": "row id={key} is missing from the {side} database",
    "msg.identity_mismatch": (
        "row id={key} in the {side} database is {actual}, expected {identity}"
    ),
    "msg.approved_row_missing": "approved row id={key} does not exist after the migration",
    "msg.approved_field_missing": (
        "{table} {label}: the plan approves {field}, but no such column exists "
        "in either snapshot"
    ),
    "msg.redacted_change": "{table} {label}.{column}: value changed {redacted}",
    "msg.unapproved_change": (
        "{table} {label}.{column}: {before} -> {after} (not an approved change)"
    ),
    "msg.wrong_old_value": (
        "{table} {label}.{column}: before is {before}, the plan expects {expected}"
    ),
    "msg.wrong_new_value": (
        "{table} {label}.{column}: after is {after}, the plan expects {expected}"
    ),
    "msg.created_default": (
        "{table} {label}.{column}: the new column holds {after}, its declared "
        "default is {expected}"
    ),
    "msg.session_drift_hint": (
        "{table} id={key}: only session columns changed - the backend was still "
        "running while this comparison ran. Stop it before migrating "
        "(see OPERATING REQUIREMENTS 2)."
    ),
    "msg.table_removed": "table removed: {name}",
    "msg.unexpected_table": "unexpected new table: {name}",
    "msg.ok": "OK - the migration changed exactly the nine approved rows.",
    "msg.mismatch": "MISMATCH - the migration did not do exactly the approved change.",
}

TEMPLATE = EXPECTED_TEMPLATES


class Refused(RuntimeError):
    """A precondition failed. Nothing was rehearsed (exit 3)."""


# ---------------------------------------------------------------------------
# Small filesystem / database helpers
# ---------------------------------------------------------------------------


def sha256_of(path: Path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(65536), b""):
            digest.update(chunk)
    return digest.hexdigest()


def stamp_of(path: Path):
    if not path.exists():
        return None
    stat = path.stat()
    return (stat.st_size, stat.st_mtime_ns)


def render(column: str, value) -> str:
    """How the verifier prints one value (independent of its own helper).

    Redacted columns are never rendered; the comparison still uses them.
    """
    if column in verifier.REDACTED_COLUMNS:
        return verifier.REDACTED_TEXT
    return repr(value)


def label_of(row) -> str:
    """The verifier labels a row ``id=<n>`` whenever the table has an id."""
    return f"id={row}"


def live_database_path() -> Path:
    """The same absolute path the backend and the seeder resolve."""
    from database import resolve_database_path  # imported late: keeps this module import-light

    path = resolve_database_path()
    if path is None:
        raise Refused("DATABASE_URL points at an in-memory database; there is nothing to rehearse.")
    return Path(path).resolve()


# ---------------------------------------------------------------------------
# Scratch guards - the reason a negative test cannot reach the live file
# ---------------------------------------------------------------------------


def assert_inside_scratch(path: Path, root: Path) -> Path:
    """A write target must be inside the rehearsal directory and never the live file."""
    resolved = Path(path).resolve()
    if resolved == live_database_path():
        raise Refused(f"refusing to write to the LIVE database: {resolved}")
    if root.resolve() not in resolved.parents:
        raise Refused(f"refusing to write outside the rehearsal directory: {resolved}")
    return resolved


def scratch_path(root: Path, index: int) -> Path:
    """The ONE name a negative test may write to: ``n-<index>.db`` inside root."""
    candidate = Path(root) / f"n-{index}.db"
    if not SCRATCH_NAME.match(candidate.name):
        raise Refused(f"negative-test scratch file must be n-*.db: {candidate.name}")
    return assert_inside_scratch(candidate, root)


def assert_template(path: Path, root: Path) -> Path:
    """A template is a disposable copy this script owns; it is never an injection target."""
    resolved = assert_inside_scratch(path, root)
    if resolved.name not in TEMPLATE_NAMES:
        raise Refused(f"expected a disposable template ({', '.join(TEMPLATE_NAMES)}): {resolved.name}")
    return resolved


# ---------------------------------------------------------------------------
# Preflight: who is holding the live database?
# ---------------------------------------------------------------------------


def sidecar_evidence(live: Path) -> list[str]:
    return [
        f"{live.name}{suffix} exists - a database writer is (or was) active"
        for suffix in SIDECAR_SUFFIXES
        if Path(str(live) + suffix).exists()
    ]


def port_evidence(port: int) -> list[str]:
    """A listener on the backend port means the backend process is up."""
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=0.5):
            return [f"something is listening on 127.0.0.1:{port} - the backend looks running"]
    except OSError:
        return []


def listener_evidence() -> tuple[list[str], str]:
    """
    Enumerate ALL listening TCP ports on all local interfaces using netstat/Get-NetTCPConnection.
    Returns (evidence_list, note). Evidence includes any listener on 0.0.0.0, [::],
    127.0.0.1, [::1], or other local addresses. A backend bound to 0.0.0.0 (all
    interfaces) or a non-loopback local address is a writer we must detect.
    Note explains if the probe was unavailable or if the scan was incomplete
    (e.g., only loopback was checked).
    """
    evidence: list[str] = []
    note = ""
    incomplete = False

    # Try netstat first (available on all supported Windows versions)
    try:
        result = subprocess.run(
            ["netstat", "-ano"],
            capture_output=True,
            text=True,
            timeout=10,
        )
        if result.returncode == 0 and result.stdout.strip():
            for line in result.stdout.splitlines():
                if "LISTENING" not in line:
                    continue
                # Match any local address: 0.0.0.0, 127.0.0.1, [::], [::1], or specific local IPs
                # netstat format: Proto LocalAddress ForeignAddress State PID
                # LocalAddress examples: 0.0.0.0:8000, 127.0.0.1:8000, [::]:8000, [::1]:8000, 192.168.1.5:8000
                # No word boundary (\b) because square brackets are not word characters
                if re.search(r"(?:0\.0\.0\.0|127\.0\.0\.1|\[::\]|\[::1\]|\d+\.\d+\.\d+\.\d+):\d+", line):
                    evidence.append(f"netstat shows a listener: {line.strip()}")
            # If we got here, netstat succeeded. But we only know about listeners on addresses netstat shows.
            # netstat -ano shows all interfaces, so this is complete for TCP listeners.
            return evidence, note
    except (OSError, subprocess.SubprocessError):
        pass

    # Fallback: PowerShell Get-NetTCPConnection (Windows 8.1+/Server 2012 R2+)
    # Query ALL local addresses, not just loopback. A backend on 0.0.0.0 or a LAN IP is a writer.
    try:
        result = subprocess.run(
            [
                "powershell",
                "-NoProfile",
                "-Command",
                "Get-NetTCPConnection -State Listen | "
                "Select-Object LocalAddress,LocalPort,OwningProcess | "
                "Format-Table -AutoSize -HideTableHeaders",
            ],
            capture_output=True,
            text=True,
            timeout=15,
        )
        if result.returncode == 0 and result.stdout.strip():
            for line in result.stdout.splitlines():
                line = line.strip()
                if line and not line.startswith("LocalAddress"):
                    evidence.append(f"Get-NetTCPConnection shows a listener: {line}")
            return evidence, note
    except (OSError, subprocess.SubprocessError):
        pass

    # Both probes failed
    note = "listener enumeration unavailable (netstat and Get-NetTCPConnection both failed)"
    return evidence, note


def process_evidence() -> tuple[list[str], str]:
    """Best-effort, read-only process scan. Never signals anything.

    ``uvicorn.exe`` is detected by name. A backend started as
    ``python -m uvicorn main:app`` is only visible by its command line, which
    Windows exposes through ``wmic``; when that is unavailable the scan returns a
    NOTE instead of guessing, and the port + sidecar probes remain the evidence.
    A missing tool must never be treated as a detected writer.
    """
    evidence: list[str] = []
    note = ""
    try:
        listing = subprocess.run(
            ["tasklist", "/FO", "CSV", "/NH"],
            capture_output=True,
            text=True,
            timeout=20,
        )
    except (OSError, subprocess.SubprocessError):
        listing = None

    if listing is None or listing.returncode != 0:
        note = "process scan unavailable: neither process names nor command lines could be read"
        return evidence, note

    names = set()
    for line in listing.stdout.splitlines():
        fields = [part.strip('"') for part in line.split('","')]
        if fields and fields[0]:
            names.add(fields[0].lower())
    if "uvicorn.exe" in names:
        evidence.append("a uvicorn.exe process is running")

    try:
        detail = subprocess.run(
            ["wmic", "process", "get", "ProcessId,CommandLine", "/format:csv"],
            capture_output=True,
            text=True,
            timeout=30,
        )
    except (OSError, subprocess.SubprocessError):
        detail = None

    if detail is None or detail.returncode != 0 or not detail.stdout.strip():
        note = (
            "command lines are unavailable on this host, so a backend started as "
            "'python -m uvicorn main:app' is only detected by its port"
        )
        return evidence, note

    for line in detail.stdout.splitlines():
        lowered = line.lower()
        if "uvicorn" in lowered or "main:app" in lowered:
            evidence.append("a process whose command line runs uvicorn main:app is present")
            break
    return evidence, note


def check_live_writer(live: Path) -> tuple[list[str], list[str]]:
    """Every detected writer is a refusal. There is deliberately no override.

    Fail-closed: we require ADEQUATE evidence that no backend writer exists.
    Adequate evidence means at least ONE of:
      (A) listener_evidence succeeds (netstat or Get-NetTCPConnection works)
          and finds NO listeners on any local interface, OR
      (B) process_evidence succeeds (wmic works) and finds no uvicorn/main:app
          AND port_evidence on the configured port finds nothing.
    If neither (A) nor (B) can be confirmed, we refuse with exit 3.

    Sidecar evidence is always checked and any finding is immediate refusal.
    """
    # Sidecar evidence is always definitive - if present, writer exists.
    sidecar = sidecar_evidence(live)
    if sidecar:
        return sidecar, ["sidecar files indicate active database writer"]

    # Port evidence on configured port (targeted check)
    port_findings = port_evidence(BACKEND_PORT)

    # Process evidence (tasklist + wmic)
    process_findings, process_note = process_evidence()

    # Listener enumeration (netstat + Get-NetTCPConnection) - checks ALL interfaces/ports
    listener_findings, listener_note = listener_evidence()

    evidence = sidecar + port_findings + process_findings + listener_findings
    notes = []

    if process_note:
        notes.append(f"process probe: {process_note}")
    if listener_note:
        notes.append(f"listener probe: {listener_note}")

    # Determine if we have adequate evidence that no writer exists.
    # Adequate = (listener probe succeeded AND found nothing) OR
    #            (process probe succeeded (wmic worked) AND found nothing AND port probe found nothing)
    listener_succeeded = not listener_note  # no note = probe worked
    listener_clean = listener_succeeded and not listener_findings

    wmic_succeeded = "command lines are unavailable" not in process_note
    process_clean = wmic_succeeded and not process_findings
    port_clean = not port_findings

    adequate_evidence = listener_clean or (process_clean and port_clean)

    if not adequate_evidence:
        reasons = []
        if not listener_succeeded:
            reasons.append("listener enumeration unavailable")
        elif listener_findings:
            reasons.append("listener(s) detected")
        if not wmic_succeeded:
            reasons.append("wmic unavailable (cannot verify process command lines)")
        elif process_findings:
            reasons.append("uvicorn/main:app process detected")
        if not port_clean:
            reasons.append(f"listener on configured port {BACKEND_PORT}")

        notes.append(
            "cannot establish backend stopped: " + "; ".join(reasons)
        )

    return evidence, notes


def read_only_probe(live: Path) -> None:
    """Open read-only and run quick_check - the only way we touch the live file."""
    connection = verifier.open_readonly(live)  # raises SnapshotError for bad input
    try:
        result = connection.execute("PRAGMA quick_check").fetchone()
    finally:
        connection.close()
    if not result or result[0] != "ok":
        raise Refused(
            "PRAGMA quick_check did not return ok "
            f"({result[0] if result else 'no result'}) - repair the file before rehearsing"
        )


def snapshot_live(source: Path, target: Path) -> None:
    """Snapshot with the online backup API: safe even while a reader is attached."""
    src = verifier.open_readonly(source)
    try:
        destination = sqlite3.connect(target)
        try:
            src.backup(destination)
        finally:
            destination.close()
    finally:
        src.close()


def read_snapshot(path: Path) -> dict:
    return verifier.snapshot(path)


def pending_plan_changes(before: dict) -> tuple[list[str], list[str], list[str]]:
    """What the plan still has to do, what is done, and what disagrees.

    Returns ``(pending, already_applied, divergent)``. All three are descriptions
    only - no value from a redacted column is ever rendered.
    """
    timetable = before.get(verifier.TIMETABLE_TABLE)
    if timetable is None:
        raise Refused(f"{verifier.TIMETABLE_TABLE} is missing from the live database")
    rows = timetable["rows"]
    columns = timetable["columns"]

    pending: list[str] = []
    applied: list[str] = []
    divergent: list[str] = []
    for key, changes in sorted(verifier.APPROVED_TIMETABLE_CHANGES.items()):
        row = rows.get(key)
        if row is None:
            raise Refused(
                f"approved row id={key} is not in the live database; "
                "the plan and the database do not match - inspect before rehearsing"
            )
        for column, (expected_old, expected_new) in sorted(changes.items()):
            value = row.get(column, verifier.ABSENT)
            if expected_old is verifier.ABSENT or expected_old != expected_new:
                if value == expected_old:
                    pending.append(f"id={key}.{column}")
                elif value == expected_new:
                    applied.append(f"id={key}.{column}")
                else:
                    divergent.append(f"id={key}.{column}")

    for table, column in sorted(verifier.BASELINE_MUST_PREDATE):
        if table == verifier.TIMETABLE_TABLE and column not in columns:
            pending.append(f"{table}.{column} (column missing)")
    return pending, applied, divergent


# ---------------------------------------------------------------------------
# Counting the verifier's report, exactly as the verifier counts it
# ---------------------------------------------------------------------------


@dataclass
class Counts:
    tables: int
    expected_rows: int
    approved: int
    compared: int
    records_checked: int
    official_checked: int


def matching_rows(before: dict, after: dict, table: str) -> int:
    key = table
    if key not in before or key not in after:
        return 0
    return len(set(before[key]["rows"]) & set(after[key]["rows"]))


def count_report(before: dict, after: dict) -> Counts:
    return Counts(
        tables=len(before),
        expected_rows=verifier.EXPECTED_TIMETABLE_ROWS,
        approved=len(verifier.APPROVED_TIMETABLE_CHANGES),
        compared=matching_rows(before, after, verifier.TIMETABLE_TABLE),
        records_checked=sum(matching_rows(before, after, t) for t in verifier.PRESERVED_TABLES),
        official_checked=sum(matching_rows(before, after, t) for t in verifier.OFFICIAL_TABLES),
    )


def all_titles(counts: Counts) -> list[str]:
    """The twelve checks the verifier runs, in the order it renders them."""
    return [
        TEMPLATE["title.schema_table_set"].format(tables=counts.tables),
        TEMPLATE["title.schema_no_column_dropped"],
        TEMPLATE["title.schema_added_columns"],
        TEMPLATE["title.schema_created_present"],
        TEMPLATE["title.timetable_no_row_deleted"],
        TEMPLATE["title.timetable_no_row_inserted"],
        TEMPLATE["title.timetable_row_count"].format(expected=counts.expected_rows),
        TEMPLATE["title.timetable_identities"],
        TEMPLATE["title.timetable_fields"].format(
            approved=counts.approved, compared=counts.compared
        ),
        TEMPLATE["title.timetable_approved_present"],
        TEMPLATE["title.records_untouched"].format(
            tables=len(verifier.PRESERVED_TABLES), checked=counts.records_checked
        ),
        TEMPLATE["title.official_data"].format(
            tables=len(verifier.OFFICIAL_TABLES), checked=counts.official_checked
        ),
    ]


# ---------------------------------------------------------------------------
# Reading the verifier's own report
# ---------------------------------------------------------------------------


@dataclass
class ReportCheck:
    status: str
    title: str
    problems: list[str] = field(default_factory=list)


def parse_report(stdout: str) -> list[ReportCheck]:
    checks: list[ReportCheck] = []
    current: ReportCheck | None = None
    for line in stdout.replace("\r\n", "\n").split("\n"):
        if line.startswith("FAIL  ") or line.startswith("PASS  "):
            current = ReportCheck(status=line[:4].strip(), title=line[6:])
            checks.append(current)
        elif line.startswith("        - ") and current is not None:
            current.problems.append(line[10:])
    return checks


def run_verifier(before: Path, after: Path) -> subprocess.CompletedProcess:
    try:
        return subprocess.run(
            [PYTHON, str(VERIFIER), "--before", str(before), "--after", str(after)],
            capture_output=True,
            text=True,
        )
    except OSError as exc:
        raise Refused(f"failed to launch verifier ({VERIFIER.name}): {exc}")


def compare_report(
    checks: list[ReportCheck],
    expected_failures: list[tuple[str, list[str]]],
    counts: Counts,
) -> list[str]:
    """Compare the COMPLETE report: every failing check, every problem line, in order."""
    problems: list[str] = []
    actual_failing = [check for check in checks if check.status == "FAIL"]
    expected_titles = [title for title, _ in expected_failures]

    actual_titles = [check.title for check in actual_failing]
    if actual_titles != expected_titles:
        problems.append(
            f"failing checks differ: expected {expected_titles}, got {actual_titles}"
        )
    else:
        for (title, expected_problems), actual in zip(expected_failures, actual_failing):
            if actual.problems != expected_problems:
                problems.append(
                    f"problem lines for '{title}' differ: "
                    f"expected {expected_problems}, got {actual.problems}"
                )

    present = [check.title for check in checks]
    if present != all_titles(counts):
        missing = [t for t in all_titles(counts) if t not in present]
        extra = [t for t in present if t not in all_titles(counts)]
        problems.append(f"report shape differs: missing={missing} extra={extra}")
    return problems


# ---------------------------------------------------------------------------
# Controls
# ---------------------------------------------------------------------------


@dataclass
class ControlResult:
    letter: str
    name: str
    status: str  # MATCH | MISMATCH | SKIPPED | NOT-LANDED
    code: int
    detail: list[str] = field(default_factory=list)
    summary: str = ""


def skipped(letter: str, name: str, reason: str) -> ControlResult:
    return ControlResult(letter, name, "SKIPPED", EXIT_INCOMPLETE, [reason], reason)


def not_landed(letter: str, name: str, reason: str) -> ControlResult:
    return ControlResult(letter, name, "NOT-LANDED", EXIT_NOT_LANDED, [reason], reason)


def first_id(connection: sqlite3.Connection, table: str, where: str = "", params=()):
    query = f'SELECT id FROM "{table}"'
    if where:
        query += f" WHERE {where}"
    query += " ORDER BY id LIMIT 1"
    row = connection.execute(query, params).fetchone()
    return None if row is None else row[0]


def scratch_from(after: Path, root: Path, index: int) -> Path:
    target = scratch_path(root, index)
    shutil.copy2(assert_template(after, root), target)
    return target


def verdict(
    letter: str,
    name: str,
    result: subprocess.CompletedProcess,
    checks: list[ReportCheck],
    expected_failures: list[tuple[str, list[str]]],
    counts: Counts,
    expect_rc: int,
) -> ControlResult:
    problems: list[str] = []
    if result.returncode != expect_rc:
        problems.append(f"exit code {result.returncode}, expected {expect_rc}")
    problems.extend(compare_report(checks, expected_failures, counts))
    failing = len([check for check in checks if check.status == "FAIL"])
    summary = f"rc={result.returncode}, {failing} failing check(s)"
    status = "MATCH" if not problems else "MISMATCH"
    return ControlResult(
        letter, name, status, EXIT_OK if not problems else EXIT_MISMATCH, problems, summary
    )


def control_a(
    before: Path, after: Path, root: Path, counts: Counts, redacted_values: set
) -> ControlResult:
    """(a) The reviewed plan, applied to a copy, must pass untouched."""
    result = run_verifier(before, after)
    checks = parse_report(result.stdout)
    outcome = verdict("a", "valid migration", result, checks, [], counts, EXIT_OK)
    if outcome.status == "MATCH":
        if TEMPLATE["msg.ok"] not in result.stdout:
            outcome.status, outcome.detail = "MISMATCH", ["the OK line is missing"]
        else:
            leaked = sorted(
                value
                for value in redacted_values
                if len(value) >= 8 and value in result.stdout + result.stderr
            )
            if leaked:
                outcome.status = "MISMATCH"
                outcome.detail = [f"{len(leaked)} redacted value(s) appeared in the output"]
    return outcome


def control_b(before: Path, after: Path, root: Path, counts: Counts) -> ControlResult:
    """(b) A session write on teachers must be caught and redacted."""
    scratch = scratch_from(after, root, 2)
    connection = sqlite3.connect(scratch)
    try:
        target = first_id(connection, "teachers")
        if target is None:
            return skipped("b", "session drift on teachers", "the teachers table is empty")
        read = "SELECT token, token_expires_at FROM teachers WHERE id=?"
        before_values = connection.execute(read, (target,)).fetchone()
        cursor = connection.execute(
            "UPDATE teachers SET token=?, token_expires_at=? WHERE id=?",
            (DRIFT_TOKEN, DRIFT_EXPIRY, target),
        )
        affected = cursor.rowcount
        connection.commit()
        after_values = connection.execute(read, (target,)).fetchone()
    finally:
        connection.close()
    if affected != 1 or after_values == before_values:
        return not_landed(
            "b",
            "session drift on teachers",
            f"the token update matched {affected} row(s) and changed "
            f"{'nothing' if after_values == before_values else 'the row'}",
        )

    label = label_of(target)
    expected = [
        (
            TEMPLATE["title.records_untouched"].format(
                tables=len(verifier.PRESERVED_TABLES), checked=counts.records_checked
            ),
            [
                TEMPLATE["msg.redacted_change"].format(
                    table="teachers", label=label, column=column,
                    redacted=verifier.REDACTED_TEXT,
                )
                for column in ("token", "token_expires_at")
            ]
            + [TEMPLATE["msg.session_drift_hint"].format(table="teachers", key=target)],
        )
    ]
    result = run_verifier(before, scratch)
    return verdict("b", "session drift on teachers", result, parse_report(result.stdout),
                   expected, counts, EXIT_MISMATCH)


def control_c(before: Path, after: Path, root: Path, counts: Counts) -> ControlResult:
    """(c) An edit to a field the plan never approves must be caught."""
    scratch = scratch_from(after, root, 3)
    connection = sqlite3.connect(scratch)
    try:
        approved = ",".join(str(key) for key in sorted(verifier.APPROVED_TIMETABLE_CHANGES))
        target = first_id(
            connection,
            verifier.TIMETABLE_TABLE,
            where=f"id NOT IN ({approved}) AND is_break = 0",
        )
        if target is None:
            return skipped(
                "c",
                "unapproved field edit",
                "no unapproved, non-break timetable row exists in this database",
            )
        read = f'SELECT faculty FROM "{verifier.TIMETABLE_TABLE}" WHERE id=?'
        before_value = connection.execute(read, (target,)).fetchone()
        cursor = connection.execute(
            f'UPDATE "{verifier.TIMETABLE_TABLE}" SET faculty=? WHERE id=?',
            (UNAPPROVED_FAULT_VALUE, target),
        )
        affected = cursor.rowcount
        connection.commit()
        after_value = connection.execute(read, (target,)).fetchone()
    finally:
        connection.close()
    if affected != 1 or after_value == before_value:
        return not_landed(
            "c", "unapproved field edit", f"the faculty update matched {affected} row(s)"
        )

    expected = [
        (
            TEMPLATE["title.timetable_fields"].format(
                approved=counts.approved, compared=counts.compared
            ),
            [
                TEMPLATE["msg.unapproved_change"].format(
                    table=verifier.TIMETABLE_TABLE,
                    label=label_of(target),
                    column="faculty",
                    before=render("faculty", before_value[0]),
                    after=render("faculty", UNAPPROVED_FAULT_VALUE),
                )
            ],
        )
    ]
    result = run_verifier(before, scratch)
    return verdict("c", "unapproved field edit", result, parse_report(result.stdout),
                   expected, counts, EXIT_MISMATCH)


def control_d(before: Path, after: Path, root: Path, counts: Counts) -> ControlResult:
    """(d) An approved row changed to the WRONG new value must be caught."""
    faculty_ids = sorted(
        key for key, changes in verifier.APPROVED_TIMETABLE_CHANGES.items() if "faculty" in changes
    )
    if not faculty_ids:
        return skipped("d", "wrong new value", "the plan approves no faculty cell")
    target = faculty_ids[0]
    expected_new = verifier.APPROVED_TIMETABLE_CHANGES[target]["faculty"][1]

    scratch = scratch_from(after, root, 4)
    connection = sqlite3.connect(scratch)
    try:
        read = f'SELECT faculty FROM "{verifier.TIMETABLE_TABLE}" WHERE id=?'
        before_value = connection.execute(read, (target,)).fetchone()
        cursor = connection.execute(
            f'UPDATE "{verifier.TIMETABLE_TABLE}" SET faculty=? WHERE id=?',
            (WRONG_NEW_VALUE, target),
        )
        affected = cursor.rowcount
        connection.commit()
        after_value = connection.execute(read, (target,)).fetchone()
    finally:
        connection.close()
    if affected != 1 or after_value == before_value:
        return not_landed(
            "d", "wrong new value", f"the faculty update matched {affected} row(s)"
        )

    expected = [
        (
            TEMPLATE["title.timetable_fields"].format(
                approved=counts.approved, compared=counts.compared
            ),
            [
                TEMPLATE["msg.wrong_new_value"].format(
                    table=verifier.TIMETABLE_TABLE,
                    label=label_of(target),
                    column="faculty",
                    after=render("faculty", WRONG_NEW_VALUE),
                    expected=render("faculty", expected_new),
                )
            ],
        )
    ]
    result = run_verifier(before, scratch)
    return verdict("d", "wrong new value", result, parse_report(result.stdout),
                   expected, counts, EXIT_MISMATCH)


def control_e(before: Path, after: Path, root: Path, counts: Counts) -> ControlResult:
    """(e) A sixth free period must break the declared default."""
    default = verifier.APPROVED_NEW_COLUMNS[(verifier.TIMETABLE_TABLE, "is_free_period")]
    scratch = scratch_from(after, root, 5)
    connection = sqlite3.connect(scratch)
    try:
        approved = ",".join(str(key) for key in sorted(verifier.APPROVED_TIMETABLE_CHANGES))
        target = first_id(
            connection,
            verifier.TIMETABLE_TABLE,
            where=f"id NOT IN ({approved}) AND is_break = 0 AND is_free_period = 0",
        )
        if target is None:
            return skipped(
                "e", "sixth free period", "no unapproved row holds the default is_free_period"
            )
        read = f'SELECT is_free_period FROM "{verifier.TIMETABLE_TABLE}" WHERE id=?'
        before_value = connection.execute(read, (target,)).fetchone()
        cursor = connection.execute(
            f'UPDATE "{verifier.TIMETABLE_TABLE}" SET is_free_period=1 WHERE id=?', (target,)
        )
        affected = cursor.rowcount
        connection.commit()
        after_value = connection.execute(read, (target,)).fetchone()
    finally:
        connection.close()
    if affected != 1 or after_value == before_value:
        return not_landed(
            "e", "sixth free period", f"the is_free_period update matched {affected} row(s)"
        )

    expected = [
        (
            TEMPLATE["title.timetable_fields"].format(
                approved=counts.approved, compared=counts.compared
            ),
            [
                TEMPLATE["msg.created_default"].format(
                    table=verifier.TIMETABLE_TABLE,
                    label=label_of(target),
                    column="is_free_period",
                    after=render("is_free_period", after_value[0]),
                    expected=render("is_free_period", default),
                )
            ],
        )
    ]
    result = run_verifier(before, scratch)
    return verdict("e", "sixth free period", result, parse_report(result.stdout),
                   expected, counts, EXIT_MISMATCH)


def drop_column(path: Path, table: str, column: str) -> None:
    """Remove a column by rebuilding the table (no sqlite version dependency)."""
    connection = sqlite3.connect(path)
    try:
        columns = [row[1] for row in connection.execute(f'PRAGMA table_info("{table}")')]
        keep = [name for name in columns if name != column]
        quoted = ", ".join(f'"{name}"' for name in keep)
        connection.execute(f'CREATE TABLE rebuilt AS SELECT {quoted} FROM "{table}"')
        connection.execute(f'DROP TABLE "{table}"')
        connection.execute(f'ALTER TABLE rebuilt RENAME TO "{table}"')
        connection.commit()
    finally:
        connection.close()


def control_f(before: Path, after: Path, root: Path, counts: Counts) -> ControlResult:
    """(f) A dropped column must be caught by the schema check AND row by row."""
    scratch = scratch_from(after, root, 6)
    connection = sqlite3.connect(scratch)
    try:
        columns = [row[1] for row in connection.execute(
            f'PRAGMA table_info("{verifier.TIMETABLE_TABLE}")'
        )]
        if DROPPED_COLUMN not in columns:
            return skipped(
                "f",
                "dropped column",
                f"{verifier.TIMETABLE_TABLE}.{DROPPED_COLUMN} does not exist in this database",
            )
        rows_before = connection.execute(
            f'SELECT id, "{DROPPED_COLUMN}" FROM "{verifier.TIMETABLE_TABLE}" ORDER BY id'
        ).fetchall()
    finally:
        connection.close()

    drop_column(scratch, verifier.TIMETABLE_TABLE, DROPPED_COLUMN)

    connection = sqlite3.connect(scratch)
    try:
        columns_after = [row[1] for row in connection.execute(
            f'PRAGMA table_info("{verifier.TIMETABLE_TABLE}")'
        )]
        rows_after = connection.execute(
            f'SELECT COUNT(*) FROM "{verifier.TIMETABLE_TABLE}"'
        ).fetchone()[0]
    finally:
        connection.close()
    if DROPPED_COLUMN in columns_after or len(rows_before) != rows_after:
        return not_landed(
            "f",
            "dropped column",
            f"after the rebuild {verifier.TIMETABLE_TABLE} has {rows_after} rows "
            f"(was {len(rows_before)}) and {DROPPED_COLUMN} present="
            f"{DROPPED_COLUMN in columns_after}",
        )

    expected = [
        (
            TEMPLATE["title.schema_no_column_dropped"],
            [TEMPLATE["msg.column_dropped"].format(
                table=verifier.TIMETABLE_TABLE, column=DROPPED_COLUMN
            )],
        ),
        (
            TEMPLATE["title.timetable_fields"].format(
                approved=counts.approved, compared=counts.compared
            ),
            [
                TEMPLATE["msg.unapproved_change"].format(
                    table=verifier.TIMETABLE_TABLE,
                    label=label_of(row_id),
                    column=DROPPED_COLUMN,
                    before=render(DROPPED_COLUMN, value),
                    after=repr(verifier.ABSENT),
                )
                for row_id, value in rows_before
            ],
        ),
    ]
    result = run_verifier(before, scratch)
    return verdict("f", "dropped column", result, parse_report(result.stdout),
                   expected, counts, EXIT_MISMATCH)


# ---------------------------------------------------------------------------
# The run
# ---------------------------------------------------------------------------


def collect_redacted_values(before: dict) -> set:
    """Values that must never reach a log. Kept in memory, never printed."""
    found = set()
    for table in verifier.PRESERVED_TABLES:
        if table not in before:
            continue
        columns = [c for c in before[table]["columns"] if c in verifier.REDACTED_COLUMNS]
        for row in before[table]["rows"].values():
            for column in columns:
                value = row.get(column)
                if isinstance(value, str) and value:
                    found.add(value)
    return found


def backend_litter() -> set:
    return {
        path.name
        for path in BACKEND_DIR.glob("*.db*")
        if path.name.endswith((".db", ".bak"))
    }


def main(argv: list[str] | None = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    if argv:
        print(f"ERROR - this script takes no arguments (got: {' '.join(argv)})")
        print("        It has no live mode and no override flags, by design.")
        return EXIT_USAGE

    try:
        live = live_database_path()
    except Refused as exc:
        print(f"ERROR - {exc}")
        return EXIT_USAGE

    print("CampusSync official-data migration REHEARSAL")
    print("  The live database is READ, never written. All writes go to disposable copies.")
    print(f"  live    : {live}")

    try:
        # --- preflight -----------------------------------------------------
        if not live.exists():
            raise Refused(f"the live database does not exist: {live}")
        if live.stat().st_size == 0:
            raise Refused(f"the live database is empty (0 bytes): {live}")

        writers, scan_notes = check_live_writer(live)
        for note in scan_notes:
            print(f"  note    : {note}")
        if writers:
            print("\nREFUSED - a live database writer was detected:")
            for item in writers:
                print(f"  - {item}")
            print("\nStop the backend (OPERATING REQUIREMENTS 2) and run this again.")
            print("There is no override flag: a session write during the rehearsal would")
            print("make the baseline untrustworthy.")
            return EXIT_REFUSED

        # Fail-closed: if scan_notes indicate we could not establish the backend
        # is stopped (both wmic and listener enumeration unavailable), refuse.
        cannot_establish_stopped = any(
            "cannot establish backend stopped" in note for note in scan_notes
        )
        if cannot_establish_stopped:
            print("\nREFUSED - cannot establish that the backend is stopped:")
            for note in scan_notes:
                print(f"  - {note}")
            print("\nEnsure the backend is stopped and that netstat or Get-NetTCPConnection")
            print("is available to verify no listener exists. There is no override flag.")
            return EXIT_REFUSED

        read_only_probe(live)
        live_sha, live_stamp = sha256_of(live), stamp_of(live)
        print(f"  sha256  : {live_sha}")
        print("  preflight: no sidecar, no listener, no uvicorn process, quick_check ok")

        litter_before = backend_litter()

        with tempfile.TemporaryDirectory(prefix="cs-rehearsal-") as tmpdir:
            tmp = Path(tmpdir)
            before = assert_template(tmp / "before.db", tmp)
            after = assert_template(tmp / "after.db", tmp)

            snapshot_live(live, before)
            pre = read_snapshot(before)

            for table, column in sorted(verifier.BASELINE_MUST_PREDATE):
                if table in pre and column in pre[table]["columns"]:
                    raise Refused(
                        f"{table}.{column} already exists in the live database, so this "
                        "baseline postdates the additive step and the column creation "
                        "cannot be rehearsed (see the verifier's OPERATING REQUIREMENTS 1)."
                    )

            pending, applied, divergent = pending_plan_changes(pre)
            if not pending:
                raise Refused(
                    "nothing is pending: the live database already matches the approved "
                    "plan, so there is no migration left to rehearse."
                )
            if applied:
                print("  note    : already applied (the verifier still compares them): "
                      f"{', '.join(applied)}")
            if divergent:
                print("  WARNING : these approved cells hold neither the plan's old nor its "
                      f"new value: {', '.join(divergent)}")
                print("            The verifier will report them; that is a finding about the "
                      "live data, not a rehearsal bug.")
            print(f"  pending : {', '.join(pending)}")

            # The seeder runs on the DISPOSABLE copy. --no-backup is correct here
            # (and only here): the copy is thrown away, so a .bak of it is noise.
            # A real migration keeps the seeder's default backup - see the review.
            shutil.copy2(before, after)
            try:
                seed = subprocess.run(
                    [PYTHON, str(SEEDER), "--db", str(after), "--apply", "--no-backup"],
                    capture_output=True,
                    text=True,
                )
            except OSError as exc:
                raise Refused(
                    f"failed to launch seeder ({SEEDER.name}): {exc}"
                )
            if seed.returncode != 0:
                print("\nREFUSED - the seeder did not apply the plan to the copy:")
                print("  " + (seed.stdout + seed.stderr).strip()[-1500:].replace("\n", "\n  "))
                return EXIT_REFUSED

            counts = count_report(pre, read_snapshot(after))
            redacted_values = collect_redacted_values(pre)

            print(f"  counts  : {counts.tables} tables, {counts.compared} timetable rows, "
                  f"{counts.records_checked} preserved rows, "
                  f"{counts.official_checked} official rows")

            print("\ncontrols")
            results = [
                control_a(before, after, tmp, counts, redacted_values),
                control_b(before, after, tmp, counts),
                control_c(before, after, tmp, counts),
                control_d(before, after, tmp, counts),
                control_e(before, after, tmp, counts),
                control_f(before, after, tmp, counts),
            ]
            for outcome in results:
                line = f"  ({outcome.letter}) {outcome.name:<28} {outcome.status:<10}"
                print(f"{line} {outcome.summary}")
                for problem in outcome.detail:
                    print(f"        {problem}")
            if [r.letter for r in results] != list(CONTROL_LETTERS):
                print("ERROR - the control set is incomplete; refusing to report a result.")
                return EXIT_USAGE

            # --- the live file must be exactly as it was -------------------
            print("\nsafety")
            live_ok = sha256_of(live) == live_sha and stamp_of(live) == live_stamp
            print(f"  live database unchanged {'.' * 20} "
                  f"{'MATCH' if live_ok else 'MISMATCH'}")
            litter_after = backend_litter()
            new_litter = sorted(litter_after - litter_before)
            print(f"  no new *.db/*.bak under backend/ {'.' * 9} "
                  f"{'MATCH' if not new_litter else 'MISMATCH'}")
            if new_litter:
                print(f"        unexpected file(s): {new_litter}")
    except Refused as exc:
        print(f"\nREFUSED - {exc}")
        print("Nothing was rehearsed.")
        return EXIT_REFUSED

    failed = [r for r in results if r.status == "MISMATCH"]
    vacuous = [r for r in results if r.status == "NOT-LANDED"]
    missed = [r for r in results if r.status == "SKIPPED"]

    print()
    print(f"rehearsal: {len(results)} controls - {len(results) - len(failed) - len(vacuous) - len(missed)} "
          f"matched, {len(failed)} failed, {len(vacuous)} vacuous, {len(missed)} skipped")

    if not live_ok:
        print("FAILED - the live database changed during the rehearsal.")
        return EXIT_MISMATCH
    if failed:
        print("REHEARSAL FAILED - a control did not behave as the reviewed table says.")
        return EXIT_MISMATCH
    if vacuous:
        print("REHEARSAL FAILED - an injection did not land, so its control proved nothing:")
        for outcome in vacuous:
            print(f"  ({outcome.letter}) {outcome.name}: {outcome.summary}")
        return EXIT_NOT_LANDED
    if missed:
        print("REHEARSAL INCOMPLETE - these controls were skipped and prove nothing:")
        for outcome in missed:
            print(f"  ({outcome.letter}) {outcome.name}: {outcome.summary}")
        return EXIT_INCOMPLETE
    print("REHEARSAL COMPLETE - every control matched; the live database was not written.")
    return EXIT_OK


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:  # noqa: BLE001 - an unexpected crash is never a pass
        import traceback

        print(f"ERROR - unexpected failure: {type(exc).__name__}: {exc}")
        traceback.print_exc(file=sys.stderr)
        sys.exit(EXIT_USAGE)
