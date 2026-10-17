"""
Custom exception classes for CampusSync backend.

Provides structured error handling with proper HTTP status codes
and consistent error response format.
"""

from fastapi import HTTPException, status


class CampusSyncException(HTTPException):
    """Base exception for CampusSync-specific errors."""

    def __init__(
        self,
        status_code: int,
        detail: str,
        code: str = None,
        headers: dict = None
    ):
        super().__init__(status_code=status_code, detail=detail, headers=headers)
        self.code = code or "UNKNOWN_ERROR"


class AuthenticationError(CampusSyncException):
    """Raised when authentication fails."""

    def __init__(self, detail: str = "Authentication failed"):
        super().__init__(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail=detail,
            code="AUTHENTICATION_FAILED"
        )


class TokenExpiredError(CampusSyncException):
    """Raised when token has expired."""

    def __init__(self, detail: str = "Token has expired, please log in again"):
        super().__init__(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail=detail,
            code="TOKEN_EXPIRED"
        )


class DuplicateEmailError(CampusSyncException):
    """Raised when email already exists."""

    def __init__(self, detail: str = "Email already registered"):
        super().__init__(
            status_code=status.HTTP_409_CONFLICT,
            detail=detail,
            code="DUPLICATE_EMAIL"
        )


class DuplicateRollNumberError(CampusSyncException):
    """Raised when roll number already exists."""

    def __init__(self, detail: str = "Roll number already registered"):
        super().__init__(
            status_code=status.HTTP_409_CONFLICT,
            detail=detail,
            code="DUPLICATE_ROLL_NUMBER"
        )


class NotFoundError(CampusSyncException):
    """Raised when resource is not found."""

    def __init__(self, detail: str = "Resource not found"):
        super().__init__(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=detail,
            code="NOT_FOUND"
        )
