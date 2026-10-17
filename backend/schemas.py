
from pydantic import BaseModel, EmailStr, field_validator
from typing import ClassVar, Optional
from datetime import datetime

VALID_BATCHES = {"D-1", "D-2", "D-3"}


class StudentRegister(BaseModel):
    # Only roll_number, email, password, confirm_password from student
    # Other details (name, branch, year, division, batch) come from registry
    roll_number: str
    email: EmailStr
    password: str
    confirm_password: str

    @field_validator("password")
    @classmethod
    def password_min_length(cls, v: str) -> str:
        if len(v) < 6:
            raise ValueError("Password must be at least 6 characters")
        return v


class StudentRegisterResponse(BaseModel):
    message: str
    student_id: int
    status: str  # pending, approved, rejected


class StudentLookupResponse(BaseModel):
    # Public endpoint: the official name is deliberately NOT returned.
    # Only initials are exposed so a student can recognise their own entry
    # while anonymous callers cannot harvest the registry (see privacy.py).
    roll_number: str
    masked_name: str
    branch: str
    year: int
    division: str
    batch: str


class StudentLogin(BaseModel):
    email: EmailStr
    password: str


class TokenResponse(BaseModel):
    message: str
    student_id: int
    name: str
    email: str
    roll_number: str
    branch: str
    year: int
    division: str
    batch: str
    token: str
    token_expires_at: str


class TeacherLogin(BaseModel):
    email: EmailStr
    password: str


class TeacherTokenResponse(BaseModel):
    message: str
    teacher_id: int
    name: str
    email: str
    role: str
    token: str
    token_expires_at: str


class TeacherCreate(BaseModel):
    name: str
    email: EmailStr
    password: str
    role: str  # "teacher" or "admin"

    # Server-side password strength. The Flutter dialog applies the same rules,
    # but the API must not rely on the client: a direct request with a weak
    # password has to be rejected before any account is created.
    MIN_PASSWORD_LENGTH: ClassVar[int] = 8

    @field_validator("password")
    @classmethod
    def password_strength(cls, v: str) -> str:
        if len(v) < cls.MIN_PASSWORD_LENGTH:
            raise ValueError(
                f"Password must be at least {cls.MIN_PASSWORD_LENGTH} characters"
            )
        if not any(c.isalpha() for c in v):
            raise ValueError("Password must contain at least one letter")
        if not any(c.isdigit() for c in v):
            raise ValueError("Password must contain at least one digit")
        return v


class TeacherOut(BaseModel):
    id: int
    name: str
    email: str
    role: str
    is_active: bool
    created_at: datetime

    # Faculty short code from the official timetable (may be NULL/unset).
    short_code: str | None = None

    # The raw configurable flag and the effective permission (admins: always
    # True). No password/hash/token field exists here, on purpose.
    can_approve_registrations: bool = False
    can_review_registrations: bool = False

    class Config:
        from_attributes = True


class StudentOut(BaseModel):
    id: int
    name: str
    email: str
    roll_number: str
    branch: str
    year: int
    division: str
    batch: str
    status: str
    approved_by: Optional[int] = None
    approved_at: Optional[datetime] = None
    rejection_reason: Optional[str] = None

    class Config:
        from_attributes = True


class PendingStudentOut(BaseModel):
    id: int
    name: str
    email: str
    roll_number: str
    branch: str
    year: int
    division: str
    batch: str
    status: str

    class Config:
        from_attributes = True


class ApproveRequest(BaseModel):
    pass  # No additional data needed for approve


class RejectRequest(BaseModel):
    reason: Optional[str] = None


class ApprovalActionResponse(BaseModel):
    message: str
    student_id: int
    status: str


class TimetableEntryOut(BaseModel):
    id: int
    day: str
    start_time: str
    end_time: str
    subject: str
    faculty: str | None
    room: str | None
    batch: str | None
    is_break: bool

    # True for the sheet's "RELM" periods: free for every class group, never
    # returned to students, offered to teachers by Claim Free Period.
    is_free_period: bool = False

    # "lecture" (no batch = whole division), "practical" (batch-specific),
    # "free_period" (RELM) or "break". Derived server-side from the same columns
    # the filters use.
    entry_type: str = "lecture"

    class Config:
        from_attributes = True


class AssignmentOut(BaseModel):
    id: int
    subject: str
    title: str
    description: str | None
    due_date: str
    year: int
    division: str
    batch: str | None

    # Attachment metadata (NULL/false for the pre-existing text-only rows).
    has_attachment: bool = False
    original_name: str | None = None
    file_size: int | None = None

    uploaded_by: int | None = None
    created_at: datetime | None = None

    class Config:
        from_attributes = True


# ======================================================================
# Teacher account permissions / assignments
# ======================================================================
class TeacherPermissionsUpdate(BaseModel):
    """Admin-only change of a teacher's configurable permissions."""

    can_approve_registrations: bool | None = None

    # Faculty short code printed on the official timetable ("SMG", "SPG", ...)
    # used to prove which periods the teacher actually teaches. Empty string
    # clears it, None leaves it unchanged.
    short_code: str | None = None

    @field_validator("short_code")
    @classmethod
    def normalise_short_code(cls, v: str | None) -> str | None:
        if v is None:
            return None
        cleaned = v.strip().upper()
        if cleaned and not cleaned.replace("-", "").replace(" ", "").isalnum():
            raise ValueError("Short code may only contain letters, digits and dashes")
        if len(cleaned) > 16:
            raise ValueError("Short code is too long (max 16 characters)")
        return cleaned


class TeacherAssignmentOut(BaseModel):
    id: int
    subject: str
    subject_code: str | None
    division: str
    batch: str
    day: str
    start_time: str
    end_time: str
    source: str

    class Config:
        from_attributes = True


class TeacherAssignmentCreate(BaseModel):
    """Admin-created assignment (never inferred from a teacher's name)."""

    subject: str
    subject_code: str | None = None
    division: str = "D"
    batch: str = ""  # "" = whole division
    day: str = ""
    start_time: str = ""
    end_time: str = ""

    @field_validator("batch")
    @classmethod
    def valid_batch(cls, v: str) -> str:
        cleaned = (v or "").strip().upper()
        if cleaned and cleaned not in VALID_BATCHES:
            raise ValueError(f"Batch must be one of {sorted(VALID_BATCHES)} or empty")
        return cleaned


# ======================================================================
# Attendance
# ======================================================================
class AttendanceClassStudentOut(BaseModel):
    id: int
    name: str
    roll_number: str
    batch: str

    class Config:
        from_attributes = True


class AttendanceSessionOut(BaseModel):
    student_id: int
    name: str
    roll_number: str
    status: str


class AttendanceMark(BaseModel):
    student_id: int
    status: str

    @field_validator("status")
    @classmethod
    def known_status(cls, v: str) -> str:
        cleaned = v.strip().lower()
        if cleaned not in {"present", "absent"}:
            raise ValueError("Status must be 'present' or 'absent'")
        return cleaned


class AttendanceSaveRequest(BaseModel):
    subject: str
    division: str = "D"
    batch: str = ""
    session_date: str  # YYYY-MM-DD
    slot_start: str
    slot_end: str
    records: list[AttendanceMark]


class AttendanceSaveResponse(BaseModel):
    message: str
    subject: str
    session_date: str
    slot_start: str
    created: int
    corrected: int


# ======================================================================
# Claim free period
# ======================================================================
class FreePeriodSlotOut(BaseModel):
    day: str
    start_time: str
    end_time: str
    division: str
    batch: str
    subject: str | None = None
    eligible: bool = False
    reason: str | None = None
    claimed: bool = False
    claim_note: str | None = None

    # True when this period is one of the sheet's free periods (RELM): a slot no
    # class group is scheduled in, which is what makes it claimable at all.
    is_free_period: bool = False


class FreePeriodClaimOut(BaseModel):
    id: int
    claim_date: str
    day: str
    start_time: str
    end_time: str
    division: str
    batch: str
    subject: str | None = None

    class Config:
        from_attributes = True


class FreePeriodAvailabilityOut(BaseModel):
    date: str
    day: str
    teacher_short_code: str | None = None

    # True for any authenticated, active teacher account (i.e. one created by an
    # admin) - the only thing needed to claim a free period. No extra per-teacher
    # permission exists, and a faculty short code is not required.
    can_claim_free_periods: bool = False

    # Whether a timetable link / assignment exists for this account. It no longer
    # blocks a free-period claim; it only decides whether the teacher's own
    # classes can be named (and whether per-batch gaps are offered).
    has_verified_assignments: bool = False
    message: str | None = None
    slots: list[FreePeriodSlotOut] = []
    claims: list[FreePeriodClaimOut] = []


class FreePeriodClaimRequest(BaseModel):
    day: str
    start_time: str
    end_time: str
    division: str = "D"
    batch: str = ""
    claim_date: str  # YYYY-MM-DD
    subject: str | None = None

    @field_validator("batch")
    @classmethod
    def valid_batch(cls, v: str) -> str:
        cleaned = (v or "").strip().upper()
        if cleaned and cleaned not in VALID_BATCHES:
            raise ValueError(f"Batch must be one of {sorted(VALID_BATCHES)} or empty")
        return cleaned


# ======================================================================
# Faculty / lab finder
# ======================================================================
class SubjectOut(BaseModel):
    name: str
    short_name: str
    code: str | None
    kind: str
    faculty_code: str | None

    class Config:
        from_attributes = True


class FacultyOut(BaseModel):
    id: int
    short_code: str
    display_name: str
    full_name: str | None
    department: str | None
    email: str | None
    office: str | None
    phone: str | None
    role_note: str | None
    is_verified: bool
    subjects: list[SubjectOut] = []


class LabRoomOut(BaseModel):
    id: int
    name: str
    code: str | None
    room: str | None
    building: str | None
    floor: str | None
    subject: str | None
    kind: str
    is_verified: bool

    class Config:
        from_attributes = True


class DirectoryStatusOut(BaseModel):
    """What the directory screens can and cannot show, and why."""

    faculty_count: int
    lab_count: int
    missing_data: list[str] = []
