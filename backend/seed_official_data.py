#!/usr/bin/env python
"""
Seed CampusSync with the official FE Division D timetable and directory data.

WHAT THIS DOES
--------------
1. Additively migrates the schema (missing columns/tables only - never drops or
   rewrites an existing column, never touches existing rows).
2. Loads the official subject catalogue, faculty directory and room directory
   from ``official_data.py`` - the transcription of the department's
   "Time Table of FE 2026-27, First Term, Division D, Revision 4".
3. Aligns ``timetable_entries`` with that grid: inserts entries that are
   missing, and corrects the faculty cell, the free-period flag and the break
   flag of an entry that demonstrably disagrees with the confirmed sheet (every
   single correction is printed). It NEVER deletes an entry and NEVER touches
   students, teachers, registrations or assignments.

WHAT "RELM" BECOMES
--------------------
The sheet's five weekly "RELM" periods are free periods (confirmed by the
department): they get ``is_free_period = 1`` and ``is_break = 0``, so students
never see them as lectures and teachers can claim them. Before that was known
an existing database may hold them as breaks - that is exactly the flag this
step reports and corrects.

WHAT IT DELIBERATELY DOES NOT DO
--------------------------------
It does not invent anything. Values the official document does not state
(full faculty names, e-mails, offices, laboratory rooms) stay NULL and are
listed by ``--report`` and by ``GET /directory/status``.

USAGE
-----
    # inspect only (default) - prints the plan, writes nothing
    python seed_official_data.py
    python seed_official_data.py --db C:/tmp/throwaway.db

    # apply the additive schema change + seed the official data
    python seed_official_data.py --apply

    # skip the automatic backup copy taken before a write
    python seed_official_data.py --apply --no-backup

    # create a missing database file (deliberate first-time setup only)
    python seed_official_data.py --apply --create

EXIT CODES
----------
    0  success, or nothing left to do
    2  usage/configuration error, or the target database is missing/invalid
    3  refused (validation failed - nothing was written)
"""

from __future__ import annotations

import argparse
import shutil
import sqlite3
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

BACKEND_DIR = Path(__file__).resolve().parent
if str(BACKEND_DIR) not in sys.path:
    sys.path.insert(0, str(BACKEND_DIR))

from sqlalchemy import create_engine  # noqa: E402
from sqlalchemy.orm import Session  # noqa: E402

import models  # noqa: E402,F401  (registers every table on Base.metadata)
import official_data as official  # noqa: E402
from database import (  # noqa: E402
    Base,
    DatabaseNotInitialised,
    resolve_database_path,
    verify_database_file,
)

SCHEMA_VERSION = "2026-10-13_teaching_features"

# Additive columns: (table, column, DDL). Added only when absent.
ADDITIVE_COLUMNS = [
    ("teachers", "short_code", "ALTER TABLE teachers ADD COLUMN short_code TEXT"),
    (
        "teachers",
        "can_approve_registrations",
        "ALTER TABLE teachers ADD COLUMN can_approve_registrations BOOLEAN NOT NULL DEFAULT 0",
    ),
    # The password as the admin provisioned it, readable only through the
    # admin-only `GET /teacher/list`. NULL for accounts created before this
    # column existed; the schema step never invents credentials.
    (
        "teachers",
        "plain_password",
        "ALTER TABLE teachers ADD COLUMN plain_password TEXT",
    ),
    ("assignments", "stored_name", "ALTER TABLE assignments ADD COLUMN stored_name TEXT"),
    ("assignments", "original_name", "ALTER TABLE assignments ADD COLUMN original_name TEXT"),
    ("assignments", "file_size", "ALTER TABLE assignments ADD COLUMN file_size INTEGER"),
    ("assignments", "uploaded_by", "ALTER TABLE assignments ADD COLUMN uploaded_by INTEGER"),
    ("assignments", "created_at", "ALTER TABLE assignments ADD COLUMN created_at TIMESTAMP"),
    (
        "attendance_records",
        "updated_by",
        "ALTER TABLE attendance_records ADD COLUMN updated_by INTEGER",
    ),
    # The sheet's "RELM" periods: free for every class group and claimable by a
    # teacher. A column of its own, because such a period is neither a lecture
    # nor an ordinary break (existing rows default to 0 = not a free period).
    (
        "timetable_entries",
        "is_free_period",
        "ALTER TABLE timetable_entries ADD COLUMN is_free_period BOOLEAN NOT NULL DEFAULT 0",
    ),
]


def log(message: str = "") -> None:
    print(message)


def table_exists(conn: sqlite3.Connection, table: str) -> bool:
    return (
        conn.execute(
            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?", (table,)
        ).fetchone()
        is not None
    )


def columns_of(conn: sqlite3.Connection, table: str) -> set[str]:
    if not table_exists(conn, table):
        return set()
    return {row[1] for row in conn.execute(f"PRAGMA table_info({table})")}


def normalise_batch(value) -> str:
    raw = (value or "").strip().upper().replace(" ", "")
    if raw in {"D1", "D-1", "D_1"}:
        return "D-1"
    if raw in {"D2", "D-2", "D_2"}:
        return "D-2"
    if raw in {"D3", "D-3", "D_3"}:
        return "D-3"
    return ""


def grid_key(day, start, end, subject, batch) -> tuple:
    return (day, start, end, (subject or "").strip(), normalise_batch(batch))


def is_free_period(day: str, start: str, end: str, subject: str) -> bool:
    """True for the sheet's free periods ("RELM"), which are not breaks."""
    if (subject or "").strip().upper() != official.FREE_PERIOD_SUBJECT:
        return False
    return official.is_free_period_slot(day, start, end)


def official_grid_rows() -> list[dict]:
    rows = []
    for day, start, end, subject, faculty, batch in official.TIMETABLE:
        rows.append(
            {
                "day": day,
                "start_time": start,
                "end_time": end,
                "subject": subject,
                "faculty": faculty,
                "division": official.DIVISION,
                "batch": batch,
                "is_break": False,
                "is_free_period": is_free_period(day, start, end, subject),
            }
        )
    for start, end, label in official.BREAKS:
        for day in official.DAYS:
            rows.append(
                {
                    "day": day,
                    "start_time": start,
                    "end_time": end,
                    "subject": label,
                    "faculty": "",
                    "division": official.DIVISION,
                    "batch": None,
                    "is_break": True,
                    "is_free_period": False,
                }
            )
    return rows


def plan_additive_schema(db_path: Path) -> list[str]:
    """What the additive schema step WOULD change. Read-only."""
    conn = sqlite3.connect(db_path)
    try:
        changes: list[str] = []
        for table, column, _ddl in ADDITIVE_COLUMNS:
            if not table_exists(conn, table):
                continue
            if column in columns_of(conn, table):
                continue
            changes.append(f"add column {table}.{column}")
        for table in sorted(Base.metadata.tables):
            if not table_exists(conn, table):
                changes.append(f"create table {table}")
        return changes
    finally:
        conn.close()


def apply_additive_schema(db_path: Path) -> list[str]:
    """Add missing columns and tables. Returns the list of changes made."""
    conn = sqlite3.connect(db_path)
    changes: list[str] = []
    try:
        for table, column, ddl in ADDITIVE_COLUMNS:
            if not table_exists(conn, table):
                continue
            if column in columns_of(conn, table):
                continue
            conn.execute(ddl)
            changes.append(f"added column {table}.{column}")
        conn.commit()
    finally:
        conn.close()

    # Missing TABLES only - create_all never alters an existing table.
    engine = create_engine(f"sqlite:///{db_path.as_posix()}")
    before = set(Base.metadata.tables)
    Base.metadata.create_all(bind=engine)
    engine.dispose()

    with sqlite3.connect(db_path) as conn:
        for table in sorted(before):
            if not table_exists(conn, table):
                changes.append(f"created table {table}")

    return changes


def seed(session: Session, apply: bool) -> dict:
    """Plan (and optionally write) the official data. Returns a summary."""
    summary: dict = {
        "subjects_created": [],
        "faculty_created": [],
        "faculty_updated": [],
        "labs_created": [],
        "timetable_missing": [],
        "timetable_faculty_fixed": [],
        "timetable_free_period_fixed": [],
        "timetable_break_fixed": [],
        "timetable_extra": [],
    }

    # ---- subjects -------------------------------------------------------
    existing_subjects = {
        (row.name, row.kind): row for row in session.query(models.Subject).all()
    }
    for name, short, code, faculty_code, kind in official.SUBJECTS:
        key = (name, kind)
        if key in existing_subjects:
            continue
        summary["subjects_created"].append(name)
        if apply:
            session.add(
                models.Subject(
                    name=name,
                    short_name=short,
                    code=code,
                    faculty_code=faculty_code,
                    kind=kind,
                    source="official_timetable",
                )
            )

    # ---- faculty --------------------------------------------------------
    existing_faculty = {
        row.short_code.upper(): row for row in session.query(models.FacultyMember).all()
    }
    for entry in official.FACULTY:
        code = entry["short_code"]
        row = existing_faculty.get(code)
        if row is None:
            summary["faculty_created"].append(code)
            if apply:
                session.add(
                    models.FacultyMember(
                        short_code=code,
                        full_name=entry["full_name"],
                        role_note=entry["role_note"],
                        is_verified=entry["verified"],
                        source="official_timetable",
                    )
                )
            continue
        # Only ever fill a blank field with an official value.
        if entry["full_name"] and not row.full_name:
            summary["faculty_updated"].append(f"{code}.full_name")
            if apply:
                row.full_name = entry["full_name"]
        if entry["role_note"] and not row.role_note:
            summary["faculty_updated"].append(f"{code}.role_note")
            if apply:
                row.role_note = entry["role_note"]
        if entry["verified"] and not row.is_verified:
            summary["faculty_updated"].append(f"{code}.is_verified")
            if apply:
                row.is_verified = True

    # ---- rooms ----------------------------------------------------------
    existing_labs = {row.name for row in session.query(models.LabRoom).all()}
    for room in official.ROOMS:
        if room["name"] in existing_labs:
            continue
        summary["labs_created"].append(room["name"])
        if apply:
            session.add(
                models.LabRoom(
                    name=room["name"],
                    code=room["code"],
                    room=room["room"],
                    building=room["building"],
                    floor=room["floor"],
                    subject=room["subject"],
                    kind=room["kind"],
                    source="official_timetable",
                    is_verified=True,
                )
            )

    if apply:
        session.commit()

    # ---- timetable ------------------------------------------------------
    official_rows = official_grid_rows()
    official_by_key = {grid_key(
        row["day"], row["start_time"], row["end_time"], row["subject"], row["batch"]
    ): row for row in official_rows}

    db_entries = (
        session.query(models.TimetableEntry)
        .filter(models.TimetableEntry.division == official.DIVISION)
        .all()
    )
    db_by_key = {
        grid_key(
            row.day, row.start_time, row.end_time, row.subject, row.batch
        ): row
        for row in db_entries
    }

    for key, row in official_by_key.items():
        if key not in db_by_key:
            summary["timetable_missing"].append(
                f"{row['day']} {row['start_time']}-{row['end_time']} "
                f"{row['subject']} ({normalise_batch(row['batch']) or 'all'})"
            )

    # An entry that exists in both but with a different faculty code (the
    # printed revision changed it) is reported, and corrected on --apply.
    for key, official_row in official_by_key.items():
        db_row = db_by_key.get(key)
        if db_row is None or official_row["is_break"]:
            continue
        if (db_row.faculty or "").strip() != (official_row["faculty"] or "").strip():
            summary["timetable_faculty_fixed"].append(
                f"{db_row.day} {db_row.start_time}-{db_row.end_time} "
                f"{db_row.subject} ({normalise_batch(db_row.batch) or 'all'}): "
                f"{db_row.faculty or '-'} -> {official_row['faculty'] or '-'}"
            )
            if apply:
                db_row.faculty = official_row["faculty"]

    # The free-period / break flags are corrected with the same rule: an entry
    # that exists in both but disagrees is reported, and only written on --apply.
    # This is what turns the five "RELM" rows from a break into a free period in
    # an existing database (they were imported as breaks before RELM was known
    # to mean a claimable free period).
    for key, official_row in official_by_key.items():
        db_row = db_by_key.get(key)
        if db_row is None:
            continue

        if bool(db_row.is_free_period) != bool(official_row["is_free_period"]):
            summary["timetable_free_period_fixed"].append(
                f"{db_row.day} {db_row.start_time}-{db_row.end_time} "
                f"{db_row.subject} ({normalise_batch(db_row.batch) or 'all'}): "
                f"is_free_period {int(bool(db_row.is_free_period))} -> "
                f"{int(bool(official_row['is_free_period']))}"
            )
            if apply:
                db_row.is_free_period = official_row["is_free_period"]

        if bool(db_row.is_break) != bool(official_row["is_break"]):
            summary["timetable_break_fixed"].append(
                f"{db_row.day} {db_row.start_time}-{db_row.end_time} "
                f"{db_row.subject} ({normalise_batch(db_row.batch) or 'all'}): "
                f"is_break {int(bool(db_row.is_break))} -> "
                f"{int(bool(official_row['is_break']))}"
            )
            if apply:
                db_row.is_break = official_row["is_break"]

    for key, db_row in db_by_key.items():
        if key not in official_by_key:
            summary["timetable_extra"].append(
                f"id={db_row.id} {db_row.day} {db_row.start_time}-{db_row.end_time} "
                f"{db_row.subject} ({normalise_batch(db_row.batch) or 'all'})"
            )

    if apply:
        for key, row in official_by_key.items():
            if key in db_by_key:
                continue
            session.add(
                models.TimetableEntry(
                    day=row["day"],
                    start_time=row["start_time"],
                    end_time=row["end_time"],
                    subject=row["subject"],
                    faculty=row["faculty"],
                    room=None,
                    division=row["division"],
                    batch=row["batch"],
                    is_break=row["is_break"],
                    is_free_period=row["is_free_period"],
                )
            )
        session.commit()

    return summary


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Seed the official Division D timetable and directory data "
            "(additive, fail-closed, never deletes)."
        )
    )
    parser.add_argument("--db", default=None, help="target database file (default: the backend's)")
    parser.add_argument("--apply", action="store_true", help="write the changes")
    parser.add_argument("--create", action="store_true", help="create a missing database file")
    parser.add_argument("--no-backup", action="store_true", help="skip the pre-write backup copy")
    parser.add_argument(
        "--schema-only",
        action="store_true",
        help=(
            "apply only the additive schema change (missing columns/tables) and "
            "leave every existing row and the official data untouched"
        ),
    )
    args = parser.parse_args(argv)

    # --db takes a plain file path (same convention as migrate_db.py); without
    # it the path is the one the backend itself resolves from DATABASE_URL.
    db_path = Path(args.db).expanduser().resolve() if args.db else resolve_database_path()
    if db_path is None:
        log("DATABASE_URL points at an in-memory database; pass --db <path>.")
        return 2

    try:
        verify_database_file(db_path, allow_create=args.create)
    except DatabaseNotInitialised as exc:
        log(str(exc))
        return 2

    if not db_path.exists():
        log(f"Database file not found: {db_path}")
        return 2

    log("CampusSync official data seed (Division D, Revision 4)")
    log(f"  database : {db_path}")
    log(f"  mode     : {'APPLY (writes)' if args.apply else 'DRY RUN (nothing is written)'}")
    log(f"  effective: {official.EFFECTIVE_FROM}")
    log("")

    if args.apply and not args.no_backup:
        stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        backup = db_path.with_suffix(f"{db_path.suffix}.{stamp}.pre-official-seed.bak")
        shutil.copy2(db_path, backup)
        log(f"  backup   : {backup.name}")

    if args.apply:
        changes = apply_additive_schema(db_path)
        if changes:
            log("  schema   :")
            for change in changes:
                log(f"    + {change}")
        else:
            log("  schema   : already up to date")
    else:
        # A dry run must not write ANYTHING, not even a missing column.
        planned = plan_additive_schema(db_path)
        if planned:
            log("  schema   : would change")
            for change in planned:
                log(f"    + {change}")
        else:
            log("  schema   : already up to date")
    log("")

    if args.schema_only:
        log("Schema-only mode: no data was written.")
        if not args.apply:
            log("DRY RUN - nothing was written. Re-run with --apply to make these changes.")
            log(f"  target   : {db_path} is unchanged.")
        return 0

    # A dry run computes the data plan on a TEMPORARY COPY that has the additive
    # schema applied. Two reasons: the target file is then never opened for
    # writing, and the plan still works before the target has been migrated (the
    # ORM cannot even read a table that is missing a column the models declare).
    plan_db = db_path
    plan_dir: Path | None = None
    if not args.apply:
        plan_dir = Path(tempfile.mkdtemp(prefix="cs-seed-plan-"))
        plan_db = plan_dir / db_path.name
        shutil.copy2(db_path, plan_db)
        apply_additive_schema(plan_db)
        log(f"  plan on  : a temporary copy ({plan_db})")
        log(f"  target   : {db_path} was not opened for writing")
        log("")

    engine = create_engine(f"sqlite:///{plan_db.as_posix()}")
    try:
        with Session(engine) as session:
            summary = seed(session, apply=args.apply)
    finally:
        engine.dispose()
        if plan_dir is not None:
            shutil.rmtree(plan_dir, ignore_errors=True)

    log("Official data")
    log(f"  subjects new      : {len(summary['subjects_created'])}")
    log(f"  faculty new       : {len(summary['faculty_created'])} {summary['faculty_created']}")
    log(f"  faculty filled in : {len(summary['faculty_updated'])}")
    log(f"  rooms new         : {len(summary['labs_created'])} {summary['labs_created']}")
    log("")
    log("Timetable")
    log(f"  entries missing   : {len(summary['timetable_missing'])}")
    for item in summary["timetable_missing"]:
        log(f"    + {item}")
    log(f"  faculty corrected : {len(summary['timetable_faculty_fixed'])}")
    for item in summary["timetable_faculty_fixed"]:
        log(f"    * {item}")
    log(
        "  free periods set  : "
        f"{len(summary['timetable_free_period_fixed'])}"
    )
    for item in summary["timetable_free_period_fixed"]:
        log(f"    * {item}")
    log(f"  break flags fixed : {len(summary['timetable_break_fixed'])}")
    for item in summary["timetable_break_fixed"]:
        log(f"    * {item}")
    log(f"  entries not in the official grid (kept): {len(summary['timetable_extra'])}")
    for item in summary["timetable_extra"][:20]:
        log(f"    ? {item}")
    log("")

    if not args.apply:
        log("DRY RUN - nothing was written. Re-run with --apply to make these changes.")
        return 0

    log("Done. Data still missing (needs a real source document):")
    for item in official.UNCONFIRMED:
        log(f"  - {item}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
