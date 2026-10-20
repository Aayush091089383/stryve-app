from sqlalchemy import (
    Boolean,
    Column,
    DateTime,
    Enum,
    ForeignKey,
    Integer,
    String,
    Text,
    UniqueConstraint,
)
from sqlalchemy.orm import relationship

from database import Base

import enum
from datetime import datetime


class StudentStatus(str, enum.Enum):
    pending = "pending"
    approved = "approved"
    rejected = "rejected"


class TeacherRole(str, enum.Enum):
    teacher = "teacher"
    admin = "admin"


class Student(Base):
    __tablename__ = "students"

    id = Column(Integer, primary_key=True, index=True)

    name = Column(String, nullable=False)

    email = Column(String, unique=True, index=True, nullable=False)

    roll_number = Column(String, unique=True, index=True, nullable=False)

    branch = Column(String, nullable=False)

    year = Column(Integer, nullable=False)

    division = Column(String, nullable=False)

    batch = Column(String, nullable=False)

    password = Column(String, nullable=False)

    # Registration approval status
    status = Column(Enum(StudentStatus), default=StudentStatus.pending, nullable=False)

    # Approval metadata
    approved_by = Column(Integer, ForeignKey("teachers.id"), nullable=True)
    approved_at = Column(DateTime, nullable=True)
    rejection_reason = Column(Text, nullable=True)

    # Simple auth token. Regenerated every time the student logs in.
    # Not a JWT - just a random string the app sends back on later
    # requests so the backend knows which student is asking.
    token = Column(String, unique=True, index=True, nullable=True)

    # Token expiration timestamp. When the token expires, the student
    # must log in again to get a new token.
    token_expires_at = Column(DateTime, nullable=True)

    # Relationship to teacher who approved/rejected
    approver = relationship("Teacher", back_populates="approved_students")


class Teacher(Base):
    __tablename__ = "teachers"

    id = Column(Integer, primary_key=True, index=True)

    name = Column(String, nullable=False)

    email = Column(String, unique=True, index=True, nullable=False)

    password = Column(String, nullable=False)

    # The password exactly as the admin provisioned it, so the Admin panel can
    # read it back to the teacher (there is no e-mail delivery in this app).
    # It exists ONLY for the admin-only account list - `TeacherOut` (everything
    # a teacher or student can receive) deliberately has no such field.
    plain_password = Column(String, nullable=True)

    role = Column(Enum(TeacherRole), default=TeacherRole.teacher, nullable=False)

    is_active = Column(Boolean, default=True, nullable=False)

    # Simple auth token for teacher/admin
    token = Column(String, unique=True, index=True, nullable=True)

    token_expires_at = Column(DateTime, nullable=True)

    created_at = Column(DateTime, nullable=False)

    # Optional link to the faculty short code used on the official timetable
    # ("SMG", "SPG", ...). It is what lets the backend tell which periods a
    # teacher actually teaches. NULL means "not linked yet" - the backend then
    # refuses timetable-derived features instead of guessing.
    short_code = Column(String, unique=True, index=True, nullable=True)

    # Configurable permission: may this teacher review student registrations?
    # Admins always may (role == "admin"); a regular teacher only when this is
    # true. Default is False so a new account is never silently given approval
    # rights.
    can_approve_registrations = Column(Boolean, default=False, nullable=False)

    @property
    def can_review_registrations(self) -> bool:
        """Effective approval permission: admins always, teachers only if granted.

        This is the single rule the API and the app both read, so the button a
        teacher sees and what the server allows can never drift apart.
        """
        return self.role == "admin" or bool(self.can_approve_registrations)

    # Relationship to students they approved
    approved_students = relationship("Student", back_populates="approver")

    # Periods this teacher is verified to teach (attendance + free periods)
    assignments = relationship(
        "TeacherAssignment",
        back_populates="teacher",
        cascade="all, delete-orphan",
    )


class TimetableEntry(Base):
    __tablename__ = "timetable_entries"

    id = Column(Integer, primary_key=True, index=True)

    # Monday, Tuesday, ... Saturday
    day = Column(String, nullable=False)

    start_time = Column(String, nullable=False)  # e.g. "10:15"
    end_time = Column(String, nullable=False)    # e.g. "11:15"

    subject = Column(String, nullable=False)
    faculty = Column(String, nullable=True)
    room = Column(String, nullable=True)

    division = Column(String, nullable=False)

    # null batch = common lecture, applies to every batch in that division
    batch = Column(String, nullable=True)

    is_break = Column(Boolean, default=False)

    # A period the department's sheet prints as "RELM": a FREE PERIOD - free for
    # every class group of the division and claimable by a teacher. It is
    # deliberately its own flag rather than a lecture or a break, so nothing can
    # label it as either by accident (see official_data.FREE_PERIOD_SLOTS).
    is_free_period = Column(
        Boolean, default=False, nullable=False, server_default="0"
    )

    @property
    def entry_type(self) -> str:
        """Lecture / Practical / Free period / Break - derived from the columns.

        The rule comes straight from the timetable: an entry naming a batch
        (D1/D2/D3) is that batch's practical, an entry with no batch is a common
        lecture for the whole division, "RELM" is a free period, and the
        lunch/short breaks are breaks. Deriving it here keeps the label and the
        filtering from ever disagreeing.
        """
        if self.is_free_period:
            return "free_period"
        if self.is_break:
            return "break"
        return "practical" if self.batch else "lecture"


class Assignment(Base):
    __tablename__ = "assignments"

    id = Column(Integer, primary_key=True, index=True)

    subject = Column(String, nullable=False)

    title = Column(String, nullable=False)

    description = Column(String, nullable=True)

    due_date = Column(String, nullable=False)

    year = Column(Integer, nullable=False)

    division = Column(String, nullable=False)

    # null batch = assignment applies to the whole division
    batch = Column(String, nullable=True)

    # ---- optional PDF attachment -------------------------------------------
    # `stored_name` is a server-generated safe filename inside the upload
    # directory (never anything the client sent); `original_name` is kept only
    # for display. Everything below is NULL for text-only assignments, which is
    # what every pre-existing row is.
    stored_name = Column(String, nullable=True)
    original_name = Column(String, nullable=True)
    file_size = Column(Integer, nullable=True)

    uploaded_by = Column(Integer, ForeignKey("teachers.id"), nullable=True)
    created_at = Column(DateTime, nullable=True)

    uploader = relationship("Teacher", foreign_keys=[uploaded_by])

    @property
    def has_attachment(self) -> bool:
        return bool(self.stored_name)


class Subject(Base):
    """Official subject catalogue (name / short / code / faculty).

    Filled from the official timetable ONLY - see ``official_data.SUBJECTS``.
    """

    __tablename__ = "subjects"

    id = Column(Integer, primary_key=True, index=True)

    name = Column(String, nullable=False)
    short_name = Column(String, nullable=False, index=True)
    code = Column(String, nullable=True)
    faculty_code = Column(String, nullable=True, index=True)

    # theory | tutorial | practical
    kind = Column(String, nullable=False, default="theory")

    source = Column(String, nullable=False, default="official_timetable")

    __table_args__ = (
        UniqueConstraint("name", "kind", name="uq_subject_name_kind"),
    )


class FacultyMember(Base):
    """Faculty directory.

    Only values that exist in an official document are stored; every unknown
    field stays NULL and is rendered as "Not available" rather than guessed.
    """

    __tablename__ = "faculty_directory"

    id = Column(Integer, primary_key=True, index=True)

    short_code = Column(String, unique=True, index=True, nullable=False)
    full_name = Column(String, nullable=True)
    department = Column(String, nullable=True)
    email = Column(String, nullable=True)
    office = Column(String, nullable=True)
    phone = Column(String, nullable=True)
    role_note = Column(String, nullable=True)

    is_verified = Column(Boolean, default=False, nullable=False)
    source = Column(String, nullable=False, default="official_timetable")

    @property
    def display_name(self) -> str:
        """Never invent a name: fall back to the code printed on the sheet."""
        return self.full_name or self.short_code


class LabRoom(Base):
    """Room / laboratory directory (classroom and lab locations)."""

    __tablename__ = "lab_directory"

    id = Column(Integer, primary_key=True, index=True)

    name = Column(String, nullable=False)
    code = Column(String, nullable=True, index=True)
    room = Column(String, nullable=True)
    building = Column(String, nullable=True)
    floor = Column(String, nullable=True)
    subject = Column(String, nullable=True)

    # classroom | laboratory
    kind = Column(String, nullable=False, default="classroom")

    source = Column(String, nullable=False, default="official_timetable")
    is_verified = Column(Boolean, default=False, nullable=False)


class TeacherAssignment(Base):
    """A period a teacher is verified to teach.

    Rows are created by an admin (or seeded from the official timetable when a
    teacher's ``short_code`` matches a faculty code). Nothing is ever inferred
    from a name.
    """

    __tablename__ = "teacher_assignments"

    id = Column(Integer, primary_key=True, index=True)

    teacher_id = Column(Integer, ForeignKey("teachers.id"), nullable=False, index=True)

    subject = Column(String, nullable=False)
    subject_code = Column(String, nullable=True)

    division = Column(String, nullable=False, default="D")
    # "" = the whole division; "D-1"/"D-2"/"D-3" = one batch
    batch = Column(String, nullable=False, default="")

    # Optional period scope. Empty day = applies to every day the subject runs.
    day = Column(String, nullable=False, default="")
    start_time = Column(String, nullable=False, default="")
    end_time = Column(String, nullable=False, default="")

    # manual | timetable
    source = Column(String, nullable=False, default="manual")
    created_at = Column(DateTime, nullable=True)

    teacher = relationship("Teacher", back_populates="assignments")

    __table_args__ = (
        UniqueConstraint(
            "teacher_id",
            "subject",
            "division",
            "batch",
            "day",
            "start_time",
            "end_time",
            name="uq_teacher_assignment_slot",
        ),
    )


class AttendanceRecord(Base):
    """One student's attendance for ONE lecture/session.

    The unique constraint is what makes "no duplicate attendance for the same
    student and lecture" true at the database level, not just in the endpoint.
    """

    __tablename__ = "attendance_records"

    id = Column(Integer, primary_key=True, index=True)

    student_id = Column(Integer, ForeignKey("students.id"), nullable=False, index=True)

    subject = Column(String, nullable=False)
    division = Column(String, nullable=False, default="D")
    batch = Column(String, nullable=False, default="")

    # "YYYY-MM-DD"
    session_date = Column(String, nullable=False, index=True)
    slot_start = Column(String, nullable=False)
    slot_end = Column(String, nullable=False)

    # present | absent
    status = Column(String, nullable=False, default="present")

    marked_by = Column(Integer, ForeignKey("teachers.id"), nullable=False)
    marked_at = Column(DateTime, nullable=True)

    # Audit: who corrected the record last, and when. NULL while the record is
    # exactly as first saved.
    updated_by = Column(Integer, ForeignKey("teachers.id"), nullable=True)
    updated_at = Column(DateTime, nullable=True)

    student = relationship("Student", foreign_keys=[student_id])
    marker = relationship("Teacher", foreign_keys=[marked_by])
    updater = relationship("Teacher", foreign_keys=[updated_by])

    __table_args__ = (
        UniqueConstraint(
            "student_id",
            "session_date",
            "slot_start",
            "subject",
            name="uq_attendance_student_session",
        ),
    )


class Notification(Base):
    """One in-app message for one student.

    Rows are created by the backend when a teacher uploads an assignment, one
    per student who can see that assignment. ``is_read`` is the only mutable
    field: the message itself is a record of what was announced and is never
    edited afterwards.
    """

    __tablename__ = "notifications"

    id = Column(Integer, primary_key=True, index=True)

    student_id = Column(Integer, ForeignKey("students.id"), nullable=False, index=True)

    title = Column(String, nullable=False)
    message = Column(Text, nullable=False)

    is_read = Column(Boolean, default=False, nullable=False)

    created_at = Column(DateTime, nullable=False)

    student = relationship("Student", foreign_keys=[student_id])


class FcmToken(Base):
    """One Firebase Cloud Messaging device token, owned by one student.

    Push is a delivery channel, not a source of truth: the in-app
    ``notifications`` rows are still what the bell and the Notifications screen
    read. A row here only says "this phone belongs to this student right now".

    ``token`` is UNIQUE because FCM issues one token per app install and a
    token can only ever ring one phone. When the same phone is signed in as a
    different student, the row is re-pointed instead of duplicated (see the
    ``/notifications/device-token`` endpoint), so a handed-over phone never
    keeps receiving the previous student's alerts.

    Tokens die silently (reinstall, app data cleared, Play Services reset). A
    send that FCM rejects permanently deletes the row.
    """

    __tablename__ = "fcm_tokens"

    id = Column(Integer, primary_key=True, index=True)

    student_id = Column(Integer, ForeignKey("students.id"), nullable=False, index=True)

    token = Column(String, unique=True, index=True, nullable=False)

    created_at = Column(DateTime, default=datetime.utcnow, nullable=False)


class FreePeriodClaim(Base):
    """A period a teacher has claimed as free (no class of their own in it)."""

    __tablename__ = "free_period_claims"

    id = Column(Integer, primary_key=True, index=True)

    teacher_id = Column(Integer, ForeignKey("teachers.id"), nullable=False, index=True)

    # "YYYY-MM-DD"
    claim_date = Column(String, nullable=False, index=True)
    day = Column(String, nullable=False)
    start_time = Column(String, nullable=False)
    end_time = Column(String, nullable=False)

    division = Column(String, nullable=False, default="D")
    # "" = the whole division (never used for a batch practical)
    batch = Column(String, nullable=False, default="")
    subject = Column(String, nullable=True)

    created_at = Column(DateTime, nullable=True)

    teacher = relationship("Teacher", foreign_keys=[teacher_id])

    __table_args__ = (
        # One claim per teacher per date+slot: the same teacher cannot hold two
        # overlapping periods.
        UniqueConstraint(
            "teacher_id",
            "claim_date",
            "start_time",
            name="uq_claim_teacher_slot",
        ),
        # One claim per class group per date+slot: two teachers cannot claim the
        # same class and period.
        UniqueConstraint(
            "division",
            "batch",
            "claim_date",
            "start_time",            name="uq_claim_class_slot",
        ),
    )


class Announcement(Base):
    """One announcement a teacher or admin posted to the student feed.

    ``year`` and ``division`` are both optional: a NULL means "no restriction on
    this field", so a row with neither set is read by every student. That is
    how a college-wide notice is posted - there is no special "everyone" value,
    just an unrestricted row.

    Rows are append-only: nothing edits or deletes an announcement, so what a
    student read yesterday is still what the feed says today. ``author_id``
    points at the teacher account that posted it and is never taken from the
    client.
    """

    __tablename__ = "announcements"

    id = Column(Integer, primary_key=True, index=True)

    title = Column(String, nullable=False)
    message = Column(Text, nullable=False)

    author_id = Column(Integer, ForeignKey("teachers.id"), nullable=False, index=True)
    created_at = Column(DateTime, nullable=False)

    # NULL = not restricted to one year / one division.
    year = Column(Integer, nullable=True, index=True)
    division = Column(String, nullable=True)

    author = relationship("Teacher", foreign_keys=[author_id])

    @property
    def author_name(self) -> str:
        """The poster's name, or a neutral fallback if the account is gone."""
        return self.author.name if self.author is not None else "CampusSync"
