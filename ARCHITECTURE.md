# CampusSync — Architecture

Verified against the source on 2026-10-12. Where something is inferred rather
than executed, it is marked *(inspection)* / *(verified by test)*.

## 1. Shape of the system

```
Flutter app (Android + Windows)
  lib/main.dart            MaterialApp + theme, home = AuthCheckPage
  lib/role_selection_page  role picker (student / teacher)
  lib/login_page.dart      student login + student registration screens
  lib/teacher_login_page   teacher/admin login
  lib/home_page.dart       3 tabs: Home, Tasks, Profile (student)
  lib/teacher_panel_page   approvals + admin-only account management
  lib/create_teacher_dialog admin-only create-account form
  lib/services/*           auth services, ApiClient (unused), ApiCache
  lib/config/environment   backend URL (dart-define BACKEND_URL)
        |
        | HTTPS + Bearer token
        v
FastAPI app  backend/main.py   (single module, all routes)
   models.py     SQLAlchemy 2.1 declarative models
   schemas.py    pydantic v2 request/response models
   auth.py       token creation + FastAPI auth dependencies
   database.py   engine / SessionLocal / Base
   dependencies  get_db() session per request
   exceptions    typed errors -> HTTP status + error code
        |
        v
SQLite file  ./campussync.db  (path is RELATIVE TO THE PROCESS CWD - see DATABASE.md)
```

## 2. Backend request flow

1. Uvicorn serves `main.app`.
2. `Base.metadata.create_all(bind=engine)` runs at import, so missing tables are
   created automatically *(inspection; this is why the app starts on a fresh DB)*.
3. A route declares its authorization with a dependency:
   * `Depends(get_current_student)` — any approved student,
   * `Depends(get_current_teacher)` — any active teacher/admin,
   * `Depends(require_teacher_or_admin)` — teacher **or** admin,
   * `Depends(require_admin)` — admin only.
4. Handlers use `Depends(get_db)`, a per-request SQLAlchemy session.
5. Errors are raised as `HTTPException`/`CampusSyncException`; two exception
   handlers convert them to `{"detail": …, "code": …}`. Pydantic
   `RequestValidationError` becomes **422** with the first message and
   `code: "VALIDATION_ERROR"`.

## 3. Authentication model

* **Opaque tokens**, not JWT: `secrets.token_hex(32)` (`auth.generate_token`).
* Stored in the `students.token` / `teachers.token` columns (UNIQUE).
* Expiry: `utcnow() + TOKEN_EXPIRATION_DAYS` (default 7) in
  `token_expires_at`.
* **One active session per account**: every login overwrites the token, so an
  older token stops working immediately *(verified by test)*.
* The client sends `Authorization: Bearer <token>`.
* Expired tokens are cleared server-side when used, and return 401.
* `SECRET_KEY` in `config.py` is **not used anywhere** — there is no signature to
  compute for opaque tokens.

## 4. Client session handling

| Situation | Behaviour |
| --- | --- |
| App start | `AuthCheckPage` → `AuthService.validateSession()` (`GET /me`) for students, then `TeacherAuthService.validateSession()` (`GET /teacher/me`) |
| 200 | open Home / Teacher Panel |
| 401 / 403 | clear that role's stored credentials → role picker / teacher login |
| network error or 5xx | **fail closed** (no screen opened) but credentials are kept so the user can retry |
| locally expired stored token | treated as no session; never calls the network |
| 401 from a screen request | that screen clears its own role's credentials and navigates to the right login/role screen |

Student keys (`auth_token`, `token_expiry`, `student_id`, …) and teacher keys
(`teacher_auth_token`, `teacher_token_expiry`, `teacher_id`, …) are disjoint;
`clearAuthData()` in each service touches only its own set *(verified by test)*.

## 5. Dependency injection seams (for tests)

Production code behaves exactly as before; tests inject mocks through optional
constructor parameters that default to `null`:

* `AuthService({http.Client? client})`
* `TeacherAuthService({http.Client? client})`
* `TeacherPanelPage({TeacherAuthService? authService, http.Client? client})`
* `AuthCheckPage({AuthService? studentAuthService, TeacherAuthService? teacherAuthService})`
* `showCreateTeacherDialog(context, client:, authService:)`

Screens that still build their own services inline and therefore have **no**
test seam: `LoginPage` (student login/registration), `TeacherLoginPage`,
`ProfilePage`, `TasksPage`, `TimetablePage`, `HomePage`. Their network paths are
covered indirectly (backend contract tests) but not by widget tests.

## 6. Data flow examples

**Registration**

```
Flutter roll input -> GET /students/lookup/7 -> {name, branch, year, division, batch}  (read-only UI)
Flutter -> POST /register {roll_number, email, password, confirm_password}
backend -> validates, looks up registry, hashes password, inserts status="pending" -> 201
```

**Approval**

```
Teacher Panel -> GET /teacher/registrations/pending        (teacher or admin)
             -> POST /teacher/registrations/{id}/approve   -> status=approved, approved_by, approved_at
             -> re-reads the pending list (never optimistic)
```

**Admin account creation**

```
Teacher Panel (admin role only) -> showCreateTeacherDialog
   -> client-side validation (name, email, password strength, role)
   -> confirmation dialog
   -> POST /teacher/create {name, email, password, role}
   -> 200 TeacherOut  -> success message + GET /teacher/list refresh
   -> 401 -> clear teacher session, teacher login
   -> 409 / 403 / 422 / network -> inline error, form preserved
```

## 7. Frontend structure conventions

* One screen per file in `lib/`; shared UI primitives in `lib/utils/glass_container.dart`.
* `lib/config/environment.dart` is the only place the backend URL is defined:
  `String.fromEnvironment('BACKEND_URL', defaultValue: <ngrok URL>)`.
  Override at build time with
  `flutter run --dart-define=BACKEND_URL=https://host`.
* Requests use `package:http` directly (`http.get`/`http.post`); `lib/services/api_client.dart`
  exists but is **not used by any screen** (see SECURITY.md — dead code).
* `lib/data/student_database.dart` is a 15 KB copy of the student registry that
  **nothing imports** (dead code).

## 8. Testing architecture

| Suite | What it covers | How it stays isolated |
| --- | --- | --- |
| `test/session_validation_test.dart` | student session restore, 401/403/expiry/unreachable, credential separation | in-memory `FlutterSecureStorage` + `MockClient` |
| `test/teacher_session_validation_test.dart` | teacher session restore, teacher-only clearing | same |
| `test/teacher_panel_test.dart` | approvals list, approve/reject, errors, retry, repeat taps | same |
| `test/admin_teacher_management_test.dart` | admin-only UI, creation, validation, duplicate, network, 401 | same |
| `test/student_logout_test.dart` | logout revokes the server session, clears only student data | same |
| `test/widget_test.dart`, `test/validators_test.dart` | startup smoke test, Gmail validator | same |
| `backend/tests/test_backend_security.py` | 115 HTTP/DB checks | throwaway SQLite DB in a temp CWD + in-process uvicorn |

`backend/backend/test_integration.py` is an older **live-server** script
(`http://localhost:8000` that registers real students). It is not part of the
safe suite and was **not** executed.
