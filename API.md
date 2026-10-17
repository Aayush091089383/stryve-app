# CampusSync — API Reference

Base URL comes from `lib/config/environment.dart` (`BACKEND_URL`, default the
current ngrok host) and is served by the FastAPI app in `backend/main.py`.

* Auth header: `Authorization: Bearer <token>` (opaque token, see
  [SECURITY.md](SECURITY.md)).
* Content type: `application/json` for all request bodies.
* Error bodies:
  * `{"detail": "<message>", "code": "<CODE>"}` for `CampusSyncException`
    (`AUTHENTICATION_FAILED`, `TOKEN_EXPIRED`, `DUPLICATE_EMAIL`,
    `DUPLICATE_ROLL_NUMBER`, `NOT_FOUND`).
  * `{"detail": "<message>", "code": "VALIDATION_ERROR"}` for **422** pydantic
    validation (only the first error is returned).
  * plain `{"detail": "<message>"}` for `HTTPException` raised in handlers.
* Tokens expire after `TOKEN_EXPIRATION_DAYS` (default **7**). Each login
  replaces the previous token, so only one session per account is valid.

Legend: **🔓** no auth · **🎓** approved student · **👩‍🏫** teacher or admin ·
**🛡️** admin only.

---

## Public

### 🔓 `GET /`
Root banner. → `200 {"message": "CampusSync backend is running!"}`

### 🔓 `GET /health` (added 2026-10-13)
Liveness probe for a tunnel, proxy or uptime monitor.
→ `200 {"status": "ok", "service": "CampusSync backend"}`

The body carries those two keys and nothing else: no version, no paths, no
configuration, no credential hints. It needs no token (a monitor cannot log in)
and deliberately **does not touch the database**, so it cannot fail - or write
anything - because of schema or data state, and it can never be used to probe
whether a database exists.

### 🔓 `POST /register`
Creates a **pending** student registration. Official details are taken from the
server-side registry; anything the client sends for name/branch/status is
ignored.

Request `StudentRegister`:

| field | type | rules |
| --- | --- | --- |
| `roll_number` | string | must exist in the registry, roll 1–72 |
| `email` | string (EmailStr) | unique |
| `password` | string | ≥ 6 characters (`field_validator`) |
| `confirm_password` | string | must equal `password` |

→ `201 StudentRegisterResponse {message, student_id, status: "pending"}`

Errors: `400` passwords do not match · `400` not first year · `400` not Division D ·
`404` roll number not in registry · `409 DuplicateEmailError` · `409 DuplicateRollNumberError` ·
`422` validation.

### 🔓 `GET /students/lookup/{roll_number}`
→ `200 {roll_number, masked_name, branch, year, division, batch}`
(`StudentLookupResponse`)

Errors: `404` unknown roll · `400` not first year / not Division D ·
`429` too many lookups (with a `Retry-After` header).

> 🔒 The official **name is deliberately not returned** — only a masked form
> (initials; `backend/privacy.py`), so anonymous callers cannot harvest the
> registry from the public endpoint. The full name is shown to staff in the
> approval queue and to the student after login.
>
> The endpoint stays unauthenticated on purpose: a first-time student must
> confirm their roll number before they can register. It is rate limited
> (`LOOKUP_RATE_LIMIT_PER_MINUTE`, default 120/min per client IP; set `0` to
> disable) — see [SECURITY.md](SECURITY.md) — Registry disclosure.
>
> A successful lookup proves **only** that the roll number is in the registry.
> It is **not** identity verification; teacher/admin approval remains the gate
> that grants access.

### 🔓 `POST /login`
Request `StudentLogin {email, password}`.

→ `200 TokenResponse {message: "Login successful", student_id, name, email,
roll_number, branch, year, division, batch, token, token_expires_at}`

Errors: `401` wrong email/password · `403 {"detail": "Your account is pending
approval or has been rejected. Please contact administration."}`

> Note for clients: the 403 body carries **`detail` only** — there is no
> `message` key on failures.

---

## Student (🎓 approved)

### 🎓 `POST /logout`
Invalidates the caller's token (`token`/`token_expires_at` → NULL).
→ `200 {"message": "Logged out"}` · `401` if the token is invalid/expired.

### 🎓 `GET /me`
→ `200 StudentOut {id, name, email, roll_number, branch, year, division, batch,
status, approved_by, approved_at, rejection_reason}`

`401` bad/expired token · `403` if the account is not approved.

### 🎓 `GET /timetable`
Entries for the caller's division, including division-wide rows (`batch = null`)
and rows for the caller's batch. The batch always comes from the authenticated
student's stored record.
→ `200 list[TimetableEntryOut {id, day, start_time, end_time, subject, faculty,
room, batch, is_break, is_free_period, entry_type}]` · `401`/`403`.

`entry_type` is `lecture` (no batch = whole division), `practical` (batch
specific), `break` or `free_period`. The five free periods (`RELM`) are **never
returned** here: a free period has no class to attend, so it belongs to the
teacher's Claim Free Period screen only. Students also never receive
`entry_type = "free_period"`, and no such period can be made to appear by any
query parameter.

### 🎓 `GET /assignments`
Assignments for the caller's year + division (division-wide or own batch),
ordered by `due_date`.
→ `200 list[AssignmentOut {id, subject, title, description, due_date, year,
division, batch, has_attachment, original_name}]` · `401`/`403`.

### 🎓 `GET /assignments/{id}/file` — read it, then download it
Returns the attached PDF (`application/pdf`) only when the caller may see that
assignment: a student must match its year/division and, for a batch assignment,
their own stored batch; a teacher may read what they uploaded; admins anything.
→ `200` PDF · `401` · `403 You are not permitted to download this assignment` ·
`404 This assignment has no attached file` / `The stored file is no longer available`.

Client contract (added 2026-10-13): the Flutter app fetches this endpoint into
memory to **show** the PDF and never writes a file while doing so. The only code
path that saves a copy is the viewer's Download button, which writes to the
device's own Downloads location. There is still no public or unauthenticated
file URL, and the app never caches the PDF to a shared folder in the background.

---

## Teacher / Admin

### 🔓 `POST /teacher/login`
Request `TeacherLogin {email, password}`.
→ `200 TeacherTokenResponse {message, teacher_id, name, email, role, token,
token_expires_at}` · `401` invalid credentials · `403` deactivated account.

### 👩‍🏫 `POST /teacher/logout`
→ `200 {"message": "Logged out"}` · `401`.

### 👩‍🏫 `GET /teacher/me`
→ `200 TeacherOut {id, name, email, role, is_active, created_at}`
· `401` bad/expired token · `403` inactive account.

### 👩‍🏫 `GET /teacher/registrations/pending`
→ `200 list[PendingStudentOut {id, name, email, roll_number, branch, year,
division, batch, status}]` (pending only, ordered by id).
No password fields are exposed *(verified by test)*. · `401`/`403`.

### 👩‍🏫 `POST /teacher/registrations/{student_id}/approve`
Body: `{}` (`ApproveRequest`).
→ `200 ApprovalActionResponse {message, student_id, status: "approved"}`
Sets `status`, `approved_by`, `approved_at` and clears `rejection_reason`.

Errors: `400` not pending (already approved/rejected) · `404` unknown student ·
`401`/`403`.

### 👩‍🏫 `POST /teacher/registrations/{student_id}/reject`
Body: `{"reason": "optional text"}` (`RejectRequest`).
→ `200 ApprovalActionResponse {message, student_id, status: "rejected"}`
Stores `rejection_reason` (null when omitted), plus `approved_by`/`approved_at`.

Errors: `400` not pending · `404` unknown student · `401`/`403`.

### 🛡️ `POST /teacher/create`
Request `TeacherCreate`:

| field | type | rules |
| --- | --- | --- |
| `name` | string | |
| `email` | string (EmailStr) | unique |
| `password` | string | **≥ 8 characters, ≥ 1 letter, ≥ 1 digit** (server-side, added 2026-10-12) |
| `role` | string | `"teacher"` or `"admin"` |

→ `200 TeacherOut {id, name, email, role, is_active, created_at}` (password is
stored with `pwdlib` argon2 hashing and is never returned).

Errors: `400` invalid role · `409` email already registered (`{"detail": "Email
already registered"}` or a conflict message) · `422` weak password/validation
(the message names the rule) · `403` non-admin caller · `401` no/invalid token.

### 🛡️ `GET /teacher/list`
→ `200 list[TeacherOut]` ordered by id · `403` non-admin · `401`.

---

## Contract notes verified by tests

* A pending or rejected student token gets **403** on `/me`, `/timetable` and
  `/assignments`; a student token on a teacher route gets **401**.
* A regular teacher token gets **403** on `/teacher/list` and `/teacher/create`;
  an admin token succeeds.
* An inactive teacher's token is refused with **403**.
* Weak teacher passwords return **422** and create **no** account.
* `POST /logout` invalidates only the caller's token; the other role's session
  keeps working.

## Code-quality note (not a contract difference)

`backend/main.py` defines three routes twice: `/timetable` (line 303 and 644),
`/me` (465 and 664) and `/teacher/me` (473 and 672). The implementations are
identical and FastAPI serves the **first** registration, so the later copies are
unreachable dead code. Removing them changes no behaviour; it was left in place
during this review to avoid touching working code.

## Missing endpoints (do not assume they exist)

No password reset, no teacher deactivation, no pagination, no per-assignment
progress tracking, no student photo endpoint. Health/diagnostics are limited to
`GET /` and `GET /health` (both liveness only - neither reports database state).

## Teaching features added 2026-10-13

All of these require a teacher/admin token unless stated otherwise, and every
permission is decided by the backend from the authenticated account.

| Method | Path | Who | Notes |
| --- | --- | --- | --- |
| GET | `/timetable` | student | unchanged route, now also returns `entry_type` (`lecture`/`practical`/`break`) and is filtered strictly by the batch **stored on the account** |
| GET | `/assignments` | student | unchanged route; a missing/unreadable stored batch now yields division-wide assignments only |
| GET | `/teacher/registrations/pending` | admin, or a teacher with `can_approve_registrations` | **changed**: a regular teacher without the permission now gets 403 |
| POST | `/teacher/registrations/{id}/approve` | same as above | **changed** in the same way |
| POST | `/teacher/registrations/{id}/reject` | same as above | **changed** in the same way |
| PATCH | `/teacher/{id}/permissions` | admin | sets `can_approve_registrations` and/or the official `short_code`; linking a code records the teacher's verified periods |
| GET | `/teacher/assignments` | teacher/admin | the caller's own verified teaching assignments (may be empty) |
| GET | `/teacher/{id}/assignments` | admin | one teacher's assignments |
| POST | `/teacher/{id}/assignments` | admin | add an assignment (409 on duplicate) |
| DELETE | `/teacher/{id}/assignments/{assignment_id}` | admin | remove one assignment row |
| GET | `/teacher/classes?division=&batch=` | teacher/admin | approved students of a class group |
| GET | `/teacher/attendance?subject=&division=&batch=&session_date=&slot_start=&slot_end=` | teacher/admin | saved attendance for one lecture |
| POST | `/teacher/attendance` | teacher/admin | save/correct one lecture; 403 unless assigned (admins excepted), 400 for an invalid slot/date/student, 409 on a concurrent save |
| GET | `/teacher/free-periods?date=YYYY-MM-DD` | teacher/admin | periods marked free/busy/claimed for the caller, computed from the official grid + existing claims. Each slot carries `is_free_period` for the five `RELM` periods; a period the caller teaches, a period with a class in it, a period another teacher is assigned to and a period already claimed are all reported as *not* eligible, each with its own reason. The reply also carries `can_claim_free_periods` (true for any authenticated, active teacher account - no per-teacher grant) and `has_verified_assignments` (whether the caller's own classes are known). Default date = today on the college clock (IST) |
| GET | `/teacher/free-periods/claims` | teacher/admin | the caller's claims |
| POST | `/teacher/free-periods/claim` | teacher/admin | claim one period. A free period (`RELM`) is **one division-wide slot**: send `batch: ""`, and the claim then reserves the whole of Division D for that date and time (a per-batch request is refused). `400` for a past date (judged on the college clock, IST) or a slot outside the official grid; `409` when the slot is taken, already claimed, taught by the caller or assigned to another teacher; `403` when the account may not claim |
| DELETE | `/teacher/free-periods/claims/{id}` | owner or admin | release a claim |
| POST | `/teacher/assignments/upload` | teacher/admin | multipart PDF upload (title, subject, due_date, year, division, batch, description, file) |
| GET | `/teacher/assignments/mine` | teacher/admin | assignments the caller uploaded |
| DELETE | `/teacher/assignments/{id}` | uploader or admin | removes an uploaded assignment and its file (never a pre-existing row) |
| GET | `/assignments/{id}/file` | student or teacher token | the attached PDF, only for the year/division/batch allowed to see it |
| GET | `/faculty?q=` | any signed-in account | official faculty records, searchable by name/code/subject |
| GET | `/labs?q=` | any signed-in account | recorded rooms/laboratories |
| GET | `/directory/status` | any signed-in account | record counts plus the list of source data still missing |

Error shape is unchanged: `{"detail": ..., "code": ...}`.
