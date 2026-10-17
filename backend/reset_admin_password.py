#!/usr/bin/env python
"""
One-time admin password reset for the existing CampusSync admin account.

    admin@campusync.edu

WHY THIS SCRIPT EXISTS
----------------------
There is no password-reset endpoint, and there will not be one for a while
(see SECURITY.md). This is the offline, operator-run equivalent: an ADMIN
password can only be replaced by someone who already has shell access to the
backend host and the database file.

WHAT IT WILL NOT DO
-------------------
* It never creates an account. If the admin account does not exist, it stops
  and says so - use ``bootstrap_admin.py`` for a first-time setup.
* It never changes any other row. Only the ``password`` column of the one
  ``admin@campusync.edu`` row is ever written.
* It never touches student rows, sessions/tokens, roles, activity flags, or
  the schema. Existing logins keep working; only the password changes.
* It never creates or migrates a database: a missing, empty or non-SQLite file
  is a hard refusal (``ALLOW_DB_CREATE`` is ignored on purpose).
* It never prints, logs or stores the password or its hash.

PASSWORD SOURCE
---------------
The new password must be supplied through the ``NEW_ADMIN_PASSWORD``
environment variable and must be at least 12 characters. It is hashed with the
same library the backend uses (``pwdlib.PasswordHash.recommended()``, argon2),
so the new hash is indistinguishable from one created at registration.

USAGE
-----
    # see what would happen, change nothing (recommended first run)
    python reset_admin_password.py --dry-run

    # perform the reset
    python reset_admin_password.py

    # same, against another (e.g. throwaway) database file
    python reset_admin_password.py --db C:/tmp/throwaway.db

    # skip the automatic backup copy taken before the write
    python reset_admin_password.py --no-backup

PowerShell (the password is prompted for with hidden input, never typed into
the command line - works on Windows PowerShell 5.1 and PowerShell 7):

    cd backend
    $sec = Read-Host -AsSecureString -Prompt 'New admin password'
    $env:NEW_ADMIN_PASSWORD = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
    .\\venv\\Scripts\\python.exe reset_admin_password.py --dry-run
    .\\venv\\Scripts\\python.exe reset_admin_password.py
    Remove-Item Env:\\NEW_ADMIN_PASSWORD

EXIT CODES
----------
    0  the password was reset (or --dry-run confirmed it could be)
    2  usage/configuration error, or the target database is missing/invalid
    3  refused - the account is absent, ambiguous, not an admin, or inactive
       (nothing was written)
"""

from __future__ import annotations

import argparse
import os
import shutil
import sqlite3
import sys
from datetime import datetime, timezone
from pathlib import Path

BACKEND_DIR = Path(__file__).resolve().parent
if str(BACKEND_DIR) not in sys.path:
    sys.path.insert(0, str(BACKEND_DIR))

from pwdlib import PasswordHash  # noqa: E402

import models  # noqa: E402,F401  (registers the tables on Base.metadata)
from database import (  # noqa: E402
    DatabaseNotInitialised,
    resolve_database_path,
    verify_database_file,
)

ADMIN_EMAIL = "admin@campusync.edu"
ADMIN_ROLE = "admin"
PASSWORD_ENV_VAR = "NEW_ADMIN_PASSWORD"
MIN_PASSWORD_LENGTH = 12

EXIT_OK = 0
EXIT_USAGE = 2
EXIT_REFUSED = 3


def log(message: str = "") -> None:
    print(message)


def error(message: str) -> None:
    print(message, file=sys.stderr)


# --------------------------------------------------------------------------
# password
# --------------------------------------------------------------------------
def read_new_password() -> str | None:
    """Read NEW_ADMIN_PASSWORD and enforce the minimum length.

    Returns ``None`` (after printing why) when the value is missing or too
    short. The value itself is never echoed back.
    """
    password = os.environ.get(PASSWORD_ENV_VAR)
    if not password:
        error(f"ERROR: {PASSWORD_ENV_VAR} environment variable is not set.")
        error(
            "Usage: NEW_ADMIN_PASSWORD='<at least 12 characters>' "
            "python reset_admin_password.py"
        )
        error("PowerShell: $sec = Read-Host -AsSecureString -Prompt 'New admin password'")
        error("            $env:NEW_ADMIN_PASSWORD = "
              "[Runtime.InteropServices.Marshal]::PtrToStringAuto("
              "[Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))")
        return None

    if len(password) < MIN_PASSWORD_LENGTH:
        error(
            f"ERROR: the new admin password must be at least "
            f"{MIN_PASSWORD_LENGTH} characters "
            f"(got {len(password)})."
        )
        return None

    return password


# --------------------------------------------------------------------------
# target database
# --------------------------------------------------------------------------
def resolve_target(explicit_db: str | None) -> Path | None:
    """The database the backend itself would use, unless --db overrides it."""
    if explicit_db:
        return Path(explicit_db).expanduser().resolve()

    resolved = resolve_database_path()
    if resolved is None:
        error("ERROR: DATABASE_URL points at an in-memory database; pass --db <path>.")
        return None
    return resolved


def find_admin_row(conn: sqlite3.Connection) -> tuple[str, list[tuple]]:
    """Look up the admin account. Returns ``(problem, rows)``.

    Matching is case-insensitive on the email so a stored
    ``Admin@campusync.edu`` is found too, but the result must be exactly one
    row - anything else is refused rather than guessed at.
    """
    try:
        rows = list(
            conn.execute(
                "SELECT id, email, role, is_active FROM teachers "
                "WHERE lower(email) = lower(?)",
                (ADMIN_EMAIL,),
            )
        )
    except sqlite3.OperationalError as exc:
        return f"cannot read the teachers table: {exc}", []

    if not rows:
        return (
            f"no account with email {ADMIN_EMAIL} exists in this database "
            "(this script never creates accounts - use bootstrap_admin.py "
            "for a first-time setup)",
            [],
        )

    if len(rows) > 1:
        return (
            f"{len(rows)} accounts match {ADMIN_EMAIL}; refusing to guess which "
            "one to change",
            rows,
        )

    return "", rows


# --------------------------------------------------------------------------
# reset
# --------------------------------------------------------------------------
def reset_admin_password(
    explicit_db: str | None,
    *,
    dry_run: bool = False,
    backup: bool = True,
) -> int:
    password = read_new_password()
    if password is None:
        return EXIT_USAGE

    db_path = resolve_target(explicit_db)
    if db_path is None:
        return EXIT_USAGE

    log("=" * 72)
    log("CampusSync admin password reset (single account, password column only)")
    log(f"Database: {db_path}")
    log(f"Account:  {ADMIN_EMAIL}")
    log("=" * 72)

    # Never create or migrate a database here.
    try:
        verify_database_file(db_path, allow_create=False)
    except DatabaseNotInitialised as exc:
        error("")
        error(f"ERROR: {exc}")
        error("Nothing was changed.")
        return EXIT_USAGE

    if not db_path.exists():
        error("")
        error(f"ERROR: database file not found: {db_path}")
        error("Nothing was changed.")
        return EXIT_USAGE

    conn = sqlite3.connect(str(db_path))
    try:
        problem, rows = find_admin_row(conn)
        if problem:
            error("")
            error(f"REFUSED: {problem}.")
            error("Nothing was changed.")
            return EXIT_REFUSED

        student_id, stored_email, role, is_active = rows[0]

        if (role or "").strip().lower() != ADMIN_ROLE:
            error("")
            error(
                f"REFUSED: {stored_email} has role {role!r}, not "
                f"{ADMIN_ROLE!r}. This script only resets admin accounts."
            )
            error("Nothing was changed.")
            return EXIT_REFUSED

        if not is_active:
            error("")
            error(
                f"REFUSED: {stored_email} is deactivated (is_active={is_active!r}). "
                "Reactivate the account first; a deactivated admin cannot log in."
            )
            error("Nothing was changed.")
            return EXIT_REFUSED

        log("")
        log(f"  found: id={student_id} email={stored_email} "
            f"role={role} is_active={is_active}")

        if dry_run:
            log("")
            log("  DRY RUN: the password would be replaced and re-hashed with "
                "pwdlib (argon2).")
            log("  No token, role, name, role flag or student row is touched.")
            log("")
            log("  Nothing was written.")
            return EXIT_OK

        if backup:
            stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
            backup_path = db_path.with_name(
                f"{db_path.name}.{stamp}.pre-admin-password-reset.bak"
            )
            shutil.copy2(db_path, backup_path)
            log("")
            log(f"  backup written: {backup_path}")

        new_hash = PasswordHash.recommended().hash(password)

        cur = conn.execute(
            "UPDATE teachers SET password = ? WHERE id = ? "
            "AND lower(email) = lower(?) AND role = ?",
            (new_hash, student_id, ADMIN_EMAIL, role),
        )
        if cur.rowcount != 1:
            conn.rollback()
            error("")
            error(
                f"REFUSED: expected to update exactly 1 row, the database "
                f"reported {cur.rowcount}. Nothing was changed."
            )
            return EXIT_REFUSED

        conn.commit()
    except sqlite3.Error as exc:
        conn.rollback()
        error("")
        error(f"ERROR: database error, nothing was changed: {exc}")
        return EXIT_USAGE
    finally:
        conn.close()

    log("")
    log(f"  SUCCESS: the password for {ADMIN_EMAIL} was updated.")
    log("  The new password came from "
        f"{PASSWORD_ENV_VAR} and was stored as an argon2 hash; neither is "
        "printed here.")
    log("  Unchanged: other accounts, students, roles, activity flags and the "
        "account's existing session token.")
    log("  Remember to clear the variable: Remove-Item Env:\\"
        f"{PASSWORD_ENV_VAR}")
    return EXIT_OK


def parse_args(argv=None):
    parser = argparse.ArgumentParser(
        description=(
            "One-time reset of the CampusSync admin password "
            f"({ADMIN_EMAIL}). The new password is read from "
            f"{PASSWORD_ENV_VAR}."
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "--db",
        default=None,
        help="Target database file (default: the backend's configured database).",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Check the account and print what would happen, writing nothing.",
    )
    parser.add_argument(
        "--no-backup",
        action="store_true",
        help="Skip the database file copy taken before the write.",
    )
    return parser.parse_args(argv)


def main(argv=None) -> int:
    args = parse_args(argv)
    return reset_admin_password(
        args.db,
        dry_run=args.dry_run,
        backup=not args.no_backup,
    )


if __name__ == "__main__":
    sys.exit(main())
