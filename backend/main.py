import csv
import io
import re
import uuid
from collections.abc import Iterable
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

from fastapi import (
    BackgroundTasks,
    Depends,
    FastAPI,
    File,
    Form,
    Query,
    Request,
    UploadFile,
    status,
    HTTPException,
)
from fastapi.exceptions import RequestValidationError
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, JSONResponse
from fastapi.staticfiles import StaticFiles
from pydantic import ValidationError
from pwdlib import PasswordHash
from sqlalchemy import func, or_
from sqlalchemy.orm import Session, joinedload
from sqlalchemy.exc import IntegrityError

import models
import official_data
import firebase_service
from auth import (
    generate_token,
    generate_token_expiration,
    get_current_actor,
    get_current_student,
    get_current_teacher,
    require_admin,
    require_registration_reviewer,
    require_teacher_or_admin,
)
from config import settings
import database
from database import Base, engine  # noqa: F401  (re-exported for existing callers)
from database import SessionLocal
from dependencies import get_db
from privacy import mask_name
from ratelimit import SlidingWindowLimiter
from exceptions import (
    CampusSyncException,
    DuplicateEmailError,
    DuplicateRollNumberError,
)
from schemas import (
    StudentLogin,
    StudentRegister,
    StudentRegisterResponse,
    StudentLookupResponse,
    TeacherLogin,
    TeacherTokenResponse,
    TeacherCreate,
    TeacherOut,
    TeacherAdminOut,
    TeacherStatusUpdate,
    StudentOut,
    PendingStudentOut,
    ApproveRequest,
    RejectRequest,
    ApprovalActionResponse,
    TimetableEntryOut,
    AssignmentOut,
    AssignmentUpdate,
    NotificationOut,
    AnnouncementOut,
    DeviceTokenRegister,
    DeviceTokenOut,
    TokenResponse,
    TeacherPermissionsUpdate,
    TeacherAssignmentOut,
    TeacherAssignmentCreate,
    AttendanceClassStudentOut,
    AttendanceHistorySessionOut,
    AttendanceDeleteRequest,
    AttendanceDeleteResponse,
    AttendanceRecordOut,
    AttendanceRecordUpdate,
    AttendanceSaveRequest,
    AttendanceSaveResponse,
    AttendanceSessionDetailOut,
    AttendanceSessionInfoOut,
    AttendanceSessionOut,
    AttendanceStudentOut,
    AttendanceSubmitRequest,
    AttendanceSubmitResponse,
    RosterEntryIn,
    RosterEntryOut,
    RosterImportResult,
    StudentAttendanceOut,
    SubjectAttendanceSummary,
    AttendanceLectureOut,
    FreePeriodAvailabilityOut,
    FreePeriodClaimOut,
    FreePeriodClaimRequest,
    ScheduleChangeOut,
    ScheduleChangesResponse,
    AdminScheduleChangeOut,
    AdminScheduleChangesOut,
    TeacherNotificationOut,
    TeacherNotificationsOut,
    FreePeriodSlotOut,
    FacultyOut,
    LabRoomOut,
    DirectoryStatusOut,
    SubjectOut,
    VALID_BATCHES,
)

# Student registry based on the 72 records from lib/data/student_database.dart
# Roll numbers 1-72 are the actual roll numbers
STUDENT_REGISTRY = [
    {"roll_number": "1", "name": "SHUBHAM SURESH AHIRE", "course": "Mechanical", "year": 1, "division": "D", "batch": "D-1"},
    {"roll_number": "2", "name": "SIMNA AHAD AKIL", "course": "Electrical", "year": 1, "division": "D", "batch": "D-1"},
    {"roll_number": "3", "name": "SAMRUDDHI MANOJ AMBEKAR", "course": "Computer", "year": 1, "division": "D", "batch": "D-1"},
    {"roll_number": "4", "name": "SHINDE AJAY ANGATRAO", "course": "E&TC", "year": 1, "division": "D", "batch": "D-1"},
    {"roll_number": "5", "name": "JAGTAP SIMA ASHOK", "course": "Civil", "year": 1, "division": "D", "batch": "D-1"},
    {"roll_number": "6", "name": "KAVERI KIRAN BABAR", "course": "E&TC", "year": 1, "division": "D", "batch": "D-1"},
    {"roll_number": "7", "name": "SHRUSHTI MANGESH BACHAL", "course": "AI&DS", "year": 1, "division": "D", "batch": "D-1"},
    {"roll_number": "8", "name": "HARSHADA NITIN BACHHAV", "course": "E&TC", "year": 1, "division": "D", "batch": "D-1"},
    {"roll_number": "9", "name": "MEDHA SANDEEP BENDALE", "course": "E&TC", "year": 1, "division": "D", "batch": "D-1"},
    {"roll_number": "10", "name": "PARAG MADAN BENDKULE", "course": "Computer", "year": 1, "division": "D", "batch": "D-1"},
    {"roll_number": "11", "name": "PAYAL NAMDEV BHABAD", "course": "Mechanical", "year": 1, "division": "D", "batch": "D-1"},
    {"roll_number": "12", "name": "YASH CHANDRAKANT BHARAMBE", "course": "Computer", "year": 1, "division": "D", "batch": "D-1"},
    {"roll_number": "13", "name": "ISHA SACHIN BIRARI", "course": "E&TC", "year": 1, "division": "D", "batch": "D-1"},
    {"roll_number": "14", "name": "MANSI BHASKAR BORSE", "course": "Electrical", "year": 1, "division": "D", "batch": "D-1"},
    {"roll_number": "15", "name": "SHRAVANI DATTU AVHAD", "course": "AI&DS", "year": 1, "division": "D", "batch": "D-1"},
    {"roll_number": "16", "name": "KUMUDINI RAVINDRA DESALE", "course": "Computer", "year": 1, "division": "D", "batch": "D-1"},
    {"roll_number": "17", "name": "DIKSHA DAMODAR DHONDU", "course": "AI&DS", "year": 1, "division": "D", "batch": "D-1"},
    {"roll_number": "18", "name": "RUTUJA SANJAY DUSANE", "course": "Mechanical", "year": 1, "division": "D", "batch": "D-1"},
    {"roll_number": "19", "name": "VAIBHAV SHARAD GADAKH", "course": "Mechanical", "year": 1, "division": "D", "batch": "D-1"},
    {"roll_number": "20", "name": "KALYANI UPADHYE GANESH", "course": "E&TC", "year": 1, "division": "D", "batch": "D-1"},
    {"roll_number": "21", "name": "SARTHAK DATTU GARE", "course": "Computer", "year": 1, "division": "D", "batch": "D-1"},
    {"roll_number": "22", "name": "KAMINI POPAT GAWALI", "course": "Civil", "year": 1, "division": "D", "batch": "D-1"},
    {"roll_number": "23", "name": "VAISHNAVI SHEKHAR GHADUSE", "course": "Electrical", "year": 1, "division": "D", "batch": "D-1"},
    {"roll_number": "24", "name": "KARTIK VISHNU GHANGHAV", "course": "Electrical", "year": 1, "division": "D", "batch": "D-1"},
    {"roll_number": "25", "name": "BHAGYASHRI VITTHALSINGH GIRASE", "course": "Computer", "year": 1, "division": "D", "batch": "D-2"},
    {"roll_number": "26", "name": "SAMRUDDHI SAMEER GOVANDE", "course": "Electrical", "year": 1, "division": "D", "batch": "D-2"},
    {"roll_number": "27", "name": "SANJANA SAMADHAN JADHAV", "course": "Civil", "year": 1, "division": "D", "batch": "D-2"},
    {"roll_number": "28", "name": "TANMAY GORAKH JEJURKAR", "course": "Electrical", "year": 1, "division": "D", "batch": "D-2"},
    {"roll_number": "29", "name": "KARTAVYA NITIN KAGANE", "course": "AI&DS", "year": 1, "division": "D", "batch": "D-2"},
    {"roll_number": "30", "name": "PIYUSH NAVNATH KANDE", "course": "Electrical", "year": 1, "division": "D", "batch": "D-2"},
    {"roll_number": "31", "name": "PARTH PRABHAKAR KOR", "course": "Computer", "year": 1, "division": "D", "batch": "D-2"},
    {"roll_number": "32", "name": "PRATIK PRABHAKAR KOR", "course": "Computer", "year": 1, "division": "D", "batch": "D-2"},
    {"roll_number": "33", "name": "SOHAM DINANATH KULTHE", "course": "Computer", "year": 1, "division": "D", "batch": "D-2"},
    {"roll_number": "34", "name": "PUJA NAVANATH KUSHARE", "course": "Mechanical", "year": 1, "division": "D", "batch": "D-2"},
    {"roll_number": "35", "name": "KAUSTUBH SOPAN MADHE", "course": "Electrical", "year": 1, "division": "D", "batch": "D-2"},
    {"roll_number": "36", "name": "LAKSH SUCHIT MAHAJAN", "course": "Electrical", "year": 1, "division": "D", "batch": "D-2"},
    {"roll_number": "37", "name": "RUPLAL HOPNA MAJHI", "course": "Civil", "year": 1, "division": "D", "batch": "D-2"},
    {"roll_number": "38", "name": "VRISHTI ALPESH MAKWANA", "course": "AI&DS", "year": 1, "division": "D", "batch": "D-2"},
    {"roll_number": "39", "name": "BHAKTI BABASAHEB MURADE", "course": "Electrical", "year": 1, "division": "D", "batch": "D-2"},
    {"roll_number": "40", "name": "HEMANGI AVCHAR NARENDRA", "course": "E&TC", "year": 1, "division": "D", "batch": "D-2"},
    {"roll_number": "41", "name": "SAMRUDDHI SOMNATH PAGARE", "course": "E&TC", "year": 1, "division": "D", "batch": "D-2"},
    {"roll_number": "42", "name": "SIMIT SANGAMESHWAR PANCHAL", "course": "Electrical", "year": 1, "division": "D", "batch": "D-2"},
    {"roll_number": "43", "name": "SHRUTI SANTOSH PANDIT", "course": "Electrical", "year": 1, "division": "D", "batch": "D-2"},
    {"roll_number": "44", "name": "ANIKET YOGESH PATIL", "course": "E&TC", "year": 1, "division": "D", "batch": "D-2"},
    {"roll_number": "45", "name": "CHETNA JITENDRA PATIL", "course": "AI&DS", "year": 1, "division": "D", "batch": "D-2"},
    {"roll_number": "46", "name": "DISHA DINESH PATIL", "course": "Mechanical", "year": 1, "division": "D", "batch": "D-2"},
    {"roll_number": "47", "name": "GITAL VIJAY PATIL", "course": "Civil", "year": 1, "division": "D", "batch": "D-2"},
    {"roll_number": "48", "name": "GITALI VASUDEO PATIL", "course": "Computer", "year": 1, "division": "D", "batch": "D-2"},
    {"roll_number": "49", "name": "GOPAL RAJENDRA PATIL", "course": "E&TC", "year": 1, "division": "D", "batch": "D-3"},
    {"roll_number": "50", "name": "TOSHIKA TUSHAR PATIL", "course": "Computer", "year": 1, "division": "D", "batch": "D-3"},
    {"roll_number": "51", "name": "VAISHNAVI MANIK PATIL", "course": "AI&DS", "year": 1, "division": "D", "batch": "D-3"},
    {"roll_number": "52", "name": "PRATHAMESH RAMESH PAWASE", "course": "Mechanical", "year": 1, "division": "D", "batch": "D-3"},
    {"roll_number": "53", "name": "OM NITIN PISE", "course": "E&TC", "year": 1, "division": "D", "batch": "D-3"},
    {"roll_number": "54", "name": "HEMAKSHI DEEPAK RANE", "course": "E&TC", "year": 1, "division": "D", "batch": "D-3"},
    {"roll_number": "55", "name": "DINESH BAPU RATHOD", "course": "Electrical", "year": 1, "division": "D", "batch": "D-3"},
    {"roll_number": "56", "name": "KRUSHNA SANTOSH REVGADE", "course": "Electrical", "year": 1, "division": "D", "batch": "D-3"},
    {"roll_number": "57", "name": "SWAYAM SARJERAO SARODE", "course": "E&TC", "year": 1, "division": "D", "batch": "D-3"},
    {"roll_number": "58", "name": "ANSHUL KIRAN SHELKE", "course": "Electrical", "year": 1, "division": "D", "batch": "D-3"},
    {"roll_number": "59", "name": "CHAITANYA PRAVIN SHENDE", "course": "Computer", "year": 1, "division": "D", "batch": "D-3"},
    {"roll_number": "60", "name": "SANSKRUTI SANJAY SHIMPI", "course": "E&TC", "year": 1, "division": "D", "batch": "D-3"},
    {"roll_number": "61", "name": "DURGESH ANTAJI SHINDE", "course": "Civil", "year": 1, "division": "D", "batch": "D-3"},
    {"roll_number": "62", "name": "PRATIKSHA PRASHANT SHINDE", "course": "Electrical", "year": 1, "division": "D", "batch": "D-3"},
    {"roll_number": "63", "name": "SWAROOP HARSHAL SHIRSATH", "course": "E&TC", "year": 1, "division": "D", "batch": "D-3"},
    {"roll_number": "64", "name": "ISHANT SANDEEP SONAWANE", "course": "Electrical", "year": 1, "division": "D", "batch": "D-3"},
    {"roll_number": "65", "name": "MOKSH NISARGARAJ SONAWANE", "course": "Civil", "year": 1, "division": "D", "batch": "D-3"},
    {"roll_number": "66", "name": "VEDANT SHARAD SONAWANE", "course": "Electrical", "year": 1, "division": "D", "batch": "D-3"},
    {"roll_number": "67", "name": "YOCHANA KARBHARI SONAWANE", "course": "Mechanical", "year": 1, "division": "D", "batch": "D-3"},
    {"roll_number": "68", "name": "HERAMB ADKE SUNIL", "course": "E&TC", "year": 1, "division": "D", "batch": "D-3"},
    {"roll_number": "69", "name": "ATHARVA PRALHAD SURYAVANSHI", "course": "Civil", "year": 1, "division": "D", "batch": "D-3"},
    {"roll_number": "70", "name": "KARTIK MAHESH SURYAWANSHI", "course": "Electrical", "year": 1, "division": "D", "batch": "D-3"},
    {"roll_number": "71", "name": "AAYUSH SHANTARAM TITAME", "course": "AI&DS", "year": 1, "division": "D", "batch": "D-3"},
    {"roll_number": "72", "name": "BASTE TUKARAM TUSHAR", "course": "E&TC", "year": 1, "division": "D", "batch": "D-3"},
]

# The API is exposed through a public tunnel, so the interactive documentation is
# off: /docs and /redoc are 404 in every environment. `openapi_url` goes with
# them - a public schema tells an attacker every route and payload shape even
# without the Swagger UI. Re-enable all three only behind authentication.
app = FastAPI(
    title="Stryve Backend",
    docs_url=None,
    redoc_url=None,
    openapi_url=None,
)

# ------------------------------------------------------------------
# CORS - now configurable via environment
# ------------------------------------------------------------------
app.add_middleware(
    CORSMiddleware,
    allow_origins=settings.get_allowed_origins(),
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# ------------------------------------------------------------------
# Static assets and the browser upload portal
# ------------------------------------------------------------------
# Anchored to backend/ (never the working directory), because uvicorn may be
# started from the repository root. StaticFiles is mounted under /static so a
# future route can never shadow a file by accident; /portal is the one stable
# address a teacher needs to remember.
STATIC_DIR = Path(__file__).resolve().parent / "static"
app.mount("/static", StaticFiles(directory=str(STATIC_DIR)), name="static")


@app.get("/portal", include_in_schema=False)
def serve_upload_portal():
    """The teacher/admin upload page.

    Plain HTML is served from the same origin as the API, so the page's
    relative fetch() calls work unchanged on localhost, the ngrok tunnel and
    any other host the backend is reached through. Access control is the
    teacher login itself: without a valid bearer token the page can render but
    every call it makes is rejected.
    """
    return FileResponse(
        STATIC_DIR / "upload.html",
        media_type="text/html; charset=utf-8",
        headers={"Cache-Control": "no-store"},
    )


# ------------------------------------------------------------------
# Exception handlers
# ------------------------------------------------------------------
@app.exception_handler(RequestValidationError)
async def validation_exception_handler(request, exc: RequestValidationError):
    first_error = exc.errors()[0]
    message = first_error.get("msg", "Invalid input")
    return JSONResponse(
        status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
        content={"detail": message, "code": "VALIDATION_ERROR"}
    )


@app.exception_handler(CampusSyncException)
async def campussync_exception_handler(request, exc: CampusSyncException):
    return JSONResponse(
        status_code=exc.status_code,
        content={"detail": exc.detail, "code": exc.code}
    )


# Password hashing
password_hash = PasswordHash.recommended()

# Validate the configured database file, then create any missing tables.
# Raises DatabaseNotInitialised (a loud startup failure) instead of quietly
# running against a freshly created empty database - see database.py.
database.init_database()


@app.get("/")
def home():
    return {
        "message": "Stryve backend is running!"
    }


@app.get("/health")
def health():
    """Liveness probe for the running process.

    Answers 200 whenever this worker is up and able to answer a request, which
    is what a tunnel, proxy or uptime monitor needs. Deliberately does NOT
    touch the database: a probe must not fail (or write anything) because of
    schema or data state, and it must never become a way to tell whether a
    database exists. No paths, versions or credential details are exposed, and
    no token is required - a monitor cannot log in.
    """
    return {
        "status": "ok",
        "service": "Stryve backend",
    }


@app.post("/register", status_code=status.HTTP_201_CREATED, response_model=StudentRegisterResponse)
def register_student(
    student: StudentRegister,
    background: BackgroundTasks,
    db: Session = Depends(get_db),
):
    """
    Register a new student account.

    Student provides: roll_number, email, password, confirm_password.
    Backend looks up roll_number in registry and auto-fills:
    - name, branch, year, division, batch

    Returns 201 with pending status, 409 if email or roll number already exists,
    404 if roll number not found in registry, 400 if not eligible (year!=1 or division!=D).
    """
    # Validate password confirmation
    if student.password != student.confirm_password:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Passwords do not match"
        )

    # Check if email already exists in our system. Email is case-insensitive:
    # rows created before lower-casing was enforced can still be mixed case.
    existing_email = db.query(models.Student).filter(
        func.lower(models.Student.email) == student.email.lower()
    ).first()

    if existing_email:
        raise DuplicateEmailError()

    # Check if roll number already registered in our system
    existing_roll = db.query(models.Student).filter(
        models.Student.roll_number == student.roll_number
    ).first()

    if existing_roll:
        raise DuplicateRollNumberError()

    # Look up roll number in the college registry (student_database)
    registry_student = next(
        (s for s in STUDENT_REGISTRY if s["roll_number"] == student.roll_number),
        None
    )

    if not registry_student:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Roll number not found in college registry. Contact administration if this is an error."
        )

    # Check eligibility: first year only, division D only
    if registry_student["year"] != 1:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Only first-year students are eligible for registration."
        )

    if registry_student["division"] != "D":
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Only Division D students are eligible for registration."
        )

    # Hash password before storing
    hashed_password = password_hash.hash(student.password)

    # Create new student with profile information from registry
    new_student = models.Student(
        name=registry_student["name"],
        # Store canonical lowercase so later lookups and duplicates agree.
        email=student.email.lower(),
        roll_number=student.roll_number,
        branch=registry_student["course"],  # registry uses "course"
        year=registry_student["year"],
        division=registry_student["division"],
        batch=registry_student["batch"],
        password=hashed_password,
        status="pending",  # New registrations are pending approval
    )

    notice_title = "New registration pending"
    notice_message = (
        f"{new_student.name} (roll {new_student.roll_number}) is waiting "
        "for approval."
    )

    try:
        db.add(new_student)
        # The id is needed by the notice below; still one transaction, so a
        # duplicate registration rolls the notice back with it.
        db.flush()

        reviewer_ids = _active_reviewer_ids(db)
        _add_teacher_bells(
            db,
            reviewer_ids,
            notice_title,
            notice_message,
            kind="registration",
            ref_id=new_student.id,
        )

        db.commit()
        db.refresh(new_student)
    except IntegrityError:
        db.rollback()
        # Race condition - another registration happened simultaneously
        raise DuplicateEmailError("Registration conflict - please try again")

    # Push after the response: a slow or unconfigured Firebase must not delay a
    # student's registration. The bell rows above are the durable record.
    reviewer_tokens = _push_tokens_for_teachers(db, reviewer_ids)
    if reviewer_tokens:
        background.add_task(
            _deliver_push,
            reviewer_tokens,
            notice_title,
            notice_message,
            {"type": "registration", "student_id": new_student.id},
            teacher_tokens=True,
        )

    return StudentRegisterResponse(
        message="Registration submitted for approval. You will be notified once approved.",
        student_id=new_student.id,
        status=new_student.status,
    )


# ------------------------------------------------------------------
# Public /students/lookup abuse + privacy controls
# ------------------------------------------------------------------
# This endpoint is unauthenticated on purpose: a first-time student must be
# able to confirm their roll number before they can register. Because anyone
# can reach it, it returns a MASKED official name and is rate limited.
lookup_limiter = SlidingWindowLimiter(settings.LOOKUP_RATE_LIMIT_PER_MINUTE)


# A loopback peer is the local ngrok agent, or this machine. Only in that case
# is a forwarded address meaningful; a request arriving from anywhere else must
# not be able to choose its own rate-limit bucket by sending the header.
LOOPBACK_CLIENT_HOSTS = frozenset({"127.0.0.1", "::1", "localhost"})


def _client_ip(request: Request) -> str:
    """The direct peer address of this request, with no header trust."""
    client = request.client
    return client.host if client and client.host else "unknown"


def _is_loopback_peer(host: str) -> bool:
    """Whether the connection itself came from this machine."""
    return (host or "").strip().lower() in LOOPBACK_CLIENT_HOSTS


def _client_key(request: Request) -> str:
    """Client identity for the in-process rate limiters.

    The backend is normally reached through the ngrok tunnel, which terminates
    the connection and forwards from 127.0.0.1 - so the peer address alone puts
    every caller in one shared bucket. ``X-Forwarded-For`` is used instead, but
    only the LAST hop (the value ngrok appended; anything the caller invented
    sits earlier) and only when the peer is a loopback address. A request that
    arrives from any other address is keyed on that peer, so it cannot pick a
    fresh bucket by sending the header itself.
    """
    peer = _client_ip(request)
    if not _is_loopback_peer(peer):
        return peer
    forwarded = request.headers.get("x-forwarded-for", "")
    hops = [hop.strip() for hop in forwarded.split(",") if hop.strip()]
    return hops[-1] if hops else peer


def lookup_rate_limit(request: Request) -> None:
    """Dependency that rejects bulk lookups with 429 + Retry-After."""
    allowed, retry_after = lookup_limiter.check(_client_key(request))
    if not allowed:
        raise HTTPException(
            status_code=status.HTTP_429_TOO_MANY_REQUESTS,
            detail=(
                "Too many roll number lookups. Please wait a moment and try "
                "again."
            ),
            headers={"Retry-After": str(retry_after)},
        )


@app.get("/students/lookup/{roll_number}", response_model=StudentLookupResponse)
def lookup_student(roll_number: str, _: None = Depends(lookup_rate_limit)):
    """
    Look up a student by roll number in the college registry.

    Returns the eligibility details needed to register, with the official name
    MASKED (initials only). The full name is never disclosed here; staff who
    approve the registration see it, and the student sees it after login.

    This is not an identity check: a roll number is guessable, so approval by
    a teacher/admin remains the gate that grants access.
    """
    registry_student = next(
        (s for s in STUDENT_REGISTRY if s["roll_number"] == roll_number),
        None
    )

    if not registry_student:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Roll number not found in college registry. Contact administration if this is an error."
        )

    # Check eligibility: first year only, division D only
    if registry_student["year"] != 1:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Only first-year students are eligible for registration."
        )

    if registry_student["division"] != "D":
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Only Division D students are eligible for registration."
        )

    return StudentLookupResponse(
        roll_number=registry_student["roll_number"],
        masked_name=mask_name(registry_student["name"]),
        branch=registry_student["course"],
        year=registry_student["year"],
        division=registry_student["division"],
        batch=registry_student["batch"],
    )


@app.get("/timetable", response_model=list[TimetableEntryOut])
def get_my_timetable(
    student: models.Student = Depends(get_current_student),
    db: Session = Depends(get_db)
):
    """
    Returns every timetable entry for the logged-in student's division,
    including both entries common to the whole division (batch is null)
    and entries specific to their own batch.
    """
    return _student_timetable_entries(db, student)


# The same brake for the student app: POST /login accepts a password from
# anyone who can reach the API, so failures are counted per client exactly like
# the portal. A successful sign-in clears the counter, so a student is never
# locked out by their own correct password.
student_login_limiter = SlidingWindowLimiter(
    settings.STUDENT_LOGIN_RATE_LIMIT_PER_MINUTE
)


def student_login_rate_limit(request: Request) -> str:
    """Reject further attempts once a client has failed too often; returns key."""
    key = _client_key(request)
    blocked, retry_after = student_login_limiter.blocked(key)
    if blocked:
        raise HTTPException(
            status_code=status.HTTP_429_TOO_MANY_REQUESTS,
            detail=(
                "Too many failed sign-in attempts. Wait a minute and try again."
            ),
            headers={"Retry-After": str(retry_after)},
        )
    return key


@app.post("/login", response_model=TokenResponse)
def login_student(
    student: StudentLogin,
    db: Session = Depends(get_db),
    login_key: str = Depends(student_login_rate_limit),
):
    """
    Authenticate a student and return a session token.

    Returns 200 with token on success, 401 if credentials are invalid, and 429
    once one client has failed too many times in a minute. Successful sign-ins
    are never counted against the limit.
    """
    # Find student by email. The comparison is case-insensitive: existing rows
    # may hold any casing (e.g. a mixed-case address saved before this rule),
    # and users type their address however they like.
    existing_student = db.query(models.Student).filter(
        func.lower(models.Student.email) == student.email.lower()
    ).first()

    if not existing_student:
        from exceptions import AuthenticationError
        student_login_limiter.check(login_key)
        raise AuthenticationError("Invalid email or password")

    # Verify password against stored hash
    password_correct = password_hash.verify(
        student.password,
        existing_student.password,
    )

    if not password_correct:
        from exceptions import AuthenticationError
        student_login_limiter.check(login_key)
        raise AuthenticationError("Invalid email or password")

    # Check if student is approved
    if existing_student.status != "approved":
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Your account is pending approval or has been rejected. Please contact administration."
        )

    # Issue a fresh token every time the student logs in. Any older
    # token they had immediately stops working - only one active
    # session per student at a time.
    new_token = generate_token()
    token_expiration = generate_token_expiration()

    existing_student.token = new_token
    existing_student.token_expires_at = token_expiration
    db.commit()

    # A correct password proves this is the account owner; earlier failures
    # should not keep them out afterwards.
    student_login_limiter.reset(login_key)

    # Return student information with token
    return TokenResponse(
        message="Login successful",
        student_id=existing_student.id,
        name=existing_student.name,
        email=existing_student.email,
        roll_number=existing_student.roll_number,
        branch=existing_student.branch,
        year=existing_student.year,
        division=existing_student.division,
        batch=existing_student.batch,
        token=new_token,
        token_expires_at=token_expiration.isoformat(),
    )


@app.post("/logout")
def logout_student(
    student: models.Student = Depends(get_current_student),
    db: Session = Depends(get_db)
):
    """
    Log out the current student by invalidating their token.
    """
    db.query(models.Student).filter(models.Student.id == student.id).update(
        {"token": None, "token_expires_at": None}
    )
    db.commit()

    return {"message": "Logged out"}


# Brute-force brake for the portal sign-in. Only FAILED attempts are recorded
# (see ratelimit.py), so a teacher's own successful sign-ins never use up the
# allowance. The key comes from _client_key: behind the ngrok tunnel every
# request arrives from the agent's loopback address, and only in that case is
# the forwarded header trusted.
teacher_login_limiter = SlidingWindowLimiter(
    settings.TEACHER_LOGIN_RATE_LIMIT_PER_MINUTE
)


def teacher_login_rate_limit(request: Request) -> str:
    """Reject further attempts once a client has failed too often; returns key."""
    key = _client_key(request)
    blocked, retry_after = teacher_login_limiter.blocked(key)
    if blocked:
        raise HTTPException(
            status_code=status.HTTP_429_TOO_MANY_REQUESTS,
            detail=(
                "Too many failed sign-in attempts. Wait a minute and try again."
            ),
            headers={"Retry-After": str(retry_after)},
        )
    return key


@app.post("/teacher/login", response_model=TeacherTokenResponse)
def login_teacher(
    teacher: TeacherLogin,
    db: Session = Depends(get_db),
    login_key: str = Depends(teacher_login_rate_limit),
):
    """
    Authenticate a teacher/admin and return a session token.

    Returns 200 with token on success, 401 if credentials are invalid, and 429
    once one client has failed too many times in a minute. Successful sign-ins
    are never counted against the limit.
    """
    # Find teacher by email, case-insensitively (see the student login above).
    existing_teacher = db.query(models.Teacher).filter(
        func.lower(models.Teacher.email) == teacher.email.lower()
    ).first()

    if not existing_teacher:
        from exceptions import AuthenticationError
        teacher_login_limiter.check(login_key)
        raise AuthenticationError("Invalid email or password")

    # Verify password against stored hash
    password_correct = password_hash.verify(
        teacher.password,
        existing_teacher.password,
    )

    if not password_correct:
        from exceptions import AuthenticationError
        teacher_login_limiter.check(login_key)
        raise AuthenticationError("Invalid email or password")

    if not existing_teacher.is_active:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Teacher account is deactivated"
        )

    # Issue a fresh token
    new_token = generate_token()
    token_expiration = generate_token_expiration()

    existing_teacher.token = new_token
    existing_teacher.token_expires_at = token_expiration
    db.commit()

    # A correct password proves this is the account owner; forgotten failures
    # should not keep them out of the portal afterwards.
    teacher_login_limiter.reset(login_key)

    return TeacherTokenResponse(
        message="Login successful",
        teacher_id=existing_teacher.id,
        name=existing_teacher.name,
        email=existing_teacher.email,
        role=existing_teacher.role,
        token=new_token,
        token_expires_at=token_expiration.isoformat(),
    )


@app.post("/teacher/logout")
def logout_teacher(
    teacher: models.Teacher = Depends(get_current_teacher),
    db: Session = Depends(get_db)
):
    """
    Log out the current teacher/admin by invalidating their token.
    """
    db.query(models.Teacher).filter(models.Teacher.id == teacher.id).update(
        {"token": None, "token_expires_at": None}
    )
    db.commit()

    return {"message": "Logged out"}


@app.get("/me", response_model=StudentOut)
def get_me(student: models.Student = Depends(get_current_student)):
    """
    Get current authenticated student information.
    """
    return student


@app.get("/teacher/me", response_model=TeacherOut)
def get_teacher_me(teacher: models.Teacher = Depends(get_current_teacher)):
    """
    Get current authenticated teacher/admin information.
    """
    return teacher


# ============================================================
# TEACHER/ADMIN APPROVAL ENDPOINTS
# ============================================================

@app.get("/teacher/registrations/pending", response_model=list[PendingStudentOut])
def get_pending_registrations(
    teacher: models.Teacher = Depends(require_registration_reviewer),
    db: Session = Depends(get_db)
):
    """
    List all pending student registrations.

    Requires admin role, or a teacher account whose configurable
    `can_approve_registrations` permission has been granted by an admin. The
    check is a server-side dependency, so hiding the button in the app is never
    the only control.
    """
    pending_students = db.query(models.Student).filter(
        models.Student.status == "pending"
    ).order_by(models.Student.id).all()

    return pending_students


@app.post("/teacher/registrations/{student_id}/approve", response_model=ApprovalActionResponse)
def approve_registration(
    student_id: int,
    request: ApproveRequest,
    background: BackgroundTasks,
    teacher: models.Teacher = Depends(require_registration_reviewer),
    db: Session = Depends(get_db)
):
    """
    Approve a pending student registration.

    Requires admin role, or an explicitly granted approval permission.
    """
    student = db.query(models.Student).filter(models.Student.id == student_id).first()

    if not student:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Student not found"
        )

    if student.status != "pending":
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"Student registration is not pending (current status: {student.status})"
        )

    student.status = "approved"
    student.approved_by = teacher.id
    student.approved_at = datetime.utcnow()
    student.rejection_reason = None

    notice_title = "Account approved 🎉"
    notice_message = (
        "Welcome to Stryve! You can now log in and see your timetable."
    )
    # Same transaction as the status change: a student is never approved
    # without the welcome notice, and a failed commit keeps neither.
    _add_student_bells(db, [student], notice_title, notice_message)
    db.commit()

    _schedule_student_push(
        background,
        db,
        [student.id],
        notice_title,
        notice_message,
        {"type": "approved", "student_id": student.id},
    )

    return ApprovalActionResponse(
        message="Student registration approved",
        student_id=student.id,
        status=student.status,
    )


@app.post("/teacher/registrations/{student_id}/reject", response_model=ApprovalActionResponse)
def reject_registration(
    student_id: int,
    request: RejectRequest,
    background: BackgroundTasks,
    teacher: models.Teacher = Depends(require_registration_reviewer),
    db: Session = Depends(get_db)
):
    """
    Reject a pending student registration.

    Requires admin role, or an explicitly granted approval permission.
    """
    student = db.query(models.Student).filter(models.Student.id == student_id).first()

    if not student:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Student not found"
        )

    if student.status != "pending":
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"Student registration is not pending (current status: {student.status})"
        )

    student.status = "rejected"
    student.approved_by = teacher.id
    student.approved_at = datetime.utcnow()
    student.rejection_reason = request.reason

    notice_title = "Registration update"
    reason = (request.reason or "").strip()
    notice_message = "Your registration was not approved."
    if reason:
        notice_message = f"{notice_message} Reason: {reason}"
    _add_student_bells(db, [student], notice_title, notice_message)
    db.commit()

    _schedule_student_push(
        background,
        db,
        [student.id],
        notice_title,
        notice_message,
        {"type": "rejected", "student_id": student.id},
    )

    return ApprovalActionResponse(
        message="Student registration rejected",
        student_id=student.id,
        status=student.status,
    )


@app.post("/teacher/create", response_model=TeacherOut)
def create_teacher(
    teacher_data: TeacherCreate,
    admin: models.Teacher = Depends(require_admin),
    db: Session = Depends(get_db)
):
    """
    Create a new teacher or admin account.

    Only admins can create teacher accounts.
    Role must be 'teacher' or 'admin'.
    """
    if teacher_data.role not in ["teacher", "admin"]:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Role must be 'teacher' or 'admin'"
        )

    # Check if email already exists, ignoring case.
    existing = db.query(models.Teacher).filter(
        func.lower(models.Teacher.email) == teacher_data.email.lower()
    ).first()
    if existing:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="Email already registered"
        )

    hashed_password = password_hash.hash(teacher_data.password)

    new_teacher = models.Teacher(
        name=teacher_data.name,
        # Canonical lowercase, matching student registration.
        email=teacher_data.email.lower(),
        password=hashed_password,
        # Kept so an admin can read the credential back out of the Admin panel;
        # it never appears in a teacher-facing response.
        plain_password=teacher_data.password,
        role=teacher_data.role,
        is_active=True,
        created_at=datetime.utcnow(),
    )

    try:
        db.add(new_teacher)
        db.commit()
        db.refresh(new_teacher)
        return new_teacher
    except IntegrityError:
        db.rollback()
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="Registration conflict - please try again"
        )


@app.get("/teacher/list", response_model=list[TeacherAdminOut])
def list_teachers(
    admin: models.Teacher = Depends(require_admin),
    db: Session = Depends(get_db)
):
    """
    List all teacher/admin accounts.

    Only admins can list all teachers.
    """
    teachers = db.query(models.Teacher).order_by(models.Teacher.id).all()
    return teachers


@app.get("/timetable", response_model=list[TimetableEntryOut])
def get_my_timetable(
    student: models.Student = Depends(get_current_student),
    db: Session = Depends(get_db)
):
    """
    Returns every timetable entry for the logged-in student's division,
    including both entries common to the whole division (batch is null)
    and entries specific to their own batch.
    """
    return _student_timetable_entries(db, student)


@app.get("/me", response_model=StudentOut)
def get_me(student: models.Student = Depends(get_current_student)):
    """
    Get current authenticated student information.
    """
    return student


@app.get("/teacher/me", response_model=TeacherOut)
def get_teacher_me(teacher: models.Teacher = Depends(get_current_teacher)):
    """
    Get current authenticated teacher/admin information.
    """
    return teacher


@app.get("/assignments", response_model=list[AssignmentOut])
def get_my_assignments(
    student: models.Student = Depends(get_current_student),
    db: Session = Depends(get_db)
):
    """
    Returns assignments for the logged-in student's year and division,
    including both division-wide and batch-specific assignments.
    """
    query = db.query(models.Assignment).filter(
        models.Assignment.year == student.year,
        models.Assignment.division == student.division,
    )

    batch = _normalise_batch(student.batch)
    if batch in VALID_BATCHES:
        query = query.filter(
            or_(
                models.Assignment.batch == None,  # noqa: E711
                models.Assignment.batch == batch,
                # tolerate the sheet's "D1" spelling next to the registry's "D-1"
                models.Assignment.batch == batch.replace("-", ""),
            )
        )
    else:
        # Missing or unreadable batch: division-wide assignments only. Never
        # fall back to "show everything" - that would expose another batch's
        # material to a student whose batch we cannot verify.
        query = query.filter(models.Assignment.batch == None)  # noqa: E711

    return query.order_by(models.Assignment.due_date).all()


@app.get("/notifications", response_model=list[NotificationOut])
def list_my_notifications(
    student: models.Student = Depends(get_current_student),
    db: Session = Depends(get_db),
):
    """The caller's notifications, newest first.

    Scoped by the authenticated student's id, never by a client-supplied one, so
    one student can never read another's feed.
    """
    return (
        db.query(models.Notification)
        .filter(models.Notification.student_id == student.id)
        .order_by(
            models.Notification.created_at.desc(),
            models.Notification.id.desc(),
        )
        .all()
    )


@app.put("/notifications/read-all")
def mark_all_notifications_read(
    student: models.Student = Depends(get_current_student),
    db: Session = Depends(get_db),
):
    """Mark every unread notification of the caller as read (idempotent)."""
    marked = (
        db.query(models.Notification)
        .filter(
            models.Notification.student_id == student.id,
            models.Notification.is_read.is_(False),
        )
        .update({models.Notification.is_read: True}, synchronize_session=False)
    )
    db.commit()
    return {"message": "Notifications marked as read", "marked_read": marked}


@app.post("/notifications/device-token", response_model=DeviceTokenOut)
def register_device_token(
    payload: DeviceTokenRegister,
    student: models.Student = Depends(get_current_student),
    db: Session = Depends(get_db),
):
    """Remember this device's Firebase token for the signed-in student.

    Idempotent: the app calls this on every launch and whenever Firebase
    rotates the token, so the same token must not accumulate rows.

    A token belongs to a *device*, not an account. FCM itself does not know
    which student is signed in, so if the row already exists for somebody else
    (the phone was handed over, or a second student logged in on it) the row is
    re-pointed at the caller. That is what stops the previous student's alerts
    from arriving on a phone they no longer use; the alternate - keeping the
    old owner - would leak that class's assignments to the wrong person.

    The token is never returned or logged: it is only a delivery address.
    """
    row = (
        db.query(models.FcmToken)
        .filter(models.FcmToken.token == payload.token)
        .first()
    )

    if row is None:
        db.add(
            models.FcmToken(
                student_id=student.id,
                token=payload.token,
                created_at=datetime.utcnow(),
            )
        )
    elif row.student_id != student.id:
        row.student_id = student.id
        row.created_at = datetime.utcnow()

    db.commit()
    return DeviceTokenOut(registered=True)


@app.delete("/notifications/device-token", response_model=DeviceTokenOut)
def unregister_device_token(
    token: str,
    student: models.Student = Depends(get_current_student),
    db: Session = Depends(get_db),
):
    """Forget a device token on logout (best effort, idempotent).

    Only the caller's own row is removed: knowing another student's token must
    not be enough to silence their notifications. An unknown token is a
    success, because the goal - "this device no longer rings for me" - holds.
    """
    cleaned = (token or "").strip()
    if not cleaned:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Device token is required",
        )

    db.query(models.FcmToken).filter(
        models.FcmToken.token == cleaned,
        models.FcmToken.student_id == student.id,
    ).delete(synchronize_session=False)
    db.commit()
    return DeviceTokenOut(registered=False)


@app.put("/notifications/{notification_id}/read", response_model=NotificationOut)
def mark_notification_read(
    notification_id: int,
    student: models.Student = Depends(get_current_student),
    db: Session = Depends(get_db),
):
    """Mark one of the caller's notifications as read (idempotent).

    A row belonging to somebody else answers 404, not 403: whether another
    student has a notification with that id is not this caller's business.
    """
    row = (
        db.query(models.Notification)
        .filter(
            models.Notification.id == notification_id,
            models.Notification.student_id == student.id,
        )
        .first()
    )

    if not row:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Notification not found",
        )

    if not row.is_read:
        row.is_read = True
        db.commit()
        db.refresh(row)

    return row


# ==================================================================
# Notification writers shared by every trigger
# ==================================================================
# The durable in-app row is written in the same transaction as the action it
# describes; the FCM hand-off happens afterwards, in a background task. A push
# failure can never undo, delay or duplicate the action itself - the bell is
# the record and the tray is only a convenience.


def _active_reviewer_ids(db: Session) -> list[int]:
    """Admins and teachers who may act on a pending registration.

    Inactive accounts are excluded: deactivating a teacher must stop their
    phone from buzzing about work they can no longer do.
    """
    rows = (
        db.query(models.Teacher.id)
        .filter(
            models.Teacher.is_active.is_(True),
            or_(
                models.Teacher.role == "admin",
                models.Teacher.can_approve_registrations.is_(True),
            ),
        )
        .all()
    )
    return [row[0] for row in rows]


def _approved_students(
    db: Session,
    *,
    year: int | None = None,
    division: str | None = None,
    batch: str = "",
) -> list[models.Student]:
    """Approved students matching the audience filters, in one query.

    ``batch`` is compared after normalisation so "D-3" and "D3" both match; an
    empty batch means the whole division. Unapproved accounts are never part of
    an audience - they cannot log in to read the bell yet.
    """
    query = db.query(models.Student).filter(
        models.Student.status == models.StudentStatus.approved
    )
    if year is not None:
        query = query.filter(models.Student.year == year)
    if division:
        query = query.filter(
            models.Student.division == (division or "").strip().upper()
        )

    students = query.all()
    wanted = _normalise_batch(batch)
    if wanted:
        students = [
            student
            for student in students
            if _normalise_batch(student.batch) == wanted
        ]
    return students


def _add_student_bells(
    db: Session,
    students: Iterable[models.Student],
    title: str,
    message: str,
    *,
    created_at: datetime | None = None,
) -> None:
    """Queue one bell row per student (no commit; the caller commits)."""
    when = created_at or datetime.utcnow()
    for student in students:
        db.add(
            models.Notification(
                student_id=student.id,
                title=title,
                message=message,
                is_read=False,
                created_at=when,
            )
        )


def _add_teacher_bells(
    db: Session,
    teacher_ids: Iterable[int],
    title: str,
    message: str,
    *,
    kind: str = "general",
    ref_id: int | None = None,
    created_at: datetime | None = None,
) -> None:
    """Queue one bell row per teacher (no commit; the caller commits)."""
    when = created_at or datetime.utcnow()
    seen: set[int] = set()
    for teacher_id in teacher_ids:
        if teacher_id in seen:
            continue
        seen.add(teacher_id)
        db.add(
            models.TeacherNotification(
                teacher_id=teacher_id,
                title=title,
                message=message,
                is_read=False,
                kind=kind,
                ref_id=ref_id,
                created_at=when,
            )
        )


def _push_tokens_for_teachers(db: Session, teacher_ids: list[int]) -> list[str]:
    """Every registered device token belonging to ``teacher_ids``."""
    if not teacher_ids:
        return []
    rows = (
        db.query(models.TeacherFcmToken.token)
        .filter(models.TeacherFcmToken.teacher_id.in_(teacher_ids))
        .all()
    )
    return [row[0] for row in rows if row[0]]


def _deliver_push(
    tokens: list[str],
    title: str,
    body: str,
    data: dict,
    *,
    teacher_tokens: bool = False,
) -> None:
    """Background job: send the tray alert and prune dead tokens.

    Runs after the response, in its own short-lived session. Every failure is
    swallowed: the in-app row is already committed and is what the bell shows.
    """
    try:
        result = firebase_service.send_push_notification(
            tokens, title, body, data=data
        )
    except Exception:
        return

    if not result.invalid_tokens:
        return

    db = SessionLocal()
    try:
        model = (
            models.TeacherFcmToken if teacher_tokens else models.FcmToken
        )
        db.query(model).filter(
            model.token.in_(result.invalid_tokens)
        ).delete(synchronize_session=False)
        db.commit()
    except Exception:
        db.rollback()
    finally:
        db.close()


def _schedule_student_push(
    background: BackgroundTasks,
    db: Session,
    student_ids: list[int],
    title: str,
    message: str,
    data: dict,
) -> None:
    """Queue one push to the devices of ``student_ids`` (no-op without tokens)."""
    tokens = _push_tokens_for_students(db, student_ids)
    if tokens:
        background.add_task(_deliver_push, tokens, title, message, data)


@app.post("/teacher/notifications/device-token", response_model=DeviceTokenOut)
def register_teacher_device_token(
    payload: DeviceTokenRegister,
    teacher: models.Teacher = Depends(require_teacher_or_admin),
    db: Session = Depends(get_db),
):
    """Remember this device's Firebase token for the signed-in teacher.

    Same idempotency and hand-over rule as the student endpoint: a token is a
    device, so signing a different teacher in on it re-points the row instead of
    creating a second delivery address.
    """
    row = (
        db.query(models.TeacherFcmToken)
        .filter(models.TeacherFcmToken.token == payload.token)
        .first()
    )

    if row is None:
        db.add(
            models.TeacherFcmToken(
                teacher_id=teacher.id,
                token=payload.token,
                created_at=datetime.utcnow(),
            )
        )
    elif row.teacher_id != teacher.id:
        row.teacher_id = teacher.id
        row.created_at = datetime.utcnow()

    db.commit()
    return DeviceTokenOut(registered=True)


@app.get("/teacher/notifications", response_model=TeacherNotificationsOut)
def list_teacher_notifications(
    teacher: models.Teacher = Depends(require_teacher_or_admin),
    db: Session = Depends(get_db),
):
    """The caller's bell feed, newest first, with the unread count.

    Scoped by the authenticated account, never by a client-supplied id.
    """
    rows = (
        db.query(models.TeacherNotification)
        .filter(models.TeacherNotification.teacher_id == teacher.id)
        .order_by(
            models.TeacherNotification.created_at.desc(),
            models.TeacherNotification.id.desc(),
        )
        .all()
    )
    return TeacherNotificationsOut(
        notifications=rows,
        unread_count=sum(1 for row in rows if not row.is_read),
    )


@app.put("/teacher/notifications/read-all")
def mark_all_teacher_notifications_read(
    teacher: models.Teacher = Depends(require_teacher_or_admin),
    db: Session = Depends(get_db),
):
    """Mark every unread notification of the caller as read (idempotent)."""
    marked = (
        db.query(models.TeacherNotification)
        .filter(
            models.TeacherNotification.teacher_id == teacher.id,
            models.TeacherNotification.is_read.is_(False),
        )
        .update(
            {models.TeacherNotification.is_read: True},
            synchronize_session=False,
        )
    )
    db.commit()
    return {"message": "Notifications marked as read", "marked_read": marked}


@app.put(
    "/teacher/notifications/{notification_id}/read",
    response_model=TeacherNotificationOut,
)
def mark_teacher_notification_read(
    notification_id: int,
    teacher: models.Teacher = Depends(require_teacher_or_admin),
    db: Session = Depends(get_db),
):
    """Mark one of the caller's notifications as read (idempotent).

    Somebody else's row answers 404, not 403: whether another account has a
    notification with that id is not this caller's business.
    """
    row = (
        db.query(models.TeacherNotification)
        .filter(
            models.TeacherNotification.id == notification_id,
            models.TeacherNotification.teacher_id == teacher.id,
        )
        .first()
    )

    if not row:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Notification not found",
        )

    if not row.is_read:
        row.is_read = True
        db.commit()
        db.refresh(row)

    return row


# ==================================================================
# Announcements - a teacher posts, the whole class group (or everyone) reads.
# ==================================================================
# The seven subjects of Division D's first-year sheet. The portal and the app
# offer exactly these labels; an empty subject means "Common" and is stored as
# NULL, which is also what every pre-subject row holds.
ANNOUNCEMENT_SUBJECTS = (
    "Engineering Mathematics-I",
    "Engineering Physics",
    "Basic Electrical Engineering",
    "Engineering Graphics",
    "Fundamentals of Programming Languages",
    "Design Thinking & Idea Lab",
    "Professional Communication Skills",
)


@app.post(
    "/teacher/announcements",
    response_model=AnnouncementOut,
    status_code=status.HTTP_201_CREATED,
)
def create_announcement(
    background: BackgroundTasks,
    title: str = Form(...),
    message: str = Form(...),
    year: int | None = Form(None),
    division: str = Form(""),
    subject: str = Form(""),
    files: list[UploadFile] = File(default=[]),
    teacher: models.Teacher = Depends(require_teacher_or_admin),
    db: Session = Depends(get_db),
):
    """Post an announcement to the student feed, with optional files.

    Any active teacher or admin account may post - this is a normal part of
    teaching here, so there is no separate permission to grant. The author is
    the authenticated account, never a client-supplied id.

    ``year``/``division`` are optional restrictions: leaving both out posts to
    every student, leaving one out keeps the other. Attachments use the same
    directory, magic-byte check and per-file size limit as assignment uploads;
    a file that fails anywhere is not stored, and a later failure removes the
    files already written.
    """
    clean_title = title.strip()
    if not clean_title or len(clean_title) > 200:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Title is required and must be at most 200 characters",
        )

    clean_message = message.strip()
    if not clean_message or len(clean_message) > 5000:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Message is required and must be at most 5000 characters",
        )

    if year is not None and not 1 <= year <= 5:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Year must be between 1 and 5, or omitted",
        )

    clean_division = division.strip().upper()
    if len(clean_division) > 8:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Division must be at most 8 characters, or omitted",
        )

    clean_subject = subject.strip()
    if clean_subject and clean_subject not in ANNOUNCEMENT_SUBJECTS:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=(
                "Subject must be one of the seven official subjects, or "
                "empty for Common"
            ),
        )

    uploads = [item for item in (files or []) if item is not None]
    if len(uploads) > MAX_ASSIGNMENT_ATTACHMENTS:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=(
                "At most "
                f"{MAX_ASSIGNMENT_ATTACHMENTS} files can be attached to one "
                "announcement"
            ),
        )

    max_bytes = max(1, settings.MAX_ASSIGNMENT_FILE_MB) * 1024 * 1024
    upload_dir = settings.upload_path
    upload_dir.mkdir(parents=True, exist_ok=True)

    # (path, stored name, display name, size) for every file already written.
    # Any failure below removes them again, so a refused post leaves nothing
    # behind and no announcement without its files is saved.
    stored_files: list[tuple[Path, str, str, int]] = []
    try:
        for upload in uploads:
            data, media_kind = _validated_upload_bytes(upload, max_bytes)
            stored_name = f"{uuid.uuid4().hex}{_MEDIA_EXTENSIONS[media_kind]}"
            (upload_dir / stored_name).write_bytes(data)
            stored_files.append(
                (
                    upload_dir / stored_name,
                    stored_name,
                    _safe_display_name(upload.filename),
                    len(data),
                )
            )
    except HTTPException:
        for path, *_ in stored_files:
            path.unlink(missing_ok=True)
        raise

    announcement = models.Announcement(
        title=clean_title,
        message=clean_message,
        author_id=teacher.id,
        created_at=datetime.utcnow(),
        year=year,
        division=clean_division or None,
        subject=clean_subject or None,
    )
    announcement.attachments = [
        models.AnnouncementAttachment(
            stored_name=stored_name,
            original_name=original_name,
            file_size=size,
        )
        for _stored_path, stored_name, original_name, size in stored_files
    ]

    # Audience for both channels: approved students in the target year and
    # division, or every approved student when neither filter is set. The bell
    # rows commit with the announcement, so a notice never exists without them.
    audience = _approved_students(
        db, year=year, division=clean_division or None
    )
    notice_title = "New announcement"
    notice_message = clean_title
    if clean_subject:
        notice_message = f"{clean_title} · {clean_subject}"

    try:
        db.add(announcement)
        _add_student_bells(db, audience, notice_title, notice_message)
        db.commit()
        db.refresh(announcement)
    except IntegrityError:
        db.rollback()
        for path, *_ in stored_files:
            path.unlink(missing_ok=True)
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="Could not save the announcement - please try again",
        )

    _schedule_student_push(
        background,
        db,
        [student.id for student in audience],
        notice_title,
        notice_message,
        {"type": "announcement", "announcement_id": announcement.id},
    )

    return announcement


@app.get("/teacher/announcements", response_model=list[AnnouncementOut])
def list_manageable_announcements(
    teacher: models.Teacher = Depends(require_teacher_or_admin),
    db: Session = Depends(get_db),
):
    """The announcements the caller may delete, newest first.

    An admin manages the whole feed; a teacher manages only what they posted,
    so the list a teacher sees is exactly the set the delete route accepts.
    The scope comes from the authenticated account, never from the client.
    """
    query = db.query(models.Announcement).options(
        joinedload(models.Announcement.author)
    )
    if teacher.role != "admin":
        query = query.filter(models.Announcement.author_id == teacher.id)

    return query.order_by(
        models.Announcement.created_at.desc(),
        models.Announcement.id.desc(),
    ).all()


@app.delete("/teacher/announcements/{announcement_id}")
def delete_announcement(
    announcement_id: int,
    teacher: models.Teacher = Depends(require_teacher_or_admin),
    db: Session = Depends(get_db),
):
    """Withdraw one announcement from the student feed.

    Only the account that posted it, or an admin, may remove it - a teacher
    cannot delete a colleague's notice. Deleting is permanent: the feed reads
    this table directly, so there is no soft-delete flag to restore from.
    """
    announcement = db.query(models.Announcement).filter(
        models.Announcement.id == announcement_id
    ).first()

    if not announcement:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Announcement not found",
        )

    if announcement.author_id != teacher.id and teacher.role != "admin":
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="You can only delete announcements you posted",
        )

    # The notice and its files go together: deleting the row must not leave
    # unreachable PDFs/videos behind on disk.
    for attachment in announcement.attachments:
        (settings.upload_path / attachment.stored_name).unlink(missing_ok=True)

    db.delete(announcement)
    db.commit()
    return {"message": "Announcement deleted", "announcement_id": announcement_id}


@app.get("/announcements/{announcement_id}/files/{file_id}")
def download_announcement_attachment(
    announcement_id: int,
    file_id: int,
    actor: tuple = Depends(get_current_actor),
    db: Session = Depends(get_db),
):
    """Download one file attached to an announcement.

    The file id alone grants nothing: the attachment must belong to the
    announcement, and the caller must be allowed to read that notice. Students
    follow the feed's audience rule (year/division); a teacher may read a file
    only from their own post, an admin from any. The stored name is a
    server-generated flat name and is never taken from the client.
    """
    role, account = actor

    announcement = db.query(models.Announcement).filter(
        models.Announcement.id == announcement_id
    ).first()
    if not announcement:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Announcement not found",
        )

    attachment = next(
        (row for row in announcement.attachments if row.id == file_id),
        None,
    )
    if attachment is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="This announcement has no file with that id",
        )

    if role == "student":
        allowed = (
            (announcement.year is None or announcement.year == account.year)
            and (
                not announcement.division
                or (announcement.division or "").upper()
                == (account.division or "").upper()
            )
        )
    else:
        allowed = account.role == "admin" or announcement.author_id == account.id

    if not allowed:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="You are not permitted to download this announcement file",
        )

    stored_name = attachment.stored_name
    if Path(stored_name).name != stored_name:
        # Defensive: a stored name must never be a path.
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND, detail="Invalid stored file"
        )

    path = settings.upload_path / stored_name
    if not path.exists():
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="The stored file is no longer available",
        )

    return _file_response(
        path,
        attachment.original_name
        or f"announcement-{announcement.id}{path.suffix.lower()}",
    )


@app.get("/announcements", response_model=list[AnnouncementOut])
def list_my_announcements(
    student: models.Student = Depends(get_current_student),
    db: Session = Depends(get_db),
):
    """The announcements this student may read, newest first.

    A NULL ``year`` or ``division`` means "no restriction on that field", so a
    college-wide post is read by everyone while a class-group post stays in
    that group. The filter is built from the authenticated student - a client
    can never ask for another year's or division's feed. A student whose own
    year/division is missing only ever sees the unrestricted rows.
    """
    year_filter = or_(
        models.Announcement.year.is_(None),
        models.Announcement.year == student.year,
    )
    division_filter = or_(
        models.Announcement.division.is_(None),
        func.upper(models.Announcement.division)
        == (student.division or "").upper(),
    )

    return (
        db.query(models.Announcement)
        .options(joinedload(models.Announcement.author))
        .filter(year_filter, division_filter)
        .order_by(
            models.Announcement.created_at.desc(),
            models.Announcement.id.desc(),
        )
        .all()
    )


# ==================================================================
# The college clock (Division D) runs on IST. A free-period claim is judged
# against that calendar day, not the UTC day: at 20:00 UTC the college is already
# on tomorrow's date, and a plain utcnow().date() would refuse a claim the
# department still considers "today". A fixed offset is enough here - the
# timetable itself is a fixed grid - and needs no extra dependency.
COLLEGE_TIMEZONE = timezone(timedelta(hours=5, minutes=30))
COLLEGE_TIMEZONE_LABEL = "IST (UTC+05:30)"


def _college_today() -> date:
    """Today's date on the college clock."""
    return datetime.now(COLLEGE_TIMEZONE).date()


# ==================================================================
# A lecture's attendance is written during that lecture, not whenever it is
# convenient. The sheet opens ATTENDANCE_GRACE before the printed period and
# closes the same amount after it, on the college clock. Admin accounts are
# exempt: they are how a mistake gets corrected after the fact.
# ==================================================================
ATTENDANCE_GRACE = timedelta(minutes=15)


def _attendance_now() -> datetime:
    """Now on the college clock.

    A single seam: the suites replace this to pin the time rules instead of
    depending on the wall clock of whichever machine runs them.
    """
    return datetime.now(COLLEGE_TIMEZONE)


def _clock_label(moment: datetime) -> str:
    """'1:05 PM' - the clock face a teacher reads off the printed timetable."""
    hour = moment.hour % 12 or 12
    suffix = "AM" if moment.hour < 12 else "PM"
    return f"{hour}:{moment.minute:02d} {suffix}"


def _lecture_moment(day_date: date, hhmm: str) -> datetime:
    """A printed time on a calendar day, read on the college clock."""
    hour, minute = (int(part) for part in hhmm.split(":"))
    return datetime(
        day_date.year,
        day_date.month,
        day_date.day,
        hour,
        minute,
        tzinfo=COLLEGE_TIMEZONE,
    )


def _attendance_window_open(
    session_date: str, slot_start: str, slot_end: str
) -> bool:
    """Is the lecture still inside its save window?

    One implementation for both the write path (which refuses outside it) and
    the history listing (which decides whether a Delete button is offered), so
    the two can never disagree about a lecture being "still open".
    """
    day_date = _parse_date(session_date)
    opens = _lecture_moment(day_date, slot_start) - ATTENDANCE_GRACE
    closes = _lecture_moment(day_date, slot_end) + ATTENDANCE_GRACE
    return opens <= _attendance_now() <= closes


def _require_attendance_window(
    teacher: models.Teacher,
    *,
    session_date: str,
    slot_start: str,
    slot_end: str,
) -> None:
    """Refuse an attendance save that is not during its lecture.

    The window is the printed period plus ATTENDANCE_GRACE on either side, judged
    on the college clock (IST) - never the UTC day, which would close an evening
    lecture four hours late. Admin accounts are exempt and may always correct a
    lecture, which is what keeps a marking mistake fixable.
    """
    if teacher.role == "admin":
        return

    if _attendance_window_open(session_date, slot_start, slot_end):
        return

    day_date = _parse_date(session_date)
    opens = _lecture_moment(day_date, slot_start) - ATTENDANCE_GRACE
    closes = _lecture_moment(day_date, slot_end) + ATTENDANCE_GRACE

    raise HTTPException(
        status_code=status.HTTP_403_FORBIDDEN,
        detail=(
            f"Attendance for {session_date} "
            f"{_clock_label(_lecture_moment(day_date, slot_start))} to "
            f"{_clock_label(_lecture_moment(day_date, slot_end))} can only be "
            f"saved from {_clock_label(opens)} to {_clock_label(closes)} "
            f"({COLLEGE_TIMEZONE_LABEL}). An administrator can still correct "
            "this lecture later."
        ),
    )


# ==================================================================
# Correcting a saved lecture is a DIFFERENT window from taking it. A teacher who
# spots a wrong mark may flip it for ATTENDANCE_EDIT_WINDOW after the session was
# marked - long enough to notice, short enough that a term's history is not
# rewritten weeks later. The delete window stays tied to the printed lecture
# (see _attendance_window_open), because deleting a whole session is a bigger
# act than correcting one student. Admin accounts are exempt from both.
# ==================================================================
ATTENDANCE_EDIT_WINDOW = timedelta(hours=24)


def _within_edit_window(rows: list[models.AttendanceRecord]) -> bool:
    """Is this session still inside its 24-hour correction window?

    Judged from the session's earliest mark, so re-saving a lecture does not
    extend its editable life: once the oldest row is a day old the whole
    session is closed.
    """
    marks = [row.marked_at for row in rows if row.marked_at is not None]
    if not marks:
        return False
    return datetime.utcnow() - min(marks) < ATTENDANCE_EDIT_WINDOW


# Official timetable helpers (Division D, First Term, Revision 4)
# ============================================================
def _normalise_batch(value) -> str:
    """Return "D-1"/"D-2"/"D-3", or "" when the value is missing/unusable.

    The registry stores "D-1" while the printed timetable says "D1", so both
    spellings normalise to the same value. Anything else becomes "" (unknown),
    which the filters below treat as "common lectures only".
    """
    raw = (value or "").strip().upper().replace(" ", "")
    match = re.fullmatch(r"D[-_]?([123])", raw)
    if match:
        return f"D-{match.group(1)}"
    return ""


def _student_timetable_entries(db: Session, student: models.Student):
    """The student's division timetable: common lectures + their own batch.

    One implementation shared by both `/timetable` route definitions, so the
    pair can never disagree. A missing or invalid stored batch degrades to
    common lectures only - it can never reveal another batch's practical.
    """
    division = (student.division or "").strip()
    batch = _normalise_batch(student.batch)

    query = db.query(models.TimetableEntry).filter(
        models.TimetableEntry.division == division
    )

    if batch in VALID_BATCHES:
        query = query.filter(
            or_(
                models.TimetableEntry.batch == None,  # noqa: E711
                models.TimetableEntry.batch == batch,
                models.TimetableEntry.batch == batch.replace("-", ""),
            )
        )
    else:
        query = query.filter(models.TimetableEntry.batch == None)  # noqa: E711

    rows = query.order_by(
        models.TimetableEntry.day, models.TimetableEntry.start_time
    ).all()

    # A free period (the sheet's "RELM") is a period with no class: a student has
    # nothing to attend, so it is never part of a student's schedule - not as a
    # lecture, not as a practical and not as a break. It stays visible to
    # teachers through Claim Free Period only.
    return [row for row in rows if not _is_free_period_entry(row)]


def _is_free_period_entry(entry: models.TimetableEntry) -> bool:
    """True when this row is one of the sheet's free periods ("RELM").

    The stored ``is_free_period`` flag is the primary source of truth. The
    official slot table is the second opinion, so a row this process can read
    but the seeder has not corrected yet (the column still holds its ``0``
    default and the row is still flagged as a break) is never handed to a
    student as a lecture either.

    A database where the additive column has not been added at all is a
    different case: the ORM query itself fails on the missing column, so no
    schedule is returned at all - a loud error, never a partial or wrongly
    labelled timetable. ``seed_official_data.py --schema-only --apply`` is the
    sanctioned first step for such a database (see DATABASE.md).
    """
    if bool(getattr(entry, "is_free_period", False)):
        return True

    if (entry.subject or "").strip().upper() != official_data.FREE_PERIOD_SUBJECT:
        return False

    return official_data.is_free_period_slot(
        entry.day, entry.start_time, entry.end_time
    )


def _faculty_tokens(faculty: str | None) -> set[str]:
    """Split a timetable faculty cell ("RVS (CCI)", "SMG / TUT") into codes."""
    return set(re.findall(r"[A-Z0-9]+", (faculty or "").upper()))


def _slot_pair(start_time: str, end_time: str) -> tuple[str, str] | None:
    """Return the official (start, end) session, or None when it does not exist.

    Official single periods and the printed multi-period practical blocks are
    both valid: a lab that runs 10:15-12:15 is marked as one session, not two
    halves, and the sheet's own correction is what allows it.
    """
    for known_start, known_end in official_data.SESSION_BLOCKS:
        if start_time == known_start and end_time == known_end:
            return known_start, known_end
    return None


def _parse_date(value: str):
    try:
        return datetime.strptime((value or "").strip(), "%Y-%m-%d").date()
    except ValueError:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Date must be in YYYY-MM-DD format",
        )


def _day_name(day_date) -> str:
    names = [
        "Monday",
        "Tuesday",
        "Wednesday",
        "Thursday",
        "Friday",
        "Saturday",
        "Sunday",
    ]
    return names[day_date.weekday()]


# ==================================================================
# Teacher assignments (who is verified to teach what)
# ============================================================
def _verified_assignment(
    db: Session,
    teacher: models.Teacher,
    *,
    subject: str,
    division: str,
    batch: str,
    day: str = "",
    slot_start: str = "",
):
    """The teacher's verified assignment for this class, or None.

    A row matches when it covers the same subject (name or code), the same
    division, the requested batch (or the whole division) and - when the row is
    period-scoped - the same day/period. Nothing is inferred from a teacher's
    name: an unlinked account simply has no verified assignment.
    """
    requested_subject = (subject or "").strip().lower()
    requested_batch = _normalise_batch(batch)

    rows = db.query(models.TeacherAssignment).filter(
        models.TeacherAssignment.teacher_id == teacher.id
    ).all()

    for row in rows:
        if row.division.strip().upper() != (division or "").strip().upper():
            continue

        row_subject = (row.subject or "").strip().lower()
        row_code = (row.subject_code or "").strip().lower()
        if requested_subject not in {row_subject, row_code}:
            continue

        row_batch = _normalise_batch(row.batch)
        if row_batch and row_batch != requested_batch:
            continue

        if row.day and day and row.day.strip().lower() != day.strip().lower():
            continue
        if row.start_time and slot_start and row.start_time != slot_start:
            continue

        return row

    return None


def _require_attendance_permission(
    db: Session,
    teacher: models.Teacher,
    *,
    subject: str,
    division: str,
    batch: str,
    day: str = "",
    slot_start: str = "",
) -> None:
    """Raise 403 unless the caller may work on this class/subject.

    Admins may act on any class. A teacher needs a verified assignment - the
    server decides, never the app.
    """
    if teacher.role == "admin":
        return

    if _verified_assignment(
        db,
        teacher,
        subject=subject,
        division=division,
        batch=batch,
        day=day,
        slot_start=slot_start,
    ):
        return

    label = batch or "whole division"
    raise HTTPException(
        status_code=status.HTTP_403_FORBIDDEN,
        detail=(
            f"You are not assigned to teach {subject} for division {division} "
            f"({label}). Ask an administrator to add the assignment before "
            "attendance or free periods can be used for this class."
        ),
    )


def _sync_assignments_from_timetable(
    db: Session, teacher: models.Teacher
) -> list[models.TeacherAssignment]:
    """Give a teacher the periods they are printed against on the timetable.

    Only exact code matches count (the faculty cell is split into tokens, so
    "RVS (CCI)" links RVS but "RVSX" does not) and rows are only ever added.
    """
    code = (teacher.short_code or "").strip().upper()
    if not code:
        return []

    existing = {
        (
            row.subject,
            row.division,
            row.batch,
            row.day,
            row.start_time,
            row.end_time,
        )
        for row in db.query(models.TeacherAssignment).filter(
            models.TeacherAssignment.teacher_id == teacher.id
        )
    }

    created = []
    entries = db.query(models.TimetableEntry).filter(
        models.TimetableEntry.is_break == False,  # noqa: E712
        models.TimetableEntry.is_free_period == False,  # noqa: E712
    ).all()

    for entry in entries:
        if code not in _faculty_tokens(entry.faculty):
            continue

        batch = _normalise_batch(entry.batch)
        key = (
            entry.subject,
            entry.division,
            batch,
            entry.day,
            entry.start_time,
            entry.end_time,
        )
        if key in existing:
            continue

        row = models.TeacherAssignment(
            teacher_id=teacher.id,
            subject=entry.subject,
            subject_code=None,
            division=entry.division,
            batch=batch,
            day=entry.day,
            start_time=entry.start_time,
            end_time=entry.end_time,
            source="timetable",
            created_at=datetime.utcnow(),
        )
        db.add(row)
        existing.add(key)
        created.append(row)

    if created:
        db.commit()
        for row in created:
            db.refresh(row)

    return created


@app.get("/teacher/assignments", response_model=list[TeacherAssignmentOut])
def list_my_assignments(
    teacher: models.Teacher = Depends(require_teacher_or_admin),
    db: Session = Depends(get_db),
):
    """The caller's own verified teaching assignments (may be empty)."""
    return (
        db.query(models.TeacherAssignment)
        .filter(models.TeacherAssignment.teacher_id == teacher.id)
        .order_by(models.TeacherAssignment.day, models.TeacherAssignment.start_time)
        .all()
    )


@app.get("/teacher/{teacher_id}/assignments", response_model=list[TeacherAssignmentOut])
def list_teacher_assignments(
    teacher_id: int,
    admin: models.Teacher = Depends(require_admin),
    db: Session = Depends(get_db),
):
    """Admin view of one teacher's verified assignments."""
    return (
        db.query(models.TeacherAssignment)
        .filter(models.TeacherAssignment.teacher_id == teacher_id)
        .order_by(models.TeacherAssignment.day, models.TeacherAssignment.start_time)
        .all()
    )


@app.post(
    "/teacher/{teacher_id}/assignments",
    response_model=TeacherAssignmentOut,
    status_code=status.HTTP_201_CREATED,
)
def create_teacher_assignment(
    teacher_id: int,
    payload: TeacherAssignmentCreate,
    admin: models.Teacher = Depends(require_admin),
    db: Session = Depends(get_db),
):
    """Admin-created assignment. Duplicates are rejected by the unique index."""
    target = db.query(models.Teacher).filter(models.Teacher.id == teacher_id).first()
    if not target:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND, detail="Teacher not found"
        )

    existing = db.query(models.TeacherAssignment).filter(
        models.TeacherAssignment.teacher_id == teacher_id,
        models.TeacherAssignment.subject == payload.subject,
        models.TeacherAssignment.division == payload.division,
        models.TeacherAssignment.batch == payload.batch,
        models.TeacherAssignment.day == payload.day,
        models.TeacherAssignment.start_time == payload.start_time,
        models.TeacherAssignment.end_time == payload.end_time,
    ).first()

    if existing:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="That assignment already exists for this teacher",
        )

    row = models.TeacherAssignment(
        teacher_id=teacher_id,
        subject=payload.subject,
        subject_code=payload.subject_code,
        division=payload.division,
        batch=payload.batch,
        day=payload.day,
        start_time=payload.start_time,
        end_time=payload.end_time,
        source="manual",
        created_at=datetime.utcnow(),
    )
    db.add(row)
    db.commit()
    db.refresh(row)
    return row


@app.delete("/teacher/{teacher_id}/assignments/{assignment_id}")
def delete_teacher_assignment(
    teacher_id: int,
    assignment_id: int,
    admin: models.Teacher = Depends(require_admin),
    db: Session = Depends(get_db),
):
    """Admin removal of one teaching-assignment row (never a bulk change)."""
    row = db.query(models.TeacherAssignment).filter(
        models.TeacherAssignment.id == assignment_id,
        models.TeacherAssignment.teacher_id == teacher_id,
    ).first()
    if not row:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND, detail="Assignment not found"
        )
    db.delete(row)
    db.commit()
    return {"message": "Assignment removed", "assignment_id": assignment_id}


@app.patch("/teacher/{teacher_id}/permissions", response_model=TeacherOut)
def update_teacher_permissions(
    teacher_id: int,
    payload: TeacherPermissionsUpdate,
    admin: models.Teacher = Depends(require_admin),
    db: Session = Depends(get_db),
):
    """Admin-only: grant/revoke the approval permission and link a faculty code.

    Linking a short code that appears on the official timetable also records
    that teacher's periods as verified assignments, which is what attendance
    and Claim Free Period validate against.
    """
    target = db.query(models.Teacher).filter(models.Teacher.id == teacher_id).first()
    if not target:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND, detail="Teacher not found"
        )

    if payload.can_approve_registrations is not None:
        target.can_approve_registrations = payload.can_approve_registrations

    if payload.short_code is not None:
        code = payload.short_code
        if code:
            clash = db.query(models.Teacher).filter(
                models.Teacher.short_code == code,
                models.Teacher.id != teacher_id,
            ).first()
            if clash:
                raise HTTPException(
                    status_code=status.HTTP_409_CONFLICT,
                    detail=f"Short code {code} is already linked to another account",
                )
        target.short_code = code or None

    db.commit()
    db.refresh(target)

    if payload.short_code:
        _sync_assignments_from_timetable(db, target)

    return target


@app.patch("/teacher/{teacher_id}/status", response_model=TeacherOut)
def update_teacher_status(
    teacher_id: int,
    payload: TeacherStatusUpdate,
    admin: models.Teacher = Depends(require_admin),
    db: Session = Depends(get_db),
):
    """Admin-only: activate or deactivate an account.

    Deactivating also drops the account's session token, so an existing login
    stops working immediately instead of lingering until it expires. An admin
    cannot deactivate their own account - that would lock the last operator out.
    """
    target = db.query(models.Teacher).filter(models.Teacher.id == teacher_id).first()
    if not target:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND, detail="Teacher not found"
        )

    if target.id == admin.id and not payload.is_active:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="You cannot deactivate your own account",
        )

    target.is_active = payload.is_active
    if not payload.is_active:
        target.token = None
        target.token_expires_at = None

    db.commit()
    db.refresh(target)
    return target


# ==================================================================
# Lecture-wise attendance
# ============================================================
@app.get("/teacher/classes", response_model=list[AttendanceClassStudentOut])
def list_class_students(
    division: str = "D",
    batch: str = "",
    teacher: models.Teacher = Depends(require_teacher_or_admin),
    db: Session = Depends(get_db),
):
    """Approved students of one class group (division, optional batch)."""
    normalised = _normalise_batch(batch)

    query = db.query(models.Student).filter(
        models.Student.division == division,
        models.Student.status == "approved",
    )
    if normalised:
        query = query.filter(
            or_(
                models.Student.batch == normalised,
                models.Student.batch == normalised.replace("-", ""),
            )
        )

    return query.order_by(models.Student.roll_number).all()


def _attendance_row_identity(
    db: Session,
    row: models.AttendanceRecord,
    *,
    division: str,
    batch: str = "",
) -> tuple[str, str, str]:
    """(roll number, name, normalised batch) for one stored attendance row.

    A row is linked to an account once the student registers; until then the
    class roster (and the official registry behind it) supplies the name. Shared
    by the correction sheet and the session detail view, so both read the same
    person the same way.
    """
    student = row.student
    if student is not None:
        return (
            (student.roll_number or "").strip(),
            student.name,
            _normalise_batch(student.batch),
        )

    # Marked from the class roster: this student has not registered yet.
    roster = _roster_entry(
        db, division=division, roll_number=row.roll_number, batch=batch
    )
    return (
        (row.roll_number or "").strip(),
        roster.name if roster else f"Roll {(row.roll_number or '').strip()}",
        _normalise_batch(roster.batch if roster else row.batch),
    )


@app.get("/teacher/attendance", response_model=list[AttendanceSessionOut])
def get_attendance(
    subject: str,
    division: str = "D",
    batch: str = "",
    session_date: str = "",
    slot_start: str = "",
    slot_end: str = "",
    teacher: models.Teacher = Depends(require_teacher_or_admin),
    db: Session = Depends(get_db),
):
    """Saved attendance for one lecture/session (empty when not marked yet)."""
    _require_attendance_permission(
        db,
        teacher,
        subject=subject,
        division=division,
        batch=batch,
        slot_start=slot_start,
    )

    if not session_date or not slot_start:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="session_date and slot_start are required",
        )

    _parse_date(session_date)

    rows = db.query(models.AttendanceRecord).filter(
        models.AttendanceRecord.subject == subject,
        models.AttendanceRecord.division == division,
        models.AttendanceRecord.session_date == session_date,
        models.AttendanceRecord.slot_start == slot_start,
        models.AttendanceRecord.deleted_at.is_(None),
    ).all()

    batch_filter = _normalise_batch(batch)
    out = []
    for row in rows:
        roll, name, row_batch = _attendance_row_identity(
            db, row, division=division, batch=batch
        )
        student = row.student
        if batch_filter and row_batch and row_batch != batch_filter:
            continue
        out.append(
            AttendanceSessionOut(
                student_id=student.id if student is not None else None,
                name=name,
                roll_number=roll,
                status=row.status,
            )
        )

    return out


@app.post("/teacher/attendance", response_model=AttendanceSaveResponse)
def save_attendance(
    payload: AttendanceSaveRequest,
    background: BackgroundTasks,
    teacher: models.Teacher = Depends(require_teacher_or_admin),
    db: Session = Depends(get_db),
):
    """Save (or correct) one lecture's attendance.

    * the caller must be assigned to teach this class/subject (admins excepted)
    * the period must be a real slot from the official timetable
    * every listed student must belong to the class group and be approved
    * one row per (student, date, period, subject): a second save corrects the
      existing row instead of adding a duplicate, and records who corrected it
    """
    subject = (payload.subject or "").strip()
    if not subject:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST, detail="Subject is required"
        )

    if not payload.records:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="At least one student record is required",
        )

    session_date = payload.session_date.strip()
    day_date = _parse_date(session_date)

    if _slot_pair(payload.slot_start, payload.slot_end) is None:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=(
                "That period is not part of the official timetable "
                f"({payload.slot_start}-{payload.slot_end})"
            ),
        )

    batch = _normalise_batch(payload.batch)

    _require_attendance_permission(
        db,
        teacher,
        subject=subject,
        division=payload.division,
        batch=batch,
        day=_day_name(day_date),
        slot_start=payload.slot_start,
    )

    _require_attendance_window(
        teacher,
        session_date=session_date,
        slot_start=payload.slot_start,
        slot_end=payload.slot_end,
    )

    resolved = _resolve_attendance_marks(db, payload)

    now = datetime.utcnow()
    created = 0
    corrected = 0

    # Only absentees ring - never the whole class - and a correction rings the
    # one student whose mark actually changed. Saving an unchanged sheet again
    # therefore writes no second notification.
    absent_students: list[models.Student] = []
    flipped: list[tuple[models.Student, str]] = []

    for record, roll, student in resolved:
        existing = db.query(models.AttendanceRecord).filter(
            models.AttendanceRecord.roll_number == roll,
            models.AttendanceRecord.subject == subject,
            models.AttendanceRecord.session_date == session_date,
            models.AttendanceRecord.slot_start == payload.slot_start,
        ).first()

        if existing:
            if existing.deleted_at is not None:
                # Re-marking a deleted lecture restores it. The row has to be
                # revived rather than duplicated: the unique key covers
                # (roll, date, slot, subject) and knows nothing about deletion,
                # and "delete the wrong session, take it again" must work.
                existing.deleted_at = None
                existing.deleted_by = None
                existing.status = record.status
                existing.updated_by = teacher.id
                existing.updated_at = now
                if student is not None:
                    existing.student_id = student.id
                    if record.status == "absent":
                        absent_students.append(student)
                created += 1
                continue

            # Keep the account link current: a student who registers after the
            # lecture was marked is attached on the next save of that lecture.
            if student is not None and existing.student_id != student.id:
                existing.student_id = student.id
            if existing.status != record.status:
                existing.status = record.status
                existing.updated_by = teacher.id
                existing.updated_at = now
                corrected += 1
                if student is not None:
                    flipped.append((student, record.status))
            elif existing.updated_at is not None or existing.updated_by is not None:
                # unchanged correction request: leave the audit trail alone
                pass
            continue

        db.add(
            models.AttendanceRecord(
                student_id=student.id if student is not None else None,
                roll_number=roll,
                subject=subject,
                division=payload.division,
                batch=batch,
                session_date=session_date,
                slot_start=payload.slot_start,
                slot_end=payload.slot_end,
                status=record.status,
                marked_by=teacher.id,
                marked_at=now,
            )
        )
        if record.status == "absent" and student is not None:
            absent_students.append(student)
        created += 1

    slot_label = f"{payload.slot_start}-{payload.slot_end}"
    absent_title = "Marked absent"
    absent_message = (
        f"{subject} on {session_date} ({slot_label}): you were marked absent."
    )
    if absent_students:
        _add_student_bells(
            db,
            absent_students,
            absent_title,
            absent_message,
            created_at=now,
        )

    flipped_title = "Attendance updated"
    flipped_messages = [
        (
            student,
            f"{subject} on {session_date} ({slot_label}): you are now marked "
            f"{status}.",
        )
        for student, status in flipped
    ]
    for student, text in flipped_messages:
        _add_student_bells(
            db, [student], flipped_title, text, created_at=now
        )

    try:
        db.commit()
    except IntegrityError:
        db.rollback()
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="Attendance for this lecture was saved by another request",
        )

    if absent_students:
        _schedule_student_push(
            background,
            db,
            [student.id for student in absent_students],
            absent_title,
            absent_message,
            {
                "type": "attendance",
                "subject": subject,
                "date": session_date,
            },
        )

    for student, text in flipped_messages:
        _schedule_student_push(
            background,
            db,
            [student.id],
            flipped_title,
            text,
            {
                "type": "attendance",
                "subject": subject,
                "date": session_date,
            },
        )

    return AttendanceSaveResponse(
        message="Attendance saved",
        subject=subject,
        session_date=session_date,
        slot_start=payload.slot_start,
        created=created,
        corrected=corrected,
    )


def _period_pair(period: str) -> tuple[str, str] | None:
    """Split a printed period label ("10:15-11:15") into the official pair."""
    text = (period or "").strip().replace("\u2013", "-").replace(" ", "")
    if text.count("-") != 1:
        return None
    start, end = text.split("-", 1)
    return _slot_pair(start, end)


def _roll_sort_key(roll_number: str):
    """Numeric roll numbers first (1, 2, 10), then any non-numeric label."""
    text = (roll_number or "").strip()
    if text.isdigit():
        return (0, int(text), "")
    return (1, 0, text)


def _registry_student(roll_number: str, *, division: str) -> dict | None:
    """The official registry row for one roll number in one division.

    `STUDENT_REGISTRY` is the college's master list: it describes every student
    of Division D whether or not they have registered an account, which is why
    the class sheet and the attendance resolver both fall back to it.
    """
    wanted_roll = (roll_number or "").strip()
    wanted_division = (division or "").strip().upper()
    if not wanted_roll:
        return None
    return next(
        (
            entry
            for entry in STUDENT_REGISTRY
            if (entry.get("roll_number") or "").strip() == wanted_roll
            and (entry.get("division") or "").strip().upper() == wanted_division
        ),
        None,
    )


def _roster_entry(
    db: Session, *, division: str, roll_number: str, batch: str = ""
) -> models.ClassRoster | None:
    """The roster row for one roll number in one division, if there is one."""
    rows = (
        db.query(models.ClassRoster)
        .filter(
            models.ClassRoster.division == division,
            models.ClassRoster.roll_number == (roll_number or "").strip(),
        )
        .all()
    )
    if not rows:
        return None
    wanted = _normalise_batch(batch)
    if wanted:
        for row in rows:
            if _normalise_batch(row.batch) == wanted:
                return row
    return rows[0]


def _resolve_attendance_marks(
    db: Session, payload: "AttendanceSaveRequest"
) -> list[tuple["AttendanceMark", str, models.Student | None]]:
    """Resolve a lecture sheet to (mark, roll number, account or None).

    The roll number is the identity that survives registration, so every mark is
    resolved to one before anything is written. A mark is accepted when the roll
    number belongs to an approved account in this division, when it is on the
    class roster, or when it is in the official registry - which is exactly what
    lets a teacher mark a student who has not signed up yet. Anything else is
    refused, so a typo cannot invent a student out of thin air.
    """
    ids = [r.student_id for r in payload.records if r.student_id is not None]
    by_id = {}
    if ids:
        by_id = {
            student.id: student
            for student in db.query(models.Student).filter(models.Student.id.in_(ids))
        }

    rolls = [r.roll_number for r in payload.records if r.roll_number]
    by_roll = {}
    if rolls:
        by_roll = {
            (student.roll_number or "").strip(): student
            for student in db.query(models.Student).filter(
                models.Student.roll_number.in_(rolls)
            )
        }

    resolved: list[tuple[AttendanceMark, str, models.Student | None]] = []
    seen: set[str] = set()
    batch = _normalise_batch(payload.batch)

    for record in payload.records:
        student = None
        roll = record.roll_number

        if record.student_id is not None:
            student = by_id.get(record.student_id)
            if student is None:
                raise HTTPException(
                    status_code=status.HTTP_404_NOT_FOUND,
                    detail=f"Student {record.student_id} not found",
                )
            roll = (student.roll_number or "").strip()
        else:
            student = by_roll.get(roll)

        if not roll:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="Every record needs a roll number",
            )

        if student is not None:
            if student.status != "approved":
                raise HTTPException(
                    status_code=status.HTTP_400_BAD_REQUEST,
                    detail=(
                        f"{student.name} is not an approved student and cannot be marked"
                    ),
                )
            if student.division != payload.division:
                raise HTTPException(
                    status_code=status.HTTP_400_BAD_REQUEST,
                    detail=f"{student.name} is not in division {payload.division}",
                )
            row_batch = _normalise_batch(student.batch)
            label = student.name
        else:
            roster = _roster_entry(
                db, division=payload.division, roll_number=roll, batch=payload.batch
            )
            official = (
                None
                if roster is not None
                else _registry_student(roll, division=payload.division)
            )
            if roster is None and official is None:
                raise HTTPException(
                    status_code=status.HTTP_400_BAD_REQUEST,
                    detail=(
                        f"Roll number {roll} is not on the class roster or in "
                        f"the official registry for division {payload.division}"
                    ),
                )
            if roster is not None:
                row_batch = _normalise_batch(roster.batch)
                label = roster.name
            else:
                row_batch = _normalise_batch(official.get("batch"))
                label = official.get("name") or roll

        if batch and row_batch and row_batch != batch:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail=f"{label} is not in batch {batch}",
            )

        if roll in seen:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="The same student was submitted more than once",
            )
        seen.add(roll)
        resolved.append((record, roll, student))

    return resolved


@app.get("/teacher/attendance/students", response_model=list[AttendanceStudentOut])
def list_attendance_students(
    year: int | None = Query(default=None, ge=1, le=5),
    division: str = "D",
    batch: str = "",
    teacher: models.Teacher = Depends(require_teacher_or_admin),
    db: Session = Depends(get_db),
):
    """The class list for one class group, sorted by roll number ascending.

    The official registry is the class list, so every student of the division is
    listed even before they register (``is_registered`` false, no account id) and
    can be marked. The roster adds students the registry does not describe, and
    an approved account that appears in neither is still added, so nobody who
    registered is ever dropped from the sheet. The response carries no
    credentials and no attendance history; ``year`` is optional so a whole
    division can be listed across years when it is unknown.
    """
    normalised = _normalise_batch(batch)

    roster_query = db.query(models.ClassRoster).filter(
        models.ClassRoster.division == division
    )
    if year is not None:
        roster_query = roster_query.filter(models.ClassRoster.year == year)
    if normalised:
        roster_query = roster_query.filter(
            or_(
                models.ClassRoster.batch == normalised,
                models.ClassRoster.batch == normalised.replace("-", ""),
                models.ClassRoster.batch == "",
            )
        )

    student_query = db.query(models.Student).filter(
        models.Student.division == division,
        models.Student.status == "approved",
    )
    if year is not None:
        student_query = student_query.filter(models.Student.year == year)
    if normalised:
        student_query = student_query.filter(
            or_(
                models.Student.batch == normalised,
                models.Student.batch == normalised.replace("-", ""),
            )
        )

    accounts = {
        (student.roll_number or "").strip(): student
        for student in student_query.all()
    }

    # roll number -> (name, branch, batch). The official registry is the base
    # layer, so the sheet is the whole class even when nobody has registered.
    merged: dict[str, tuple[str, str, str]] = {}
    wanted_division = (division or "").strip().upper()
    for entry in STUDENT_REGISTRY:
        if (entry.get("division") or "").strip().upper() != wanted_division:
            continue
        if year is not None and entry.get("year") != year:
            continue
        entry_batch = _normalise_batch(entry.get("batch"))
        if normalised and entry_batch != normalised:
            continue
        roll = (entry.get("roll_number") or "").strip()
        if roll:
            merged[roll] = (
                entry.get("name") or "",
                entry.get("course") or "",
                entry.get("batch") or "",
            )

    # A roster row is an explicit class-list entry: it may add a roll the
    # registry does not have, and its name is the one the admin chose to keep.
    for entry in roster_query.all():
        roll = (entry.roll_number or "").strip()
        if not roll:
            continue
        official = merged.get(roll)
        merged[roll] = (
            entry.name,
            official[1] if official else "",
            entry.batch or (official[2] if official else ""),
        )

    for roll, student in accounts.items():
        merged.setdefault(
            roll, (student.name, student.branch or "", student.batch or "")
        )

    out: list[AttendanceStudentOut] = []
    for roll in sorted(merged, key=_roll_sort_key):
        class_name, class_branch, class_batch = merged[roll]
        student = accounts.get(roll)
        out.append(
            AttendanceStudentOut(
                id=student.id if student is not None else None,
                roll_number=roll,
                name=student.name if student is not None else class_name,
                branch=(
                    (student.branch or None)
                    if student is not None
                    else (class_branch or None)
                ),
                batch=(student.batch or "") if student is not None else class_batch,
                is_registered=student is not None,
            )
        )
    return out


@app.post("/teacher/attendance/submit", response_model=AttendanceSubmitResponse)
def submit_attendance(
    payload: AttendanceSubmitRequest,
    background: BackgroundTasks,
    teacher: models.Teacher = Depends(require_teacher_or_admin),
    db: Session = Depends(get_db),
):
    """Save one lecture's whole sheet, addressed by date and printed period.

    The period is resolved against the official timetable before anything is
    written, then the request is handed to the same save path the app already
    uses, so permission checks, duplicate prevention and the correction audit
    trail are identical for both shapes of request.
    """
    pair = _period_pair(payload.period)
    if pair is None:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=(
                "That period is not part of the official timetable "
                f"({payload.period})"
            ),
        )
    slot_start, slot_end = pair

    saved = save_attendance(
        AttendanceSaveRequest(
            subject=payload.subject,
            division=payload.division,
            batch=payload.batch,
            session_date=payload.class_date,
            slot_start=slot_start,
            slot_end=slot_end,
            records=payload.records,
        ),
        background,
        teacher,
        db,
    )

    present = sum(1 for record in payload.records if record.status == "present")
    return AttendanceSubmitResponse(
        message="Attendance saved",
        subject=saved.subject,
        class_date=saved.session_date,
        period=f"{slot_start}-{slot_end}",
        total=len(payload.records),
        present=present,
        absent=len(payload.records) - present,
        created=saved.created,
        corrected=saved.corrected,
    )


@app.get(
    "/teacher/attendance/history",
    response_model=list[AttendanceHistorySessionOut],
)
def attendance_history(
    subject: str = "",
    division: str = "",
    limit: int = Query(default=50, ge=1, le=200),
    teacher: models.Teacher = Depends(require_teacher_or_admin),
    db: Session = Depends(get_db),
):
    """Saved lectures, newest first, grouped by date + period + subject.

    A teacher sees the lectures they marked (or last corrected); an admin sees
    every saved lecture. Tallies come from the stored rows, never from a
    client-side count. Soft-deleted sessions are omitted entirely, and each
    session says whether *this* caller may delete it, so no client has to guess
    at the lecture clock.
    """
    query = db.query(models.AttendanceRecord).filter(
        models.AttendanceRecord.deleted_at.is_(None)
    )
    if subject:
        query = query.filter(models.AttendanceRecord.subject == subject)
    if division:
        query = query.filter(models.AttendanceRecord.division == division)
    rows = query.all()

    def session_key(row) -> tuple:
        return (
            row.session_date,
            row.slot_start,
            row.slot_end,
            row.subject,
            row.division,
            row.batch or "",
        )

    deletable: set[tuple] | None = None
    if teacher.role != "admin":
        # A teacher sees each lecture they took part in, as a lecture - not just
        # the rows they personally wrote. Correcting one student must not make
        # the other students of the same session disappear from the tally.
        live = db.query(models.AttendanceRecord).filter(
            models.AttendanceRecord.deleted_at.is_(None)
        )
        mine = {
            session_key(row)
            for row in live.filter(
                or_(
                    models.AttendanceRecord.marked_by == teacher.id,
                    models.AttendanceRecord.updated_by == teacher.id,
                )
            ).all()
        }
        rows = [row for row in rows if session_key(row) in mine]

        # Deletion is narrower than visibility: only the teacher who wrote the
        # marks owns the session, and only while its lecture window is open. A
        # correction alone is not ownership. The endpoint enforces the same
        # rule; this flag only keeps the button off a session that would 403.
        deletable = {
            session_key(row)
            for row in live.filter(
                models.AttendanceRecord.marked_by == teacher.id
            ).all()
        }

    # (date, slot_start, slot_end, subject, division, batch) -> tallies
    sessions: dict[tuple, dict[str, int]] = {}
    for row in rows:
        key = session_key(row)
        bucket = sessions.setdefault(key, {"total": 0, "present": 0})
        bucket["total"] += 1
        if row.status == "present":
            bucket["present"] += 1

    keys = sorted(sessions, key=lambda k: (k[0], k[1]), reverse=True)[:limit]

    return [
        AttendanceHistorySessionOut(
            class_date=key[0],
            period=f"{key[1]}-{key[2]}",
            subject=key[3],
            division=key[4],
            batch=key[5],
            total=sessions[key]["total"],
            present=sessions[key]["present"],
            absent=sessions[key]["total"] - sessions[key]["present"],
            can_delete=(
                True
                if deletable is None
                else (
                    key in deletable
                    and _attendance_window_open(key[0], key[1], key[2])
                )
            ),
        )
        for key in keys
    ]


def _session_rows(
    db: Session,
    *,
    subject: str,
    division: str,
    batch: str,
    class_date: str,
    slot_start: str,
    slot_end: str,
) -> list[models.AttendanceRecord]:
    """The live rows of one saved session, identified exactly as it was written.

    One definition shared by the delete endpoint and the detail view, so the
    session a teacher expands is always the session the server would delete.
    Soft-deleted rows are never part of it.
    """
    return (
        db.query(models.AttendanceRecord)
        .filter(
            models.AttendanceRecord.subject == subject,
            models.AttendanceRecord.division == division,
            models.AttendanceRecord.batch == batch,
            models.AttendanceRecord.session_date == class_date,
            models.AttendanceRecord.slot_start == slot_start,
            models.AttendanceRecord.slot_end == slot_end,
            models.AttendanceRecord.deleted_at.is_(None),
        )
        .all()
    )


@app.delete(
    "/teacher/attendance/session",
    response_model=AttendanceDeleteResponse,
)
def delete_attendance_session(
    payload: AttendanceDeleteRequest,
    teacher: models.Teacher = Depends(require_teacher_or_admin),
    db: Session = Depends(get_db),
):
    """Soft-delete one saved lecture for the whole class group.

    Nothing is destroyed: ``deleted_at``/``deleted_by`` record the deletion on
    every row, so the audit trail survives and every read path (student
    dashboard, teacher history, the correction sheet) simply hides them. Marking
    the same lecture again revives those rows (see ``save_attendance``).

    An administrator may delete any session at any time - that is the recovery
    path once the lecture window has closed. A teacher may delete only a session
    they themselves marked, and only while that lecture's window is still open,
    which keeps a marking mistake fixable without letting history be rewritten
    later.
    """
    subject = (payload.subject or "").strip()
    if not subject:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST, detail="Subject is required"
        )

    pair = _period_pair(payload.period)
    if pair is None:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=(
                "That period is not part of the official timetable "
                f"({payload.period})"
            ),
        )
    slot_start, slot_end = pair

    session_date = (payload.class_date or "").strip()
    day_date = _parse_date(session_date)
    division = payload.division
    batch = _normalise_batch(payload.batch)

    rows = _session_rows(
        db,
        subject=subject,
        division=division,
        batch=batch,
        class_date=session_date,
        slot_start=slot_start,
        slot_end=slot_end,
    )

    if not rows:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="No attendance session found for that lecture.",
        )

    if teacher.role != "admin":
        if not any(row.marked_by == teacher.id for row in rows):
            raise HTTPException(
                status_code=status.HTTP_403_FORBIDDEN,
                detail="You can only delete a session you marked.",
            )
        if not _attendance_window_open(session_date, slot_start, slot_end):
            raise HTTPException(
                status_code=status.HTTP_403_FORBIDDEN,
                detail=(
                    "This session can no longer be deleted by a teacher: the "
                    f"lecture's window on {day_date.isoformat()} has closed "
                    f"({COLLEGE_TIMEZONE_LABEL}). An administrator can still "
                    "delete it."
                ),
            )

    now = datetime.utcnow()
    for row in rows:
        row.deleted_at = now
        row.deleted_by = teacher.id

    db.commit()

    return AttendanceDeleteResponse(
        message="Attendance session deleted",
        deleted_count=len(rows),
        class_date=session_date,
        period=f"{slot_start}-{slot_end}",
        subject=subject,
        division=division,
        batch=batch,
    )


@app.get(
    "/teacher/attendance/session",
    response_model=AttendanceSessionDetailOut,
)
def get_attendance_session(
    class_date: str,
    period: str,
    subject: str,
    division: str = "D",
    batch: str = "",
    teacher: models.Teacher = Depends(require_teacher_or_admin),
    db: Session = Depends(get_db),
):
    """One saved lecture, split into its present and absent lists.

    This is what the expandable Past sessions card reads. A teacher may open a
    session they took part in - the same rule that puts it in their history - and
    an administrator may open any. The two flags say what *this* caller may do,
    judged on the server: ``can_edit`` from the session's 24-hour correction
    window, ``can_delete`` from the printed lecture's own window. They are
    separate on purpose: correcting one mark is not deleting a lecture.
    """
    subject = (subject or "").strip()
    if not subject:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST, detail="Subject is required"
        )

    slot_pair = _period_pair(period)
    if slot_pair is None:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=(
                "That period is not part of the official timetable "
                f"({period})"
            ),
        )
    slot_start, slot_end = slot_pair

    session_date = (class_date or "").strip()
    _parse_date(session_date)
    batch = _normalise_batch(batch)

    rows = _session_rows(
        db,
        subject=subject,
        division=division,
        batch=batch,
        class_date=session_date,
        slot_start=slot_start,
        slot_end=slot_end,
    )
    if not rows:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="No attendance session found for that lecture.",
        )

    marked_by_me = any(row.marked_by == teacher.id for row in rows)
    if teacher.role != "admin" and not (
        marked_by_me or any(row.updated_by == teacher.id for row in rows)
    ):
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="You can only open a session you took part in.",
        )

    records: list[tuple[models.AttendanceRecord, AttendanceRecordOut]] = []
    for row in rows:
        roll, name, _ = _attendance_row_identity(
            db, row, division=division, batch=batch
        )
        records.append(
            (
                row,
                AttendanceRecordOut(
                    record_id=row.id,
                    roll_number=roll,
                    name=name,
                    status=row.status,
                    marked_at=(
                        row.marked_at.isoformat() if row.marked_at is not None else None
                    ),
                    updated_at=(
                        row.updated_at.isoformat()
                        if row.updated_at is not None
                        else None
                    ),
                ),
            )
        )

    # Roll order, so the two lists read like the class sheet.
    records.sort(key=lambda item: _roll_sort_key(item[1].roll_number))
    marks = [row.marked_at for row in rows if row.marked_at is not None]

    return AttendanceSessionDetailOut(
        session=AttendanceSessionInfoOut(
            class_date=session_date,
            period=f"{slot_start}-{slot_end}",
            subject=subject,
            division=division,
            batch=batch,
            marked_at=min(marks).isoformat() if marks else None,
            can_edit=(
                True
                if teacher.role == "admin"
                else marked_by_me and _within_edit_window(rows)
            ),
            can_delete=(
                True
                if teacher.role == "admin"
                else marked_by_me
                and _attendance_window_open(session_date, slot_start, slot_end)
            ),
        ),
        present=[record for _, record in records if record.status == "present"],
        absent=[record for _, record in records if record.status == "absent"],
    )


@app.patch(
    "/teacher/attendance/record/{record_id}",
    response_model=AttendanceRecordOut,
)
def update_attendance_record(
    record_id: int,
    payload: AttendanceRecordUpdate,
    background: BackgroundTasks,
    teacher: models.Teacher = Depends(require_teacher_or_admin),
    db: Session = Depends(get_db),
):
    """Flip one student's mark inside a saved session.

    This corrects a single row, not the lecture, so it does NOT use the
    timetable lock: it can only ever happen after the lecture anyway. It is
    limited by ATTENDANCE_EDIT_WINDOW (24 hours from the session's marks) and to
    a teacher who marked that session; an administrator may always correct one.

    ``updated_at``/``updated_by`` move on every flip, while ``marked_by`` and
    ``marked_at`` keep saying who took the lecture and when.
    """
    row = (
        db.query(models.AttendanceRecord)
        .filter(
            models.AttendanceRecord.id == record_id,
            models.AttendanceRecord.deleted_at.is_(None),
        )
        .first()
    )
    if row is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Attendance record not found.",
        )

    session_rows = _session_rows(
        db,
        subject=row.subject,
        division=row.division,
        batch=row.batch,
        class_date=row.session_date,
        slot_start=row.slot_start,
        slot_end=row.slot_end,
    )

    if teacher.role != "admin":
        if not any(other.marked_by == teacher.id for other in session_rows):
            raise HTTPException(
                status_code=status.HTTP_403_FORBIDDEN,
                detail="You can only edit a session you marked.",
            )
        if not _within_edit_window(session_rows):
            raise HTTPException(
                status_code=status.HTTP_403_FORBIDDEN,
                detail=(
                    "You can only edit attendance within 24 hours of "
                    "submission. An administrator can still correct it."
                ),
            )

    student = row.student
    if row.status != payload.status:
        row.status = payload.status
        row.updated_at = datetime.utcnow()
        row.updated_by = teacher.id

        # The student whose mark actually changed hears about it: one durable
        # bell row commits with the correction, and the tray alert follows the
        # response. A no-op tap (same status) writes nothing, so re-opening a
        # session and saving it again cannot spam the class.
        if student is not None:
            notice_title = "Attendance updated"
            notice_message = (
                f"{row.subject} on {row.session_date} "
                f"({row.slot_start}-{row.slot_end}): you are now marked "
                f"{row.status}."
            )
            _add_student_bells(
                db,
                [student],
                notice_title,
                notice_message,
                created_at=row.updated_at,
            )

        db.commit()

        if student is not None:
            _schedule_student_push(
                background,
                db,
                [student.id],
                notice_title,
                notice_message,
                {
                    "type": "attendance",
                    "subject": row.subject,
                    "date": row.session_date,
                },
            )

    roll, name, _ = _attendance_row_identity(
        db, row, division=row.division, batch=row.batch
    )
    return AttendanceRecordOut(
        record_id=row.id,
        roll_number=roll,
        name=name,
        status=row.status,
        marked_at=row.marked_at.isoformat() if row.marked_at is not None else None,
        updated_at=row.updated_at.isoformat() if row.updated_at is not None else None,
    )


@app.get("/student/schedule-changes", response_model=ScheduleChangesResponse)
def student_schedule_changes(
    student: models.Student = Depends(get_current_student),
    db: Session = Depends(get_db),
):
    """Today's claimed free periods that change this student's timetable.

    A claim is included when it is for today, in the student's division, and is
    either division-wide (``batch`` empty) or for the student's own batch. A
    claim for another batch is somebody else's practical and must not appear;
    past days are history, not a schedule change, so they are excluded too.

    The identity is the session's, never a query parameter: a student can only
    ever read their own class group's changes.
    """
    today = _college_today().isoformat()
    batch = _normalise_batch(student.batch)

    batch_filters = [
        models.FreePeriodClaim.batch == "",
        models.FreePeriodClaim.batch.is_(None),
    ]
    # The normalised and the raw stored spelling both count: the registry uses
    # "D-3" while an older row may carry "D3".
    for value in {batch, (student.batch or "").strip()} - {""}:
        batch_filters.append(models.FreePeriodClaim.batch == value)

    claims = (
        db.query(models.FreePeriodClaim)
        .options(joinedload(models.FreePeriodClaim.teacher))
        .filter(
            models.FreePeriodClaim.claim_date == today,
            models.FreePeriodClaim.division == (student.division or "").strip(),
            or_(*batch_filters),
        )
        .order_by(models.FreePeriodClaim.start_time)
        .all()
    )

    changes = [
        ScheduleChangeOut(
            id=claim.id,
            day=claim.day,
            time=f"{claim.start_time} - {claim.end_time}",
            subject=claim.subject,
            division=claim.division,
            batch=claim.batch or "",
            claimed_by_name=(
                claim.teacher.name if claim.teacher is not None else "A teacher"
            ),
            is_today=True,
        )
        for claim in claims
    ]

    count = len(changes)
    if count == 0:
        message = "No schedule changes today."
    elif count == 1:
        message = f"1 free period claimed: {changes[0].time}"
    else:
        message = f"{count} free periods claimed today."

    return ScheduleChangesResponse(
        date=today,
        count=count,
        changes=changes,
        message=message,
    )


@app.get("/student/attendance", response_model=StudentAttendanceOut)
def my_attendance(
    student: models.Student = Depends(get_current_student),
    db: Session = Depends(get_db),
):
    """The signed-in student's own attendance, broken down by subject.

    Only the caller's rows are read - the identity comes from the session, never
    from a query parameter - and only subjects with at least one recorded
    lecture are listed. Lectures are newest first; subjects are alphabetical.

    Rows are matched on the roll number, so lectures marked from the class
    roster before this account existed are already part of the history. The
    account id is also matched, which keeps any row written by an older client
    that only knew the id from disappearing.
    """
    roll_number = (student.roll_number or "").strip()
    rows = (
        db.query(models.AttendanceRecord)
        .filter(
            or_(
                models.AttendanceRecord.roll_number == roll_number,
                models.AttendanceRecord.student_id == student.id,
            ),
            models.AttendanceRecord.deleted_at.is_(None),
        )
        .all()
    )

    by_subject: dict[str, list[models.AttendanceRecord]] = {}
    for row in rows:
        by_subject.setdefault(row.subject, []).append(row)

    subjects_out: list[SubjectAttendanceSummary] = []
    total = 0
    attended = 0

    for subject in sorted(by_subject, key=lambda name: name.lower()):
        lectures = sorted(
            by_subject[subject],
            key=lambda row: (row.session_date, row.slot_start),
            reverse=True,
        )
        subject_total = len(lectures)
        subject_attended = sum(1 for row in lectures if row.status == "present")

        total += subject_total
        attended += subject_attended

        subjects_out.append(
            SubjectAttendanceSummary(
                subject=subject,
                total_classes=subject_total,
                attended=subject_attended,
                percentage=round(subject_attended * 100 / subject_total, 1),
                lectures=[
                    AttendanceLectureOut(
                        date=row.session_date,
                        period=f"{row.slot_start}-{row.slot_end}",
                        status=row.status,
                    )
                    for row in lectures
                ],
            )
        )

    return StudentAttendanceOut(
        overall_percentage=round(attended * 100 / total, 1) if total else 0.0,
        total_classes=total,
        attended=attended,
        subjects=subjects_out,
    )


# ==================================================================
# Class roster (admin)
# ============================================================
def _registered_by_roll(
    db: Session, *, year: int, division: str
) -> dict[str, models.Student]:
    """Registered accounts of one class group, keyed by roll number."""
    return {
        (student.roll_number or "").strip(): student
        for student in db.query(models.Student)
        .filter(
            models.Student.year == year,
            models.Student.division == division,
            models.Student.status == "approved",
        )
        .all()
    }


def _roster_out(
    entry: models.ClassRoster, accounts: dict[str, models.Student]
) -> RosterEntryOut:
    student = accounts.get((entry.roll_number or "").strip())
    return RosterEntryOut(
        id=entry.id,
        roll_number=entry.roll_number,
        name=entry.name,
        year=entry.year,
        division=entry.division,
        batch=entry.batch or "",
        registered_student_id=student.id if student is not None else None,
        registered_as=student.name if student is not None else None,
    )


def _upsert_roster_entry(
    db: Session, entry: RosterEntryIn
) -> tuple[models.ClassRoster, bool]:
    """Insert or update one roster row. Returns (row, created)."""
    row = (
        db.query(models.ClassRoster)
        .filter(
            models.ClassRoster.year == entry.year,
            models.ClassRoster.division == entry.division,
            models.ClassRoster.roll_number == entry.roll_number,
        )
        .first()
    )
    now = datetime.utcnow()

    if row is None:
        row = models.ClassRoster(
            roll_number=entry.roll_number,
            name=entry.name,
            year=entry.year,
            division=entry.division,
            batch=entry.batch,
            created_at=now,
        )
        db.add(row)
        return row, True

    row.name = entry.name
    row.batch = entry.batch
    row.updated_at = now
    return row, False


@app.get("/admin/roster", response_model=list[RosterEntryOut])
def list_roster(
    year: int | None = Query(default=None, ge=1, le=5),
    division: str = "",
    batch: str = "",
    admin: models.Teacher = Depends(require_admin),
    db: Session = Depends(get_db),
):
    """The class roster, sorted by class group then roll number.

    ``registered_student_id`` says which entries already have an account, so an
    admin can see at a glance who is still missing.
    """
    query = db.query(models.ClassRoster)
    if year is not None:
        query = query.filter(models.ClassRoster.year == year)
    if division:
        query = query.filter(
            models.ClassRoster.division == division.strip().upper()
        )
    normalised = _normalise_batch(batch)
    if normalised:
        query = query.filter(
            or_(
                models.ClassRoster.batch == normalised,
                models.ClassRoster.batch == "",
            )
        )

    entries = sorted(
        query.all(),
        key=lambda entry: (
            entry.year,
            entry.division,
            _roll_sort_key(entry.roll_number),
        ),
    )

    cache: dict[tuple[int, str], dict[str, models.Student]] = {}
    out: list[RosterEntryOut] = []
    for entry in entries:
        key = (entry.year, entry.division)
        if key not in cache:
            cache[key] = _registered_by_roll(
                db, year=entry.year, division=entry.division
            )
        out.append(_roster_out(entry, cache[key]))
    return out


@app.post("/admin/roster/add", response_model=RosterEntryOut)
def add_roster_entry(
    payload: RosterEntryIn,
    admin: models.Teacher = Depends(require_admin),
    db: Session = Depends(get_db),
):
    """Add one student to the class roster, or update the row already there."""
    row, _created = _upsert_roster_entry(db, payload)
    try:
        db.commit()
    except IntegrityError:
        db.rollback()
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="That roll number is already on this class roster",
        )
    db.refresh(row)
    return _roster_out(
        row, _registered_by_roll(db, year=row.year, division=row.division)
    )


@app.post("/admin/roster/upload", response_model=RosterImportResult)
async def upload_roster(
    file: UploadFile = File(...),
    year: int = Form(1),
    division: str = Form("D"),
    batch: str = Form(""),
    admin: models.Teacher = Depends(require_admin),
    db: Session = Depends(get_db),
):
    """Import a class roster from a CSV file.

    Format: ``roll_number,name[,batch]`` per line, an optional header row, UTF-8.
    Rows are upserted on (year, division, roll_number), so re-uploading a
    corrected list updates names instead of duplicating students. A row that
    does not parse is reported in ``errors`` and skipped - the rest still land.
    """
    raw = await file.read()
    if not raw:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST, detail="The file is empty"
        )
    if len(raw) > 512 * 1024:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="That file is larger than 512 KB",
        )
    try:
        text = raw.decode("utf-8-sig")
    except UnicodeDecodeError:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="The CSV must be UTF-8 text",
        )

    rows = [row for row in csv.reader(io.StringIO(text)) if any(c.strip() for c in row)]
    if not rows:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST, detail="The file has no rows"
        )

    first = [cell.strip().lower() for cell in rows[0]]
    has_header = bool(first) and first[0] in {
        "roll",
        "roll no",
        "rollno",
        "roll number",
        "roll_number",
        "rollnumber",
    }
    data_rows = rows[1:] if has_header else rows

    added = 0
    updated = 0
    skipped = 0
    errors: list[str] = []

    for offset, row in enumerate(data_rows, start=2 if has_header else 1):
        cells = [cell.strip() for cell in row]
        if len(cells) < 2 or not cells[0] or not cells[1]:
            skipped += 1
            errors.append(f"Line {offset}: expected roll_number,name")
            continue

        row_batch = cells[2] if len(cells) > 2 and cells[2] else batch
        try:
            entry = RosterEntryIn(
                roll_number=cells[0],
                name=cells[1],
                year=year,
                division=division,
                batch=row_batch,
            )
        except ValidationError as exc:
            skipped += 1
            first_error = exc.errors()[0]
            errors.append(
                f"Line {offset}: {first_error.get('msg', 'invalid row')}"
            )
            continue

        _row, created = _upsert_roster_entry(db, entry)
        if created:
            added += 1
        else:
            updated += 1

    try:
        db.commit()
    except IntegrityError:
        db.rollback()
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="The roster changed while the file was being imported",
        )

    return RosterImportResult(
        message="Roster imported",
        added=added,
        updated=updated,
        skipped=skipped,
        errors=errors[:20],
    )


@app.delete("/admin/roster/{entry_id}")
def delete_roster_entry(
    entry_id: int,
    admin: models.Teacher = Depends(require_admin),
    db: Session = Depends(get_db),
):
    """Remove one student from the class roster.

    Attendance already marked for that roll number is kept: the lecture did
    happen, and the record stays attributable to the roll number.
    """
    row = (
        db.query(models.ClassRoster)
        .filter(models.ClassRoster.id == entry_id)
        .first()
    )
    if row is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="That roster entry no longer exists",
        )
    db.delete(row)
    db.commit()
    return {"message": f"Roll {row.roll_number} removed from the roster"}


# ==================================================================
# Claim free period
# ============================================================
def _teacher_timetable_links(
    db: Session, teacher: models.Teacher
) -> list[models.TimetableEntry]:
    """Timetable entries the teacher's short code is actually printed against."""
    code = (teacher.short_code or "").strip().upper()
    if not code:
        return []

    return [
        entry
        for entry in db.query(models.TimetableEntry).all()
        if code in _faculty_tokens(entry.faculty)
    ]


def _other_teacher_covering(
    db: Session,
    *,
    day: str,
    division: str,
    batch: str,
    start_time: str,
    end_time: str,
    exclude_teacher_id: int,
) -> models.TeacherAssignment | None:
    """Another teacher's verified assignment covering this exact period.

    A period is never offered as "free" when a colleague is verified to teach it,
    even if the printed grid has no class in that cell (an admin can add a manual
    assignment the sheet does not show). A row counts when it is for the same
    division and the same class group (or the whole division) and either applies
    to every day/period or to this exact day/period.
    """
    requested_batch = _normalise_batch(batch)

    rows = (
        db.query(models.TeacherAssignment)
        .filter(
            models.TeacherAssignment.teacher_id != exclude_teacher_id,
            models.TeacherAssignment.division == division,
        )
        .all()
    )

    for row in rows:
        if row.day.strip() and row.day.strip().lower() != (day or "").strip().lower():
            continue
        if row.start_time and row.start_time != start_time:
            continue
        if row.end_time and row.end_time != end_time:
            continue

        row_batch = _normalise_batch(row.batch)
        if row_batch and row_batch != requested_batch:
            continue

        return row

    return None


def _free_period_availability(
    db: Session, teacher: models.Teacher, day_date
) -> FreePeriodAvailabilityOut:
    day = _day_name(day_date)
    claim_date = day_date.strftime("%Y-%m-%d")
    code = (teacher.short_code or "").strip().upper()

    # Who may claim: any authenticated, ACTIVE teacher account - i.e. one created
    # through the admin workflow (there is no public teacher sign-up). No extra
    # per-teacher free-period permission is required, and a faculty short code is
    # not needed for the sheet's free periods. The auth dependency has already
    # rejected missing/expired tokens and deactivated accounts, so this mirrors
    # exactly what the API enforces.
    can_claim = bool(teacher.is_active) and teacher.role in {"teacher", "admin"}

    links = _teacher_timetable_links(db, teacher)
    manual = (
        db.query(models.TeacherAssignment)
        .filter(models.TeacherAssignment.teacher_id == teacher.id)
        .count()
    )

    claims = (
        db.query(models.FreePeriodClaim)
        .filter(models.FreePeriodClaim.claim_date == claim_date)
        .all()
    )
    my_claims = [claim for claim in claims if claim.teacher_id == teacher.id]

    has_verified = bool(links) or manual > 0

    # ``message`` explains a limitation; it is None when there is nothing to
    # explain. Not being linked to a faculty code no longer blocks claiming a free
    # period - it only means the teacher's own classes cannot be named.
    message = None
    if not can_claim:
        message = (
            "This account cannot claim free periods. Ask an administrator to "
            "reactivate it."
        )
    elif not has_verified:
        if not code:
            message = (
                "Your account is not linked to a faculty code from the official "
                "timetable, so Stryve cannot show which classes are yours. "
                "The department's free periods below can still be claimed - ask "
                "an administrator to set your faculty short code to see your own "
                "classes."
            )
        else:
            message = (
                f"Your faculty code {code} does not appear on the official "
                "Division D timetable. The department's free periods below can "
                "still be claimed - ask an administrator to verify your timetable "
                "link to see your own classes."
            )

    if day in {"Sunday"}:
        return FreePeriodAvailabilityOut(
            date=claim_date,
            day=day,
            teacher_short_code=code or None,
            can_claim_free_periods=can_claim,
            has_verified_assignments=has_verified,
            message=message or "No timetable periods are scheduled on Sunday.",
            slots=[],
            claims=[FreePeriodClaimOut.model_validate(claim) for claim in my_claims],
        )

    # The classes scheduled that day. A free period ("RELM") is excluded here
    # on purpose: no class group is busy in it, which is what makes it free, and
    # it is reported separately (``is_free_period``) rather than as a class.
    entries = [
        entry
        for entry in db.query(models.TimetableEntry).filter(
            models.TimetableEntry.day == day,
            models.TimetableEntry.is_break == False,  # noqa: E712
            models.TimetableEntry.is_free_period == False,  # noqa: E712
        )
    ]

    groups = [("", "Whole division")] + [
        (batch, batch) for batch in official_data.BATCHES
    ]

    slots: list[FreePeriodSlotOut] = []

    for start_time, end_time in official_data.TIME_SLOTS:
        # Overlap, not equality: a practical that runs across both periods of a
        # slot (or starts at 15:35) still occupies it, so the period is reported
        # as busy instead of looking free to another teacher.
        in_slot = [
            entry
            for entry in entries
            if entry.start_time < end_time and entry.end_time > start_time
        ]

        # The sheet's own free-period table decides whether this period is a
        # claimable free period (it is the same table the student timetable
        # filters on, so the two can never disagree).
        official_free_period = official_data.is_free_period_slot(
            day, start_time, end_time
        )

        teaching = [entry for entry in in_slot if code and code in _faculty_tokens(entry.faculty)]

        if official_free_period:
            # ONE division-wide slot per free period: a RELM free period belongs
            # to the whole of Division D, so D-1/D-2/D-3 are not separate choices
            # for it and one claim reserves the entire slot.
            other_teacher = _other_teacher_covering(
                db,
                day=day,
                division=official_data.DIVISION,
                batch="",
                start_time=start_time,
                end_time=end_time,
                exclude_teacher_id=teacher.id,
            )
            # Any claim on this date and period counts, whatever batch it was
            # stored with: the slot is the whole division.
            mine = next(
                (claim for claim in my_claims if claim.start_time == start_time),
                None,
            )
            taken = next(
                (claim for claim in claims if claim.start_time == start_time), None
            )

            if in_slot:
                reason = "Class scheduled: " + ", ".join(
                    sorted(
                        f"{entry.subject} "
                        f"({_normalise_batch(entry.batch) or 'whole division'})"
                        for entry in in_slot
                    )
                )
            elif not can_claim:
                reason = message
            elif mine is not None:
                reason = "You already claimed this period"
            elif taken is not None:
                reason = "Another teacher already claimed this free period"
            elif other_teacher is not None:
                reason = (
                    "Another teacher is assigned to this period "
                    f"({other_teacher.subject})"
                )
            else:
                reason = None

            slots.append(
                FreePeriodSlotOut(
                    day=day,
                    start_time=start_time,
                    end_time=end_time,
                    division=official_data.DIVISION,
                    batch="",
                    eligible=reason is None,
                    reason=reason,
                    claimed=mine is not None,
                    is_free_period=True,
                )
            )
            continue

        for batch, _label in groups:
            if teaching:
                what = teaching[0]
                slots.append(
                    FreePeriodSlotOut(
                        day=day,
                        start_time=start_time,
                        end_time=end_time,
                        division=official_data.DIVISION,
                        batch=batch,
                        subject=what.subject,
                        eligible=False,
                        reason=(
                            f"You teach {what.subject} "
                            f"({_normalise_batch(what.batch) or 'whole division'}) "
                            "in this period"
                        ),
                    )
                )
                continue

            if batch:
                busy = [
                    entry
                    for entry in in_slot
                    if entry.batch is None
                    or _normalise_batch(entry.batch) == batch
                ]
            else:
                # "whole division" is only free when nothing at all is scheduled
                busy = in_slot

            conflict = next((claim for claim in claims if claim.batch == batch), None)
            mine = next(
                (claim for claim in my_claims if claim.batch == batch), None
            )

            # A period another teacher is verified to teach is never free for
            # this teacher, even when no class is printed in it (a manual
            # assignment can exist for a period the grid does not fill in).
            other_teacher = _other_teacher_covering(
                db,
                day=day,
                division=official_data.DIVISION,
                batch=batch,
                start_time=start_time,
                end_time=end_time,
                exclude_teacher_id=teacher.id,
            )

            if busy:
                subject = busy[0].subject
                detail = ", ".join(
                    sorted(
                        {
                            f"{entry.subject} "
                            f"({_normalise_batch(entry.batch) or 'whole division'})"
                            for entry in busy
                        }
                    )
                )
                slots.append(
                    FreePeriodSlotOut(
                        day=day,
                        start_time=start_time,
                        end_time=end_time,
                        division=official_data.DIVISION,
                        batch=batch,
                        subject=subject,
                        eligible=False,
                        reason=f"Class scheduled: {detail}",
                        is_free_period=official_free_period,
                    )
                )
                continue

            if other_teacher is not None:
                slots.append(
                    FreePeriodSlotOut(
                        day=day,
                        start_time=start_time,
                        end_time=end_time,
                        division=official_data.DIVISION,
                        batch=batch,
                        eligible=False,
                        reason=(
                            "Another teacher is assigned to this period "
                            f"({other_teacher.subject})"
                        ),
                        is_free_period=official_free_period,
                    )
                )
                continue

            eligible = has_verified and mine is None and conflict is None

            slots.append(
                FreePeriodSlotOut(
                    day=day,
                    start_time=start_time,
                    end_time=end_time,
                    division=official_data.DIVISION,
                    batch=batch,
                    eligible=eligible,
                    reason=(
                        None
                        if eligible
                        else (
                            message
                            if not has_verified
                            else (
                                "You already claimed this period"
                                if mine is not None
                                else "Another teacher already claimed this class group"
                            )
                        )
                    ),
                    claimed=mine is not None,
                    is_free_period=official_free_period,
                )
            )

    return FreePeriodAvailabilityOut(
        date=claim_date,
        day=day,
        teacher_short_code=code or None,
        can_claim_free_periods=can_claim,
        has_verified_assignments=has_verified,
        message=message,
        slots=slots,
        claims=[FreePeriodClaimOut.model_validate(claim) for claim in my_claims],
    )


@app.get("/teacher/free-periods", response_model=FreePeriodAvailabilityOut)
def get_free_periods(
    date: str = "",
    teacher: models.Teacher = Depends(require_teacher_or_admin),
    db: Session = Depends(get_db),
):
    """Periods on that date, marked free / busy / claimed for this teacher.

    Validity comes from the official timetable and existing claims - a period is
    never reported as available without both being checked.
    """
    day_date = _parse_date(date) if date else _college_today()
    return _free_period_availability(db, teacher, day_date)


@app.get("/teacher/free-periods/claims", response_model=list[FreePeriodClaimOut])
def list_my_claims(
    teacher: models.Teacher = Depends(require_teacher_or_admin),
    db: Session = Depends(get_db),
):
    """Every free period this teacher has claimed."""
    return (
        db.query(models.FreePeriodClaim)
        .filter(models.FreePeriodClaim.teacher_id == teacher.id)
        .order_by(
            models.FreePeriodClaim.claim_date, models.FreePeriodClaim.start_time
        )
        .all()
    )


@app.post(
    "/teacher/free-periods/claim",
    response_model=FreePeriodClaimOut,
    status_code=status.HTTP_201_CREATED,
)
def claim_free_period(
    payload: FreePeriodClaimRequest,
    background: BackgroundTasks,
    teacher: models.Teacher = Depends(require_teacher_or_admin),
    db: Session = Depends(get_db),
):
    """Claim one free period after re-validating it server-side."""
    day_date = _parse_date(payload.claim_date)
    day = _day_name(day_date)

    if payload.day.strip() and payload.day.strip() != day:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"{payload.claim_date} is a {day}, not a {payload.day}",
        )

    # A period that has already been and gone can never be claimed. The date is
    # judged on the college clock (IST) - the calendar day the department is
    # working on - not on the UTC day, which lags behind every evening.
    college_today = _college_today()
    if day_date < college_today:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=(
                f"{payload.claim_date} is in the past. A free period can only be "
                f"claimed for today or a later date (today is "
                f"{college_today.isoformat()} on the college clock, "
                f"{COLLEGE_TIMEZONE_LABEL})."
            ),
        )

    if _slot_pair(payload.start_time, payload.end_time) is None:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=(
                "That period is not part of the official timetable "
                f"({payload.start_time}-{payload.end_time})"
            ),
        )

    batch = _normalise_batch(payload.batch)

    # A free period belongs to the whole division: it is never claimed per batch,
    # and claiming it reserves the entire Division D slot.
    if batch and official_data.is_free_period_slot(
        day, payload.start_time, payload.end_time
    ):
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail=(
                "That is a free period for the whole of Division D, so it cannot "
                f"be claimed for {batch} alone. Claim it with an empty batch to "
                "reserve the whole slot."
            ),
        )

    availability = _free_period_availability(db, teacher, day_date)

    if not availability.can_claim_free_periods:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail=availability.message
            or "This account may not claim free periods.",
        )

    slot = next(
        (
            item
            for item in availability.slots
            if item.start_time == payload.start_time
            and item.end_time == payload.end_time
            and item.batch == batch
        ),
        None,
    )

    if slot is None or not slot.eligible:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail=(slot.reason if slot and slot.reason else "That period is not available"),
        )

    row = models.FreePeriodClaim(
        teacher_id=teacher.id,
        claim_date=payload.claim_date,
        day=day,
        start_time=payload.start_time,
        end_time=payload.end_time,
        division=payload.division,
        batch=batch,
        subject=payload.subject,
        created_at=datetime.utcnow(),
    )
    db.add(row)

    # The audience mirrors who can actually see the change: a whole-division
    # claim reaches the division, a batch practical only its own batch.
    audience = _approved_students(
        db, division=row.division, batch=batch
    )
    notice_title = "Free period claimed"
    notice_message = f"{day}, {payload.start_time}-{payload.end_time} is now free"
    if batch:
        notice_message = f"{notice_message} ({batch})"
    if (payload.subject or "").strip():
        notice_message = f"{notice_message} · {payload.subject.strip()}"
    _add_student_bells(db, audience, notice_title, notice_message)

    try:
        db.commit()
    except IntegrityError:
        db.rollback()
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="That period was claimed a moment ago - please refresh",
        )

    db.refresh(row)

    _schedule_student_push(
        background,
        db,
        [student.id for student in audience],
        notice_title,
        notice_message,
        {"type": "free_period", "claim_id": row.id},
    )

    return row


@app.delete("/teacher/free-periods/claims/{claim_id}")
def release_free_period(
    claim_id: int,
    background: BackgroundTasks,
    teacher: models.Teacher = Depends(require_teacher_or_admin),
    db: Session = Depends(get_db),
):
    """Release one of the caller's own claims (admins may release any)."""
    row = db.query(models.FreePeriodClaim).filter(
        models.FreePeriodClaim.id == claim_id
    ).first()

    if not row:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND, detail="Claim not found"
        )

    if row.teacher_id != teacher.id and teacher.role != "admin":
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="You can only release your own claimed periods",
        )

    audience = _approved_students(
        db, division=row.division, batch=row.batch or ""
    )
    notice_title = "Free period released"
    notice_message = (
        f"{row.day}, {row.start_time}-{row.end_time} is no longer a claimed "
        "free period."
    )
    _add_student_bells(db, audience, notice_title, notice_message)

    db.delete(row)
    db.commit()

    _schedule_student_push(
        background,
        db,
        [student.id for student in audience],
        notice_title,
        notice_message,
        {"type": "free_period_released", "claim_id": claim_id},
    )

    return {"message": "Claim released", "claim_id": claim_id}


@app.get("/admin/schedule-changes", response_model=AdminScheduleChangesOut)
def list_schedule_changes(
    date: str | None = None,
    division: str | None = None,
    teacher: models.Teacher = Depends(require_teacher_or_admin),
    db: Session = Depends(get_db),
):
    """Every free-period claim on one date, for the staff portal.

    Reading is open to every staff account: a teacher needs to see who holds a
    slot as much as an admin does. Deleting reuses the release endpoint, whose
    rule (admin any, teacher own only) is reported here per row as
    ``can_delete`` so the portal never offers a button the backend would refuse.
    """
    target_date = _parse_date(date) if date else _college_today()

    query = (
        db.query(models.FreePeriodClaim)
        .options(joinedload(models.FreePeriodClaim.teacher))
        .filter(models.FreePeriodClaim.claim_date == target_date.isoformat())
    )

    wanted = (division or "").strip().upper()
    if wanted:
        query = query.filter(models.FreePeriodClaim.division == wanted)

    claims = query.order_by(
        models.FreePeriodClaim.division,
        models.FreePeriodClaim.start_time,
        models.FreePeriodClaim.id,
    ).all()

    rows = [
        AdminScheduleChangeOut(
            id=claim.id,
            claim_date=claim.claim_date,
            day=claim.day,
            time=f"{claim.start_time} - {claim.end_time}",
            division=claim.division,
            batch=claim.batch or "",
            subject=claim.subject,
            claimed_by_name=(claim.teacher.name if claim.teacher else "Unknown teacher"),
            claimed_by_id=claim.teacher_id,
            can_delete=(teacher.role == "admin" or claim.teacher_id == teacher.id),
        )
        for claim in claims
    ]

    return AdminScheduleChangesOut(
        date=target_date.isoformat(), count=len(rows), claims=rows
    )


# ==================================================================
# Assignments: PDF / video upload + download
# ============================================================
# An assignment attachment is either a PDF or a video. The content type the
# client claims is only a hint: the bytes decide (see _sniff_media_kind), so a
# video renamed to .pdf - or the reverse - is refused rather than stored and
# served as the wrong kind of file.
_ALLOWED_PDF_TYPES = {
    "application/pdf",
    "application/x-pdf",
}
_ALLOWED_VIDEO_TYPES = {
    "video/mp4",
    "video/quicktime",
    "video/x-matroska",
    "video/x-m4v",
}
# Browsers and the file_picker plugin often send this for a local file whose
# type they do not know; the magic bytes below are the real check.
_GENERIC_BINARY_TYPES = {"application/octet-stream", "binary/octet-stream"}

_ALLOWED_UPLOAD_TYPES = (
    _ALLOWED_PDF_TYPES | _ALLOWED_VIDEO_TYPES | _GENERIC_BINARY_TYPES
)

# kind -> stored file extension, and the type the download endpoint serves.
_MEDIA_EXTENSIONS = {
    "pdf": ".pdf",
    "mp4": ".mp4",
    "mov": ".mov",
    "mkv": ".mkv",
}
_MEDIA_CONTENT_TYPES = {
    ".pdf": "application/pdf",
    ".mp4": "video/mp4",
    ".mov": "video/quicktime",
    ".mkv": "video/x-matroska",
}


# One upload may carry several files, but never an unbounded number: each file
# is read into memory for the magic-byte check before it is written.
MAX_ASSIGNMENT_ATTACHMENTS = 10


def _validated_upload_bytes(
    upload: UploadFile, max_bytes: int
) -> tuple[bytes, str]:
    """Read one uploaded file and prove it is a PDF or a video.

    The claimed content type is only a hint: the bytes decide what this is (see
    ``_sniff_media_kind``), and a file whose header contradicts its contents is
    refused rather than stored and served as the wrong kind.
    """
    content_type = (upload.content_type or "").split(";")[0].strip().lower()
    if content_type and content_type not in _ALLOWED_UPLOAD_TYPES:
        raise HTTPException(
            status_code=status.HTTP_415_UNSUPPORTED_MEDIA_TYPE,
            detail="Only PDF and video files can be uploaded",
        )

    data = upload.file.read(max_bytes + 1)

    if not data:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="The uploaded file is empty",
        )

    if len(data) > max_bytes:
        raise HTTPException(
            status_code=status.HTTP_413_REQUEST_ENTITY_TOO_LARGE,
            detail=(
                "Each file must be at most "
                f"{settings.MAX_ASSIGNMENT_FILE_MB} MB"
            ),
        )

    media_kind = _sniff_media_kind(data)
    if media_kind is None:
        raise HTTPException(
            status_code=status.HTTP_415_UNSUPPORTED_MEDIA_TYPE,
            detail="The uploaded file is not a valid PDF or video",
        )

    if content_type and content_type not in _GENERIC_BINARY_TYPES:
        claimed_video = content_type in _ALLOWED_VIDEO_TYPES
        if (media_kind == "pdf") == claimed_video:
            raise HTTPException(
                status_code=status.HTTP_415_UNSUPPORTED_MEDIA_TYPE,
                detail="The file type does not match its contents",
            )

    return data, media_kind


def _sniff_media_kind(data: bytes) -> str | None:
    """The real kind of an attachment, read from its first bytes.

    ISO base media files (MP4/MOV/M4V) carry a ``ftyp`` box at offset 4; the
    brand says which member of the family it is. Matroska/WebM starts with the
    EBML header. Anything else is not something this endpoint stores.
    """
    if data.startswith(b"%PDF-"):
        return "pdf"
    if len(data) >= 12 and data[4:8] == b"ftyp":
        brand = data[8:12]
        if brand == b"qt  ":
            return "mov"
        return "mp4"
    if data.startswith(b"\x1aE\xdf\xa3"):
        return "mkv"
    return None


def _safe_display_name(filename: str | None) -> str:
    """Keep only a plain file name for display - never used as a path."""
    name = (filename or "").replace("\\", "/").split("/")[-1]
    name = re.sub(r"[\x00-\x1f]", "", name).strip()
    return name[:120] or "assignment.pdf"


def _assignment_notification_text(assignment: models.Assignment) -> tuple[str, str]:
    """Title and body for an upload, shared by the in-app row and the push.

    One helper for both channels so the tray alert and the Notifications screen
    can never word the same upload differently.
    """
    return "New assignment", f"New assignment uploaded: {assignment.title}"


def _notify_students_of_assignment(db: Session, assignment: models.Assignment) -> list[int]:
    """Queue one notification per student who can see a new assignment.

    Recipients follow exactly the same rule as ``GET /assignments``: the same
    year and division, every approved student in the division for a
    division-wide upload, and only the matching batch for a batch-specific one.
    Pending and rejected accounts are skipped - they cannot sign in, so a
    notification for them could never be read.

    The rows are added to the caller's session but not committed here, so the
    assignment and its notifications are saved in one transaction.

    Returns the recipient student ids, which is what the push delivery uses to
    find device tokens once the transaction has committed.
    """
    query = db.query(models.Student).filter(
        models.Student.year == assignment.year,
        models.Student.division == assignment.division,
        models.Student.status == models.StudentStatus.approved,
    )

    batch = _normalise_batch(assignment.batch)
    if batch:
        query = query.filter(
            or_(
                models.Student.batch == batch,
                models.Student.batch == batch.replace("-", ""),
            )
        )

    created_at = datetime.utcnow()
    title, message = _assignment_notification_text(assignment)

    recipient_ids: list[int] = []
    for student in query.all():
        db.add(
            models.Notification(
                student_id=student.id,
                title=title,
                message=message,
                is_read=False,
                created_at=created_at,
            )
        )
        recipient_ids.append(student.id)
    return recipient_ids


def _push_tokens_for_students(db: Session, student_ids: list[int]) -> list[str]:
    """Every registered device token belonging to ``student_ids``.

    Read after the upload transaction committed: a phone that registered a
    token while the teacher was uploading is included, and a failed push can
    never roll the assignment back.
    """
    if not student_ids:
        return []

    rows = (
        db.query(models.FcmToken.token)
        .filter(models.FcmToken.student_id.in_(student_ids))
        .all()
    )
    return [row[0] for row in rows if row[0]]


def _deliver_assignment_push(
    tokens: list[str],
    title: str,
    body: str,
    data: dict,
) -> None:
    """Background job: push the alert and prune dead tokens.

    Runs after the HTTP response, in its own short-lived session, so Google's
    latency never reaches the teacher's upload and nothing here can undo it.
    Every failure is swallowed - the in-app notification row is the record, and
    it is already committed.
    """
    try:
        result = firebase_service.send_push_notification(
            tokens, title, body, data=data
        )
    except Exception:
        return

    if not result.invalid_tokens:
        return

    db = SessionLocal()
    try:
        db.query(models.FcmToken).filter(
            models.FcmToken.token.in_(result.invalid_tokens)
        ).delete(synchronize_session=False)
        db.commit()
    except Exception:
        db.rollback()
    finally:
        db.close()


@app.post(
    "/teacher/assignments/upload",
    response_model=AssignmentOut,
    status_code=status.HTTP_201_CREATED,
)
def upload_assignment(
    background: BackgroundTasks,
    title: str = Form(...),
    subject: str = Form(...),
    due_date: str = Form(...),
    year: int = Form(...),
    division: str = Form("D"),
    description: str = Form(""),
    batch: str = Form(""),
    file: UploadFile | None = File(None),
    files: list[UploadFile] = File(default=[]),
    teacher: models.Teacher = Depends(require_teacher_or_admin),
    db: Session = Depends(get_db),
):
    """Create an assignment, optionally with PDF/video files attached.

    A text-only assignment ("Read chapter 4") needs no file; any file that IS
    sent is validated (magic bytes, not just a header), size-checked, and every
    file is authorized the same way. PDFs and MP4/MOV/MKV video are accepted;
    the stored extension follows what the bytes are, and the client's name is
    kept only for display.

    ``files`` is the multi-file field; the older single ``file`` field is still
    accepted so an existing CLI or app build keeps working unchanged.

    Uploading the real PDF for a subject replaces that class group's text-only
    rows for the same subject/year/division, so a student sees one card per
    subject instead of a placeholder next to the file. Creating another
    text-only assignment does not delete the earlier one.
    """
    clean_title = title.strip()
    clean_subject = subject.strip()
    clean_division = division.strip().upper()
    clean_description = description.strip()

    if not clean_title or len(clean_title) > 200:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Title is required and must be at most 200 characters",
        )
    if not clean_subject or len(clean_subject) > 120:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Subject is required and must be at most 120 characters",
        )
    if len(clean_description) > 2000:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Instructions must be at most 2000 characters",
        )
    if not clean_division or len(clean_division) > 8:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Division is required",
        )
    if year < 1 or year > 5:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Year must be between 1 and 5",
        )

    normalised_batch = _normalise_batch(batch)
    if (batch or "").strip() and normalised_batch not in VALID_BATCHES:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"Batch must be one of {sorted(VALID_BATCHES)} or empty",
        )

    due = _parse_date(due_date)

    uploads = [
        item
        for item in ([file] if file is not None else []) + list(files or [])
        if item is not None
    ]
    if len(uploads) > MAX_ASSIGNMENT_ATTACHMENTS:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=(
                "At most "
                f"{MAX_ASSIGNMENT_ATTACHMENTS} files can be attached to one "
                "assignment"
            ),
        )

    max_bytes = max(1, settings.MAX_ASSIGNMENT_FILE_MB) * 1024 * 1024
    upload_dir = settings.upload_path
    upload_dir.mkdir(parents=True, exist_ok=True)

    # (path, stored name, display name, size) for every file already written.
    # A later file that fails validation removes the earlier ones again, so a
    # rejected multi-file upload leaves nothing behind.
    stored_files: list[tuple[Path, str, str, int]] = []
    try:
        for upload in uploads:
            data, media_kind = _validated_upload_bytes(upload, max_bytes)
            stored_name = f"{uuid.uuid4().hex}{_MEDIA_EXTENSIONS[media_kind]}"
            (upload_dir / stored_name).write_bytes(data)
            stored_files.append(
                (
                    upload_dir / stored_name,
                    stored_name,
                    _safe_display_name(upload.filename),
                    len(data),
                )
            )
    except HTTPException:
        for path, *_ in stored_files:
            path.unlink(missing_ok=True)
        raise

    # A real file supersedes the same subject/year/division text-only rows, so
    # the student sees one card per subject. Another text-only post must NOT
    # delete earlier text-only assignments: those are separate work, not
    # placeholders waiting for a file.
    if stored_files:
        replaced_placeholders = (
            db.query(models.Assignment)
            .filter(
                models.Assignment.subject == clean_subject,
                models.Assignment.year == year,
                models.Assignment.division == clean_division,
                models.Assignment.stored_name.is_(None),
            )
            .all()
        )
        for row in replaced_placeholders:
            db.delete(row)

    # The first file also fills the legacy single-file columns, so the old
    # download route and any client that predates multiple attachments keep
    # working against the same assignment. A text-only assignment leaves them
    # NULL, exactly like every pre-existing row.
    if stored_files:
        _path, primary_name, primary_original, primary_size = stored_files[0]
    else:
        primary_name = None
        primary_original = None
        primary_size = None

    assignment = models.Assignment(
        subject=clean_subject,
        title=clean_title,
        description=clean_description or None,
        due_date=due.strftime("%Y-%m-%d"),
        year=year,
        division=clean_division,
        batch=normalised_batch or None,
        stored_name=primary_name,
        original_name=primary_original,
        file_size=primary_size,
        uploaded_by=teacher.id,
        created_at=datetime.utcnow(),
    )
    assignment.attachments = [
        models.AssignmentAttachment(
            stored_name=stored_name,
            original_name=original_name,
            file_size=size,
        )
        for _stored_path, stored_name, original_name, size in stored_files
    ]

    recipient_ids: list[int] = []
    try:
        db.add(assignment)
        # Flush so the assignment has an id before its notifications are queued;
        # everything below is still committed as one transaction.
        db.flush()

        recipient_ids = _notify_students_of_assignment(db, assignment)

        db.commit()
        db.refresh(assignment)
    except IntegrityError:
        db.rollback()
        for path, *_ in stored_files:
            path.unlink(missing_ok=True)
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="Could not save the assignment - please try again",
        )

    # Push runs after the response, so a slow or unconfigured Firebase can
    # never delay the teacher's upload or fail it. The in-app notification rows
    # above are already the durable record.
    push_tokens = _push_tokens_for_students(db, recipient_ids)
    if push_tokens:
        push_title, push_body = _assignment_notification_text(assignment)
        background.add_task(
            _deliver_assignment_push,
            push_tokens,
            push_title,
            push_body,
            {
                "type": "assignment",
                "assignment_id": assignment.id,
                "subject": assignment.subject,
            },
        )

    return assignment


@app.get("/teacher/assignments/mine", response_model=list[AssignmentOut])
def list_my_uploaded_assignments(
    teacher: models.Teacher = Depends(require_teacher_or_admin),
    db: Session = Depends(get_db),
):
    """Assignments uploaded by the caller, newest first."""
    return (
        db.query(models.Assignment)
        .filter(models.Assignment.uploaded_by == teacher.id)
        .order_by(models.Assignment.id.desc())
        .all()
    )


@app.patch("/teacher/assignments/{assignment_id}", response_model=AssignmentOut)
def update_uploaded_assignment(
    assignment_id: int,
    payload: AssignmentUpdate,
    teacher: models.Teacher = Depends(require_teacher_or_admin),
    db: Session = Depends(get_db),
):
    """Change the title, instructions or due date of one assignment.

    Only the account that uploaded it (or an admin) may edit it, exactly like
    DELETE. A field left out of the body is not touched; a field that IS sent
    is validated with the upload route's limits, so a PATCH cannot store a
    title or instructions an upload would have refused.

    Subject, year, division, batch and the files are not editable: changing
    those would change which students can see the assignment (and the file it
    serves), which is a different operation. Moving the due date is enough to
    reorder the student's list, because the app sorts by due date.
    """
    assignment = db.query(models.Assignment).filter(
        models.Assignment.id == assignment_id
    ).first()

    if not assignment:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="No uploaded assignment with that id",
        )

    if assignment.uploaded_by != teacher.id and teacher.role != "admin":
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="You can only edit assignments you uploaded",
        )

    changes = payload.model_dump(exclude_unset=True)
    if not changes:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Provide at least one of title, description or due_date",
        )

    if "title" in changes:
        clean_title = (changes["title"] or "").strip()
        if not clean_title or len(clean_title) > 200:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="Title is required and must be at most 200 characters",
            )
        assignment.title = clean_title

    if "description" in changes:
        clean_description = (changes["description"] or "").strip()
        if len(clean_description) > 2000:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="Instructions must be at most 2000 characters",
            )
        # Empty means "no instructions", matching what an upload stores.
        assignment.description = clean_description or None

    if "due_date" in changes:
        if not (changes["due_date"] or "").strip():
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="A due date is required",
            )
        assignment.due_date = _parse_date(changes["due_date"]).strftime(
            "%Y-%m-%d"
        )

    db.commit()
    db.refresh(assignment)
    return assignment


@app.delete("/teacher/assignments/{assignment_id}")
def delete_uploaded_assignment(
    assignment_id: int,
    teacher: models.Teacher = Depends(require_teacher_or_admin),
    db: Session = Depends(get_db),
):
    """Remove one uploaded assignment (admins may remove any).

    A text-only row is a subject placeholder, not an upload: it is what the
    student's card falls back to, so it is never removable here. Uploading a
    file for the subject replaces it instead. Only rows with an ``uploaded_by``
    owner can be removed, so the seeded records can never be deleted from here.
    """
    assignment = db.query(models.Assignment).filter(
        models.Assignment.id == assignment_id
    ).first()

    if not assignment:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="No uploaded assignment with that id",
        )

    if assignment.stored_name is None:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Cannot delete a subject placeholder. Upload a file to replace it.",
        )

    if not assignment.uploaded_by:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="No uploaded assignment with that id",
        )

    if assignment.uploaded_by != teacher.id and teacher.role != "admin":
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="You can only manage assignments you uploaded",
        )

    # Every file the assignment carries goes with it: the legacy column and any
    # additional attachments (the ORM cascade removes their rows).
    stored_names = {row.stored_name for row in assignment.attachments}
    if assignment.stored_name:
        stored_names.add(assignment.stored_name)
    for name in stored_names:
        (settings.upload_path / name).unlink(missing_ok=True)

    db.delete(assignment)
    db.commit()
    return {"message": "Assignment removed", "assignment_id": assignment_id}


def _authorized_assignment_file(
    db: Session,
    actor: tuple,
    assignment_id: int,
    attachment_id: int | None = None,
) -> tuple[Path, str]:
    """Resolve one of an assignment's files, or refuse with the right status.

    The single-file route (``attachment_id`` None) serves the legacy columns;
    the per-attachment route serves one row of ``assignment_attachments``. Both
    are authorized the same way - by the assignment's visibility, never by the
    file's id alone - and neither ever trusts a client-supplied path.
    """
    role, account = actor

    assignment = db.query(models.Assignment).filter(
        models.Assignment.id == assignment_id
    ).first()

    if not assignment:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="This assignment has no attached file",
        )

    if attachment_id is None:
        stored_name = assignment.stored_name
        display_name = assignment.original_name
        if not stored_name:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND,
                detail="This assignment has no attached file",
            )
    else:
        attachment = next(
            (row for row in assignment.attachments if row.id == attachment_id),
            None,
        )
        if attachment is None:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND,
                detail="This assignment has no file with that id",
            )
        stored_name = attachment.stored_name
        display_name = attachment.original_name

    if role == "student":
        batch = _normalise_batch(account.batch)
        allowed = (
            assignment.year == account.year
            and assignment.division == account.division
            and (
                assignment.batch is None
                or _normalise_batch(assignment.batch) == batch
            )
        )
    else:
        allowed = account.role == "admin" or assignment.uploaded_by == account.id

    if not allowed:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="You are not permitted to download this assignment",
        )

    if Path(stored_name).name != stored_name:
        # Defensive: a stored name must never be a path.
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND, detail="Invalid stored file"
        )

    path = settings.upload_path / stored_name
    if not path.exists():
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="The stored file is no longer available",
        )

    return path, display_name or f"assignment-{assignment.id}{path.suffix.lower() or '.pdf'}"


def _file_response(path: Path, display_name: str) -> FileResponse:
    return FileResponse(
        path,
        # The stored extension is what the upload actually was; serving every
        # attachment as application/pdf would make a video unplayable.
        media_type=_MEDIA_CONTENT_TYPES.get(
            path.suffix.lower(), "application/octet-stream"
        ),
        filename=display_name,
    )


@app.get("/assignments/{assignment_id}/file")
def download_assignment_file(
    assignment_id: int,
    actor: tuple = Depends(get_current_actor),
    db: Session = Depends(get_db),
):
    """Download an assignment's primary file (the pre-multi-file route).

    Kept for every client that predates ``attachments``: it serves the first
    file, exactly as before. A student must match the assignment's
    year/division and, for a batch assignment, their stored batch. A teacher may
    download what they uploaded (admins anything).
    """
    path, display_name = _authorized_assignment_file(db, actor, assignment_id)
    return _file_response(path, display_name)


@app.get("/assignments/{assignment_id}/files/{attachment_id}")
def download_assignment_attachment(
    assignment_id: int,
    attachment_id: int,
    actor: tuple = Depends(get_current_actor),
    db: Session = Depends(get_db),
):
    """Download ONE file of a multi-file assignment.

    The attachment must belong to the assignment and the caller must be allowed
    to see that assignment; the id alone grants nothing.
    """
    path, display_name = _authorized_assignment_file(
        db, actor, assignment_id, attachment_id
    )
    return _file_response(path, display_name)


# ==================================================================
# Faculty Finder / Lab Finder
# ============================================================
@app.get("/faculty", response_model=list[FacultyOut])
def list_faculty(
    q: str = "",
    actor: tuple = Depends(get_current_actor),
    db: Session = Depends(get_db),
):
    """Faculty directory, searchable by name, code or subject.

    Only values that exist in an official record are returned; unknown fields
    come back as null so the app shows "Not available" instead of a guess.
    """
    rows = db.query(models.FacultyMember).order_by(models.FacultyMember.short_code).all()
    subjects = db.query(models.Subject).all()

    by_code: dict[str, list[models.Subject]] = {}
    for subject in subjects:
        for code in _faculty_tokens(subject.faculty_code):
            by_code.setdefault(code, []).append(subject)

    needle = (q or "").strip().lower()
    results: list[FacultyOut] = []

    for row in rows:
        taught = by_code.get(row.short_code.strip().upper(), [])
        haystack = " ".join(
            [
                row.short_code,
                row.full_name or "",
                row.department or "",
                row.role_note or "",
            ]
            + [item.name for item in taught]
            + [item.short_name for item in taught]
            + [item.code or "" for item in taught]
        ).lower()

        if needle and needle not in haystack:
            continue

        results.append(
            FacultyOut(
                id=row.id,
                short_code=row.short_code,
                display_name=row.display_name,
                full_name=row.full_name,
                department=row.department,
                email=row.email,
                office=row.office,
                phone=row.phone,
                role_note=row.role_note,
                is_verified=row.is_verified,
                subjects=[
                    SubjectOut.model_validate(item)
                    for item in sorted(taught, key=lambda item: item.name)
                ],
            )
        )

    return results


@app.get("/labs", response_model=list[LabRoomOut])
def list_labs(
    q: str = "",
    actor: tuple = Depends(get_current_actor),
    db: Session = Depends(get_db),
):
    """Room/laboratory directory, searchable by name, code, room or subject."""
    rows = db.query(models.LabRoom).order_by(models.LabRoom.name).all()
    needle = (q or "").strip().lower()

    results = []
    for row in rows:
        haystack = " ".join(
            [
                row.name or "",
                row.code or "",
                row.room or "",
                row.building or "",
                row.floor or "",
                row.subject or "",
            ]
        ).lower()
        if needle and needle not in haystack:
            continue
        results.append(row)

    return results


@app.get("/directory/status", response_model=DirectoryStatusOut)
def directory_status(
    actor: tuple = Depends(get_current_actor),
    db: Session = Depends(get_db),
):
    """What the finder screens can show, and exactly what data is still missing."""
    faculty_count = db.query(models.FacultyMember).count()
    lab_count = db.query(models.LabRoom).count()

    missing = list(official_data.UNCONFIRMED)
    if faculty_count == 0:
        missing.insert(
            0,
            "The faculty directory is empty. Run `python seed_official_data.py "
            "--apply` (or add records) before the Faculty Finder can show "
            "anything.",
        )
    if lab_count == 0:
        missing.insert(
            0,
            "The room/laboratory directory is empty. Run `python "
            "seed_official_data.py --apply` before the Lab Finder can show "
            "anything.",
        )

    return DirectoryStatusOut(
        faculty_count=faculty_count, lab_count=lab_count, missing_data=missing
    )


if __name__ == "__main__":
    # Plain ``python main.py`` entrypoint for a container or a cloud host.
    # Render/Railway/Fly inject $PORT and expect the process to bind 0.0.0.0;
    # the Dockerfile CMD passes the same values to uvicorn directly. The app
    # object is passed instead of the "main:app" string so importing this
    # module once is enough (it initialises the database on import).
    import os

    import uvicorn

    uvicorn.run(
        app,
        host=os.environ.get("HOST", "0.0.0.0"),
        port=int(os.environ.get("PORT", "8000")),
    )
