# CampusSync — Product Requirements Document (PRD)

> Status of this document: written from the **actual source code** on 2026-10-12
> (Flutter app in `lib/`, FastAPI backend in `backend/`). Every feature below is
> labelled **Implemented**, **Partial**, **Planned** or **Unverified**.
> It is not a wish list: nothing here is invented.

## 1. Purpose

CampusSync is a college companion app for a single first-year engineering
division. Students register with their roll number, wait for a teacher or admin
to approve the account, and then use the app for timetable, assignments and
their profile. Teachers/admins review pending registrations and manage accounts.

The student list is a **local registry embedded in the backend source**
(72 records, roll numbers 1–72, first year, Division D). It is *not* connected to
any official college database, and the app must not claim that it is.

## 2. Roles

| Role | How they sign in | What they can do |
| --- | --- | --- |
| Student | email + password (`POST /login`), only after approval | timetable, assignments, profile (+ local photo), log out |
| Teacher | email + password (`POST /teacher/login`) | review pending registrations, approve/reject them |
| Admin | same login; `role = "admin"` | everything a teacher can do, **plus** create teacher/admin accounts and list accounts |

Authorization is enforced **server-side**; the UI only hides what the API
refuses. See [SECURITY.md](SECURITY.md).

## 3. Student registration workflow — **Implemented**

1. Student opens *Student Registration* from the role picker.
2. Enters a roll number; the app calls `GET /students/lookup/{roll}` as the user
   types and shows the returned details.
3. The returned name, branch/course, year, division and batch are shown as
   **read-only** "Verified Student Details".
4. Student enters email, password, confirm password (Gmail-only email rule in
   the UI; passwords ≥ 6 characters, confirmation must match).
5. `POST /register` re-validates everything, looks the roll number up in the
   **server-side registry**, and stores the official details — client-supplied
   names/branches/status are ignored.
6. The account is created with `status = "pending"`; the student is **not**
   signed in. The screen pops back and shows "Registration submitted for
   approval…".
7. A teacher or admin approves or rejects the request in the Teacher Panel.
8. Only an `approved` student can log in and reach protected endpoints.

Evidence: `backend/tests/test_backend_security.py` sections 1–3, 7.

## 4. Feature inventory

### 4.1 Implemented and verified

| Feature | Notes |
| --- | --- |
| Roll-number lookup | `GET /students/lookup/{roll_number}`, registry-driven |
| Student registration | pending-by-default, duplicate/eligibility checks, hashed password |
| Student login / logout | token issued, one active session per student |
| Student session validation at startup | `GET /me`; 401/403 clears, unreachable fails closed |
| Student approval / rejection | teacher/admin, records `approved_by` + `approved_at` / `rejection_reason` |
| Teacher login / logout / session validation | `GET /teacher/me` before the panel opens |
| Admin identification | `role` from the authenticated teacher record (server-side) |
| Admin-only account creation | `POST /teacher/create`, admin token required, password policy enforced |
| Admin-only account list | `GET /teacher/list` |
| Teacher access to approvals | `GET /teacher/registrations/pending`, approve/reject |
| Timetable viewing | `GET /timetable` (division + batch filtered) |
| Assignment viewing | `GET /assignments` (+ 5-minute in-memory cache) |
| Profile viewing | name/roll/course/year/division/batch from stored session |
| Profile photo (device-local) | picked with `image_picker`, path kept in secure storage |
| Credential separation | student keys and `teacher_*` keys are distinct; clearing one never clears the other |
| Teacher password policy | ≥ 8 chars, ≥ 1 letter, ≥ 1 digit (client **and** server) |
| Student password policy | ≥ 6 chars (client **and** server) |

### 4.2 Partial

| Feature | What is missing |
| --- | --- |
| Home dashboard | `lib/home_page.dart` renders **static** cards ("Today's Schedule" → "C Programming"); it makes no network call. Real timetable data is only on the Timetable tab. |
| Profile photo | Stored **only** on the device, as the path returned by `image_picker` (an app cache path that the OS may purge). The backend never sees it, and the `students.photo_path` column is unused. |
| Logout (student) | Now revokes the token via `POST /logout` (best effort) and always clears local data. |
| Teacher Panel | No account deactivate/reactivate, no password reset, no pagination/search in the account list. |
| Error messages | Network/validation errors surface as snackbars; there is no offline/retry screen for the student side. |

### 4.3 Planned / not implemented (do not document as working)

* Assignment **upload** (teacher side) — no endpoint and no client code exist.
* File/attachment handling of any kind.
* Password reset / forced password change.
* Teacher account deactivation.
* Push notifications, attendance, marks, chat.
* Multi-division or multi-year support (registry and eligibility checks are
  hard-coded to first year, Division D).
* Offline mode (the only cache is the 5-minute in-memory assignment cache).

### 4.4 Unverified (needs a real device + live backend)

* Behaviour of `image_picker` on the user's phone (gallery permissions).
* Real ngrok latency/timeouts against the deployed backend.
* Anything that needs a real approved student account created through the UI.

## 5. Non-goals

* No database migration away from SQLite.
* No change to the light-blue glassmorphism design language
  (see [DESIGN_SYSTEM.md](DESIGN_SYSTEM.md)).
* No performance/load testing in this phase.

## 6. Success criteria for the current milestone

1. A new student can register, be approved by a teacher, and sign in.
2. A pending or rejected student cannot reach protected endpoints.
3. A regular teacher cannot create accounts or list them (403 from the API).
4. An admin can create a teacher account with a strong password, and weak
   passwords are refused by the server.
5. No test regressions: `flutter analyze`, `flutter test` and the backend suite
   all pass.
