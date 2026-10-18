"""
Configuration management for Stryve backend.

Loads environment variables from .env file and provides
configuration settings for the application.
"""

from pydantic_settings import BaseSettings
from pathlib import Path
from typing import List

# backend/ directory - used to pin the .env lookup so configuration never
# depends on the working directory uvicorn was started from. (A relative
# ".env" was previously resolved against the CWD, so starting the backend from
# the repository root loaded the Flutter .env there and failed on its
# BACKEND_URL key.)
BACKEND_DIR = Path(__file__).resolve().parent
ENV_FILE = BACKEND_DIR / ".env"


class Settings(BaseSettings):
    """Application settings loaded from environment variables."""

    # Security
    SECRET_KEY: str = "campussync-dev-secret-key-change-in-production"
    DEBUG: bool = True

    # Database
    # A relative path in this URL is anchored to backend/ (not the working
    # directory). See database.py.
    DATABASE_URL: str = "sqlite:///./campussync.db"

    # Create the database file/tables when it does not exist yet.
    # Off by default: the backend must never silently boot against a newly
    # created empty database. Set ALLOW_DB_CREATE=1 for a first-time setup.
    ALLOW_DB_CREATE: bool = False

    # Public roll-number lookup: requests allowed per minute per client IP.
    # 0 disables the limit. The lookup is unauthenticated (first-time
    # registration needs it), so it is rate limited and returns a masked name.
    LOOKUP_RATE_LIMIT_PER_MINUTE: int = 120

    # Token Settings
    TOKEN_EXPIRATION_DAYS: int = 7

    # Assignment PDF uploads.
    # Files are written to this directory (relative paths are anchored to
    # backend/, like the database) under a server-generated name; the client's
    # filename is never used on disk. Nothing in this directory is served
    # statically - downloads go through the authorized endpoint.
    UPLOAD_DIR: str = "uploads/assignments"
    MAX_ASSIGNMENT_FILE_MB: int = 10

    # CORS Settings
    ALLOWED_ORIGINS: str = "*"  # Comma-separated in production

    # Frontend URL
    FRONTEND_URL: str = "http://localhost:*"

    class Config:
        env_file = str(ENV_FILE)  # pinned to backend/.env, never CWD-relative
        env_file_encoding = "utf-8"
        case_sensitive = False

    @property
    def allow_db_create(self) -> bool:
        """Whether a missing database file may be created."""
        return bool(self.ALLOW_DB_CREATE)

    @property
    def upload_path(self) -> Path:
        """Absolute directory for uploaded assignment PDFs (anchored to backend/)."""
        path = Path(self.UPLOAD_DIR)
        if not path.is_absolute():
            path = BACKEND_DIR / path
        return path

    def get_allowed_origins(self) -> List[str]:
        """Parse ALLOWED_ORIGINS into a list."""
        if self.ALLOWED_ORIGINS == "*":
            return ["*"]
        return [origin.strip() for origin in self.ALLOWED_ORIGINS.split(",")]


# Global settings instance
settings = Settings()
