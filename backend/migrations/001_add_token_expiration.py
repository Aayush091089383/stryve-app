"""
Migration: Add token_expires_at column to students table

This migration adds token expiration tracking to enable secure session management.
Existing tokens (with NULL expiration) will be handled gracefully by the auth system.
"""

import sqlite3
import sys
from datetime import datetime


def migrate(db_path: str):
    """Add token_expires_at column to students table."""
    conn = sqlite3.connect(db_path)
    cursor = conn.cursor()

    try:
        # Check if column already exists
        cursor.execute("PRAGMA table_info(students)")
        columns = [row[1] for row in cursor.fetchall()]

        if 'token_expires_at' in columns:
            print("[OK] Column 'token_expires_at' already exists")
            return True

        # Add the column
        cursor.execute("""
            ALTER TABLE students
            ADD COLUMN token_expires_at DATETIME
        """)

        conn.commit()
        print("[OK] Added token_expires_at column to students table")

        # Verify the migration
        cursor.execute("PRAGMA table_info(students)")
        columns = [row[1] for row in cursor.fetchall()]

        if 'token_expires_at' not in columns:
            raise Exception("Migration verification failed: column not found")

        # Check data preservation
        cursor.execute("SELECT COUNT(*) FROM students")
        count = cursor.fetchone()[0]
        print(f"[OK] Verified: {count} student records preserved")

        return True

    except Exception as e:
        conn.rollback()
        print(f"[ERROR] Migration failed: {e}")
        return False

    finally:
        conn.close()


def rollback(db_path: str):
    """
    Rollback is not supported for SQLite ALTER TABLE ADD COLUMN.
    To rollback, restore from backup: campussync_backup_YYYYMMDD_HHMMSS.db
    """
    print("[WARN] Rollback not supported for this migration")
    print("[WARN] To rollback, restore from backup database")
    return False


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python 001_add_token_expiration.py <database_path>")
        sys.exit(1)

    db_path = sys.argv[1]

    print(f"Running migration on: {db_path}")
    print(f"Timestamp: {datetime.now().isoformat()}")
    print("-" * 50)

    if migrate(db_path):
        print("-" * 50)
        print("[SUCCESS] Migration completed successfully")
        sys.exit(0)
    else:
        print("-" * 50)
        print("[FAILED] Migration failed")
        sys.exit(1)
