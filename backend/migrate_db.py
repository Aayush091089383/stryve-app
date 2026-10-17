#!/usr/bin/env python
"""
CampusSync database migration - FAIL-CLOSED and repeatable.

WHAT THIS SCRIPT USED TO DO (the bug this replaces)
---------------------------------------------------
It ended with::

    UPDATE students SET status = "approved", approved_by = NULL,
           approved_at = ? WHERE status = "pending"

That statement approves EVERY pending row, so a student who had just
registered and was waiting for a teacher's approval became fully approved the
next time the script ran. It also overwrote approval metadata on every run and
used a blanket UPDATE.

WHY THERE IS NO AUTOMATIC BACKFILL ANY MORE
-------------------------------------------
The ``students`` table has no ``created_at`` (or any other) column, and a
legacy pre-approval-workflow row is byte-for-byte identical to a brand-new
pending registration:

    status='pending', approved_by IS NULL, approved_at IS NULL, token IS NULL

So the database alone CANNOT tell "this person registered before the approval
workflow existed" from "this person registered five minutes ago". Guessing in
either direction is unsafe - approving grants access, and never approving
locks someone out - so this script does not guess. It:

* migrates the schema additively (idempotent, no status changes ever);
* reports the current status counts;
* approves only rows the operator names explicitly, with ``--apply``, and
  only if they are still cleanly pending;
* refuses to repeat the same backfill twice (recorded in schema_migrations);
* copies the database file before any status change.

USAGE
-----
    # 0) see what is there - never changes statuses
    python migrate_db.py --status

    # 1) additive schema migration (safe, repeatable, no status changes)
    python migrate_db.py
    python migrate_db.py --db C:/tmp/throwaway.db

    # 2) first-time setup only: create a missing database file + schema
    python migrate_db.py --create

    # 3) one-off compatibility backfill for rows you have identified by hand
    python migrate_db.py --approve-legacy-ids 4,7             # dry run
    python migrate_db.py --approve-legacy-ids 4,7 --apply     # apply

PREFERRED: for a pending account that should be approved, use the Teacher
Panel instead - it records which teacher approved it (``approved_by``), which
this script cannot.

EXIT CODES
----------
    0  success, or nothing to do (a repeat run)
    2  the target database is missing/invalid, or bad arguments
    3  refused to change anything (validation failed)
"""

from __future__ import annotations

import argparse
import shutil
import sqlite3
import sys
from datetime import datetime, timezone
from pathlib import Path

BACKEND_DIR = Path(__file__).resolve().parent
if str(BACKEND_DIR) not in sys.path:
    sys.path.insert(0, str(BACKEND_DIR))

import models  # noqa: E402,F401  (registers the tables on Base.metadata)
from database import (  # noqa: E402
    Base,
    DatabaseNotInitialised,
    resolve_database_path,
    verify_database_file,
)

# --------------------------------------------------------------------------
# Additive schema migrations: (column, DDL). Only added when absent.
# --------------------------------------------------------------------------
STUDENT_COLUMNS = [
    ("status", "ALTER TABLE students ADD COLUMN status TEXT NOT NULL DEFAULT 'pending'"),
    ("approved_by", "ALTER TABLE students ADD COLUMN approved_by INTEGER"),
    ("approved_at", "ALTER TABLE students ADD COLUMN approved_at TIMESTAMP"),
    ("rejection_reason", "ALTER TABLE students ADD COLUMN rejection_reason TEXT"),
    ("photo_path", "ALTER TABLE students ADD COLUMN photo_path TEXT"),
    ("token", "ALTER TABLE students ADD COLUMN token TEXT"),
    ("token_expires_at", "ALTER TABLE students ADD COLUMN token_expires_at TIMESTAMP"),
]

SCHEMA_VERSION = "2026-10-12_additive_student_columns"
LEGACY_BACKFILL_VERSION = "2026-10-12_legacy_approval_backfill"

MISSING_FILE_HINT = (
    "Refusing to create a database implicitly. Pass --create for a first-time "
    "setup, or --db <path> to target another file."
)


# --------------------------------------------------------------------------
# small helpers
# --------------------------------------------------------------------------
def log(message: str = "") -> None:
    print(message)


def ensure_version_table(conn: sqlite3.Connection) -> None:
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS schema_migrations (
            version TEXT PRIMARY KEY,
            applied_at TEXT NOT NULL
        )
        """
    )


def applied_versions(conn: sqlite3.Connection) -> set[str]:
    return {row[0] for row in conn.execute("SELECT version FROM schema_migrations")}


def record_version(conn: sqlite3.Connection, version: str) -> None:
    conn.execute(
        "INSERT OR REPLACE INTO schema_migrations (version, applied_at) VALUES (?, ?)",
        (version, datetime.now(timezone.utc).isoformat()),
    )


def table_exists(conn: sqlite3.Connection, table: str) -> bool:
    row = conn.execute(
        "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?", (table,)
    ).fetchone()
    return row is not None


def columns_of(conn: sqlite3.Connection, table: str) -> set[str]:
    return {row[1] for row in conn.execute(f"PRAGMA table_info({table})")}


def status_counts(conn: sqlite3.Connection) -> dict:
    counts = {row[0]: row[1] for row in conn.execute(
        "SELECT status, COUNT(*) FROM students GROUP BY status"
    )}
    for known in ("pending", "approved", "rejected"):
        counts.setdefault(known, 0)
    return counts


def pending_rows(conn: sqlite3.Connection) -> list[tuple]:
    return list(
        conn.execute(
            "SELECT id, roll_number, status, approved_at, approved_by, "
            "rejection_reason, token IS NOT NULL "
            "FROM students WHERE status = 'pending' ORDER BY id"
        )
    )


# --------------------------------------------------------------------------
# steps
# --------------------------------------------------------------------------
def step_add_columns(conn: sqlite3.Connection) -> list[str]:
    """Add any missing student column. Never changes an existing value."""
    if not table_exists(conn, "students"):
        log("  ! no 'students' table in this database - nothing to migrate.")
        return []

    existing = columns_of(conn, "students")
    added = []
    for name, ddl in STUDENT_COLUMNS:
        if name in existing:
            continue
        conn.execute(ddl)
        added.append(name)
        log(f"  + added column students.{name}")

    return added


def step_report(conn: sqlite3.Connection) -> None:
    if not table_exists(conn, "students"):
        log("  no 'students' table in this database.")
        return

    if "status" not in columns_of(conn, "students"):
        total = conn.execute("SELECT COUNT(*) FROM students").fetchone()[0]
        log("")
        log(f"  students: {total} row(s) and no 'status' column yet")
        log("  (pre-approval-workflow schema - run the migration to add it)")
        return

    counts = status_counts(conn)
    log("")
    log(f"  students: {counts['approved']} approved, "
        f"{counts['pending']} pending, {counts['rejected']} rejected")

    pending = pending_rows(conn)
    if not pending:
        return

    log("")
    log(f"  {len(pending)} pending account(s) - NOT approved by this script:")
    for row in pending:
        student_id, roll, _status, approved_at, approved_by, reason, has_token = row
        log(
            f"    id={student_id:<4} roll={roll:<4} "
            f"approved_at={'set' if approved_at else 'null'} "
            f"approved_by={'set' if approved_by else 'null'} "
            f"reason={'set' if reason else 'null'} "
            f"session={'yes' if has_token else 'no'}"
        )

    log("")
    log("  These rows cannot be classified automatically: the students table has")
    log("  no registration timestamp, so a legacy pre-approval-workflow account")
    log("  looks exactly like a brand-new pending registration. Approving them")
    log("  wholesale could grant access to an account nobody reviewed; leaving")
    log("  them pending could lock out a real legacy account.")
    log("")
    log("  Safe options, in order of preference:")
    log("    1. Approve/reject each one in the Teacher Panel (records who did it).")
    log("    2. If you have already identified a legacy row by hand:")
    log("         python migrate_db.py --approve-legacy-ids <id>          (dry run)")
    log("         python migrate_db.py --approve-legacy-ids <id> --apply")


def step_backfill(
    conn: sqlite3.Connection,
    db_path: Path,
    ids: list[int],
    apply: bool,
    backup: bool,
    force: bool,
) -> int:
    """Approve ONLY the explicitly named rows. All-or-nothing."""
    done = applied_versions(conn)
    if LEGACY_BACKFILL_VERSION in done and not force:
        log("")
        log(f"  SKIPPED: '{LEGACY_BACKFILL_VERSION}' was already applied to this")
        log("  database. Nothing to do (use --force only if you really must run it")
        log("  again). No row was changed.")
        return 0

    rows = {
        row[0]: row
        for row in conn.execute(
            "SELECT id, roll_number, status, approved_at, approved_by "
            "FROM students WHERE id IN (%s)"
            % ",".join("?" * len(ids)),
            ids,
        )
    }

    problems = []
    for student_id in ids:
        row = rows.get(student_id)
        if row is None:
            problems.append(f"id={student_id}: no such student")
            continue
        _id, roll, status_value, approved_at, approved_by = row
        if status_value != "pending":
            problems.append(f"id={student_id} (roll {roll}): status is "
                            f"'{status_value}', not 'pending'")
        elif approved_at is not None or approved_by is not None:
            problems.append(f"id={student_id} (roll {roll}): already carries "
                            f"approval metadata")

    if problems:
        log("")
        log("  REFUSED - nothing was changed:")
        for problem in problems:
            log(f"    {problem}")
        return 3

    log("")
    if not apply:
        log("  DRY RUN (add --apply to make these changes):")
    for student_id in ids:
        roll = rows[student_id][1]
        verb = "APPROVE" if apply else "WOULD APPROVE"
        log(f"    {verb} id={student_id} (roll {roll}) "
            f"[approved_by stays null - use the Teacher Panel to record a teacher]")

    if not apply:
        log("")
        log("  Nothing was written.")
        return 0

    if backup:
        stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        backup_path = db_path.with_name(f"{db_path.name}.{stamp}.pre-legacy-backfill.bak")
        shutil.copy2(db_path, backup_path)
        log("")
        log(f"  backup written: {backup_path}")

    now = datetime.now(timezone.utc).isoformat()
    for student_id in ids:
        conn.execute(
            "UPDATE students SET status = 'approved', approved_at = ?, "
            "approved_by = NULL WHERE id = ? AND status = 'pending'",
            (now, student_id),
        )

    record_version(conn, LEGACY_BACKFILL_VERSION)
    log("")
    log(f"  approved {len(ids)} explicitly named row(s); approved_at recorded.")
    log("  Because Staff approval metadata (approved_by) is unknown on these rows,")
    log("  approved_by stays NULL - that is intentional, not a failure.")
    log(f"  '{LEGACY_BACKFILL_VERSION}' recorded: this backfill will not run again.")
    return 0


# --------------------------------------------------------------------------
# entry point
# --------------------------------------------------------------------------
def parse_args(argv=None):
    parser = argparse.ArgumentParser(
        description="CampusSync additive schema migration (never mass-approves).",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "--db",
        default=None,
        help="Target database file (default: the backend's configured database).",
    )
    parser.add_argument(
        "--create",
        action="store_true",
        help="Create the database file and schema if it does not exist yet.",
    )
    parser.add_argument(
        "--status",
        action="store_true",
        help="Report status counts and exit without changing anything.",
    )
    parser.add_argument(
        "--approve-legacy-ids",
        default=None,
        metavar="I,I",
        help=(
            "Comma-separated student ids to approve (dry run unless --apply). "
            "Only ever changes the ids you name."
        ),
    )
    parser.add_argument(
        "--apply",
        action="store_true",
        help="Actually write the --approve-legacy-ids changes.",
    )
    parser.add_argument(
        "--no-backup",
        action="store_true",
        help="Skip the database file copy taken before a backfill.",
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="Re-run a backfill that this database already recorded.",
    )
    return parser.parse_args(argv)


def main(argv=None) -> int:
    args = parse_args(argv)

    db_path = Path(args.db).expanduser().resolve() if args.db else resolve_database_path()
    if db_path is None:
        log("ERROR: DATABASE_URL points at an in-memory database; pass --db <path>.")
        return 2

    log("=" * 72)
    log("CampusSync migration (additive, fail-closed)")
    log(f"Database: {db_path}")
    log("=" * 72)

    try:
        verify_database_file(db_path, allow_create=args.create)
    except DatabaseNotInitialised as exc:
        log("")
        log(f"ERROR: {exc}")
        log(MISSING_FILE_HINT)
        return 2

    if not db_path.exists():
        if not args.create:
            log("")
            log(f"ERROR: {db_path} does not exist.")
            log(MISSING_FILE_HINT)
            return 2

        from sqlalchemy import create_engine  # imported lazily on purpose

        log("")
        log("  creating a new database (--create) ...")
        engine = create_engine(f"sqlite:///{db_path.as_posix()}")
        Base.metadata.create_all(bind=engine)
        engine.dispose()
        log(f"  created {db_path} with the current schema")

    if args.status:
        # Read-only: --status opens the file with mode=ro so it cannot write.
        try:
            conn = sqlite3.connect(f"{db_path.as_uri()}?mode=ro", uri=True)
        except sqlite3.OperationalError as exc:
            log("")
            log(f"ERROR: cannot open {db_path} read-only: {exc}")
            return 2
        try:
            log("")
            log("status report (read-only; nothing is written)")
            step_report(conn)
            log("")
            log("  --status: no changes were made.")
            return 0
        finally:
            conn.close()

    conn = sqlite3.connect(str(db_path))
    try:
        ensure_version_table(conn)

        log("")
        log("1. additive schema migration")
        added = step_add_columns(conn)
        if not added:
            log("  no changes needed (columns already present)")

        if added:
            log("")
            log("  NOTE: rows that had no status column are now 'pending' (fail-closed:")
            log("  pending accounts cannot log in until they are approved). Approve the")
            log("  real legacy accounts in the Teacher Panel, or name them explicitly")
            log("  with --approve-legacy-ids.")

        record_version(conn, SCHEMA_VERSION)
        conn.commit()

        log("")
        log("2. status report (no statuses are changed by this script)")
        step_report(conn)

        exit_code = 0
        if args.approve_legacy_ids:
            try:
                ids = sorted({
                    int(part) for part in args.approve_legacy_ids.split(",") if part.strip()
                })
            except ValueError:
                log("")
                log("ERROR: --approve-legacy-ids expects comma-separated integers.")
                return 2

            if not ids:
                log("")
                log("ERROR: --approve-legacy-ids was empty.")
                return 2

            log("")
            log("3. legacy approval backfill (explicit ids only)")
            exit_code = step_backfill(
                conn,
                db_path,
                ids,
                apply=args.apply,
                backup=not args.no_backup,
                force=args.force,
            )
            if exit_code == 0 and args.apply:
                conn.commit()
            else:
                conn.rollback()

        log("")
        log("migration complete"
            + (" (some changes were refused)" if exit_code else " (statuses preserved)"))
        return exit_code
    finally:
        conn.close()


if __name__ == "__main__":
    sys.exit(main())
