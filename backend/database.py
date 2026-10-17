"""
Database configuration for CampusSync.

The SQLite file is resolved to ONE absolute path, so the backend always uses
the same database no matter which working directory uvicorn was started from.
(Before this change the path was CWD-relative: starting uvicorn from the
repository root silently created/used an empty ``campussync.db`` there.)

Resolution rules
----------------
* ``DATABASE_URL`` (environment variable, then ``.env``, then the built-in
  default) is the single source of truth.
* A RELATIVE sqlite path inside that URL is anchored to this file's directory
  (``backend/``), never to the current working directory. So the default
  ``sqlite:///./campussync.db`` always means ``backend/campussync.db`` - the
  existing database keeps its location and its records.
* An absolute sqlite path in ``DATABASE_URL`` is used exactly as given, so a
  test can point the app at a throwaway file.
* ``sqlite://`` / ``:memory:`` returns ``None`` (no file, no file policy).
* A non-SQLite URL is passed through untouched; the file policy below only
  applies to SQLite URLs.

Startup policy (see ``init_database``)
--------------------------------------
A missing, empty or non-SQLite file is a hard error unless ``ALLOW_DB_CREATE``
is enabled: the backend must never quietly boot against a freshly created
empty database while the real one sits somewhere else.
"""

from __future__ import annotations

from pathlib import Path
from typing import Optional, Tuple

from sqlalchemy import create_engine
from sqlalchemy.orm import declarative_base, sessionmaker

from config import settings

BACKEND_DIR = Path(__file__).resolve().parent
DEFAULT_DB_FILENAME = "campussync.db"
DEFAULT_DATABASE_URL = "sqlite:///./campussync.db"

_SQLITE_PREFIX = "sqlite:///"
_SQLITE_MEMORY = {
    "sqlite://",
    "sqlite:///:memory:",
    "sqlite+pysqlite://",
    "sqlite+pysqlite:///:memory:",
}
_SQLITE_MAGIC = b"SQLite format 3\x00"


class DatabaseNotInitialised(RuntimeError):
    """The configured database file is missing, empty or not a SQLite database."""


def resolve_database_url(url: Optional[str] = None) -> Tuple[str, Optional[Path]]:
    """Return ``(sqlalchemy_url, absolute_path_or_None)`` for a database URL.

    Relative SQLite paths are anchored to :data:`BACKEND_DIR`.
    """
    raw = (settings.DATABASE_URL if url is None else url).strip()

    if raw.lower() in _SQLITE_MEMORY:
        return raw, None

    if not raw.startswith(_SQLITE_PREFIX):
        # Not a SQLite URL (e.g. postgresql://...) - leave it alone.
        return raw, None

    raw_path = raw[len(_SQLITE_PREFIX):]
    # ``sqlite:////absolute/path`` keeps a leading slash, and a Windows drive
    # letter (``sqlite:///C:/...``) is already absolute.
    path = Path(raw_path)
    if not path.is_absolute():
        path = BACKEND_DIR / path
    path = path.resolve()

    return f"{_SQLITE_PREFIX}{path.as_posix()}", path


def resolve_database_path(url: Optional[str] = None) -> Optional[Path]:
    """Absolute path of the configured SQLite database (``None`` for memory)."""
    return resolve_database_url(url)[1]


DATABASE_URL, DATABASE_PATH = resolve_database_url(settings.DATABASE_URL)

engine = create_engine(
    DATABASE_URL,
    connect_args={"check_same_thread": False},
)

SessionLocal = sessionmaker(
    autocommit=False,
    autoflush=False,
    bind=engine,
)

Base = declarative_base()


def verify_database_file(path: Optional[Path], allow_create: bool) -> None:
    """Fail loudly instead of using an empty / foreign database.

    * missing file      -> error unless ``allow_create``
    * zero-byte file    -> error unless ``allow_create``
    * not a SQLite file -> always an error
    """
    if path is None:
        return

    if not path.exists():
        if allow_create:
            return
        raise DatabaseNotInitialised(
            f"Database file not found: {path}\n"
            "Refusing to start against an empty database. Create it "
            "deliberately (`python migrate_db.py --create`) or set "
            "ALLOW_DB_CREATE=1 for a first-time setup."
        )

    if path.stat().st_size == 0:
        if allow_create:
            return
        raise DatabaseNotInitialised(
            f"Database file is empty (0 bytes): {path}\n"
            "Refusing to start against an empty database. Point DATABASE_URL at "
            "the real database, or set ALLOW_DB_CREATE=1 for a first-time setup."
        )

    with path.open("rb") as handle:
        header = handle.read(len(_SQLITE_MAGIC))

    if header != _SQLITE_MAGIC:
        raise DatabaseNotInitialised(
            f"Not a SQLite database: {path}\n"
            "Point DATABASE_URL at the real database file, or delete the "
            "leftover file deliberately."
        )


def init_database(bind=None, allow_create: Optional[bool] = None) -> Optional[Path]:
    """Validate the configured database file, then create any missing tables.

    Called at import time by ``main.py``. Raises :class:`DatabaseNotInitialised`
    rather than silently creating a new database in the current directory.
    """
    if allow_create is None:
        allow_create = settings.ALLOW_DB_CREATE

    existed_before = DATABASE_PATH is not None and DATABASE_PATH.exists()

    verify_database_file(DATABASE_PATH, allow_create)
    Base.metadata.create_all(bind=bind if bind is not None else engine)

    if DATABASE_PATH is not None and not existed_before:
        print(f"[campusync] created database at {DATABASE_PATH}")

    return DATABASE_PATH
