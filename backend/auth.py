import secrets
from datetime import datetime, timedelta
from typing import Optional

from fastapi import Depends, Header, HTTPException, status
from sqlalchemy.orm import Session

import models
from config import settings
from dependencies import get_db
from exceptions import AuthenticationError, TokenExpiredError


def generate_token() -> str:
    """Generate a random, unguessable token for a logged-in student/teacher."""
    return secrets.token_hex(32)


def generate_token_expiration() -> datetime:
    """Generate expiration timestamp for a new token."""
    return datetime.utcnow() + timedelta(days=settings.TOKEN_EXPIRATION_DAYS)


def get_current_student(
    authorization: str = Header(default=None),
    db: Session = Depends(get_db)
) -> models.Student:
    """
    FastAPI dependency that reads the 'Authorization' header, expects it
    in the form 'Bearer <token>', and returns the matching Student.

    Validates token expiration and raises appropriate errors.

    Use this on any route that should only work for a logged-in student:

        @app.get("/me")
        def me(student: models.Student = Depends(get_current_student)):
            return {"name": student.name}
    """
    if not authorization or not authorization.startswith("Bearer "):
        raise AuthenticationError("Missing or invalid Authorization header")

    token = authorization.removeprefix("Bearer ").strip()

    student = db.query(models.Student).filter(models.Student.token == token).first()

    if not student:
        raise AuthenticationError("Invalid or expired session, please log in again")

    # Check token expiration
    if student.token_expires_at:
        if datetime.utcnow() > student.token_expires_at:
            # Token expired - clear it
            student.token = None
            student.token_expires_at = None
            db.commit()
            raise TokenExpiredError()

    # Check if student is approved
    if student.status != "approved":
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Your account is pending approval or has been rejected. Please contact administration."
        )

    return student


def get_current_teacher(
    authorization: str = Header(default=None),
    db: Session = Depends(get_db)
) -> models.Teacher:
    """
    FastAPI dependency that reads the 'Authorization' header, expects it
    in the form 'Bearer <token>', and returns the matching Teacher.

    Validates token expiration and raises appropriate errors.

    Use this on any route that should only work for a logged-in teacher/admin:

        @app.get("/teacher/me")
        def me(teacher: models.Teacher = Depends(get_current_teacher)):
            return {"name": teacher.name}
    """
    if not authorization or not authorization.startswith("Bearer "):
        raise AuthenticationError("Missing or invalid Authorization header")

    token = authorization.removeprefix("Bearer ").strip()

    teacher = db.query(models.Teacher).filter(models.Teacher.token == token).first()

    if not teacher:
        raise AuthenticationError("Invalid or expired session, please log in again")

    # Check token expiration
    if teacher.token_expires_at:
        if datetime.utcnow() > teacher.token_expires_at:
            # Token expired - clear it
            teacher.token = None
            teacher.token_expires_at = None
            db.commit()
            raise TokenExpiredError()

    if not teacher.is_active:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Teacher account is deactivated"
        )

    return teacher


def require_admin(teacher: models.Teacher = Depends(get_current_teacher)) -> models.Teacher:
    """Dependency that requires admin role."""
    if teacher.role != "admin":
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Admin access required"
        )
    return teacher


def can_approve_registrations(teacher: models.Teacher) -> bool:
    """May this account review student registrations?

    Admins always may. A regular teacher may only when the configurable
    ``can_approve_registrations`` flag is set - a new teacher account is created
    without it, so approval rights are never granted implicitly.
    """
    return teacher.role == "admin" or bool(teacher.can_approve_registrations)


def get_current_actor(
    authorization: str = Header(default=None),
    db: Session = Depends(get_db),
) -> tuple[str, object]:
    """Resolve the caller as either a student or a teacher/admin.

    Needed by routes both roles may reach (downloading an assignment file).
    Returns ``("student", Student)`` or ``("teacher", Teacher)``; the token
    lookup, expiry and account-state checks match the role-specific
    dependencies above, so this is not a weaker path - it is the same checks
    applied to whichever kind of token was sent.
    """
    if not authorization or not authorization.startswith("Bearer "):
        raise AuthenticationError("Missing or invalid Authorization header")

    token = authorization.removeprefix("Bearer ").strip()

    student = db.query(models.Student).filter(models.Student.token == token).first()
    if student:
        if student.token_expires_at and datetime.utcnow() > student.token_expires_at:
            student.token = None
            student.token_expires_at = None
            db.commit()
            raise TokenExpiredError()
        if student.status != "approved":
            raise HTTPException(
                status_code=status.HTTP_403_FORBIDDEN,
                detail=(
                    "Your account is pending approval or has been rejected. "
                    "Please contact administration."
                ),
            )
        return "student", student

    teacher = db.query(models.Teacher).filter(models.Teacher.token == token).first()
    if teacher:
        if teacher.token_expires_at and datetime.utcnow() > teacher.token_expires_at:
            teacher.token = None
            teacher.token_expires_at = None
            db.commit()
            raise TokenExpiredError()
        if not teacher.is_active:
            raise HTTPException(
                status_code=status.HTTP_403_FORBIDDEN,
                detail="Teacher account is deactivated",
            )
        return "teacher", teacher

    raise AuthenticationError("Invalid or expired session, please log in again")


def require_registration_reviewer(
    teacher: models.Teacher = Depends(get_current_teacher),
) -> models.Teacher:
    """Dependency for the registration approval workflow.

    Raises 403 for a teacher whose permissions do not include approvals. This is
    enforced here (server-side) so hiding the button in the app is never the
    only control.
    """
    if not can_approve_registrations(teacher):
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail=(
                "Your account is not permitted to review student registrations. "
                "Ask an administrator to grant the approval permission."
            ),
        )
    return teacher


def require_teacher_or_admin(
    actor: tuple[str, object] = Depends(get_current_actor),
) -> models.Teacher:
    """Dependency that requires a teacher or admin account.

    A valid student token proves who the caller is, so reaching a teacher route
    with one is a permission failure and must answer 403, not the 401 reserved
    for missing, invalid or expired credentials. ``get_current_actor`` already
    performs the same token, expiry and account-state checks as the role-
    specific dependencies, so this does not become a weaker path.
    """
    role, account = actor
    if role != "teacher":
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Student accounts cannot access teacher routes",
        )
    return account
