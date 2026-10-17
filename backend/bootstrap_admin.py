"""
Bootstrap script to create the first Admin account.

    ADMIN_PASSWORD='<strong password>' python bootstrap_admin.py

The admin password must be provided via the ADMIN_PASSWORD environment
variable. This prevents hardcoded passwords and ensures the operator chooses a
secure password.

The script resolves the SAME database path as the backend (database.py), so it
can never create an admin account inside an empty database in the wrong
directory. Pass ``--db <path>`` to target a throwaway database instead; the
resolved absolute path is always printed before anything is written.
"""
import argparse
import os
import sqlite3
import sys
from pathlib import Path

BACKEND_DIR = Path(__file__).resolve().parent
if str(BACKEND_DIR) not in sys.path:
    sys.path.insert(0, str(BACKEND_DIR))

from pwdlib import PasswordHash  # noqa: E402
from sqlalchemy import create_engine  # noqa: E402

import models  # noqa: E402  (registers the tables on Base.metadata)
from database import (  # noqa: E402
    DATABASE_PATH,
    Base,
    resolve_database_path,
)

ADMIN_EMAIL = "admin@campusync.edu"


def _resolve_target(explicit_db: str | None) -> Path:
    if explicit_db:
        return Path(explicit_db).expanduser().resolve()

    resolved = DATABASE_PATH or resolve_database_path()
    if resolved is None:
        print(
            "ERROR: DATABASE_URL points at an in-memory database; pass --db <path>.",
            file=sys.stderr,
        )
        sys.exit(1)
    return resolved


def _ensure_schema(path: Path) -> None:
    """Create the file and any missing tables (explicit setup only)."""
    engine = create_engine(f"sqlite:///{path.as_posix()}")
    Base.metadata.create_all(bind=engine)
    engine.dispose()


def create_admin(db_path: str | None = None) -> None:
    # Password must be provided via environment variable
    admin_password = os.environ.get("ADMIN_PASSWORD")
    if not admin_password:
        print("ERROR: ADMIN_PASSWORD environment variable not set.", file=sys.stderr)
        print(
            "Usage: ADMIN_PASSWORD='your-secure-password' python bootstrap_admin.py",
            file=sys.stderr,
        )
        sys.exit(1)

    if len(admin_password) < 12:
        print("ERROR: Admin password must be at least 12 characters.", file=sys.stderr)
        sys.exit(1)

    target = _resolve_target(db_path)
    print(f"Database: {target}")

    if not target.exists():
        _ensure_schema(target)

    conn = sqlite3.connect(str(target))
    try:
        cursor = conn.cursor()

        # Check if admin already exists
        existing = cursor.execute(
            "SELECT id FROM teachers WHERE email = ?", (ADMIN_EMAIL,)
        ).fetchone()
        if existing:
            print("Admin account already exists!")
            return

        hashed_password = PasswordHash.recommended().hash(admin_password)

        cursor.execute(
            """
            INSERT INTO teachers (name, email, password, role, is_active, created_at)
            VALUES (?, ?, ?, ?, ?, datetime('now'))
            """,
            ("Admin User", ADMIN_EMAIL, hashed_password, "admin", True),
        )

        conn.commit()
    finally:
        conn.close()

    print("Admin account created successfully!")
    print(f"Email: {ADMIN_EMAIL}")
    print("Password: (provided via ADMIN_PASSWORD environment variable)")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Create the first CampusSync admin account.")
    parser.add_argument(
        "--db",
        default=None,
        help="Target database file (defaults to the backend's configured database).",
    )
    args = parser.parse_args()
    create_admin(args.db)
