# CampusSync — Security

Everything below was inspected in the source on 2026-10-12. Findings are split
into **verified by execution** (backend suite / Flutter suite), **verified by
inspection**, and **open risks / recommendations**.

## 1. Authentication

| Aspect | Implementation |
| --- | --- |
| Token type | opaque `secrets.token_hex(32)` — not JWT, no signature |
| Transport | `Authorization: Bearer <token>` |
| Storage (server) | `students.token`, `teachers.token` (UNIQUE) |
| Storage (client) | `flutter_secure_storage` (Android Keystore / encrypted prefs) |
| Expiry | `utcnow() + TOKEN_EXPIRATION_DAYS` (default 7), checked on every request |
| Sessions per account | **one** — every login overwrites the token, so an older token dies immediately |
| Expiry handling | expired token is cleared server-side and returns 401 |
| Logout | `POST /logout` (student) and `POST /teacher/logout` clear only that account's token |

Passwords are hashed with `pwdlib.PasswordHash.recommended()` (argon2) and are
never returned by any endpoint *(verified by test: `POST /teacher/create`
responses contain no `password` key, and stored values are not the plaintext)*.

## 2. Password policy

| Role | Rule | Enforced |
| --- | --- | --- |
| Student | ≥ 6 characters | client (`login_page.dart`) **and** server (`StudentRegister` validator) |
| Teacher/Admin | ≥ 8 characters, ≥ 1 letter, ≥ 1 digit | client (`create_teacher_dialog.dart`) **and** server (`TeacherCreate` validator, added 2026-10-12) |

Until this review the teacher rule existed **only** in Flutter, so a direct API
call could create an account with a 1-character password. The server-side
validator closes that gap; weak requests now return **422** and create no account
*(verified by test)*.

## 3. Authorization matrix — verified by execution

`backend/tests/test_backend_security.py` (130 checks, all passing) proves:

* `/me`, `/timetable`, `/assignments` without a token → **401**; with a bogus
  token → **401**; with a pending or rejected student's token → **403**.
* `/teacher/me`, `/teacher/list`, `/teacher/create`,
  `/teacher/registrations/*` with a **student** token → **401**.
* `/teacher/list` and `/teacher/create` with a **regular teacher** token →
  **403**; an escalation attempt creates no account.
* An **inactive** teacher's stored token is refused → **403**.
* `/teacher/registrations/pending` and approve/reject work for both teacher and
  admin (matching `require_teacher_or_admin`).
* Approving twice, rejecting an approved row, and processing a rejected row all
  → **400**; unknown ids → **404**.
* Admin checks are done by the backend (`require_admin`), not by hiding buttons.
* `GET /health` answers **200 without a token** and returns exactly
  `{status, service}` — no version, path or configuration — while `GET /` keeps
  its original response. It reads no database, so it leaks no schema state.

### 3a. Assignment PDFs (student side, 2026-10-13)

* A student reads the PDF through `GET /assignments/{id}/file` with their own
  bearer token; there is no public, unauthenticated or guessable file URL, and
  the response is authorized per year/division/**stored** batch on the server.
* Reading never writes to the device: the viewer holds the bytes in memory only.
  The single code path that saves a copy is the Download button, which writes to
  the device's Downloads location (Android MediaStore, or the system Save dialog
  where MediaStore is unavailable).
* Temporary viewer state and intentional downloads are separate: nothing is
  written to a shared or cache folder while reading, and the app never stores
  the token or any account detail in a file name or PDF metadata (the viewer's
  source name is `assignment-<id>.pdf`).

Client-side gating (`_teacher?.isAdmin == true` before rendering the management
section, and a test asserting a regular teacher never even *calls* the admin
endpoints) is convenience on top of that.

## 4. Credential separation

Student keys (`auth_token`, `token_expiry`, `student_id`, `name`, `email`,
`roll_number`, `branch`, `year`, `division`, `batch`, `college`, `photo_path`)
and teacher keys (`teacher_auth_token`, `teacher_token_expiry`, `teacher_id`,
`teacher_name`, `teacher_email`, `teacher_role`) are disjoint.

* `AuthService.clearAuthData()` deletes only student keys.
* `TeacherAuthService.clearAuthData()` deletes only teacher keys — it previously
  called `deleteAll()`; that was fixed in an earlier task.
* *(verified by test)* a teacher 401/expiry never disturbs a stored student
  session, and student logout never disturbs a teacher session.

## 5. Secrets

| Item | State | Guidance |
| --- | --- | --- |
| Admin password | supplied at bootstrap time via the `ADMIN_PASSWORD` environment variable, ≥ 12 chars, never hard-coded, never printed | keep it out of shell history; `backend/bootstrap_admin.py` was **not** executed during this review |
| Admin password (reset) | supplied through the `NEW_ADMIN_PASSWORD` environment variable, ≥ 12 chars, read from the environment and hashed with the same `pwdlib` (argon2) hasher as login; the value and its hash are never printed | offline, operator-only: `backend/reset_admin_password.py` changes **only** the `password` column of the existing `admin@campusync.edu` row and refuses if that account is missing, not an `admin`, or deactivated — it never creates accounts or touches student rows. Run it with `--dry-run` first. Not executed against the real database during this review |
| `SECRET_KEY` (`config.py`) | default value `campussync-dev-secret-key-change-in-production`, **never read anywhere in the backend** | dead configuration — either delete it or document that it is unused; do not treat it as a signing key |
| `.env` files | exist at the repo root and in `backend/`, and were **not** read, printed or modified | remain the source of local config |
| `.gitignore` | now ignores `.env`, `*.db`, `venv/`, `build/` (added 2026-10-12) | prevents a future `git init` from committing DBs and secrets |
| Logs | no `print`/`logging` of passwords or tokens anywhere in `backend/`; the Flutter code has no `print` in the auth/teacher paths | keep it that way |

## 6. Open risks and recommendations

Ordered by value. None of these were changed during the review except where noted.

1. **`migrate_db.py` mass-approved pending students.** *(measured, **fixed**)*
   The old script ran a blanket
   `UPDATE students SET status='approved' WHERE status='pending'`, approving
   brand-new registrations as "backward compatibility" (verified on a temporary
   copy — [DATABASE.md](DATABASE.md) §4). **Fixed in this review:** the script
   is now additive-only, never changes a status without explicit `--approve-legacy-ids`,
   and refuses (all-or-nothing) on any dirty id. Because `students` has no
   timestamp column, a legacy row and a new pending row are byte-for-byte
   identical, so the script **reports the ambiguity instead of guessing**.
   *(verified by test: `backend/tests/test_migrate_db_safety.py`, incl. an AST
   source guard against a blanket UPDATE returning)*
2. **Registry disclosure without authentication.** *(partly fixed)*
   `GET /students/lookup/{roll}` previously returned the official **full name**,
   branch, year, division and batch for rolls 1–72 to anyone, and the Flutter UI
   called it on **every keystroke**. **Fixed in this review:** the response now
   carries only a **masked name** (initials) plus the eligibility fields, the
   client debounces keystrokes, and the endpoint is rate limited per client IP
   (`LOOKUP_RATE_LIMIT_PER_MINUTE`, default 120/min → `429` + `Retry-After`).
   The endpoint remains unauthenticated on purpose (first-time registration
   needs it) and roll numbers are still enumerable in principle — a successful
   lookup is **not** identity proof and approval by a teacher/admin is still the
   gate. Stronger options (a shared registration token, CAPTCHA) remain open.
   *(verified by test: `backend/tests/test_lookup_privacy.py`, incl. the full
   register→approve→login flow and a Flutter widget suite)*
3. **CORS default is `*` with `allow_credentials=True`.** The effective value
   comes from `ALLOWED_ORIGINS` in `.env` (not a bare wildcard), but the code
   default is permissive. Since auth is a Bearer header (not cookies), impact is
   limited; still, keep `ALLOWED_ORIGINS` explicit in every environment.
   *(inspection)*
4. **Server-side logout was missing on the student side** — the app only cleared
   local data, so a token stayed valid up to 7 days after "Log Out".
   **Fixed in this review:** `AuthService.logout()` calls `POST /logout`
   (best effort) and always clears local credentials; `profile.dart` uses it.
   *(verified by test on the client side; the endpoint behaviour is verified by
   the backend suite)*
5. **Profile photo path points into the app cache.** `image_picker` returns a
   file in a cache directory; only that path is stored, so the OS may purge the
   image. Fix: copy the picked file into the app documents directory before
   saving the path — this needs `path_provider` and is therefore **not applied**
   pending your approval of a new dependency. *(inspection)*
6. **Wrong login error text for pending/rejected students.** The 403 body is
   `{"detail": …}` only, but the student login read just `message`, so the user
   saw "Invalid email or password". **Fixed in this review** (fall back to
   `detail`). *(inspection of the fix; the 403 body shape is verified by the
   backend suite)*
7. **Dead code with latent bugs:** `lib/services/api_client.dart` is unused but
   would, on a 401, clear **student** credentials regardless of which role made
   the call and navigate to a named route `'/'` that does not exist in
   `main.dart`. Delete it or fix it before use. `lib/data/student_database.dart`
   (15 KB) is an unused copy of the registry — a second source of truth that
   should be deleted. *(inspection)*
8. **Duplicate route definitions** in `main.py` (`/me`, `/timetable`,
   `/teacher/me` defined twice, identical) are unreachable dead code. No security
   impact; remove for clarity. *(inspection)*
9. **No rate limiting, lockout or CAPTCHA** on `/login`, `/teacher/login`.
   `/students/lookup/{roll}` **is now rate limited** (in-process
   `SlidingWindowLimiter`, `backend/ratelimit.py`, `LOOKUP_RATE_LIMIT_PER_MINUTE`);
   `/login` and `/teacher/login` are not. A single-process limiter is fine for
   the current single-instance setup; behind multiple workers use a
   reverse-proxy / shared-store limit. *(inspection; lookup limit verified by
   test)*
10. **No deactivation or forced rotation** for accounts, and the API still has
    no endpoint to change a password (deliberate: an unauthenticated or
    weakly-guarded reset endpoint is a bigger risk than the offline path).
    **Partly addressed:** an operator-run script,
    `backend/reset_admin_password.py`, resets the password of the existing
    `admin@campusync.edu` account from the `NEW_ADMIN_PASSWORD` environment
    variable (≥ 12 chars, hashed with the backend's `pwdlib`/argon2 hasher). It
    refuses to create an account, to touch a non-admin or deactivated account,
    and to touch student rows; it prints the resolved database path and never
    the password or its hash. Deactivation and self-service rotation remain
    planned work. *(verified by test:
    `backend/tests/test_admin_password_reset.py`; the script itself was not run
    against the real database)*
11. **`DEBUG=True` is the config default** and `uvicorn` runs without TLS in
    development; the app relies on ngrok for HTTPS in the deployed setup.
    Ensure production runs with `DEBUG=False` and a real TLS terminator.
    *(inspection)*

## 7. Upload security requirements (for when uploads are added)

There is **no** upload functionality today (no `MultipartRequest`, no
`File`/`UploadFile` handling, no storage bucket). When assignment uploads are
implemented, the following are required:

1. Authenticate and authorize the uploader server-side (teacher/admin only).
2. Enforce a maximum request size and a content-length check *before* reading
   the body; stream to disk instead of buffering in memory.
3. Validate the **MIME type and magic bytes**, not just the file extension; allow
   an explicit allow-list (pdf, docx, images) and never trust the client's
   `Content-Type`.
4. Store files outside the code tree with a generated name (never the client's
   filename), and reject path traversal (`..`, absolute paths).
5. Serve downloads through an authenticated route that re-checks ownership; do
   not expose a directory listing or a guessable public path.
6. Scan or at least quarantine on a size/type basis; log uploads without logging
   tokens or personal data.
7. Keep the file metadata in SQLite (assignment id, uploader id, size, hash) so
   orphaned files can be found and cleaned.

## 8. Verification limits of this review

* No penetration testing, load testing or fuzzing was performed (explicitly out
  of scope for this phase).
* Server-side behaviour is verified against a **throwaway** SQLite database; the
  real database and the live ngrok backend were never contacted.
* `backend/backend/test_integration.py` (live-server script that creates real
  students) was **not** executed.

## 9. Teaching features (2026-10-13)

Controls added, and what remains open:

* **Registration approvals are a permission, not a screen.** `can_approve_registrations`
  is a column, granted/changed only by an admin through
  `PATCH /teacher/{id}/permissions`; `require_registration_reviewer` enforces it
  server-side, so hiding a button is never the only control. Admins always may.
* **Attendance is assignment-checked.** A teacher can only save attendance for a
  subject/class/period the backend can match to a verified assignment; a
  duplicate (student, date, period, subject) is impossible at the database level
  (unique index) and a correction records `updated_by`/`updated_at`.
* **Free periods are computed, never assumed.** Availability comes from the
  official grid plus existing claims; a practical for one batch never makes a
  period "free" for the whole division, and a claim is re-validated at save time
  against two unique constraints.
* **Uploads.** PDFs are checked by magic bytes as well as content type, capped at
  `MAX_ASSIGNMENT_FILE_MB` (default 10), stored under a server-generated
  UUID name, and downloaded only through an authorized route that re-checks the
  student's year/division/batch (or the uploader/admin). The client's filename is
  kept for display only and is stripped of path separators and control
  characters.
* **No fabricated directory data.** The Faculty Finder shows exactly the codes and
  subjects printed on the official timetable; every unknown field (full names,
  e-mail, office, phone) is `NULL` and rendered as "Not available". The Lab
  Finder contains only classroom M308 (Block-11) - no laboratory location exists
  in the source document.
* **Free periods are free, and only free.** A teacher may claim a period only
  when the server says no class group is scheduled in it, no colleague is
  assigned to that period, and nobody (including the caller) has claimed that
  slot for that date yet. The five `RELM` periods are the periods this exists
  for; every failure is answered with `409` (or `400` for a past date) and a
  reason. Simultaneous claims are resolved by unique constraints in the
  database, so a race can produce one winner and one "already claimed" message,
  never two claims.
* **Who may claim.** Any authenticated, active teacher account - i.e. one an
  administrator created through `POST /teacher/create`; there is no public
  teacher sign-up and no extra per-teacher free-period permission to grant. A
  student token never resolves to a teacher, so it is refused (`401`), and a
  deactivated account is refused (`403`). A free period is a **whole-division**
  slot: it is claimed with an empty batch, and a per-batch request is refused, so
  D-1/D-2/D-3 cannot each hold the same free period.
* **No retrospective claims.** A free period in the past cannot be claimed: the
  date is compared with today on the college clock (IST, UTC+05:30) and refused
  with `400` and an explanation.
* **Still open:** laboratory room/building/floor data, full faculty names and
  contact details, whether Monday's last period is a sixth free period, no rate
  limiting on `/login` or `/teacher/login`, and no virus scanning of uploads
  (type/size only).
