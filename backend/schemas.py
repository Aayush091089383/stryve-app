
from pydantic import BaseModel, EmailStr, field_validator, model_validator
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


class TeacherAdminOut(TeacherOut):
    """An account as the Admin panel sees it.

    Adds the provisioned password so an admin can hand it to the teacher. This
    is the ONLY response model carrying it, and it is used exclusively by
    admin-only routes (`GET /teacher/list`); every teacher-facing response stays
    `TeacherOut`, which has no password field at all.
    """

    plain_password: str | None = None


class TeacherStatusUpdate(BaseModel):
    """Admin-only activation toggle: ``{"is_active": false}`` disables an account."""

    is_active: bool


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


class AttachmentOut(BaseModel):
    """One file attached to an assignment.

    The kind (PDF or video) is the client's business: it is derived from the
    display name's extension, exactly like the single-file fields below.
    """

    id: int
    original_name: str
    file_size: int

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

    # Attachment metadata (NULL/false for the pre-existing text-only rows). The
    # three single-file fields mirror the FIRST attachment and stay for clients
    # that predate multiple files; ``attachments`` is the full list.
    has_attachment: bool = False
    original_name: str | None = None
    file_size: int | None = None
    attachments: list[AttachmentOut] = []

    uploaded_by: int | None = None
    created_at: datetime | None = None

    class Config:
        from_attributes = True


class AssignmentUpdate(BaseModel):
    """Fields a teacher may change on an assignment they uploaded.

    Every field is optional so one PATCH can move only the due date. A field
    that is present is validated by the endpoint with the same rules the upload
    route uses: the subject, year, division, batch and files are deliberately
    not editable here, so an edit never changes which students can see the
    assignment.
    """

    title: str | None = None
    description: str | None = None
    due_date: str | None = None


class NotificationOut(BaseModel):
    """One student-visible notification.

    There is deliberately no recipient field: a student only ever receives
    their own rows from ``GET /notifications``, so echoing somebody else's
    ``student_id`` back is unnecessary surface.
    """

    id: int
    title: str
    message: str
    is_read: bool
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
    # None for a roster entry whose student has not registered yet.
    student_id: Optional[int] = None
    name: str
    roll_number: str
    status: str


class AttendanceMark(BaseModel):
    """One student's mark on a lecture sheet.

    ``roll_number`` is the identity the roster-based clients send, because it is
    the only one that exists before a student registers. ``student_id`` stays
    accepted so an existing client keeps working; the backend resolves either
    one to a roll number before it writes anything.
    """

    roll_number: Optional[str] = None
    student_id: Optional[int] = None
    status: str

    @field_validator("status")
    @classmethod
    def known_status(cls, v: str) -> str:
        cleaned = v.strip().lower()
        if cleaned not in {"present", "absent"}:
            raise ValueError("Status must be 'present' or 'absent'")
        return cleaned

    @field_validator("roll_number")
    @classmethod
    def clean_roll_number(cls, v: Optional[str]) -> Optional[str]:
        if v is None:
            return None
        cleaned = v.strip()
        return cleaned or None

    @model_validator(mode="after")
    def identified(self):
        if self.roll_number is None and self.student_id is None:
            raise ValueError("Each record needs a roll_number or a student_id")
        return self


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


class AttendanceStudentOut(BaseModel):
    """One student in a class list, ordered by roll number by the endpoint.

    ``id`` is the account id, or None for a roster entry whose student has not
    registered yet; ``is_registered`` says which, so the client never has to
    infer it from a null.
    """

    id: Optional[int] = None
    roll_number: str
    name: str
    branch: Optional[str] = None
    batch: str
    is_registered: bool = True


# ======================================================================
# Class roster
# ======================================================================
class RosterEntryIn(BaseModel):
    """One class-list row, as an admin adds or imports it."""

    roll_number: str
    name: str
    year: int = 1
    division: str = "D"
    batch: str = ""

    @field_validator("roll_number", "name")
    @classmethod
    def not_blank(cls, v: str) -> str:
        cleaned = (v or "").strip()
        if not cleaned:
            raise ValueError("This field cannot be empty")
        return cleaned

    @field_validator("year")
    @classmethod
    def sane_year(cls, v: int) -> int:
        if v < 1 or v > 5:
            raise ValueError("Year must be between 1 and 5")
        return v

    @field_validator("division")
    @classmethod
    def clean_division(cls, v: str) -> str:
        cleaned = (v or "").strip().upper()
        if not cleaned:
            raise ValueError("Division is required")
        return cleaned

    @field_validator("batch")
    @classmethod
    def valid_batch(cls, v: str) -> str:
        cleaned = (v or "").strip().upper().replace(" ", "")
        if cleaned in {"D1", "D_1"}:
            cleaned = "D-1"
        elif cleaned in {"D2", "D_2"}:
            cleaned = "D-2"
        elif cleaned in {"D3", "D_3"}:
            cleaned = "D-3"
        if cleaned and cleaned not in VALID_BATCHES:
            raise ValueError(f"Batch must be one of {sorted(VALID_BATCHES)} or empty")
        return cleaned


class RosterEntryOut(BaseModel):
    id: int
    roll_number: str
    name: str
    year: int
    division: str
    batch: str
    registered_student_id: Optional[int] = None
    registered_as: Optional[str] = None


class RosterImportResult(BaseModel):
    message: str
    added: int
    updated: int
    skipped: int
    errors: list[str]


class AttendanceSubmitRequest(BaseModel):
    """One lecture's whole sheet, addressed by date and printed period.

    ``period`` is the timetable's own label ("10:15-11:15"); the endpoint
    resolves it to the stored ``slot_start``/``slot_end`` pair, so the client can
    never invent a period that is not on the official grid.
    """

    class_date: str  # YYYY-MM-DD
    period: str
    subject: str
    division: str = "D"
    batch: str = ""
    records: list[AttendanceMark]

    @field_validator("batch")
    @classmethod
    def valid_batch(cls, v: str) -> str:
        cleaned = (v or "").strip().upper()
        if cleaned and cleaned not in VALID_BATCHES:
            raise ValueError(f"Batch must be one of {sorted(VALID_BATCHES)} or empty")
        return cleaned


class AttendanceSubmitResponse(BaseModel):
    message: str
    subject: str
    class_date: str
    period: str
    total: int
    present: int
    absent: int
    created: int
    corrected: int


class AttendanceDeleteRequest(BaseModel):
    """One saved lecture to soft-delete.

    A session is identified exactly as it was submitted: the calendar date, the
    printed period, the subject and the class group. ``period`` is resolved to
    the stored slot pair by the endpoint, so a client cannot delete a period the
    official timetable does not have.
    """

    class_date: str  # YYYY-MM-DD
    period: str
    subject: str
    division: str = "D"
    batch: str = ""

    @field_validator("batch")
    @classmethod
    def valid_batch(cls, v: str) -> str:
        cleaned = (v or "").strip().upper()
        if cleaned and cleaned not in VALID_BATCHES:
            raise ValueError(f"Batch must be one of {sorted(VALID_BATCHES)} or empty")
        return cleaned


class AttendanceDeleteResponse(BaseModel):
    """The result of a soft delete: rows touched, never rows destroyed."""

    message: str
    deleted_count: int
    class_date: str
    period: str
    subject: str
    division: str
    batch: str


class AttendanceHistorySessionOut(BaseModel):
    """One saved lecture (a date + period + subject), with its tallies.

    ``can_delete`` is decided by the server, because the lecture window is
    judged on the college clock: a client cannot be trusted to know whether a
    session is still inside it.
    """

    class_date: str
    period: str
    subject: str
    division: str
    batch: str
    total: int
    present: int
    absent: int
    can_delete: bool = False


class AttendanceLectureOut(BaseModel):
    """One lecture as the student saw it."""

    date: str
    period: str
    status: str


class SubjectAttendanceSummary(BaseModel):
    subject: str
    total_classes: int
    attended: int
    percentage: float
    lectures: list[AttendanceLectureOut]


class StudentAttendanceOut(BaseModel):
    """The signed-in student's own attendance, never another student's."""

    overall_percentage: float
    total_classes: int
    attended: int
    subjects: list[SubjectAttendanceSummary]


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


# ======================================================================
# Push notifications (Firebase Cloud Messaging)
# ======================================================================
class DeviceTokenRegister(BaseModel):
    """The FCM registration token this device received from Firebase.

    Validated here (not in the endpoint) so an empty or absurdly long token is
    rejected with the usual 422 shape instead of reaching the database.
    """

    token: str

    @field_validator("token")
    @classmethod
    def token_is_usable(cls, v: str) -> str:
        cleaned = (v or "").strip()
        if not cleaned:
            raise ValueError("Device token is required")
        # FCM tokens are a few hundred characters; 4096 leaves plenty of room
        # while keeping an oversized body out of the database.
        if len(cleaned) > 4096:
            raise ValueError("Device token is too long")
        return cleaned


class DeviceTokenOut(BaseModel):
    """Whether this device is now registered for push, for the caller."""

    registered: bool


# ======================================================================
# Announcements (teacher posts a notice, students read the feed)
# ======================================================================
class AnnouncementAttachmentOut(BaseModel):
    """One file attached to an announcement.

    The kind (PDF or video) is derived from ``original_name`` on the client,
    exactly like an assignment attachment. Ids are scoped to their
    announcement by the download route.
    """

    id: int
    original_name: str
    file_size: int

    class Config:
        from_attributes = True


class AnnouncementOut(BaseModel):
    """One announcement as the feed (and the poster's confirmation) sees it."""

    id: int
    title: str
    message: str

    author_id: int
    # Resolved server-side from author_id; the client never supplies it.
    author_name: str

    created_at: datetime

    # NULL = not restricted to one year / one division.
    year: int | None = None
    division: str | None = None

    # The official subject this notice is filed under; NULL = Common.
    subject: str | None = None

    # PDFs/videos posted with the notice, in upload order. Empty for a
    # text-only announcement (every row from before files were supported).
    attachments: list[AnnouncementAttachmentOut] = []

    class Config:
        from_attributes = True
