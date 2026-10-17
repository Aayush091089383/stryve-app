"""
FastAPI dependency injection utilities.

Provides database session management with proper context managers
and error handling.
"""

from typing import Generator
from sqlalchemy.orm import Session

from database import SessionLocal


def get_db() -> Generator[Session, None, None]:
    """
    FastAPI dependency that provides a database session.

    Automatically handles session cleanup even if an error occurs.
    Use this instead of manually creating SessionLocal() instances.

    Usage:
        @app.get("/endpoint")
        def my_endpoint(db: Session = Depends(get_db)):
            # Use db here
            pass
    """
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()
