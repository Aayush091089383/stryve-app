# AGENTS.md — working on CampusSync

Instructions for AI coding agents (and humans) editing this project.
Read this before changing anything; it exists to protect working features,
user data and credentials.

## 1. What this project is

* `lib/` — Flutter app (Android + Windows), light-blue glassmorphism UI.
* `backend/` — FastAPI + SQLAlchemy + SQLite backend, single `main.py` with all routes.
* Docs: [PRD.md](PRD.md), [ARCHITECTURE.md](ARCHITECTURE.md), [API.md](API.md),
  [DATABASE.md](DATABASE.md), [SECURITY.md](SECURITY.md),
  [DESIGN_SYSTEM.md](DESIGN_SYSTEM.md), [CODE_STYLE.md](CODE_STYLE.md).

## 2. Absolute rules

1. **Never commit, print, log or document secrets** (passwords, tokens, hashes,
   `.env` values). Do not `cat` `.env` files; if you need to know which keys
   exist, list key *names* only.
2. **Never run destructive commands**: no `git push/reset/checkout --`,
   no `DROP`/`DELETE` SQL, no `migrate_db.py`, no database reset or reseed.
3. **Never touch the real database** (`backend/campussync.db`) outside normal
   backend operation. For schema or data questions, copy the file to a temp
   directory and inspect the copy.
4. **Do not create real accounts** in the real database, and do not run
   `bootstrap_admin.py`. Test accounts belong in a throwaway database.
5. **Do not weaken, skip or delete tests** to get a green run. Fix the cause.
6. **Preserve behaviour you were not asked to change**: routes, navigation, UI
   design, stored keys and token semantics.
7. **Never claim a check passed unless you ran it** and captured its exit code.
8. Make a backup of any file you edit (`Documents/campus_sync_backups/<date>/`)
   before editing; never overwrite the existing full backup.

## 3. Run the app / backend

```bash
# backend (any working directory now works — the SQLite path is absolute)
cd backend
./venv/Scripts/python.exe -m uvicorn main:app --reload --port 8000   # Windows venv
```

```bash
# Flutter app (backend URL defaults to the current ngrok host)
flutter run
flutter run --dart-define=BACKEND_URL=https://your-host        # explicit backend
```

The database is resolved to an absolute path from `settings.DATABASE_URL`
(anchored to `backend/`, never the working directory), so uvicorn may be started
from the repo root or `backend/` and both use `backend/campussync.db`. A
missing/empty/non-SQLite file makes startup **fail loudly** rather than create an
empty database; `ALLOW_DB_CREATE=1` is only for a deliberate first-time setup —
see [DATABASE.md](DATABASE.md) §1.

## 4. Checks to run before reporting done

```bash
flutter analyze
flutter test                     # full suite, currently 160 tests
```

```bash
# backend suites — MUST run from an EMPTY TEMP directory (safety guards inside)
mkdir /tmp/cs-review && cd /tmp/cs-review
<repo>/backend/venv/Scripts/python.exe <repo>/backend/tests/test_backend_security.py
<repo>/backend/venv/Scripts/python.exe <repo>/backend/tests/test_database_path.py
<repo>/backend/venv/Scripts/python.exe <repo>/backend/tests/test_migrate_db_safety.py
<repo>/backend/venv/Scripts/python.exe <repo>/backend/tests/test_lookup_privacy.py
<repo>/backend/venv/Scripts/python.exe <repo>/backend/tests/test_admin_password_reset.py
<repo>/backend/venv/Scripts/python.exe <repo>/backend/tests/test_teacher_features.py
```

* All suites above use throwaway databases and verify the real
  `backend/campussync.db` size/mtime is unchanged.
* `backend/backend/test_integration.py` hits `http://localhost:8000` and creates
  real student rows — **do not run it** without explicit permission.
* Capture exit codes; a filtered pipeline is not a passing test.

## 5. Conventions

* **Dart**: follow `flutter_lints` (`analysis_options.yaml`). Screens live one
  per file in `lib/`; shared widgets in `lib/utils/glass_container.dart`; use
  `GlassColors`/`GlassCard`/`GlassButton` instead of ad-hoc colours.
* **Teacher/Admin screens**: shared data classes in `lib/teacher_models.dart`,
  shared HTTP helpers in `lib/utils/teacher_api.dart`. The Teacher Panel's bottom
  navigation is exactly Home / Assignments / Profile; Approvals and the admin
  dashboard are separate surfaces, and every permission is enforced by the
  backend (never by hiding a button).
* **Network**: `package:http` directly, `Environment.backendUrl` for the host,
  `Authorization: Bearer <token>` for authenticated calls. Never add a second
  copy of the base URL.
* **Testability**: when a widget needs to make requests, accept an optional
  `http.Client?`/service parameter that defaults to `null` (see
  `TeacherPanelPage`, `AuthService`, `TeacherAuthService`). Do not restructure
  screens just to add one.
* **Python**: keep the single-module FastAPI layout; add new request/response
  models to `schemas.py`, new authorization as a dependency in `auth.py`.
* **Backend error shape**: raise `HTTPException`/`CampusSyncException`;
  responses are `{"detail": …, "code": …}`. Clients must read **`detail`** first
  — `message` is only present on success payloads.
* **UI states**: every list needs loading, empty, error and populated states,
  and an error must never be rendered as an empty state.
* **Action buttons**: solid colours, no gradients, label stays readable while a
  request is in flight, repeated taps disabled.
* **Assignment PDFs (student side)**: shared model in `lib/assignment.dart`;
  fetching in `lib/services/assignment_pdf_service.dart`; the screen in
  `lib/assignment_pdf_viewer_page.dart`; the renderer behind
  `lib/utils/pdf_surface.dart`; file names from `lib/utils/assignment_file_name.dart`.
  Reading and saving are separate concerns: `AssignmentPdfService.load` only reads
  into memory, and `saveAssignmentPdf` is called from the viewer's Download button
  and nowhere else. New screens that render a PDF must take the same optional
  `PdfSurfaceFactory`/loader/saver parameters so widget tests never start the
  native PDF engine.

## 6. Things that are known and intentional — do not "fix" blindly

* `secrets.token_hex(32)` opaque tokens with a UNIQUE column: one active
  session per account is deliberate (a new login invalidates the old token).
* The registry (`STUDENT_REGISTRY` in `main.py`) is the source of truth for
  official student details; the client must never supply them.
* `students.photo_path` exists in the database but is not mapped or used; photos
  are device-local.
* Three routes are defined twice in `main.py`; the duplicates are dead code with
  no runtime effect. Remove only with a dedicated change and re-run the suites.
* There is deliberately **no password-reset API**. Changing an admin password is
  an offline, operator-only action:
  `NEW_ADMIN_PASSWORD=<12+ chars> backend/venv/Scripts/python.exe backend/reset_admin_password.py [--dry-run]`.
  It only ever rewrites the `password` column of the existing
  `admin@campusync.edu` row (never creating an account, never touching students
  or roles), resolves the same database path as the backend, and prints the path
  but never the password/hash. Never widen it into a general-purpose editor.
* `lib/services/api_client.dart` and `lib/data/student_database.dart` are unused;
  prefer deleting over "fixing" them.
* Approvals are permission-based on purpose: a regular teacher gets **403** from
  `/teacher/registrations/*` until an admin sets `can_approve_registrations`.
  Do not "restore" the old behaviour of letting every teacher approve.
* Teaching data is only ever verified, never inferred: attendance, free periods
  and finder results need an assignment (or a `short_code` printed on the
  official timetable). An empty result is the correct answer when the source data
  does not exist. (`backend/official_data.py` is the single transcription of
  Division D, Revision 4 - see its `UNCONFIRMED` list.)
* **`RELM` means a free period**, confirmed by the department: the five weekly
  `RELM` rows are stored with `timetable_entries.is_free_period = 1` and
  `is_break = 0`, are never shown to students, and are claimed by teachers
  through Claim Free Period. They are also listed in
  `official_data.FREE_PERIOD_SLOTS`, which is what `/timetable` and
  `/teacher/free-periods` both read - so do not reclassify them as lectures or
  as ordinary breaks, and do not add a sixth slot without the printed sheet.
* The four confirmed rows (Saturday `CCC-1` by `HBW`, and `RVS (CCI)` with the
  letter I on Wednesday D-3 / Friday D-2) are listed in `official_data.CONFIRMED`.
  `seed_official_data.py` reports and corrects those cells; do not "restore" the
* Monday has **no** free period: its batch practicals are D-1 PHY (SPG), D-2 BEE
  (HBW) and D-3 EG (VTM). Do not turn any of them into a RELM row (the older
  "possible sixth free period" note is settled - see `official_data.UNCONFIRMED`
  for the one thing still open, which cell the sheet prints them in).
* **Who may claim a free period**: any authenticated, active teacher account -
  i.e. one an admin created. Do not add a per-teacher free-period permission
  grant, and do not require a `short_code` for it. A free period is ONE
  division-wide slot (`batch = ""`); do not offer Whole division / D-1 / D-2 /
  D-3 as separate choices for a `RELM` period, and do not accept a per-batch
  claim for one.
* A free period in the past cannot be claimed. The date is judged on the college
  clock (`COLLEGE_TIMEZONE` = IST in `main.py`), not UTC.
* **Reading an assignment PDF is not downloading it.** The viewer fetches through
  `GET /assignments/{id}/file` into memory and writes nothing; only the Download
  button saves a copy, and it saves into the device's Downloads location
  (`file_saver`: MediaStore on Android 10+, system Save dialog as the fallback).
  Do not "restore" the old behaviour of writing the PDF into a temp directory on
  tap, and do not make opening a PDF save anything. The viewer's pdfrx source name
  is `assignment-<id>.pdf` - never the token or any account detail.
* `lib/tasks.dart` re-exports `lib/assignment.dart`; the `Assignment` model lives
  in its own file so the viewer and the Tasks tab can share it without a cycle.
* Schema/ordering: the `is_free_period` column is additive. On an existing
  database run `seed_official_data.py --schema-only --apply` (schema only, no
  data) before starting a backend built from this revision, otherwise the ORM
  queries a column the file does not have yet.
* `backend/seed_official_data.py` is the only sanctioned way to fill the official
  data. It is additive and fail-closed; a dry run must write nothing (including no
  schema change), and `--schema-only` exists so the operator can migrate the real
  database without importing any timetable correction.
* `GET /health` is a liveness probe only (added 2026-10-13): no token, no
  database, and the body is exactly `{status, service}`. `GET /` keeps its
  original banner. A `404` for `/health` in the terminal means the running
  uvicorn process predates the route - it is started **without `--reload`**, so
  it keeps serving the old code until it is restarted. Do not restart the live
  backend against a database whose schema this revision cannot query (see the
  schema/ordering note above); restart only after the schema step is applied.

## 7. Known open risks (see SECURITY.md)

`migrate_db.py` mass-approving pending students and the unauthenticated registry
lookup **were fixed on 2026-10-12** (the script is now additive-only and
fail-closed; the lookup returns a masked name and is rate limited). Still open:
permissive CORS default · profile photo stored in a cache path · no rate limiting
on `/login` or `/teacher/login` · no deactivation/password-reset endpoints · no
virus scanning of assignment uploads (PDF magic bytes + a size limit only) · no
laboratory room data, full faculty names or contact details (only classroom M308
and the faculty codes printed on the official timetable exist) · teacher records
are still not linked to faculty codes, so attendance and Claim Free Period need
an admin to set each teacher's `short_code` first · whether Monday's last period
is a sixth free period (see `official_data.UNCONFIRMED`).

## 8. When you are unsure

Stop and report: what you inspected, what you changed, the exact commands and
exit codes, what remains unverified, and any risk that could lock out users or
corrupt data. A clear blocker is better than a silent workaround.

## 9. Security audit skill

The Cloudflare `security-audit` skill is installed globally at
`~/.agents/skills/security-audit/` (symlinked into `~/.claude/skills/`). It is a
six-phase harness — reconnaissance → coverage-led hunting → candidate
validation → structured output → record verification → reporting — with
per-attack-class reference files (`WEB-PROTOCOL-AND-AUTH.md`, `CLIENT-SIDE.md`,
`DESKTOP-MOBILE-AND-LOCAL-IPC.md`, …) and two JSON validators.

* **When**: only for an explicit audit, pen-test or "find vulnerabilities"
  request. Ordinary bug fixes and feature work do not load it — it says so
  itself (guidance mode vs. full audit mode).
* **Entry point**: read `SKILL.md` in that directory first. It defines the
  evidence bar: a candidate needs a named principal, resource, crossed trust
  boundary and a concrete result; a missing best practice is not a finding.
* **The validators need Node.js**, which is *not* on `PATH` by default:
  `export PATH="$HOME/.local/opt/node-v24.22.1-linux-x64/bin:$PATH"`. Then
  `node validate-findings.cjs <findings.json>` against `report-schema.json`, and
  `node validate-coverage-ledger.cjs <coverage-ledger.json>`. Do not report an
  audit as finished unless both pass.
* **Output lives outside the repo**: `~/security-audit-skill/<repo>/run-<N>/`,
  never in the working tree, so an audit leaves `git status` clean.
* **An audit is read-only.** It must not modify application code, `backend/
  campussync.db`, the running backend, or any test. Applying fixes is a
  separate, explicitly requested change that follows §2–§4 like any other edit.
