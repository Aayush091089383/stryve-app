import re
import uuid
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

from fastapi import (
    Depends,
    FastAPI,
    File,
    Form,
    Request,
    UploadFile,
    status,
    HTTPException,
)
from fastapi.exceptions import RequestValidationError
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, JSONResponse
from pwdlib import PasswordHash
from sqlalchemy import or_
from sqlalchemy.orm import Session
from sqlalchemy.exc import IntegrityError

import models
import official_data
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
    StudentOut,
    PendingStudentOut,
    ApproveRequest,
    RejectRequest,
    ApprovalActionResponse,
    TimetableEntryOut,
    AssignmentOut,
    TokenResponse,
    TeacherPermissionsUpdate,
    TeacherAssignmentOut,
    TeacherAssignmentCreate,
    AttendanceClassStudentOut,
    AttendanceSaveRequest,
    AttendanceSaveResponse,
    AttendanceSessionOut,
    FreePeriodAvailabilityOut,
    FreePeriodClaimOut,
    FreePeriodClaimRequest,
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

app = FastAPI(title="CampusSync Backend")

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
        "message": "CampusSync backend is running!"
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
        "service": "CampusSync backend",
    }


@app.post("/register", status_code=status.HTTP_201_CREATED, response_model=StudentRegisterResponse)
def register_student(student: StudentRegister, db: Session = Depends(get_db)):
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

    # Check if email already exists in our system
    existing_email = db.query(models.Student).filter(
        models.Student.email == student.email
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
        email=student.email,
        roll_number=student.roll_number,
        branch=registry_student["course"],  # registry uses "course"
        year=registry_student["year"],
        division=registry_student["division"],
        batch=registry_student["batch"],
        password=hashed_password,
        status="pending",  # New registrations are pending approval
    )

    try:
        db.add(new_student)
        db.commit()
        db.refresh(new_student)

        return StudentRegisterResponse(
            message="Registration submitted for approval. You will be notified once approved.",
            student_id=new_student.id,
            status=new_student.status,
        )
    except IntegrityError:
        db.rollback()
        # Race condition - another registration happened simultaneously
        raise DuplicateEmailError("Registration conflict - please try again")


# ------------------------------------------------------------------
# Public /students/lookup abuse + privacy controls
# ------------------------------------------------------------------
# This endpoint is unauthenticated on purpose: a first-time student must be
# able to confirm their roll number before they can register. Because anyone
# can reach it, it returns a MASKED official name and is rate limited.
lookup_limiter = SlidingWindowLimiter(settings.LOOKUP_RATE_LIMIT_PER_MINUTE)


def _client_ip(request: Request) -> str:
    """Best-effort client identity for the in-process limiter.

    Behind a reverse proxy every request may share one address; the limiter is
    defence in depth, not the primary control (the masked response is).
    """
    client = request.client
    return client.host if client and client.host else "unknown"


def lookup_rate_limit(request: Request) -> None:
    """Dependency that rejects bulk lookups with 429 + Retry-After."""
    allowed, retry_after = lookup_limiter.check(_client_ip(request))
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


@app.post("/login", response_model=TokenResponse)
def login_student(student: StudentLogin, db: Session = Depends(get_db)):
    """
    Authenticate a student and return a session token.

    Returns 200 with token on success, 401 if credentials are invalid.
    """
    # Find student by email
    existing_student = db.query(models.Student).filter(
        models.Student.email == student.email
    ).first()

    if not existing_student:
        from exceptions import AuthenticationError
        raise AuthenticationError("Invalid email or password")

    # Verify password against stored hash
    password_correct = password_hash.verify(
        student.password,
        existing_student.password,
    )

    if not password_correct:
        from exceptions import AuthenticationError
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


@app.post("/teacher/login", response_model=TeacherTokenResponse)
def login_teacher(teacher: TeacherLogin, db: Session = Depends(get_db)):
    """
    Authenticate a teacher/admin and return a session token.

    Returns 200 with token on success, 401 if credentials are invalid.
    """
    # Find teacher by email
    existing_teacher = db.query(models.Teacher).filter(
        models.Teacher.email == teacher.email
    ).first()

    if not existing_teacher:
        from exceptions import AuthenticationError
        raise AuthenticationError("Invalid email or password")

    # Verify password against stored hash
    password_correct = password_hash.verify(
        teacher.password,
        existing_teacher.password,
    )

    if not password_correct:
        from exceptions import AuthenticationError
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
    db.commit()

    return ApprovalActionResponse(
        message="Student registration approved",
        student_id=student.id,
        status=student.status,
    )


@app.post("/teacher/registrations/{student_id}/reject", response_model=ApprovalActionResponse)
def reject_registration(
    student_id: int,
    request: RejectRequest,
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
    db.commit()

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

    # Check if email already exists
    existing = db.query(models.Teacher).filter(models.Teacher.email == teacher_data.email).first()
    if existing:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="Email already registered"
        )

    hashed_password = password_hash.hash(teacher_data.password)

    new_teacher = models.Teacher(
        name=teacher_data.name,
        email=teacher_data.email,
        password=hashed_password,
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


@app.get("/teacher/list", response_model=list[TeacherOut])
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
    """Return the official (start, end) slot, or None when it does not exist."""
    for known_start, known_end in official_data.TIME_SLOTS:
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
    ).all()

    batch_filter = _normalise_batch(batch)
    out = []
    for row in rows:
        student = row.student
        if student is None:
            continue
        if batch_filter and _normalise_batch(student.batch) != batch_filter:
            continue
        out.append(
            AttendanceSessionOut(
                student_id=student.id,
                name=student.name,
                roll_number=student.roll_number,
                status=row.status,
            )
        )

    return out


@app.post("/teacher/attendance", response_model=AttendanceSaveResponse)
def save_attendance(
    payload: AttendanceSaveRequest,
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

    if len({record.student_id for record in payload.records}) != len(payload.records):
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="The same student was submitted more than once",
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

    student_ids = [record.student_id for record in payload.records]
    students = {
        student.id: student
        for student in db.query(models.Student).filter(
            models.Student.id.in_(student_ids)
        )
    }

    for record in payload.records:
        student = students.get(record.student_id)
        if student is None:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND,
                detail=f"Student {record.student_id} not found",
            )
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
        if batch and _normalise_batch(student.batch) != batch:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail=f"{student.name} is not in batch {batch}",
            )

    now = datetime.utcnow()
    created = 0
    corrected = 0

    for record in payload.records:
        existing = db.query(models.AttendanceRecord).filter(
            models.AttendanceRecord.student_id == record.student_id,
            models.AttendanceRecord.subject == subject,
            models.AttendanceRecord.session_date == session_date,
            models.AttendanceRecord.slot_start == payload.slot_start,
        ).first()

        if existing:
            if existing.status != record.status:
                existing.status = record.status
                existing.updated_by = teacher.id
                existing.updated_at = now
                corrected += 1
            elif existing.updated_at is not None or existing.updated_by is not None:
                # unchanged correction request: leave the audit trail alone
                pass
            continue

        db.add(
            models.AttendanceRecord(
                student_id=record.student_id,
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
        created += 1

    try:
        db.commit()
    except IntegrityError:
        db.rollback()
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="Attendance for this lecture was saved by another request",
        )

    return AttendanceSaveResponse(
        message="Attendance saved",
        subject=subject,
        session_date=session_date,
        slot_start=payload.slot_start,
        created=created,
        corrected=corrected,
    )


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
                "timetable, so CampusSync cannot show which classes are yours. "
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
        in_slot = [
            entry
            for entry in entries
            if entry.start_time == start_time and entry.end_time == end_time
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

    try:
        db.commit()
    except IntegrityError:
        db.rollback()
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="That period was claimed a moment ago - please refresh",
        )

    db.refresh(row)
    return row


@app.delete("/teacher/free-periods/claims/{claim_id}")
def release_free_period(
    claim_id: int,
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

    db.delete(row)
    db.commit()
    return {"message": "Claim released", "claim_id": claim_id}


# ==================================================================
# Assignments: PDF upload / download
# ============================================================
_ALLOWED_UPLOAD_TYPES = {
    "application/pdf",
    "application/x-pdf",
    "application/octet-stream",
    "binary/octet-stream",
}


def _safe_display_name(filename: str | None) -> str:
    """Keep only a plain file name for display - never used as a path."""
    name = (filename or "").replace("\\", "/").split("/")[-1]
    name = re.sub(r"[\x00-\x1f]", "", name).strip()
    return name[:120] or "assignment.pdf"


@app.post(
    "/teacher/assignments/upload",
    response_model=AssignmentOut,
    status_code=status.HTTP_201_CREATED,
)
def upload_assignment(
    title: str = Form(...),
    subject: str = Form(...),
    due_date: str = Form(...),
    year: int = Form(...),
    division: str = Form("D"),
    description: str = Form(""),
    batch: str = Form(""),
    file: UploadFile = File(...),
    teacher: models.Teacher = Depends(require_teacher_or_admin),
    db: Session = Depends(get_db),
):
    """Upload a PDF assignment for a class group.

    Validates the file type (PDF magic bytes, not just a header), the size, the
    metadata and the caller's authorization. The stored file name is generated
    server-side; the client's name is kept only for display.
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

    content_type = (file.content_type or "").split(";")[0].strip().lower()
    if content_type and content_type not in _ALLOWED_UPLOAD_TYPES:
        raise HTTPException(
            status_code=status.HTTP_415_UNSUPPORTED_MEDIA_TYPE,
            detail="Only PDF files can be uploaded",
        )

    max_bytes = max(1, settings.MAX_ASSIGNMENT_FILE_MB) * 1024 * 1024
    data = file.file.read(max_bytes + 1)

    if not data:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST, detail="The uploaded file is empty"
        )

    if len(data) > max_bytes:
        raise HTTPException(
            status_code=status.HTTP_413_REQUEST_ENTITY_TOO_LARGE,
            detail=f"PDF must be at most {settings.MAX_ASSIGNMENT_FILE_MB} MB",
        )

    if not data.startswith(b"%PDF-"):
        raise HTTPException(
            status_code=status.HTTP_415_UNSUPPORTED_MEDIA_TYPE,
            detail="The uploaded file is not a valid PDF",
        )

    upload_dir = settings.upload_path
    upload_dir.mkdir(parents=True, exist_ok=True)

    stored_name = f"{uuid.uuid4().hex}.pdf"
    (upload_dir / stored_name).write_bytes(data)

    assignment = models.Assignment(
        subject=clean_subject,
        title=clean_title,
        description=clean_description or None,
        due_date=due.strftime("%Y-%m-%d"),
        year=year,
        division=clean_division,
        batch=normalised_batch or None,
        stored_name=stored_name,
        original_name=_safe_display_name(file.filename),
        file_size=len(data),
        uploaded_by=teacher.id,
        created_at=datetime.utcnow(),
    )

    try:
        db.add(assignment)
        db.commit()
        db.refresh(assignment)
    except IntegrityError:
        db.rollback()
        (upload_dir / stored_name).unlink(missing_ok=True)
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="Could not save the assignment - please try again",
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


@app.delete("/teacher/assignments/{assignment_id}")
def delete_uploaded_assignment(
    assignment_id: int,
    teacher: models.Teacher = Depends(require_teacher_or_admin),
    db: Session = Depends(get_db),
):
    """Remove one assignment the caller uploaded (admins may remove any).

    Only rows with an ``uploaded_by`` owner can be removed this way, so the
    pre-existing (seeded) assignment records can never be deleted from here.
    """
    assignment = db.query(models.Assignment).filter(
        models.Assignment.id == assignment_id
    ).first()

    if not assignment or not assignment.uploaded_by:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="No uploaded assignment with that id",
        )

    if assignment.uploaded_by != teacher.id and teacher.role != "admin":
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="You can only manage assignments you uploaded",
        )

    if assignment.stored_name:
        (settings.upload_path / assignment.stored_name).unlink(missing_ok=True)

    db.delete(assignment)
    db.commit()
    return {"message": "Assignment removed", "assignment_id": assignment_id}


@app.get("/assignments/{assignment_id}/file")
def download_assignment_file(
    assignment_id: int,
    actor: tuple = Depends(get_current_actor),
    db: Session = Depends(get_db),
):
    """Download an assignment PDF, only for people allowed to see that assignment.

    A student must match the assignment's year/division and, for a batch
    assignment, their stored batch. A teacher may download what they uploaded
    (admins anything).
    """
    role, account = actor

    assignment = db.query(models.Assignment).filter(
        models.Assignment.id == assignment_id
    ).first()

    if not assignment or not assignment.stored_name:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="This assignment has no attached file",
        )

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

    if Path(assignment.stored_name).name != assignment.stored_name:
        # Defensive: a stored name must never be a path.
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND, detail="Invalid stored file"
        )

    path = settings.upload_path / assignment.stored_name
    if not path.exists():
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="The stored file is no longer available",
        )

    return FileResponse(
        path,
        media_type="application/pdf",
        filename=assignment.original_name or f"assignment-{assignment.id}.pdf",
    )


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