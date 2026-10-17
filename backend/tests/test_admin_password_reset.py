"""Safety tests for reset_admin_password.py - temp databases only.

What is being protected
-----------------------
The one-time admin password reset is the only way to change
``admin@campusync.edu``'s password without a running backend. It must be
surgical:

* the new password comes from ``NEW_ADMIN_PASSWORD`` and is never printed,
  logged or hardcoded;
* a shorter-than-12-character password is refused;
* it resolves the SAME database path the backend uses (``DATABASE_URL``);
* it refuses to create an account, to change a non-admin account, and to
  change a deactivated account - in all three cases NOTHING is written;
* after a successful reset only that one ``password`` cell differs: other
  teachers/admins, student rows, roles, activity flags and session tokens are
  byte-for-byte identical;
* the real database is never opened.

RUN
---
    mkdir /tmp/cs-adminreset && cd /tmp/cs-adminreset
    <repo>/backend/venv/Scripts/python.exe <repo>/backend/tests/test_admin_password_reset.py
"""

import ast
import os
import sqlite3
import subprocess
import sys
import tempfile
from pathlib import Path

BACKEND_DIR = Path(__file__).resolve().parent.parent
REAL_DB = (BACKEND_DIR / "campussync.db").resolve()
RESET_SCRIPT = BACKEND_DIR / "reset_admin_password.py"
PYTHON = sys.executable

sys.path.insert(0, str(BACKEND_DIR))

from pwdlib import PasswordHash  # noqa: E402

PASSED = []
FAILED = []

ADMIN_EMAIL = "admin@campusync.edu"
OLD_ADMIN_PASSWORD = "OldAdminPassword123"
NEW_ADMIN_PASSWORD = "BrandNewAdminPassword456"
TEACHER_PASSWORD = "TeacherPassword123"
STUDENT_PASSWORD = "StudentPassword123"


def check(label, condition, detail=""):
    if condition:
        PASSED.append(label)
        print(f"  PASS  {label}")
    else:
        FAILED.append(f"{label} {detail}".strip())
        print(f"  FAIL  {label}  {detail}")
    return bool(condition)


def stamp_of(path: Path):
    """(size, mtime_ns) of a file, or None when it does not exist."""
    if not path.exists():
        return None
    stat = path.stat()
    return (stat.st_size, stat.st_mtime_ns)


REAL_DB_STAMP = stamp_of(REAL_DB)
REAL_DB_BACKUPS_BEFORE = sorted(REAL_DB.parent.glob("campussync.db.*.pre-admin-password-reset.bak"))


# --------------------------------------------------------------------------
# fixtures
# --------------------------------------------------------------------------
def clean_env(**overrides):
    """Environment for the script subprocess, without inherited secrets."""
    env = dict(os.environ)
    for name in ("DATABASE_URL", "ALLOW_DB_CREATE", "NEW_ADMIN_PASSWORD"):
        env.pop(name, None)
    env.update({k: str(v) for k, v in overrides.items()})
    return env


def hash_password(password: str) -> str:
    return PasswordHash.recommended().hash(password)


TEACHERS_DDL = """
CREATE TABLE teachers (
    id INTEGER PRIMARY KEY,
    name TEXT NOT NULL,
    email TEXT UNIQUE NOT NULL,
    password TEXT NOT NULL,
    role TEXT NOT NULL DEFAULT 'teacher',
    is_active BOOLEAN NOT NULL DEFAULT 1,
    token TEXT,
    token_expires_at TIMESTAMP,
    created_at TIMESTAMP NOT NULL
)
"""

STUDENTS_DDL = """
CREATE TABLE students (
    id INTEGER PRIMARY KEY,
    name TEXT NOT NULL,
    email TEXT UNIQUE NOT NULL,
    roll_number TEXT UNIQUE NOT NULL,
    branch TEXT NOT NULL,
    year INTEGER NOT NULL,
    division TEXT NOT NULL,
    batch TEXT NOT NULL,
    password TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'pending',
    approved_by INTEGER,
    approved_at TIMESTAMP,
    rejection_reason TEXT,
    photo_path TEXT,
    token TEXT,
    token_expires_at TIMESTAMP
)
"""

ADMIN_ROW = (1, "Admin User", ADMIN_EMAIL, OLD_ADMIN_PASSWORD, "admin", 1, "admin-session-token", "2026-10-18T10:00:00")
TEACHER_ROW = (2, "Teacher One", "teacher@campusync.edu", TEACHER_PASSWORD, "teacher", 1, "teacher-session-token", None)
OTHER_ADMIN_ROW = (3, "Second Admin", "admin2@campusync.edu", OLD_ADMIN_PASSWORD, "admin", 1, None, None)
STUDENT_ROWS = [
    (1, "SHUBHAM SURESH AHIRE", "campus.csync.student7@gmail.com", "7", "Computer", 1, "D", "D-3", STUDENT_PASSWORD, "pending", None, None, None, None, None, None),
    (2, "PENDING STUDENT", "campus.csync.student8@gmail.com", "8", "Computer", 1, "D", "D-2", STUDENT_PASSWORD, "approved", 1, "2026-10-11T10:00:00", None, None, "student-token", None),
]

ROWS_BY_EMAIL = {
    ADMIN_EMAIL: ADMIN_ROW,
    "teacher@campusync.edu": TEACHER_ROW,
    "admin2@campusync.edu": OTHER_ADMIN_ROW,
}


def make_db(path: Path, *, teachers=None, students=True, emails_as_stored=None):
    """Create a throwaway database with the real table shapes."""
    teachers = list(ROWS_BY_EMAIL.values()) if teachers is None else teachers
    emails_as_stored = emails_as_stored or {}

    conn = sqlite3.connect(str(path))
    try:
        conn.execute(TEACHERS_DDL)
        for row in teachers:
            teacher_id, name, email, password, role, is_active, token, expires = row
            stored_email = emails_as_stored.get(email, email)
            conn.execute(
                "INSERT INTO teachers (id, name, email, password, role, is_active, "
                "token, token_expires_at, created_at) VALUES (?,?,?,?,?,?,?,?,?)",
                (teacher_id, name, stored_email, hash_password(password), role,
                 is_active, token, expires, "2026-09-01T09:00:00"),
            )
        if students:
            conn.execute(STUDENTS_DDL)
            for row in STUDENT_ROWS:
                conn.execute(
                    "INSERT INTO students (id, name, email, roll_number, branch, year, "
                    "division, batch, password, status, approved_by, approved_at, "
                    "rejection_reason, photo_path, token, token_expires_at) "
                    "VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                    (row[0], row[1], row[2], row[3], row[4], row[5], row[6], row[7],
                     hash_password(row[8]), *row[9:]),
                )
        conn.commit()
    finally:
        conn.close()


def run_reset(env_db, password=None, extra_args=()):
    """Run the reset script as a subprocess against a throwaway database.

    The target is passed through DATABASE_URL so the script exercises the same
    resolution path the backend uses.
    """
    env = clean_env(**({"NEW_ADMIN_PASSWORD": password} if password else {}))
    env["DATABASE_URL"] = f"sqlite:///{Path(env_db).as_posix()}"
    return subprocess.run(
        [PYTHON, str(RESET_SCRIPT), *extra_args],
        cwd=str(BACKEND_DIR.parent),
        env=env,
        capture_output=True,
        text=True,
        timeout=180,
    )


def fetch_teachers(path: Path):
    conn = sqlite3.connect(str(path))
    try:
        return {
            row[0]: row
            for row in conn.execute(
                "SELECT email, password, name, role, is_active, token, "
                "token_expires_at, created_at FROM teachers"
            )
        }
    finally:
        conn.close()


def fetch_students(path: Path):
    conn = sqlite3.connect(str(path))
    try:
        return {
            row[0]: row
            for row in conn.execute(
                "SELECT email, password, status, roll_number, approved_at, token "
                "FROM students ORDER BY id"
            )
        }
    finally:
        conn.close()


def verify(password: str, stored_hash: str) -> bool:
    return PasswordHash.recommended().verify(password, stored_hash)


with tempfile.TemporaryDirectory(prefix="cs-adminreset-") as tmpdir:
    tmp = Path(tmpdir).resolve()

    # ----------------------------------------------------------------------
    print("\n1. The new password must come from NEW_ADMIN_PASSWORD")
    # ----------------------------------------------------------------------
    db = tmp / "teachers-only.db"
    make_db(db)
    before = fetch_teachers(db)

    result = run_reset(db)
    check(
        "missing NEW_ADMIN_PASSWORD is refused (exit 2)",
        result.returncode == 2,
        f"exit={result.returncode} stderr={result.stderr.strip()[-200:]}",
    )
    check(
        "the error names the environment variable",
        "NEW_ADMIN_PASSWORD" in (result.stderr + result.stdout),
    )
    check(
        "missing password: nothing was written",
        fetch_teachers(db) == before,
    )

    db = tmp / "short-password.db"
    make_db(db)
    before = fetch_teachers(db)
    result = run_reset(db, password="short-pass1")  # 11 characters
    check(
        "a password shorter than 12 characters is refused (exit 2)",
        result.returncode == 2,
        f"exit={result.returncode} stderr={result.stderr.strip()[-200:]}",
    )
    check(
        "the refusal states the minimum length",
        "12 characters" in (result.stderr + result.stdout),
    )
    check("short password: nothing was written", fetch_teachers(db) == before)

    exactly_12 = run_reset(db, password="twelve-chars")  # exactly 12
    check(
        "a 12-character password is accepted",
        exactly_12.returncode == 0,
        f"exit={exactly_12.returncode} stderr={exactly_12.stderr.strip()[-200:]}",
    )

    # ----------------------------------------------------------------------
    print("\n2. --dry-run changes nothing but reports the resolved path")
    # ----------------------------------------------------------------------
    db = tmp / "dry-run.db"
    make_db(db)
    before = fetch_teachers(db)

    result = run_reset(db, password=NEW_ADMIN_PASSWORD, extra_args=("--dry-run",))
    check("--dry-run exits 0", result.returncode == 0, f"exit={result.returncode}")
    check(
        "the resolved database path is printed",
        str(db) in result.stdout,
        result.stdout.strip()[-300:],
    )
    check(
        "--dry-run says nothing was written",
        "Nothing was written" in result.stdout,
    )
    check("--dry-run did not touch the password", fetch_teachers(db) == before)
    check(
        "--dry-run left no backup file behind",
        list(tmp.glob("dry-run.db.*.pre-admin-password-reset.bak")) == [],
    )

    # ----------------------------------------------------------------------
    print("\n3. A successful reset changes exactly one password cell")
    # ----------------------------------------------------------------------
    db = tmp / "success.db"
    make_db(db)
    teachers_before = fetch_teachers(db)
    students_before = fetch_students(db)
    conn = sqlite3.connect(str(db))
    try:
        counts_before = (
            conn.execute("SELECT COUNT(*) FROM teachers").fetchone()[0],
            conn.execute("SELECT COUNT(*) FROM students").fetchone()[0],
        )
    finally:
        conn.close()

    result = run_reset(db, password=NEW_ADMIN_PASSWORD)
    check(
        "the reset succeeds (exit 0)",
        result.returncode == 0,
        f"exit={result.returncode} stderr={result.stderr.strip()[-300:]}",
    )
    check(
        "success is reported clearly",
        "SUCCESS" in result.stdout,
        result.stdout.strip()[-300:],
    )
    check(
        "the resolved database path is printed before any write",
        str(db) in result.stdout,
    )

    teachers_after = fetch_teachers(db)
    admin_after = teachers_after[ADMIN_EMAIL]
    admin_before = teachers_before[ADMIN_EMAIL]

    check(
        "the new password verifies against the stored hash",
        verify(NEW_ADMIN_PASSWORD, admin_after[1]),
    )
    check(
        "the old password no longer verifies",
        not verify(OLD_ADMIN_PASSWORD, admin_after[1]),
    )
    check("the stored hash actually changed", admin_after[1] != admin_before[1])
    check(
        "the stored hash uses the backend's hasher (argon2 via pwdlib)",
        admin_after[1].startswith("$argon2"),
        admin_after[1][:20],
    )
    check(
        "name / role / is_active / token / created_at are unchanged",
        admin_after[0] == admin_before[0]
        and admin_after[2] == admin_before[2]
        and admin_after[3] == admin_before[3]
        and admin_after[4] == admin_before[4]
        and admin_after[5] == admin_before[5]
        and admin_after[6] == admin_before[6]
        and admin_after[7] == admin_before[7],
        f"before={admin_before} after={admin_after}",
    )
    check(
        "the second admin's password is untouched",
        teachers_after["admin2@campusync.edu"] == teachers_before["admin2@campusync.edu"],
    )
    check(
        "the teacher account is untouched",
        teachers_after["teacher@campusync.edu"] == teachers_before["teacher@campusync.edu"],
    )
    check(
        "the teacher's password still verifies",
        verify(TEACHER_PASSWORD, teachers_after["teacher@campusync.edu"][1]),
    )
    check(
        "student rows are byte-for-byte identical",
        fetch_students(db) == students_before,
        str(fetch_students(db)),
    )
    check(
        "the student's password still verifies",
        verify(STUDENT_PASSWORD, fetch_students(db)["campus.csync.student7@gmail.com"][1]),
    )

    conn = sqlite3.connect(str(db))
    try:
        counts_after = (
            conn.execute("SELECT COUNT(*) FROM teachers").fetchone()[0],
            conn.execute("SELECT COUNT(*) FROM students").fetchone()[0],
        )
    finally:
        conn.close()
    check("no account was created or deleted", counts_after == counts_before, str(counts_after))

    backups = list(tmp.glob("success.db.*.pre-admin-password-reset.bak"))
    check("a backup copy was taken before the write", len(backups) == 1, str(backups))
    if backups:
        original = sqlite3.connect(str(backups[0]))
        try:
            old_hash = original.execute(
                "SELECT password FROM teachers WHERE email = ?", (ADMIN_EMAIL,)
            ).fetchone()[0]
        finally:
            original.close()
        check(
            "the backup still holds the OLD hash",
            verify(OLD_ADMIN_PASSWORD, old_hash),
        )

    # ----------------------------------------------------------------------
    print("\n4. The password and hash are never printed")
    # ----------------------------------------------------------------------
    output = result.stdout + result.stderr
    check("the new password never appears in the output", NEW_ADMIN_PASSWORD not in output)
    check("the old password never appears in the output", OLD_ADMIN_PASSWORD not in output)
    check("the stored hash never appears in the output", admin_after[1] not in output)
    check(
        "no 'password: <value>' style echo is printed",
        "Password: " not in output,
    )

    # ----------------------------------------------------------------------
    print("\n5. Refusals write nothing")
    # ----------------------------------------------------------------------
    # 5a. no such account - and it must not be created
    empty = tmp / "no-admin.db"
    make_db(empty, teachers=[TEACHER_ROW])
    before = fetch_teachers(empty)
    result = run_reset(empty, password=NEW_ADMIN_PASSWORD)
    check(
        "a missing admin account is refused (exit 3)",
        result.returncode == 3,
        f"exit={result.returncode} stderr={result.stderr.strip()[-200:]}",
    )
    check("the refusal says REFUSED", "REFUSED" in (result.stderr + result.stdout))
    check("no account was created", fetch_teachers(empty) == before, str(fetch_teachers(empty)))

    # 5b. the target email belongs to a non-admin account
    non_admin = tmp / "not-admin.db"
    wrong_role = (*ADMIN_ROW[:4], "teacher", 1, None, None)
    make_db(non_admin, teachers=[wrong_role, TEACHER_ROW])
    before = fetch_teachers(non_admin)
    result = run_reset(non_admin, password=NEW_ADMIN_PASSWORD)
    check(
        "a non-admin account is refused (exit 3)",
        result.returncode == 3,
        f"exit={result.returncode} stderr={result.stderr.strip()[-200:]}",
    )
    check(
        "the refusal mentions the role",
        "role" in (result.stderr + result.stdout).lower(),
    )
    check("no password was changed", fetch_teachers(non_admin) == before)

    # 5c. deactivated admin
    inactive = tmp / "inactive.db"
    inactive_row = (*ADMIN_ROW[:5], 0, None, None)
    make_db(inactive, teachers=[inactive_row, OTHER_ADMIN_ROW])
    before = fetch_teachers(inactive)
    result = run_reset(inactive, password=NEW_ADMIN_PASSWORD)
    check(
        "a deactivated admin is refused (exit 3)",
        result.returncode == 3,
        f"exit={result.returncode} stderr={result.stderr.strip()[-200:]}",
    )
    check(
        "the refusal mentions is_active",
        "is_active" in (result.stderr + result.stdout),
    )
    check("no password was changed", fetch_teachers(inactive) == before)

    # 5d. the database file does not exist - never create it
    missing = tmp / "sub" / "missing.db"
    missing.parent.mkdir(parents=True, exist_ok=True)
    result = run_reset(missing, password=NEW_ADMIN_PASSWORD)
    check(
        "a missing database file is refused (exit 2)",
        result.returncode == 2,
        f"exit={result.returncode} stderr={result.stderr.strip()[-200:]}",
    )
    check("the missing database was NOT created", not missing.exists())

    # 5e. ambiguous match (two rows with the same email in different cases)
    ambiguous = tmp / "ambiguous.db"
    make_db(
        ambiguous,
        teachers=[
            ADMIN_ROW,
            (9, "Clone Admin", "admin2@campusync.edu", OLD_ADMIN_PASSWORD, "admin", 1, None, None),
        ],
        # the clone is stored with a case-variant of the admin address; the
        # teachers table's UNIQUE index is case-sensitive, so both can coexist
        emails_as_stored={"admin2@campusync.edu": "Admin@Campusync.edu"},
    )
    before = fetch_teachers(ambiguous)
    result = run_reset(ambiguous, password=NEW_ADMIN_PASSWORD)
    check(
        "an ambiguous (case-variant) match is refused (exit 3)",
        result.returncode == 3,
        f"exit={result.returncode} stderr={result.stderr.strip()[-200:]}",
    )
    check("ambiguous match: nothing was written", fetch_teachers(ambiguous) == before)

    # ----------------------------------------------------------------------
    print("\n6. --db overrides DATABASE_URL, and the default follows it")
    # ----------------------------------------------------------------------
    target = tmp / "chosen.db"
    decoy = tmp / "decoy.db"
    make_db(target)
    make_db(decoy)
    target_before = fetch_teachers(target)
    decoy_before = fetch_teachers(decoy)

    result = run_reset(
        decoy,
        password=NEW_ADMIN_PASSWORD,
        extra_args=("--db", str(target)),
    )
    check(
        "--db wins over DATABASE_URL (exit 0)",
        result.returncode == 0,
        f"exit={result.returncode} stderr={result.stderr.strip()[-200:]}",
    )
    check(
        "the chosen database was the one printed",
        str(target) in result.stdout,
    )
    check(
        "the chosen database was updated",
        verify(NEW_ADMIN_PASSWORD, fetch_teachers(target)[ADMIN_EMAIL][1]),
    )
    check("the DATABASE_URL database was not touched", fetch_teachers(decoy) == decoy_before)
    check(
        "the chosen database's other rows are intact",
        fetch_teachers(target)["teacher@campusync.edu"]
        == target_before["teacher@campusync.edu"],
    )

    # ----------------------------------------------------------------------
    print("\n7. Source guards")
    # ----------------------------------------------------------------------
    source = RESET_SCRIPT.read_text(encoding="utf-8")
    tree = ast.parse(source)

    # Docstrings are compared by VALUE (not by re-reading the file text): the
    # module docstring contains Windows paths such as ".\venv\Scripts", whose
    # escapes make the decoded string differ from the raw source line.
    docstrings = set()
    for node in ast.walk(tree):
        if isinstance(node, (ast.Module, ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
            doc = ast.get_docstring(node, clean=False)
            if doc:
                docstrings.add(doc)

    string_constants = [
        node.value
        for node in ast.walk(tree)
        if isinstance(node, ast.Constant) and isinstance(node.value, str)
    ]
    sql_strings = [value for value in string_constants if value not in docstrings]
    # statements that START with UPDATE (prose mentioning "update" is not SQL)
    updates = [s for s in sql_strings if s.strip().upper().startswith("UPDATE ")]
    check("there is exactly one UPDATE statement", len(updates) == 1, str(updates))
    check("it updates only the teachers.password column",
          updates and updates[0].strip().upper().startswith("UPDATE TEACHERS SET PASSWORD"),
          str(updates))
    check(
        "it is scoped to one explicit row (WHERE id = ?)",
        updates and "WHERE id = ?" in updates[0],
        str(updates),
    )
    check(
        "no INSERT / DELETE / DROP / student write is present",
        not any(
            token in s.upper()
            for s in sql_strings
            for token in ("INSERT ", "DELETE ", "DROP ", "UPDATE STUDENTS")
        ),
    )
    check(
        "the password is read from the environment, not a literal",
        "os.environ.get(PASSWORD_ENV_VAR)" in source
        and 'PASSWORD_ENV_VAR = "NEW_ADMIN_PASSWORD"' in source,
    )
    check(
        "no password literal is baked into the source",
        OLD_ADMIN_PASSWORD not in source and NEW_ADMIN_PASSWORD not in source,
    )
    check(
        "creating a database is not possible from this script",
        not any("ALLOW_DB_CREATE" in value for value in sql_strings)
        and not any(
            isinstance(node, ast.Attribute) and node.attr == "ALLOW_DB_CREATE"
            for node in ast.walk(tree)
        )
        and not any(
            isinstance(node, ast.Name) and node.id == "ALLOW_DB_CREATE"
            for node in ast.walk(tree)
        ),
    )
    verify_calls = [
        node
        for node in ast.walk(tree)
        if isinstance(node, ast.Call)
        and getattr(node.func, "id", None) == "verify_database_file"
    ]
    check(
        "the database file is only ever verified with allow_create=False",
        verify_calls
        and all(
            any(
                kw.arg == "allow_create"
                and isinstance(kw.value, ast.Constant)
                and kw.value.value is False
                for kw in call.keywords
            )
            for call in verify_calls
        )
        and not any(
            kw.arg == "allow_create" and kw.value.value is True
            for call in verify_calls
            for kw in call.keywords
        ),
        f"calls={len(verify_calls)}",
    )

    # ----------------------------------------------------------------------
    print("\n8. The real database was not touched")
    # ----------------------------------------------------------------------
    check(
        "real database size/mtime unchanged by this suite",
        stamp_of(REAL_DB) == REAL_DB_STAMP,
        f"before={REAL_DB_STAMP} after={stamp_of(REAL_DB)}",
    )
    check(
        "no backup of the real database was created",
        sorted(REAL_DB.parent.glob("campussync.db.*.pre-admin-password-reset.bak"))
        == REAL_DB_BACKUPS_BEFORE,
    )

print("\n" + "=" * 72)
print(f"admin password reset tests: {len(PASSED)} passed, {len(FAILED)} failed")
for failure in FAILED:
    print(f"  FAILED: {failure}")
print("=" * 72)
sys.exit(1 if FAILED else 0)
