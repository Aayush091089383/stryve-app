"""Regression tests for migrate_db.py - the mass-approval bug must never return.

The old script ended with a blanket ``UPDATE students SET status='approved'
WHERE status='pending'``, which silently approved brand-new pending
registrations (demonstrated in the previous review). These tests pin down the
replacement behaviour on THROWAWAY databases:

* a normal run never changes any approval status / metadata / token;
* the migration is repeatable (second run is a no-op);
* a brand-new pending registration stays pending;
* rejected rows keep their status and reason;
* only explicitly named ids can be approved, after a dry run, and only when
  they are cleanly pending (otherwise nothing at all is changed);
* the explicit backfill refuses to run twice;
* there is no "approve everything" flag;
* the real database is never opened.

RUN
---
    <repo>/backend/venv/Scripts/python.exe <repo>/backend/tests/test_migrate_db_safety.py
"""

import ast
import os
import sqlite3
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

BACKEND_DIR = Path(__file__).resolve().parent.parent
REAL_DB = (BACKEND_DIR / "campussync.db").resolve()
MIGRATE = BACKEND_DIR / "migrate_db.py"
PYTHON = sys.executable

PASSED = []
FAILED = []


def check(label, condition, detail=""):
    if condition:
        PASSED.append(label)
        print(f"  PASS  {label}")
    else:
        FAILED.append(f"{label} {detail}".strip())
        print(f"  FAIL  {label}  {detail}")
    return bool(condition)


def stamp_of(path: Path):
    if not path.exists():
        return None
    stat = path.stat()
    return (stat.st_size, stat.st_mtime_ns)


REAL_DB_STAMP = stamp_of(REAL_DB)

# --------------------------------------------------------------------------
# fixtures
# --------------------------------------------------------------------------
LEGACY_SCHEMA = """
CREATE TABLE students (
    id INTEGER PRIMARY KEY,
    email TEXT UNIQUE,
    roll_number TEXT UNIQUE,
    password TEXT,
    name TEXT,
    branch TEXT,
    year INTEGER,
    division TEXT,
    batch TEXT,
    token TEXT,
    token_expires_at TIMESTAMP
)
"""

MODERN_SCHEMA = """
CREATE TABLE students (
    id INTEGER PRIMARY KEY,
    email TEXT UNIQUE,
    roll_number TEXT UNIQUE,
    password TEXT,
    name TEXT,
    branch TEXT,
    year INTEGER,
    division TEXT,
    batch TEXT,
    token TEXT,
    token_expires_at TIMESTAMP,
    status TEXT NOT NULL DEFAULT 'pending',
    approved_by INTEGER,
    approved_at TIMESTAMP,
    rejection_reason TEXT,
    photo_path TEXT
)
"""

APPROVED_AT = "2026-10-11T10:00:00+00:00"

# id, roll, status, approved_by, approved_at, rejection_reason, token
MODERN_ROWS = [
    (1, "71", "approved", 2, APPROVED_AT, None, None),   # approved, no session
    (2, "1", "pending", None, None, None, None),         # brand-new registration
    (3, "2", "rejected", None, None, "not eligible", None),
    (4, "3", "pending", None, None, None, None),         # the row the operator names
    (5, "4", "approved", 1, APPROVED_AT, None, "live-session-token"),
]


def make_db(path: Path, schema: str, rows, legacy=False) -> None:
    conn = sqlite3.connect(str(path))
    try:
        conn.execute(schema)
        for student_id, roll, status, approved_by, approved_at, reason, token in rows:
            if legacy:
                conn.execute(
                    "INSERT INTO students (id, email, roll_number, password, name, "
                    "branch, year, division, batch, token, token_expires_at) "
                    "VALUES (?,?,?,?,?,?,?,?,?,?,?)",
                    (
                        student_id,
                        f"s{student_id}@example.com",
                        roll,
                        "hash",
                        f"STUDENT {student_id} NAME",
                        "Computer",
                        1,
                        "D",
                        "D-1",
                        token,
                        None,
                    ),
                )
            else:
                conn.execute(
                    "INSERT INTO students (id, email, roll_number, password, name, "
                    "branch, year, division, batch, token, token_expires_at, status, "
                    "approved_by, approved_at, rejection_reason) "
                    "VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                    (
                        student_id,
                        f"s{student_id}@example.com",
                        roll,
                        "hash",
                        f"STUDENT {student_id} NAME",
                        "Computer",
                        1,
                        "D",
                        "D-1",
                        token,
                        None,
                        status,
                        approved_by,
                        approved_at,
                        reason,
                    ),
                )
        conn.commit()
    finally:
        conn.close()


def snapshot(path: Path) -> list:
    conn = sqlite3.connect(str(path))
    try:
        return list(
            conn.execute(
                "SELECT id, status, approved_by, approved_at, rejection_reason, token "
                "FROM students ORDER BY id"
            )
        )
    finally:
        conn.close()


def columns(path: Path) -> set:
    conn = sqlite3.connect(str(path))
    try:
        return {row[1] for row in conn.execute("PRAGMA table_info(students)")}
    finally:
        conn.close()


def versions(path: Path) -> set:
    conn = sqlite3.connect(str(path))
    try:
        if not conn.execute(
            "SELECT 1 FROM sqlite_master WHERE type='table' AND name='schema_migrations'"
        ).fetchone():
            return set()
        return {row[0] for row in conn.execute("SELECT version FROM schema_migrations")}
    finally:
        conn.close()


def run_migrate(*args, db: Path | None = None):
    command = [PYTHON, str(MIGRATE)]
    if db is not None:
        command += ["--db", str(db)]
    command += list(args)
    env = dict(os.environ)
    env.pop("DATABASE_URL", None)
    env.pop("ALLOW_DB_CREATE", None)
    return subprocess.run(
        command, capture_output=True, text=True, timeout=120, env=env
    )


def backups_of(db: Path) -> list:
    return sorted(db.parent.glob(f"{db.name}.*.bak"))


with tempfile.TemporaryDirectory(prefix="cs-migrate-") as tmpdir:
    tmp = Path(tmpdir).resolve()

    # ----------------------------------------------------------------------
    print("\n1. Plain migration on a current-schema database: nothing changes")
    # ----------------------------------------------------------------------
    modern = tmp / "modern.db"
    make_db(modern, MODERN_SCHEMA, MODERN_ROWS)
    before = snapshot(modern)

    first = run_migrate(db=modern)
    check("exit 0", first.returncode == 0, first.stderr.strip()[-300:])
    check(
        "every status / approval metadata / token is byte-identical",
        snapshot(modern) == before,
        f"{before} -> {snapshot(modern)}",
    )
    check(
        "the run reports the pending accounts instead of approving them",
        "pending account(s) - NOT approved by this script" in first.stdout,
        first.stdout[-400:],
    )
    check(
        "the run explains the legacy/new ambiguity",
        "cannot be classified automatically" in first.stdout,
    )
    check(
        "no backup file is written when nothing is applied",
        backups_of(modern) == [],
        str(backups_of(modern)),
    )

    # ----------------------------------------------------------------------
    print("\n2. Repeatable: a second and third run are no-ops")
    # ----------------------------------------------------------------------
    second = run_migrate(db=modern)
    check("second run exits 0", second.returncode == 0, second.stderr.strip()[-300:])
    check(
        "second run says no columns were needed",
        "no changes needed (columns already present)" in second.stdout,
        second.stdout[-400:],
    )
    check("second run changed nothing", snapshot(modern) == before)
    third = run_migrate("--status", db=modern)
    check("--status exits 0", third.returncode == 0, third.stderr.strip()[-300:])
    check("--status changed nothing", snapshot(modern) == before)
    check(
        "--status reports it wrote nothing",
        "no changes were made" in third.stdout,
    )

    # ----------------------------------------------------------------------
    print("\n3. A brand-new pending registration is never approved")
    # ----------------------------------------------------------------------
    rows = {row[0]: row for row in snapshot(modern)}
    check("new registration id=2 is still pending", rows[2][1] == "pending", str(rows[2]))
    check(
        "new registration id=2 gained no approval metadata",
        rows[2][2] is None and rows[2][3] is None,
        str(rows[2]),
    )
    check("rejected id=3 kept its status and reason", rows[3][1] == "rejected" and rows[3][4] == "not eligible", str(rows[3]))
    check(
        "approved id=1 kept approved_by/approved_at",
        rows[1][1] == "approved" and rows[1][2] == 2 and rows[1][3] == APPROVED_AT,
        str(rows[1]),
    )
    check("id=5 still has its live session token", rows[5][5] == "live-session-token", str(rows[5]))

    # ----------------------------------------------------------------------
    print("\n4. Pre-workflow schema: columns are added, rows become pending")
    # ----------------------------------------------------------------------
    legacy = tmp / "legacy.db"
    make_db(
        legacy,
        LEGACY_SCHEMA,
        [
            (1, "5", None, None, None, None, None),
            (2, "6", None, None, None, None, None),
        ],
        legacy=True,
    )
    check(
        "legacy schema really has no status column",
        "status" not in columns(legacy),
        str(columns(legacy)),
    )
    status_only = run_migrate("--status", db=legacy)
    check("--status on the legacy schema exits 0", status_only.returncode == 0, status_only.stderr.strip()[-300:])
    check(
        "--status reports the missing column without adding it",
        "no 'status' column" in status_only.stdout and "status" not in columns(legacy),
        status_only.stdout[-300:],
    )

    result = run_migrate(db=legacy)
    check("legacy migration exits 0", result.returncode == 0, result.stderr.strip()[-300:])
    added = columns(legacy)
    check(
        "all lifecycle columns were added",
        {"status", "approved_by", "approved_at", "rejection_reason", "photo_path", "token", "token_expires_at"} <= added,
        str(sorted(added)),
    )
    legacy_rows = snapshot(legacy)
    check(
        "legacy rows are pending (fail-closed), never auto-approved",
        all(row[1] == "pending" for row in legacy_rows) and len(legacy_rows) == 2,
        str(legacy_rows),
    )
    check(
        "the run warns that pending accounts cannot log in",
        "cannot log in until they are approved" in result.stdout,
        result.stdout[-500:],
    )
    after_first = snapshot(legacy)
    again = run_migrate(db=legacy)
    check("second legacy run exits 0 and changes nothing", again.returncode == 0 and snapshot(legacy) == after_first)

    # ----------------------------------------------------------------------
    print("\n5. Explicit-id backfill: dry run, apply, and only that row")
    # ----------------------------------------------------------------------
    target = tmp / "explicit.db"
    make_db(target, MODERN_SCHEMA, MODERN_ROWS)
    before_target = snapshot(target)

    dry = run_migrate("--approve-legacy-ids", "4", db=target)
    check("dry run exits 0", dry.returncode == 0, dry.stderr.strip()[-300:])
    check("dry run announces itself", "DRY RUN" in dry.stdout, dry.stdout[-300:])
    check("dry run changed nothing", snapshot(target) == before_target)
    check("dry run wrote no backup", backups_of(target) == [])

    applied = run_migrate("--approve-legacy-ids", "4", "--apply", db=target)
    check("apply exits 0", applied.returncode == 0, applied.stderr.strip()[-300:])
    rows = {row[0]: row for row in snapshot(target)}
    check("named id=4 is approved", rows[4][1] == "approved", str(rows[4]))
    check(
        "named id=4 got an approved_at timestamp",
        isinstance(rows[4][3], str) and len(rows[4][3]) > 10,
        str(rows[4]),
    )
    check("approved_by stays null (staff metadata is not invented)", rows[4][2] is None, str(rows[4]))
    check(
        "the OTHER pending row (id=2) is untouched - proves no blanket update",
        rows[2] == (2, "pending", None, None, None, None),
        str(rows[2]),
    )
    check(
        "approved/rejected/other rows are untouched",
        rows[1] == (1, "approved", 2, APPROVED_AT, None, None)
        and rows[3] == (3, "rejected", None, None, "not eligible", None)
        and rows[5][5] == "live-session-token",
        f"{rows[1]} {rows[3]} {rows[5]}",
    )
    backups = backups_of(target)
    check("a pre-change backup was written", len(backups) == 1, str(backups))
    if backups:
        backup_rows = {row[0]: row for row in snapshot(backups[0])}
        check(
            "the backup holds the pre-change state (id=4 still pending there)",
            backup_rows[4][1] == "pending" and backup_rows == {r[0]: r for r in before_target},
            str(backup_rows.get(4)),
        )
    check(
        "the backfill version was recorded",
        "2026-10-12_legacy_approval_backfill" in versions(target),
        str(versions(target)),
    )

    # ----------------------------------------------------------------------
    print("\n6. Repeat runs and refusals")
    # ----------------------------------------------------------------------
    after_apply = snapshot(target)
    repeat = run_migrate("--approve-legacy-ids", "4", "--apply", db=target)
    check("second identical backfill exits 0", repeat.returncode == 0, repeat.stderr.strip()[-300:])
    check(
        "second backfill reports SKIPPED and the row is unchanged",
        "SKIPPED" in repeat.stdout and snapshot(target) == after_apply,
        repeat.stdout[-300:],
    )
    check("second backfill wrote no further backup", len(backups_of(target)) == 1, str(backups_of(target)))

    refused = tmp / "refused.db"
    make_db(refused, MODERN_SCHEMA, MODERN_ROWS)
    refused_before = snapshot(refused)
    bad = run_migrate("--approve-legacy-ids", "1,3,999", "--apply", db=refused)
    check(
        "naming an already-approved / rejected / missing id is refused (exit 3)",
        bad.returncode == 3,
        f"returncode={bad.returncode}",
    )
    check("the refusal changed nothing at all (all-or-nothing)", snapshot(refused) == refused_before)
    check("the refusal wrote no backup", backups_of(refused) == [])
    check(
        "refusal explains why",
        "REFUSED - nothing was changed" in bad.stdout and "no such student" in bad.stdout,
        bad.stdout[-400:],
    )

    sweep = run_migrate("--approve-all-pending", db=refused)
    check(
        "there is no 'approve everything' flag",
        sweep.returncode == 2 and "unrecognized arguments" in sweep.stderr,
        f"returncode={sweep.returncode}",
    )
    check("the rejected sweep changed nothing", snapshot(refused) == refused_before)
    check(
        "the migration complete line states statuses were preserved",
        "statuses preserved" in run_migrate(db=refused).stdout,
    )

    # ----------------------------------------------------------------------
    print("\n7. Missing database: never created implicitly")
    # ----------------------------------------------------------------------
    missing = tmp / "nope" / "campussync.db"
    missing.parent.mkdir(parents=True, exist_ok=True)
    result = run_migrate(db=missing)
    check("missing database without --create: exit 2", result.returncode == 2, f"returncode={result.returncode}")
    check("missing database: file still absent", not missing.exists())
    check(
        "missing database: the hint names --create / --db",
        "--create" in result.stdout and "--db" in result.stdout,
        result.stdout[-300:],
    )

    created = tmp / "new" / "campussync.db"
    created.parent.mkdir(parents=True, exist_ok=True)
    result = run_migrate("--create", db=created)
    check("--create exits 0", result.returncode == 0, result.stderr.strip()[-300:])
    check("--create made the file", created.exists())
    conn = sqlite3.connect(str(created))
    try:
        tables = {row[0] for row in conn.execute("SELECT name FROM sqlite_master WHERE type='table'")}
        students = conn.execute("SELECT COUNT(*) FROM students").fetchone()[0]
    finally:
        conn.close()
    check("created database has the schema and no students", {"students", "teachers"} <= tables and students == 0, str(sorted(tables)))

    garbage = tmp / "garbage.db"
    garbage.write_bytes(b"not a database" * 10)
    result = run_migrate(db=garbage)
    check(
        "a non-SQLite file is refused (exit 2)",
        result.returncode == 2 and "Not a SQLite database" in result.stdout,
        result.stdout[-300:],
    )

    # ----------------------------------------------------------------------
    print("\n8. Source guard: no blanket status UPDATE can come back")
    # ----------------------------------------------------------------------
    source = MIGRATE.read_text(encoding="utf-8")
    tree = ast.parse(source)

    # Skip docstrings: the module header quotes the OLD buggy statement on purpose.
    docstrings = set()
    for node in ast.walk(tree):
        if isinstance(
            node, (ast.Module, ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)
        ):
            doc = ast.get_docstring(node, clean=False)
            if doc:
                docstrings.add(doc)

    sql_strings = [
        node.value
        for node in ast.walk(tree)
        if isinstance(node, ast.Constant)
        and isinstance(node.value, str)
        and "students" in node.value
        and node.value not in docstrings
    ]
    updates = [s for s in sql_strings if "UPDATE students" in s]
    check("there is exactly one UPDATE students statement", len(updates) == 1, str(updates))
    check(
        "it targets one explicit id (no blanket update)",
        updates and all("WHERE id = ?" in s for s in updates),
        str(updates),
    )
    # Read-only statements may filter by status (that is how the report lists
    # pending accounts). What must never exist is a WRITE that is not scoped to
    # one explicit id.
    unscoped_writes = [
        s for s in sql_strings if " SET " in s.upper() and "WHERE id = ?" not in s
    ]
    check(
        "no statement can write to more than one row",
        unscoped_writes == [],
        str(unscoped_writes),
    )

    # ----------------------------------------------------------------------
    print("\n9. The real database was not touched")
    # ----------------------------------------------------------------------
    check(
        "real database size/mtime unchanged by this suite",
        stamp_of(REAL_DB) == REAL_DB_STAMP,
        f"before={REAL_DB_STAMP} after={stamp_of(REAL_DB)}",
    )

print("\n" + "=" * 72)
print(f"migration safety tests: {len(PASSED)} passed, {len(FAILED)} failed")
for failure in FAILED:
    print(f"  FAILED: {failure}")
print("=" * 72)
sys.exit(1 if FAILED else 0)
