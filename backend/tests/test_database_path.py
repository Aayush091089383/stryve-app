"""Regression tests: the backend must use ONE configured database path.

Bug being pinned down
---------------------
`DATABASE_URL` used to be relative to the current working directory, so
starting uvicorn from the repository root created/used an empty
`./campussync.db` there instead of `backend/campussync.db`. This suite proves:

* resolution is CWD-independent (relative URLs are anchored to backend/);
* the app really imports and initialises the SAME file from any directory;
* a missing / empty / non-SQLite file is a loud startup error instead of a
  silent fallback to a fresh empty database;
* ALLOW_DB_CREATE=1 is the only way to create a database file deliberately;
* the real database is untouched by this suite.

SAFETY
------
* Every subprocess that imports `main` gets DATABASE_URL pointed at a
  throwaway file in a temporary directory; nothing here ever opens the real
  database. Resolution-only checks never open a file either.
* The real database's size and mtime are compared before/after.
* Never run this file against the real database with ALLOW_DB_CREATE=1.

RUN
---
    mkdir /tmp/cs-dbpath && cd /tmp/cs-dbpath
    <repo>/backend/venv/Scripts/python.exe <repo>/backend/tests/test_database_path.py
"""

import os
import sqlite3
import subprocess
import sys
import tempfile
from pathlib import Path

BACKEND_DIR = Path(__file__).resolve().parent.parent
REAL_DB = BACKEND_DIR / "campussync.db"

sys.path.insert(0, str(BACKEND_DIR))

import database  # noqa: E402

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


# --------------------------------------------------------------------------
# helpers
# --------------------------------------------------------------------------
def clean_env(**overrides):
    """Environment for a subprocess, without inherited DB overrides."""
    env = dict(os.environ)
    for name in ("DATABASE_URL", "ALLOW_DB_CREATE"):
        env.pop(name, None)
    env.update({k: str(v) for k, v in overrides.items()})
    return env


RESOLVE_SCRIPT = (
    "import sys; sys.path.insert(0, r'{backend}');"
    "import database;"
    "print('RESOLVED=' + database.DATABASE_URL);"
    "print('PATH=' + str(database.DATABASE_PATH))"
)

INIT_SCRIPT = (
    "import sys; sys.path.insert(0, r'{backend}');"
    "import main;"
    "print('IMPORT_OK')"
)


def run_script(script, cwd, env):
    return subprocess.run(
        [sys.executable, "-c", script.format(backend=BACKEND_DIR)],
        cwd=str(cwd),
        env=env,
        capture_output=True,
        text=True,
        timeout=120,
    )


def stamp_of(path):
    """(size, mtime) of a file, or None when it does not exist."""
    if not path.exists():
        return None
    stat = path.stat()
    return (stat.st_size, stat.st_mtime_ns)


ROOT_DB = BACKEND_DIR.parent / "campussync.db"  # 0-byte leftover of the old bug
stamp_before = stamp_of(REAL_DB)
root_db_before = stamp_of(ROOT_DB)

with tempfile.TemporaryDirectory(prefix="cs-dbpath-") as tmpdir:
    tmp = Path(tmpdir).resolve()
    throwaway = tmp / "campussync.db"
    throwaway_url = f"sqlite:///{throwaway.as_posix()}"

    # ----------------------------------------------------------------------
    print("\n1. URL resolution (pure path arithmetic, no file access)")
    # ----------------------------------------------------------------------
    url, path = database.resolve_database_url("sqlite:///./campussync.db")
    check(
        "relative './campussync.db' resolves to backend/campussync.db",
        path == REAL_DB,
        f"got {path}",
    )
    check("resolved URL is absolute", url == f"sqlite:///{REAL_DB.as_posix()}", url)
    check(
        "executable default URL (no env, no .env) is the same file",
        database.resolve_database_path(database.DEFAULT_DATABASE_URL) == REAL_DB,
    )

    _, path_no_dot = database.resolve_database_url("sqlite:///campussync.db")
    check("'campussync.db' (no ./) resolves to the same file", path_no_dot == REAL_DB)

    _, path_abs = database.resolve_database_url(throwaway_url)
    check("absolute URL is used exactly as given", path_abs == throwaway)

    _, memory = database.resolve_database_url("sqlite:///:memory:")
    check("in-memory URL has no file path", memory is None)

    other_url, other_path = database.resolve_database_url("postgresql://user@host/db")
    check(
        "non-SQLite URL is passed through untouched",
        other_url == "postgresql://user@host/db" and other_path is None,
    )

    check(
        "anchoring is to backend/, not to the current directory",
        database.resolve_database_path("sqlite:///./campussync.db")
        != Path.cwd().resolve() / "campussync.db"
        or Path.cwd().resolve() == BACKEND_DIR,
    )

    # ----------------------------------------------------------------------
    print("\n2. Same configured database from three working directories")
    # ----------------------------------------------------------------------
    resolved = {}
    for label, cwd in (
        ("repo root", BACKEND_DIR.parent),
        ("backend/", BACKEND_DIR),
        ("temp dir", tmp),
    ):
        result = run_script(
            RESOLVE_SCRIPT, cwd, clean_env(DATABASE_URL=throwaway_url, ALLOW_DB_CREATE=1)
        )
        resolved[label] = result.stdout
        check(
            f"import from {label}: exit 0",
            result.returncode == 0,
            result.stderr.strip()[-300:],
        )

    paths = {}
    for label, out in resolved.items():
        value = None
        for line in out.splitlines():
            if line.startswith("PATH="):
                value = line.split("=", 1)[1].strip()
        paths[label] = value

    check(
        "all three working directories resolve to the same absolute path",
        len(set(paths.values())) == 1 and paths.get("temp dir") == str(throwaway),
        str(paths),
    )
    check(
        "no database file was created in any of those directories",
        stamp_of(ROOT_DB) == root_db_before and stamp_of(REAL_DB) == stamp_before,
        f"root={stamp_of(ROOT_DB)} (was {root_db_before})",
    )

    # ----------------------------------------------------------------------
    print("\n2b. Configuration itself is CWD-independent (no env overrides)")
    # ----------------------------------------------------------------------
    # From the repository root the backend previously picked up the Flutter
    # .env there and failed on its BACKEND_URL key, and a relative DATABASE_URL
    # resolved to <repo root>/campussync.db. Neither may happen now.
    config_script = (
        "import sys; sys.path.insert(0, r'{backend}');"
        "from config import settings, ENV_FILE;"
        "print('ENV_FILE=' + str(ENV_FILE));"
        "print('DB_URL=' + settings.DATABASE_URL)"
    )
    for label, cwd in (("repo root", BACKEND_DIR.parent), ("temp dir", tmp)):
        result = run_script(config_script, cwd, clean_env())
        check(
            f"config import from {label} with no overrides: exit 0",
            result.returncode == 0,
            result.stderr.strip()[-300:],
        )
        check(
            f"config from {label} reads backend/.env, not a CWD .env",
            f"ENV_FILE={BACKEND_DIR / '.env'}" in result.stdout,
            result.stdout.strip(),
        )

    result = run_script(RESOLVE_SCRIPT, BACKEND_DIR.parent, clean_env())
    default_path = None
    for line in result.stdout.splitlines():
        if line.startswith("PATH="):
            default_path = line.split("=", 1)[1].strip()
    check(
        "from the repo root, the DEFAULT configured database is still backend/campussync.db",
        result.returncode == 0 and default_path == str(REAL_DB),
        f"returncode={result.returncode} path={default_path} (expected {REAL_DB})",
    )

    # ----------------------------------------------------------------------
    print("\n3. Startup policy: refuse to run against a missing/empty/garbage DB")
    # ----------------------------------------------------------------------
    missing = tmp / "missing" / "campussync.db"
    missing.parent.mkdir(parents=True, exist_ok=True)
    result = run_script(
        INIT_SCRIPT,
        tmp,
        clean_env(DATABASE_URL=f"sqlite:///{missing.as_posix()}"),
    )
    check(
        "missing database file without ALLOW_DB_CREATE: startup fails",
        result.returncode != 0,
    )
    check(
        "missing database file: error names the configured path",
        "Database file not found" in result.stderr and str(missing) in result.stderr,
        result.stderr.strip()[-300:],
    )
    check("missing database file: nothing was created", not missing.exists())
    check(
        "missing database file: no empty database in the working directory",
        not (tmp / "campussync.db").exists(),
    )

    empty = tmp / "empty.db"
    empty.write_bytes(b"")
    result = run_script(
        INIT_SCRIPT, tmp, clean_env(DATABASE_URL=f"sqlite:///{empty.as_posix()}")
    )
    check(
        "0-byte database without ALLOW_DB_CREATE: startup fails",
        result.returncode != 0,
    )
    check(
        "0-byte database: error message says it is empty",
        "empty (0 bytes)" in result.stderr,
        result.stderr.strip()[-300:],
    )
    check(
        "0-byte database: still 0 bytes (not silently initialised)",
        empty.stat().st_size == 0,
    )

    garbage = tmp / "garbage.db"
    garbage.write_bytes(b"this is not a sqlite database at all" * 4)
    result = run_script(
        INIT_SCRIPT,
        tmp,
        clean_env(DATABASE_URL=f"sqlite:///{garbage.as_posix()}", ALLOW_DB_CREATE=1),
    )
    check(
        "non-SQLite file fails even with ALLOW_DB_CREATE=1",
        result.returncode != 0 and "Not a SQLite database" in result.stderr,
        result.stderr.strip()[-300:],
    )

    # ----------------------------------------------------------------------
    print("\n4. ALLOW_DB_CREATE=1 is the deliberate path to a new database")
    # ----------------------------------------------------------------------
    created = tmp / "created" / "campussync.db"
    created.parent.mkdir(parents=True, exist_ok=True)
    result = run_script(
        INIT_SCRIPT,
        tmp,
        clean_env(DATABASE_URL=f"sqlite:///{created.as_posix()}", ALLOW_DB_CREATE=1),
    )
    check(
        "missing file + ALLOW_DB_CREATE=1: app starts",
        result.returncode == 0 and "IMPORT_OK" in result.stdout,
        result.stderr.strip()[-300:],
    )
    check("database was created at the configured path", created.exists())
    check(
        "database was NOT created in the working directory",
        not (tmp / "campussync.db").exists(),
    )

    if created.exists():
        conn = sqlite3.connect(str(created))
        try:
            tables = {
                row[0]
                for row in conn.execute(
                    "SELECT name FROM sqlite_master WHERE type='table'"
                ).fetchall()
            }
        finally:
            conn.close()
        check(
            "created database has the students/teachers tables",
            {"students", "teachers"} <= tables,
            str(sorted(tables)),
        )

    # ----------------------------------------------------------------------
    print("\n5. The real database was not touched")
    # ----------------------------------------------------------------------
    check(
        "real database size/mtime unchanged by this suite",
        stamp_of(REAL_DB) == stamp_before,
        f"before={stamp_before} after={stamp_of(REAL_DB)}",
    )

print("\n" + "=" * 72)
print(f"database path tests: {len(PASSED)} passed, {len(FAILED)} failed")
for failure in FAILED:
    print(f"  FAILED: {failure}")
print("=" * 72)
sys.exit(1 if FAILED else 0)
