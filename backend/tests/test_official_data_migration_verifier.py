#!/usr/bin/env python
"""
Synthetic-database tests for ``backend/verify_official_data_migration.py``.

Every database used here is built from scratch in a temporary directory and is
thrown away at the end. The real ``backend/campussync.db`` is never opened: the
suite records its SHA-256, size and mtime up front and asserts they are
unchanged at the end (the project convention for backend suites).

WHAT IS PINNED DOWN
-------------------
* one VALID migration passes, and nothing in its output leaks a credential;
* a credential-only change in ``teachers`` is caught AND redacted;
* every structurally wrong change is rejected: deleted row, inserted row, a
  wrong row id, an unapproved field, a wrong old value, a wrong new value, a
  sixth free period, a dropped column, an undeclared added column, an
  unexpected table, and a missing column this migration is meant to create;
* each preserved table (students/teachers/assignments/teacher_assignments/
  attendance_records/free_period_claims) is protected individually;
* the official-data rules are exact: subjects/lab_directory existing rows are
  frozen, and only the documented faculty blank-fill / 0-to-1 edits are allowed;
* the preconditions fail closed: a baseline that already has
  ``is_free_period``, a missing/empty/foreign file, a directory;
* the verifier agrees with the seeder and with ``official_data.py`` about
  exactly which nine rows change and to what values;
* the verifier has only ``--before``/``--after`` (no session-drift override),
  writes nothing, and is deterministic;
* the rehearsal harness (``backend/rehearse_official_data_migration.py``) still
  matches THIS verifier: every message template it expects exists in this
  source, it has no override flag, and its exit-code contract is unchanged.

RUN
---
    <repo>/backend/venv/Scripts/python.exe <repo>/backend/tests/test_official_data_migration_verifier.py
"""

import ast
import hashlib
import re
import shutil
import sqlite3
import subprocess
import sys
import tempfile
from pathlib import Path

BACKEND_DIR = Path(__file__).resolve().parent.parent
VERIFIER = BACKEND_DIR / "verify_official_data_migration.py"
SEEDER = BACKEND_DIR / "seed_official_data.py"
REHEARSAL = BACKEND_DIR / "rehearse_official_data_migration.py"
REAL_DB = (BACKEND_DIR / "campussync.db").resolve()
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


def sha256_of(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(65536), b""):
            digest.update(chunk)
    return digest.hexdigest()


def stamp_of(path):
    if not path.exists():
        return None
    stat = path.stat()
    return (stat.st_size, stat.st_mtime_ns)


REAL_DB_SHA = sha256_of(REAL_DB)
REAL_DB_STAMP = stamp_of(REAL_DB)

# ---------------------------------------------------------------------------
# Fixture: fake credentials (never real) and the live database's 54 rows
# ---------------------------------------------------------------------------

FIXTURE_PASSWORD_HASH = "fixture-not-a-real-password-hash"
FIXTURE_TOKEN = "fixture-not-a-real-token"
FIXTURE_TOKEN_EXPIRY = "2030-01-01 00:00:00"
DRIFTED_TOKEN = "drifted-not-a-real-token"
FIXTURE_SECRETS = (FIXTURE_PASSWORD_HASH, FIXTURE_TOKEN, DRIFTED_TOKEN, FIXTURE_TOKEN_EXPIRY)

# The schema the live database actually has: every additive column EXCEPT
# is_free_period, which is the one this migration is supposed to create.
SCHEMA = """
CREATE TABLE students (
    id INTEGER PRIMARY KEY, email TEXT UNIQUE, roll_number TEXT UNIQUE,
    password TEXT, name TEXT, branch TEXT, year INTEGER, division TEXT,
    batch TEXT, token TEXT, token_expires_at TIMESTAMP,
    status TEXT NOT NULL DEFAULT 'pending', approved_by INTEGER,
    approved_at TIMESTAMP, rejection_reason TEXT, photo_path TEXT
);
CREATE TABLE teachers (
    id INTEGER PRIMARY KEY, name TEXT, email TEXT UNIQUE, password TEXT,
    role TEXT, is_active BOOLEAN, token TEXT, token_expires_at TIMESTAMP,
    created_at TIMESTAMP, short_code TEXT,
    can_approve_registrations BOOLEAN NOT NULL DEFAULT 0
);
CREATE TABLE timetable_entries (
    id INTEGER PRIMARY KEY, day TEXT, start_time TEXT, end_time TEXT,
    subject TEXT, faculty TEXT, room TEXT, division TEXT, batch TEXT,
    is_break BOOLEAN
);
CREATE TABLE assignments (
    id INTEGER PRIMARY KEY, title TEXT, subject TEXT, stored_name TEXT,
    original_name TEXT, file_size INTEGER, uploaded_by INTEGER,
    created_at TIMESTAMP
);
CREATE TABLE subjects (
    id INTEGER PRIMARY KEY, name TEXT, short_name TEXT, code TEXT,
    faculty_code TEXT, kind TEXT, source TEXT
);
CREATE TABLE faculty_directory (
    id INTEGER PRIMARY KEY, short_code TEXT, full_name TEXT, role_note TEXT,
    is_verified BOOLEAN, source TEXT
);
CREATE TABLE lab_directory (
    id INTEGER PRIMARY KEY, name TEXT, code TEXT, room TEXT, building TEXT,
    floor INTEGER, subject TEXT, kind TEXT, source TEXT, is_verified BOOLEAN
);
CREATE TABLE teacher_assignments (
    id INTEGER PRIMARY KEY, teacher_id INTEGER, subject TEXT, division TEXT,
    batch TEXT
);
CREATE TABLE attendance_records (
    id INTEGER PRIMARY KEY, student_id INTEGER, timetable_entry_id INTEGER,
    date TEXT, status TEXT, updated_by INTEGER
);
CREATE TABLE free_period_claims (
    id INTEGER PRIMARY KEY, teacher_id INTEGER, timetable_entry_id INTEGER,
    date TEXT, claimed_at TIMESTAMP
);
"""

# id, day, start, end, subject, faculty, batch, is_break - the live table,
# read from a read-only copy of backend/campussync.db.
BASELINE_TIMETABLE = [
    (1, "Monday", "10:15", "11:15", "FPL", "RVS", None, 0),
    (2, "Monday", "11:15", "12:15", "PHY", "SPG", None, 0),
    (3, "Monday", "12:15", "13:00", "LUNCH BREAK", "", None, 1),
    (4, "Monday", "13:00", "14:00", "M-1", "SMG", None, 0),
    (5, "Monday", "14:00", "15:00", "BEE", "HBW", None, 0),
    (6, "Monday", "15:00", "15:15", "SHORT BREAK", "", None, 1),
    (7, "Monday", "15:15", "16:15", "PHY", "SPG", "D-1", 0),
    (8, "Monday", "15:15", "16:15", "BEE", "HBW", "D-2", 0),
    (9, "Monday", "15:35", "17:15", "EG", "VTM", "D-3", 0),
    (10, "Tuesday", "10:15", "11:15", "PHY", "SPG", "D-2", 0),
    (11, "Tuesday", "10:15", "12:15", "BEE", "HBW", "D-3", 0),
    (12, "Tuesday", "11:15", "12:15", "EG", "VTM", "D-1", 0),
    (13, "Tuesday", "12:15", "13:00", "LUNCH BREAK", "", None, 1),
    (14, "Tuesday", "13:00", "14:00", "BEE", "HBW", None, 0),
    (15, "Tuesday", "14:00", "15:00", "M-1", "SMG", None, 0),
    (16, "Tuesday", "15:00", "15:15", "SHORT BREAK", "", None, 1),
    (17, "Tuesday", "15:15", "16:15", "RELM", "", None, 1),
    (18, "Tuesday", "16:15", "17:15", "RELM", "", None, 1),
    (19, "Wednesday", "10:15", "11:15", "EG", "VTM", None, 0),
    (20, "Wednesday", "11:15", "12:15", "M-1", "SMG", None, 0),
    (21, "Wednesday", "12:15", "13:00", "LUNCH BREAK", "", None, 1),
    (22, "Wednesday", "13:00", "14:00", "DTIL", "RST", "D-2", 0),
    (23, "Wednesday", "13:00", "15:00", "FPL", "RVS (CC1)", "D-3", 0),
    (24, "Wednesday", "14:00", "15:00", "LIB", "TAS", "D-1", 0),
    (25, "Wednesday", "15:00", "15:15", "SHORT BREAK", "", None, 1),
    (26, "Wednesday", "15:15", "16:15", "CCC-1", "HBW", None, 0),
    (27, "Wednesday", "16:15", "17:15", "CCC-1", "HBW", None, 0),
    (28, "Thursday", "10:15", "11:15", "RELM", "", None, 1),
    (29, "Thursday", "11:15", "12:15", "M-1", "SMG / TUT", None, 0),
    (30, "Thursday", "12:15", "13:00", "LUNCH BREAK", "", None, 1),
    (31, "Thursday", "13:00", "14:00", "FPL", "RVS", None, 0),
    (32, "Thursday", "14:00", "15:00", "PHY", "SPG", None, 0),
    (33, "Thursday", "15:00", "15:15", "SHORT BREAK", "", None, 1),
    (34, "Thursday", "15:15", "16:15", "PCS", "SPK", None, 0),
    (35, "Thursday", "16:15", "17:15", "PCS", "SPK", None, 0),
    (36, "Friday", "10:15", "11:15", "PHY", "SPG", None, 0),
    (37, "Friday", "11:15", "12:15", "EG", "VTM", None, 0),
    (38, "Friday", "12:15", "13:00", "LUNCH BREAK", "", None, 1),
    (39, "Friday", "13:00", "15:00", "PHY", "SPG", "D-3", 0),
    (40, "Friday", "13:00", "14:00", "BEE", "HBW", "D-1", 0),
    (41, "Friday", "14:00", "15:00", "EG", "VTM", "D-2", 0),
    (42, "Friday", "15:00", "15:15", "SHORT BREAK", "", None, 1),
    (43, "Friday", "15:15", "16:15", "DTIL", "SPG", "D-1", 0),
    (44, "Friday", "15:15", "16:15", "FPL", "RVS (CC1)", "D-2", 0),
    (45, "Friday", "16:15", "17:15", "LIB", "TAS", "D-3", 0),
    (46, "Saturday", "10:15", "12:15", "DTIL", "RST", "D-3", 0),
    (47, "Saturday", "10:15", "11:15", "FPL", "RVS (CCI)", "D-1", 0),
    (48, "Saturday", "11:15", "12:15", "LIB", "TAS", "D-2", 0),
    (49, "Saturday", "12:15", "13:00", "LUNCH BREAK", "", None, 1),
    (50, "Saturday", "13:00", "14:00", "CCC-1", "DPK", None, 0),
    (51, "Saturday", "14:00", "15:00", "CCC-1", "DPK", None, 0),
    (52, "Saturday", "15:00", "15:15", "SHORT BREAK", "", None, 1),
    (53, "Saturday", "15:15", "16:15", "RELM", "", None, 1),
    (54, "Saturday", "16:15", "17:15", "RELM", "", None, 1),
]

FACULTY_BY_ID = {row[0]: row[5] for row in BASELINE_TIMETABLE}
BREAK_BY_ID = {row[0]: row[7] for row in BASELINE_TIMETABLE}


def build_baseline(path):
    """Write the pre-migration database (no is_free_period) to ``path``."""
    connection = sqlite3.connect(path)
    connection.executescript(SCHEMA)
    connection.execute(
        "INSERT INTO students (id, email, roll_number, password, name, branch,"
        " year, division, batch, token, token_expires_at, status) VALUES"
        " (1,'a@x.edu','71',?,'Student One','AI&DS',1,'D','D-3',?,?,'approved')",
        (FIXTURE_PASSWORD_HASH, FIXTURE_TOKEN, FIXTURE_TOKEN_EXPIRY),
    )
    connection.execute(
        "INSERT INTO students (id, email, roll_number, password, name, branch,"
        " year, division, batch, status) VALUES"
        " (2,'b@x.edu','72',?,'Student Two','AI&DS',1,'D','D-1','pending')",
        (FIXTURE_PASSWORD_HASH,),
    )
    connection.execute(
        "INSERT INTO teachers (id, name, email, password, role, is_active, token,"
        " token_expires_at, created_at, short_code, can_approve_registrations)"
        " VALUES (1,'Admin User','admin@x.edu',?,'admin',1,?,?,"
        "'2026-10-10 17:51:55',NULL,0)",
        (FIXTURE_PASSWORD_HASH, FIXTURE_TOKEN, FIXTURE_TOKEN_EXPIRY),
    )
    connection.execute(
        "INSERT INTO teachers (id, name, email, password, role, is_active,"
        " created_at, short_code, can_approve_registrations) VALUES"
        " (2,'Teacher Two','t2@x.edu',?,'teacher',1,'2026-10-11 06:09:26',NULL,0)",
        (FIXTURE_PASSWORD_HASH,),
    )
    connection.executemany(
        "INSERT INTO timetable_entries (id, day, start_time, end_time, subject,"
        " faculty, room, division, batch, is_break)"
        " VALUES (?,?,?,?,?,?,NULL,'D',?,?)",
        BASELINE_TIMETABLE,
    )
    connection.execute(
        "INSERT INTO assignments (id, title, subject, stored_name, original_name,"
        " file_size, uploaded_by, created_at) VALUES"
        " (1,'Sheet 1','FPL','stored-1.pdf','sheet-1.pdf',1024,2,'2026-10-12 10:00:00')"
    )
    connection.execute(
        "INSERT INTO subjects (id, name, short_name, code, faculty_code, kind,"
        " source) VALUES (1,'Engineering Physics','PHY','BSC-102','SPG','theory',"
        "'official_timetable')"
    )
    connection.execute(
        "INSERT INTO subjects (id, name, short_name, code, faculty_code, kind,"
        " source) VALUES (2,'Engineering Physics (Practical)','PHY','BSC-102',"
        "'SPG','practical','official_timetable')"
    )
    connection.execute(
        "INSERT INTO faculty_directory (id, short_code, full_name, role_note,"
        " is_verified, source) VALUES"
        " (1,'SMG','Mrs. S. M. Gangurde','Class Coordinator (Division D)',1,"
        "'official_timetable')"
    )
    connection.execute(
        "INSERT INTO faculty_directory (id, short_code, full_name, role_note,"
        " is_verified, source) VALUES (2,'HBW',NULL,NULL,0,NULL)"
    )
    connection.execute(
        "INSERT INTO lab_directory (id, name, code, room, building, floor,"
        " subject, kind, source, is_verified) VALUES"
        " (1,'Division D Classroom','M308','M308','Block-11',NULL,NULL,"
        "'classroom','official_timetable',1)"
    )
    connection.execute(
        "INSERT INTO teacher_assignments (id, teacher_id, subject, division, batch)"
        " VALUES (1,2,'FPL','D','D-3')"
    )
    connection.execute(
        "INSERT INTO attendance_records (id, student_id, timetable_entry_id, date,"
        " status, updated_by) VALUES (1,1,1,'2026-10-13','present',2)"
    )
    connection.execute(
        "INSERT INTO free_period_claims (id, teacher_id, timetable_entry_id, date,"
        " claimed_at) VALUES (1,2,17,'2026-10-13','2026-10-13 09:00:00')"
    )
    connection.commit()
    connection.close()


def apply_valid_migration(baseline, target, add_column=True):
    """The reviewed plan, applied to a copy: schema step + nine row changes."""
    shutil.copyfile(baseline, target)
    connection = sqlite3.connect(target)
    if add_column:
        connection.execute(
            "ALTER TABLE timetable_entries ADD COLUMN is_free_period BOOLEAN"
            " NOT NULL DEFAULT 0"
        )
    connection.execute("UPDATE timetable_entries SET faculty='HBW' WHERE id IN (50,51)")
    connection.execute("UPDATE timetable_entries SET faculty='RVS (CCI)' WHERE id IN (23,44)")
    connection.execute(
        "UPDATE timetable_entries SET is_break=0 WHERE id IN (17,18,28,53,54)"
    )
    if add_column:
        connection.execute(
            "UPDATE timetable_entries SET is_free_period=1 WHERE id IN (17,18,28,53,54)"
        )
    # Official data: inserts plus the only two existing-row edits the seeder makes.
    connection.execute(
        "INSERT INTO subjects (id, name, short_name, code, faculty_code, kind,"
        " source) VALUES (3,'Fundamentals of Programming Languages','FPL',"
        "'ESC-105','RVS','theory','official_timetable')"
    )
    connection.execute(
        "INSERT INTO faculty_directory (id, short_code, full_name, role_note,"
        " is_verified, source) VALUES (3,'SPG',NULL,NULL,0,'official_timetable')"
    )
    connection.execute(
        "INSERT INTO lab_directory (id, name, code, room, building, floor, subject,"
        " kind, source, is_verified) VALUES (2,'Physics Lab','PHYL','PHYL',NULL,"
        "NULL,'PHY','laboratory','official_timetable',1)"
    )
    connection.execute(
        "UPDATE faculty_directory SET full_name='Mr. H. B. Wagh',"
        " role_note='Assistant Professor', is_verified=1 WHERE id=2"
    )
    connection.commit()
    connection.close()


def run_verifier(before, after):
    return subprocess.run(
        [PYTHON, str(VERIFIER), "--before", str(before), "--after", str(after)],
        capture_output=True,
        text=True,
        cwd=str(Path(before).parent),
    )


def mutate(path, sql, params=()):
    connection = sqlite3.connect(path)
    connection.execute(sql, params)
    connection.commit()
    connection.close()


def drop_column(path, table, column):
    """Remove a column by rebuilding the table (no sqlite version dependency)."""
    connection = sqlite3.connect(path)
    columns = [row[1] for row in connection.execute(f'PRAGMA table_info("{table}")')]
    keep = [name for name in columns if name != column]
    quoted = ", ".join(f'"{name}"' for name in keep)
    connection.execute(f'CREATE TABLE rebuilt AS SELECT {quoted} FROM "{table}"')
    connection.execute(f'DROP TABLE "{table}"')
    connection.execute(f'ALTER TABLE rebuilt RENAME TO "{table}"')
    connection.commit()
    connection.close()


def make_empty_database(path):
    """A valid SQLite file with no user tables."""
    connection = sqlite3.connect(path)
    connection.execute("CREATE TABLE scratch (id INTEGER PRIMARY KEY)")
    connection.execute("DROP TABLE scratch")
    connection.commit()
    connection.close()


def fresh(tmp, name):
    """A baseline plus a validly migrated copy, in their own sub-directory."""
    directory = tmp / name
    directory.mkdir(parents=True, exist_ok=True)
    before = directory / "before.db"
    after = directory / "after.db"
    build_baseline(before)
    apply_valid_migration(before, after)
    return before, after


# ===========================================================================
# 1. A valid migration passes, and leaks nothing
# ===========================================================================
with tempfile.TemporaryDirectory(prefix="cs-verify-") as tmpdir:
    tmp = Path(tmpdir)

    print("\n1. A valid migration passes and leaks no credential")
    before, after = fresh(tmp, "valid")
    before_sha, after_sha = sha256_of(before), sha256_of(after)
    result = run_verifier(before, after)
    combined = result.stdout + result.stderr

    check("valid run: exit 0", result.returncode == 0, f"rc={result.returncode}")
    check(
        "valid run: reports OK",
        "OK - the migration changed exactly the nine approved rows." in result.stdout,
        result.stdout[-400:],
    )
    check("valid run: no FAIL line", "FAIL" not in result.stdout, result.stdout[-600:])
    check(
        "valid run: the nine approved rows were compared",
        "9 approved rows" in result.stdout and "54 rows compared" in result.stdout,
        result.stdout,
    )
    check(
        "valid run: inserts are reported as notes",
        "note  subjects:" in result.stdout and "note  faculty_directory:" in result.stdout,
        result.stdout,
    )
    leaked = [secret for secret in FIXTURE_SECRETS if secret in combined]
    check(
        "valid run: no fixture credential appears in the output",
        leaked == [],
        f"leaked={leaked}",
    )
    check(
        "valid run: no redaction marker is needed when nothing sensitive changed",
        "<redacted>" not in combined,
    )
    check(
        "valid run: the verifier wrote to neither file",
        sha256_of(before) == before_sha and sha256_of(after) == after_sha,
    )

    # -----------------------------------------------------------------------
    print("\n2. A credential-only change is caught and redacted (F1)")
    # -----------------------------------------------------------------------
    before, after = fresh(tmp, "drift")
    mutate(
        after,
        "UPDATE teachers SET token=?, token_expires_at='2031-02-03 04:05:06' WHERE id=1",
        (DRIFTED_TOKEN,),
    )
    result = run_verifier(before, after)
    combined = result.stdout + result.stderr
    check("session drift on teachers: exit 1", result.returncode == 1, f"rc={result.returncode}")
    check(
        "session drift: the changed column is named",
        "teachers id=1.token" in result.stdout and "teachers id=1.token_expires_at" in result.stdout,
        result.stdout[-800:],
    )
    check(
        "session drift: both changed columns are shown as redacted",
        combined.count("<redacted>") >= 2
        and "value changed <redacted>" in combined,
        combined[-600:],
    )
    leaked = [
        value
        for value in (DRIFTED_TOKEN, FIXTURE_TOKEN, FIXTURE_TOKEN_EXPIRY, FIXTURE_PASSWORD_HASH)
        if value in combined
    ]
    check("session drift: no credential value is printed", leaked == [], f"leaked={leaked}")
    check(
        "session drift: the message explains the backend must be stopped",
        "backend was still running" in result.stdout,
        result.stdout[-600:],
    )

    # -----------------------------------------------------------------------
    print("\n3. Structural timetable changes are rejected")
    # -----------------------------------------------------------------------
    before, after = fresh(tmp, "deleted")
    mutate(after, "DELETE FROM timetable_entries WHERE id = 22")
    result = run_verifier(before, after)
    check("deleted row: exit 1", result.returncode == 1, f"rc={result.returncode}")
    check("deleted row: names the id", "row id=22 was deleted" in result.stdout, result.stdout[-600:])
    check(
        "deleted row: the row-count check fails too",
        "found 53 rows, expected 54" in result.stdout,
        result.stdout[-600:],
    )

    before, after = fresh(tmp, "inserted")
    mutate(
        after,
        "INSERT INTO timetable_entries (id, day, start_time, end_time, subject,"
        " faculty, room, division, batch, is_break, is_free_period) VALUES"
        " (55,'Sunday','10:15','11:15','XYZ','',NULL,'D',NULL,0,0)",
    )
    result = run_verifier(before, after)
    check("inserted row: exit 1", result.returncode == 1, f"rc={result.returncode}")
    check("inserted row: names the id", "row id=55 was inserted" in result.stdout, result.stdout[-600:])

    before, after = fresh(tmp, "wrongid")
    mutate(after, "UPDATE timetable_entries SET day='Friday' WHERE id = 50")
    result = run_verifier(before, after)
    check("wrong row identity: exit 1", result.returncode == 1, f"rc={result.returncode}")
    check(
        "wrong row identity: shows expected vs actual",
        "expected ('Saturday', '13:00', '14:00', 'CCC-1')" in result.stdout,
        result.stdout[-800:],
    )

    # -----------------------------------------------------------------------
    print("\n4. Field-level changes are exact")
    # -----------------------------------------------------------------------
    before, after = fresh(tmp, "unapproved")
    mutate(after, "UPDATE timetable_entries SET faculty='XYZ' WHERE id = 53")
    result = run_verifier(before, after)
    check("unapproved field: exit 1", result.returncode == 1, f"rc={result.returncode}")
    check(
        "unapproved field: says it is not approved",
        "timetable_entries id=53.faculty" in result.stdout
        and "(not an approved change)" in result.stdout,
        result.stdout[-800:],
    )

    before, after = fresh(tmp, "wrongnew")
    mutate(after, "UPDATE timetable_entries SET faculty='ZZZ' WHERE id = 50")
    result = run_verifier(before, after)
    check("wrong new value: exit 1", result.returncode == 1, f"rc={result.returncode}")
    check(
        "wrong new value: states the expected new value",
        "the plan expects 'HBW'" in result.stdout,
        result.stdout[-800:],
    )

    before, after = fresh(tmp, "wrongold")
    mutate(before, "UPDATE timetable_entries SET faculty='HBW' WHERE id = 50")
    apply_valid_migration(before, after)
    result = run_verifier(before, after)
    check("wrong old value: exit 1", result.returncode == 1, f"rc={result.returncode}")
    check(
        "wrong old value: states the expected old value",
        "before is 'HBW', the plan expects 'DPK'" in result.stdout,
        result.stdout[-800:],
    )

    before, after = fresh(tmp, "sixth")
    mutate(after, "UPDATE timetable_entries SET is_free_period=1 WHERE id = 16")
    result = run_verifier(before, after)
    check("sixth free period: exit 1", result.returncode == 1, f"rc={result.returncode}")
    check(
        "sixth free period: cites the declared default",
        "its declared default is 0" in result.stdout,
        result.stdout[-800:],
    )

    before, after = fresh(tmp, "breakflip")
    mutate(after, "UPDATE timetable_entries SET is_break=0 WHERE id = 16")
    result = run_verifier(before, after)
    check("unapproved break flag: exit 1", result.returncode == 1, f"rc={result.returncode}")

    before, after = fresh(tmp, "typo")
    mutate(after, "UPDATE timetable_entries SET faculty='RVS (CC1)' WHERE id = 23")
    result = run_verifier(before, after)
    check("the (CCI) typo left unfixed: exit 1", result.returncode == 1, f"rc={result.returncode}")
    check(
        "the (CCI) typo: states the expected value",
        "the plan expects 'RVS (CCI)'" in result.stdout,
        result.stdout[-800:],
    )

    before, after = fresh(tmp, "nocolumn")
    apply_valid_migration(before, after, add_column=False)
    result = run_verifier(before, after)
    check("is_free_period never added: exit 1", result.returncode == 1, f"rc={result.returncode}")
    check(
        "is_free_period never added: the plan's column is reported missing",
        "no such column exists in either snapshot" in result.stdout,
        result.stdout[-800:],
    )

    # -----------------------------------------------------------------------
    print("\n5. Schema changes are exact")
    # -----------------------------------------------------------------------
    before, after = fresh(tmp, "extracolumn")
    mutate(after, "ALTER TABLE timetable_entries ADD COLUMN extra_flag INTEGER")
    result = run_verifier(before, after)
    check("undeclared column: exit 1", result.returncode == 1, f"rc={result.returncode}")
    check(
        "undeclared column: named as undeclared",
        "timetable_entries.extra_flag was added but is not declared" in result.stdout,
        result.stdout[-800:],
    )

    before, after = fresh(tmp, "droppedcolumn")
    drop_column(after, "timetable_entries", "room")
    result = run_verifier(before, after)
    check("dropped column: exit 1", result.returncode == 1, f"rc={result.returncode}")
    check(
        "dropped column: reported as dropped",
        "timetable_entries.room was dropped" in result.stdout,
        result.stdout[-800:],
    )

    before, after = fresh(tmp, "extratable")
    mutate(after, "CREATE TABLE scratch (id INTEGER PRIMARY KEY)")
    result = run_verifier(before, after)
    check("unexpected table: exit 1", result.returncode == 1, f"rc={result.returncode}")
    check(
        "unexpected table: named",
        "unexpected new table: scratch" in result.stdout,
        result.stdout[-800:],
    )

    before, after = fresh(tmp, "emptyafter")
    after.unlink()
    make_empty_database(after)
    result = run_verifier(before, after)
    check("empty database as --after: exit 1", result.returncode == 1, f"rc={result.returncode}")
    check(
        "empty database as --after: reports the missing tables",
        "table removed: timetable_entries" in result.stdout,
        result.stdout[-800:],
    )

    # -----------------------------------------------------------------------
    print("\n6. Every preserved table is protected")
    # -----------------------------------------------------------------------
    preserved_mutations = [
        ("students", "UPDATE students SET name='MUTATED' WHERE id=1"),
        ("teachers", "UPDATE teachers SET name='MUTATED' WHERE id=2"),
        ("assignments", "UPDATE assignments SET title='MUTATED' WHERE id=1"),
        ("teacher_assignments", "UPDATE teacher_assignments SET batch='MUTATED' WHERE id=1"),
        ("attendance_records", "UPDATE attendance_records SET status='MUTATED' WHERE id=1"),
        ("free_period_claims", "UPDATE free_period_claims SET date='MUTATED' WHERE id=1"),
    ]
    for table, sql in preserved_mutations:
        before, after = fresh(tmp, f"preserve-{table}")
        mutate(after, sql)
        result = run_verifier(before, after)
        check(
            f"{table}: an edit is rejected",
            result.returncode == 1 and f"{table} id=" in result.stdout,
            f"rc={result.returncode}",
        )

    before, after = fresh(tmp, "preserve-insert")
    mutate(
        after,
        "INSERT INTO students (id, email, roll_number, name, status) VALUES"
        " (99,'c@x.edu','99','New Student','pending')",
    )
    result = run_verifier(before, after)
    check(
        "students: an insert is rejected",
        result.returncode == 1 and "students id=99 was inserted" in result.stdout,
        f"rc={result.returncode} {result.stdout[-400:]}",
    )

    before, after = fresh(tmp, "preserve-delete")
    mutate(after, "DELETE FROM students WHERE id=2")
    result = run_verifier(before, after)
    check(
        "students: a delete is rejected",
        result.returncode == 1 and "students id=2 was deleted" in result.stdout,
        f"rc={result.returncode} {result.stdout[-400:]}",
    )

    # -----------------------------------------------------------------------
    print("\n7. Official-data rules are exact (F3)")
    # -----------------------------------------------------------------------
    before, after = fresh(tmp, "subjectchange")
    mutate(after, "UPDATE subjects SET faculty_code='XXX' WHERE id=1")
    result = run_verifier(before, after)
    check("subjects: an existing row edit is rejected", result.returncode == 1, f"rc={result.returncode}")
    check(
        "subjects: the row is named",
        "subjects id=1.faculty_code" in result.stdout,
        result.stdout[-800:],
    )

    before, after = fresh(tmp, "labchange")
    mutate(after, "UPDATE lab_directory SET code='CHANGED' WHERE id=1")
    result = run_verifier(before, after)
    check("lab_directory: an existing row edit is rejected", result.returncode == 1, f"rc={result.returncode}")

    before, after = fresh(tmp, "facultyoverwrite")
    mutate(after, "UPDATE faculty_directory SET full_name='Overwritten' WHERE id=1")
    result = run_verifier(before, after)
    check("faculty full_name overwrite: rejected", result.returncode == 1, f"rc={result.returncode}")

    before, after = fresh(tmp, "facultyunverify")
    mutate(after, "UPDATE faculty_directory SET is_verified=0 WHERE id=1")
    result = run_verifier(before, after)
    check("faculty is_verified 1 -> 0: rejected", result.returncode == 1, f"rc={result.returncode}")

    before, after = fresh(tmp, "facultyclear")
    mutate(after, "UPDATE faculty_directory SET role_note=NULL WHERE id=1")
    result = run_verifier(before, after)
    check("faculty role_note cleared: rejected", result.returncode == 1, f"rc={result.returncode}")

    before, after = fresh(tmp, "facultydelete")
    mutate(after, "DELETE FROM faculty_directory WHERE id=1")
    result = run_verifier(before, after)
    check("faculty row deleted: rejected", result.returncode == 1, f"rc={result.returncode}")

    # A blank-fill is ALLOWED, not REQUIRED: if the seeder finds no official
    # value for a row it simply leaves it alone, so an unfilled row must not be
    # reported as a mismatch. (Consequence: this verifier cannot prove that an
    # optional fill happened - see the note in the report.)
    before, after = fresh(tmp, "facultyfillskipped")
    mutate(after, "UPDATE faculty_directory SET full_name=NULL WHERE id=2")
    result = run_verifier(before, after)
    check(
        "a faculty fill the seeder did not make is accepted (fills are optional)",
        result.returncode == 0,
        f"rc={result.returncode} {result.stdout[-400:]}",
    )

    # -----------------------------------------------------------------------
    print("\n8. Preconditions and unreadable inputs fail closed")
    # -----------------------------------------------------------------------
    before, after = fresh(tmp, "baselinepostdates")
    mutate(before, "ALTER TABLE timetable_entries ADD COLUMN is_free_period INTEGER DEFAULT 0")
    result = run_verifier(before, after)
    check("baseline already has the column: exit 2", result.returncode == 2, f"rc={result.returncode}")
    check(
        "baseline already has the column: explains the requirement",
        "baseline postdates the additive schema step" in result.stdout
        and "Nothing was compared" in result.stdout,
        result.stdout[-600:],
    )

    before, after = fresh(tmp, "unmigrated")
    shutil.copyfile(before, after)
    result = run_verifier(before, after)
    check("no migration at all: exit 1", result.returncode == 1, f"rc={result.returncode}")

    before, _ = fresh(tmp, "missing")
    result = run_verifier(tmp / "missing" / "does-not-exist.db", before)
    check("missing --before: exit 2", result.returncode == 2, f"rc={result.returncode}")
    check("missing --before: says file not found", "file not found" in result.stdout, result.stdout[-300:])

    result = run_verifier(before, tmp / "missing" / "does-not-exist.db")
    check("missing --after: exit 2", result.returncode == 2, f"rc={result.returncode}")

    garbage = tmp / "garbage.db"
    garbage.write_bytes(b"not a database" * 10)
    result = run_verifier(garbage, before)
    check("non-SQLite file: exit 2", result.returncode == 2, f"rc={result.returncode}")
    check(
        "non-SQLite file: says bad header",
        "not a SQLite database" in result.stdout,
        result.stdout[-300:],
    )

    empty = tmp / "zero.db"
    empty.write_bytes(b"")
    result = run_verifier(empty, before)
    check("zero-byte file: exit 2", result.returncode == 2, f"rc={result.returncode}")
    check("zero-byte file: says empty", "empty" in result.stdout, result.stdout[-300:])

    directory = tmp / "adir"
    directory.mkdir(exist_ok=True)
    result = run_verifier(directory, before)
    check("a directory as a path: exit 2", result.returncode == 2, f"rc={result.returncode}")
    check("a directory as a path: says not a file", "not a file" in result.stdout, result.stdout[-300:])

    result = subprocess.run(
        [PYTHON, str(VERIFIER)], capture_output=True, text=True
    )
    check(
        "no arguments: exit 2 (argparse usage error)",
        result.returncode == 2,
        f"rc={result.returncode}",
    )

    # -----------------------------------------------------------------------
    print("\n9. Determinism and a clean second run")
    # -----------------------------------------------------------------------
    before, after = fresh(tmp, "determinism")
    first = run_verifier(before, after)
    second = run_verifier(before, after)
    check(
        "the same inputs give the same exit code",
        first.returncode == second.returncode == 0,
        f"{first.returncode} vs {second.returncode}",
    )
    check("the same inputs give the same output", first.stdout == second.stdout)

# ===========================================================================
# 10. The verifier agrees with the seeder and with official_data.py
# ===========================================================================
sys.path.insert(0, str(BACKEND_DIR))
try:
    import models  # noqa: E402
    import official_data as official  # noqa: E402
    import rehearse_official_data_migration as rehearsal  # noqa: E402
    import seed_official_data as seeder  # noqa: E402
    import verify_official_data_migration as verifier  # noqa: E402

    IMPORTS_OK = True
    IMPORT_ERROR = ""
except Exception as exc:  # pragma: no cover - reported as a failure below
    IMPORTS_OK = False
    IMPORT_ERROR = f"{type(exc).__name__}: {exc}"

print("\n10. Verifier, seeder and official_data.py agree")
if not check("modules import cleanly", IMPORTS_OK, IMPORT_ERROR):
    pass
else:
    # -- the declared additive columns and their defaults -------------------
    declared = {(table, column): ddl for table, column, ddl in seeder.ADDITIVE_COLUMNS}

    def ddl_default(ddl):
        match = re.search(r"DEFAULT\s+([A-Za-z0-9_'\"]+)", ddl, re.IGNORECASE)
        if not match:
            return None
        token = match.group(1).strip("'\"")
        return int(token) if token.isdigit() else token

    mismatched = []
    for (table, column), expected in verifier.APPROVED_NEW_COLUMNS.items():
        ddl = declared.get((table, column))
        if ddl is None:
            mismatched.append(f"{table}.{column} is not in the seeder's ADDITIVE_COLUMNS")
        elif ddl_default(ddl) != expected:
            mismatched.append(
                f"{table}.{column}: verifier says default {expected!r}, "
                f"seeder DDL says {ddl_default(ddl)!r}"
            )
    check(
        "every declared new column matches the seeder's ADDITIVE_COLUMNS and default",
        mismatched == [],
        str(mismatched),
    )

    check(
        "the column this migration creates is in the seeder's ADDITIVE_COLUMNS",
        all(item in declared for item in verifier.BASELINE_MUST_PREDATE),
        str(verifier.BASELINE_MUST_PREDATE),
    )

    # -- which fields the seeder is allowed to touch ------------------------
    def assigned_attributes(source, receiver):
        tree = ast.parse(source)
        found = set()
        for node in ast.walk(tree):
            if isinstance(node, ast.Assign):
                for target in node.targets:
                    if (
                        isinstance(target, ast.Attribute)
                        and isinstance(target.value, ast.Name)
                        and target.value.id == receiver
                    ):
                        found.add(target.attr)
        return found

    seeder_source = SEEDER.read_text(encoding="utf-8")
    faculty_fields = assigned_attributes(seeder_source, "row")
    expected_faculty_fields = set(verifier.FACULTY_FILL_COLUMNS) | {
        verifier.FACULTY_VERIFY_COLUMN
    }
    check(
        "the verifier's faculty columns are exactly the fields the seeder fills",
        faculty_fields == expected_faculty_fields,
        f"seeder={sorted(faculty_fields)} verifier={sorted(expected_faculty_fields)}",
    )

    timetable_fields = assigned_attributes(seeder_source, "db_row")
    approved_fields = {
        column
        for changes in verifier.APPROVED_TIMETABLE_CHANGES.values()
        for column in changes
    }
    check(
        "the verifier's approved timetable fields are exactly the fields the seeder corrects",
        timetable_fields == approved_fields,
        f"seeder={sorted(timetable_fields)} verifier={sorted(approved_fields)}",
    )

    # -- no table is left unchecked ----------------------------------------
    model_tables = set(models.Base.metadata.tables)
    covered = (
        set(verifier.PRESERVED_TABLES)
        | set(verifier.OFFICIAL_TABLES)
        | set(verifier.UNRELATED_TABLES)
        | {verifier.TIMETABLE_TABLE}
    )
    check(
        "every table in the schema is classified "
        "(preserved, official, unrelated or timetable)",
        model_tables == covered,
        f"uncovered={sorted(model_tables - covered)} extra={sorted(covered - model_tables)}",
    )
    check(
        "no table is in two categories",
        not (
            set(verifier.PRESERVED_TABLES) & set(verifier.OFFICIAL_TABLES)
            or set(verifier.PRESERVED_TABLES) & set(verifier.UNRELATED_TABLES)
            or set(verifier.OFFICIAL_TABLES) & set(verifier.UNRELATED_TABLES)
            or verifier.TIMETABLE_TABLE in set(verifier.PRESERVED_TABLES)
            | set(verifier.OFFICIAL_TABLES)
            | set(verifier.UNRELATED_TABLES)
        ),
    )

    # -- the plan matches the official grid and the live baseline ----------
    grid = {}
    for row in seeder.official_grid_rows():
        key = (
            row["day"],
            row["start_time"],
            row["end_time"],
            row["subject"],
            seeder.normalise_batch(row["batch"]),
        )
        grid[key] = row

    baseline_by_key = {}
    for rid, day, start, end, subject, _faculty, batch, _is_break in BASELINE_TIMETABLE:
        baseline_by_key[(day, start, end, subject, seeder.normalise_batch(batch))] = rid

    check(
        "the baseline fixture has the same 54 slots as official_data.py",
        set(baseline_by_key) == set(grid),
        f"baseline_only={sorted(set(baseline_by_key) - set(grid))} "
        f"grid_only={sorted(set(grid) - set(baseline_by_key))}",
    )
    check(
        "the baseline fixture has 54 rows",
        len(baseline_by_key) == verifier.EXPECTED_TIMETABLE_ROWS == 54,
        f"fixture={len(baseline_by_key)} verifier={verifier.EXPECTED_TIMETABLE_ROWS}",
    )

    # Rows whose faculty disagrees between the live baseline and the sheet are
    # exactly the four the verifier approves.
    faculty_mismatch = {
        rid
        for key, rid in baseline_by_key.items()
        if key in grid and (FACULTY_BY_ID[rid] or "") != (grid[key]["faculty"] or "")
    }
    check(
        "exactly the four faculty cells disagree, and the verifier approves the same ids",
        faculty_mismatch == {23, 44, 50, 51}
        and {rid for rid, c in verifier.APPROVED_TIMETABLE_CHANGES.items() if "faculty" in c}
        == {23, 44, 50, 51},
        f"derived={sorted(faculty_mismatch)}",
    )

    # Rows whose is_break disagrees are exactly the five RELM rows.
    break_mismatch = {
        rid
        for key, rid in baseline_by_key.items()
        if key in grid and bool(BREAK_BY_ID[rid]) != bool(grid[key]["is_break"])
    }
    check(
        "exactly the five RELM rows disagree on is_break, and the verifier approves them",
        break_mismatch == {17, 18, 28, 53, 54}
        and {rid for rid, c in verifier.APPROVED_TIMETABLE_CHANGES.items() if "is_break" in c}
        == {17, 18, 28, 53, 54},
        f"derived={sorted(break_mismatch)}",
    )

    # The five free-period ids must be the sheet's five RELM slots.
    free_ids = {
        rid for rid, c in verifier.APPROVED_TIMETABLE_CHANGES.items() if "is_free_period" in c
    }
    free_slots = set()
    for key, rid in baseline_by_key.items():
        if rid in free_ids:
            free_slots.add((key[0], key[1], key[2]))
    check(
        "the five approved free periods are exactly official_data.FREE_PERIOD_SLOTS",
        free_slots == set(official.FREE_PERIOD_SLOTS) and len(free_ids) == 5,
        f"verifier={sorted(free_slots)} official={sorted(official.FREE_PERIOD_SLOTS)}",
    )

    # Every approved new value must equal what the official grid says, and the
    # old value must equal the live baseline.
    value_problems = []
    for rid, changes in verifier.APPROVED_TIMETABLE_CHANGES.items():
        key = next(k for k, value in baseline_by_key.items() if value == rid)
        official_row = grid[key]
        for column, (expected_old, expected_new) in changes.items():
            if column == "faculty":
                actual_old, actual_new = FACULTY_BY_ID[rid], official_row["faculty"]
            elif column == "is_break":
                actual_old, actual_new = int(bool(BREAK_BY_ID[rid])), int(bool(official_row["is_break"]))
            elif column == "is_free_period":
                actual_old, actual_new = None, int(bool(official_row["is_free_period"]))
            else:
                value_problems.append(f"{rid}.{column}: unknown column")
                continue
            if expected_old is not verifier.ABSENT and expected_old != actual_old:
                value_problems.append(
                    f"{rid}.{column}: plan old {expected_old!r} != baseline {actual_old!r}"
                )
            if expected_new != actual_new:
                value_problems.append(
                    f"{rid}.{column}: plan new {expected_new!r} != official {actual_new!r}"
                )
    check(
        "every approved old/new value matches the baseline and the official sheet",
        value_problems == [],
        str(value_problems),
    )

    identity_problems = []
    for rid, identity in verifier.APPROVED_ROW_IDENTITY.items():
        key = next((k for k, value in baseline_by_key.items() if value == rid), None)
        if key is None:
            identity_problems.append(f"id {rid} is not present in the baseline fixture")
        elif identity != (key[0], key[1], key[2], key[3]):
            identity_problems.append(
                f"id {rid}: plan says {identity}, the baseline row is {(key[0], key[1], key[2], key[3])}"
            )
    check(
        "the approved ids' identities match the baseline fixture",
        identity_problems == [],
        str(identity_problems),
    )

    # -- interface guards ---------------------------------------------------
    interface = ast.parse(VERIFIER.read_text(encoding="utf-8"))
    options = set()
    for node in ast.walk(interface):
        if (
            isinstance(node, ast.Call)
            and isinstance(node.func, ast.Attribute)
            and node.func.attr == "add_argument"
            and node.args
            and isinstance(node.args[0], ast.Constant)
        ):
            options.add(node.args[0].value)
    check(
        "the verifier accepts only --before and --after (no session-drift override)",
        options == {"--before", "--after"},
        str(sorted(options)),
    )

    docstring = ast.get_docstring(interface) or ""
    check(
        "the docstring documents the pre-schema baseline requirement",
        "MUST PREDATE THE ADDITIVE SCHEMA STEP" in docstring,
    )
    check(
        "the docstring documents that the backend must be stopped",
        "THE BACKEND MUST BE STOPPED" in docstring,
    )

    # Secrets may only be named inside a *_COLUMNS declaration.
    sensitive_names = {"password", "password_hash", "token", "token_expires_at"}
    declaration_nodes = [
        node
        for node in ast.walk(interface)
        if isinstance(node, ast.Assign)
        and isinstance(node.targets[0], ast.Name)
        and node.targets[0].id.endswith("_COLUMNS")
    ]
    declared_inside = set()
    for node in declaration_nodes:
        for inner in ast.walk(node):
            if isinstance(inner, ast.Constant) and inner.value in sensitive_names:
                declared_inside.add(inner.value)
    known = {id(inner) for node in declaration_nodes for inner in ast.walk(node)}
    elsewhere = sorted(
        node.value
        for node in ast.walk(interface)
        if isinstance(node, ast.Constant)
        and node.value in sensitive_names
        and id(node) not in known
    )
    check(
        "sensitive column names appear only in *_COLUMNS declarations",
        declared_inside == sensitive_names and elsewhere == [],
        f"declared={sorted(declared_inside)} elsewhere={elsewhere}",
    )
    check(
        "the redaction set covers every sensitive column the comparison touches",
        sensitive_names <= set(verifier.REDACTED_COLUMNS),
        str(sorted(verifier.REDACTED_COLUMNS)),
    )

    # -- the rehearsal harness still matches THIS verifier -------------------
    # The rehearsal asserts exact FAIL titles and problem lines. Those messages
    # live in the verifier, so a renamed or reworded message must fail HERE -
    # in the synthetic suite - instead of surfacing as a mysterious rehearsal
    # failure later. Templates are compared with every ``{...}`` placeholder
    # (and f-string interpolation) collapsed to one marker, so the check pins the
    # wording without pinning the run-time values.
    def normalise_template(text):
        collapsed = re.sub(r"\{[^{}]*\}", "\x00", text)
        return re.sub(r"\s+", " ", collapsed).strip()

    verifier_templates = set()
    for node in ast.walk(ast.parse(VERIFIER.read_text(encoding="utf-8"))):
        if isinstance(node, ast.JoinedStr):
            verifier_templates.add(
                normalise_template(
                    "".join(
                        value.value
                        if isinstance(value, ast.Constant) and isinstance(value.value, str)
                        else "\x00"
                        for value in node.values
                    )
                )
            )
        elif isinstance(node, ast.Constant) and isinstance(node.value, str):
            verifier_templates.add(normalise_template(node.value))

    drifted = sorted(
        name
        for name, template in rehearsal.EXPECTED_TEMPLATES.items()
        if normalise_template(template) not in verifier_templates
    )
    check(
        "every rehearsal message template still exists in this verifier",
        drifted == [] and len(rehearsal.EXPECTED_TEMPLATES) >= 30,
        f"drifted={drifted} templates={len(rehearsal.EXPECTED_TEMPLATES)}",
    )

    check(
        "the rehearsal covers six controls, labelled a-f",
        tuple(rehearsal.CONTROL_LETTERS) == ("a", "b", "c", "d", "e", "f")
        and len(set(rehearsal.CONTROL_LETTERS)) == 6,
        f"letters={rehearsal.CONTROL_LETTERS}",
    )
    check(
        "the rehearsal refuses a live writer with exit 3 and reports skips with exit 5",
        rehearsal.EXIT_REFUSED == 3
        and rehearsal.EXIT_INCOMPLETE == 5
        and rehearsal.EXIT_NOT_LANDED == 4,
        f"refused={rehearsal.EXIT_REFUSED} incomplete={rehearsal.EXIT_INCOMPLETE} "
        f"not_landed={rehearsal.EXIT_NOT_LANDED}",
    )
    check(
        "the rehearsal has no override flag",
        "add_argument" not in REHEARSAL.read_text(encoding="utf-8"),
        "an argparse option appeared in the rehearsal",
    )
    check(
        "the rehearsal's negative tests may only write n-*.db scratch files",
        rehearsal.SCRATCH_NAME.pattern == r"^n-\d+\.db$"
        and sorted(rehearsal.TEMPLATE_NAMES) == ["after.db", "before.db"],
        f"pattern={rehearsal.SCRATCH_NAME.pattern} templates={rehearsal.TEMPLATE_NAMES}",
    )
    check(
        "the rehearsal is import-safe: importing it must not have touched the database",
        stamp_of(REAL_DB) == REAL_DB_STAMP,
        f"before={REAL_DB_STAMP} after={stamp_of(REAL_DB)}",
    )

    # The negative tests must never be able to reach the live file or a template:
    # they build their target through scratch_path(), so its behaviour - and the
    # guards around it - are checked here rather than assumed.
    with tempfile.TemporaryDirectory(prefix="cs-rehearsal-guard-") as guard_dir:
        guard_root = Path(guard_dir)
        targets = [rehearsal.scratch_path(guard_root, index) for index in range(1, 7)]
        check(
            "the rehearsal injects only into n-1.db ... n-6.db inside its scratch root",
            [target.name for target in targets] == [f"n-{index}.db" for index in range(1, 7)]
            and all(guard_root.resolve() in target.parents for target in targets),
            f"targets={[target.name for target in targets]}",
        )

        refused_live = refused_outside = False
        try:
            rehearsal.assert_inside_scratch(REAL_DB, guard_root)
        except rehearsal.Refused:
            refused_live = True
        try:
            rehearsal.assert_inside_scratch(guard_root.parent / "n-9.db", guard_root)
        except rehearsal.Refused:
            refused_outside = True
        check(
            "the rehearsal refuses the live database and anything outside its scratch root",
            refused_live
            and refused_outside
            and rehearsal.SCRATCH_NAME.match("n-1.db") is not None
            and rehearsal.SCRATCH_NAME.match("after.db") is None
            and rehearsal.SCRATCH_NAME.match("before.db") is None,
            f"live={refused_live} outside={refused_outside}",
        )

# ===========================================================================
# 11. The real database was not touched
# ===========================================================================
print("\n11. The real database was not touched")
check(
    "real database SHA-256 unchanged by this suite",
    sha256_of(REAL_DB) == REAL_DB_SHA,
    f"before={REAL_DB_SHA[:16]} after={sha256_of(REAL_DB)[:16]}",
)
check(
    "real database size/mtime unchanged by this suite",
    stamp_of(REAL_DB) == REAL_DB_STAMP,
    f"before={REAL_DB_STAMP} after={stamp_of(REAL_DB)}",
)

print("\n" + "=" * 72)
print(f"verifier tests: {len(PASSED)} passed, {len(FAILED)} failed")
for failure in FAILED:
    print(f"  FAILED: {failure}")
print("=" * 72)
sys.exit(1 if FAILED else 0)
