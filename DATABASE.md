# CampusSync — Database

Engine: **SQLite** via SQLAlchemy 2.1. No migration framework (no Alembic) is
used; schema changes are done with ad-hoc scripts.

## 1. Where the database file lives (important)

**Fixed in this review (2026-10-12).** `backend/database.py` now resolves the
SQLite file to **one absolute path**, and `settings.DATABASE_URL` from
`config.py` / `backend/.env` is the single source of truth:

```python
from config import settings
# A RELATIVE sqlite path is anchored to backend/, never to the CWD.
DATABASE_URL, DATABASE_PATH = resolve_database_url(settings.DATABASE_URL)
engine = create_engine(DATABASE_URL, connect_args={"check_same_thread": False})
```

* A **relative** path in `DATABASE_URL` (the default
  `sqlite:///./campussync.db`) is anchored to `backend/`, so it always means
  `backend/campussync.db` **regardless of the working directory** uvicorn was
  started from. The real database therefore keeps its location and its records.
* An **absolute** path is used exactly as given (this is how tests point the app
  at a throwaway file).
* `sqlite://` / `:memory:` resolves to no file; a non-SQLite URL is passed
  through untouched.
* `.env` discovery is also pinned to `backend/.env` (`config.py`), so starting
  the backend from the repository root no longer reads the Flutter `.env` there.

**Startup policy (`init_database`, called on import):** a **missing, 0-byte or
non-SQLite** file is a hard error, not a silent fallback to a fresh empty
database:

* missing / 0-byte file → refuse to start unless `ALLOW_DB_CREATE=1`
* non-SQLite file → always refused, even with `ALLOW_DB_CREATE=1`
* `ALLOW_DB_CREATE` defaults to **off**; set it (or run
  `python migrate_db.py --create`) only for a deliberate first-time setup.

**Consequence:** you may now start uvicorn from either `backend/` or the repo
root; both use `backend/campussync.db`. The 0-byte repo-root `campussync.db`
left over from the old bug is inert and was not touched. Starting from outside
the repo is also safe: the configured file is still `backend/campussync.db`,
and a wrong/missing `DATABASE_URL` fails loudly instead of booting empty.

## 2. Tables (read from a **copy** of the real file — the original was not opened)

### `students` — 3 rows

| column | type | constraints |
| --- | --- | --- |
| `id` | INTEGER | PK |
| `email` | VARCHAR | NOT NULL, **UNIQUE** (`ix_students_email`) |
| `roll_number` | VARCHAR | NOT NULL, **UNIQUE** (`ix_students_roll_number`) |
| `password` | VARCHAR | NOT NULL — argon2 hash |
| `name`, `branch` | TEXT | NOT NULL |
| `year` | INTEGER | NOT NULL |
| `division`, `batch` | TEXT | NOT NULL |
| `token` | TEXT | NULL (single active session) |
| `token_expires_at` | DATETIME | NULL |
| `status` | TEXT | NOT NULL — `pending` / `approved` / `rejected` |
| `approved_by` | INTEGER | NULL — FK to `teachers.id` in the ORM |
| `approved_at` | TIMESTAMP | NULL |
| `rejection_reason` | TEXT | NULL |
| `photo_path` | TEXT | NULL — **not mapped by the ORM** (added by `migrate_db.py`) |

### `teachers` — 8 rows

| column | type | constraints |
| --- | --- | --- |
| `id` | INTEGER | PK |
| `name` | VARCHAR | NOT NULL |
| `email` | VARCHAR | NOT NULL, **UNIQUE** |
| `password` | VARCHAR | NOT NULL — argon2 hash |
| `role` | VARCHAR(7) | NOT NULL — `teacher` / `admin` |
| `is_active` | BOOLEAN | NOT NULL |
| `token` | VARCHAR | NULL, **UNIQUE** (`ix_teachers_token`) |
| `token_expires_at` | DATETIME | NULL |
| `created_at` | DATETIME | NOT NULL |

### `timetable_entries` — 54 rows

`id` PK, `day`, `start_time`, `end_time`, `subject` NOT NULL, `faculty`, `room`,
`division` NOT NULL, `batch` (NULL = whole division), `is_break` BOOLEAN,
`is_free_period` BOOLEAN NOT NULL DEFAULT 0.

`is_free_period` marks the five periods the official sheet prints as free periods
("RELM") — Tuesday 15:15 and 16:15, Thursday 10:15, Saturday 15:15 and 16:15.
They are genuine periods, so they are neither a lecture nor an ordinary break:
`entry_type` reports `free_period`, `/timetable` never returns them to a student,
and Claim Free Period offers them to a teacher. The column is added by
`seed_official_data.py` (`--schema-only --apply` adds it and nothing else).

**The column is a precondition, not a nicety.** The ORM names it in every
`TimetableEntry` query, so on a file that does not have it yet `/timetable` and
`/teacher/free-periods` fail loudly with `500` (`no such column:
timetable_entries.is_free_period`) instead of answering - run
`seed_official_data.py --schema-only --apply` **before** starting a backend
built from this revision against that file. Verified on a throwaway copy in the
state the live database is in today.

`GET /teacher/free-periods` derives the five periods from
`official_data.FREE_PERIOD_SLOTS` rather than from the stored flag, so **once the
column exists but before the seeder's data corrections are applied** they are
still recognised: the official free periods are offered to teachers and kept out
of a student's schedule. (The data corrections below are still needed for the
stored flags to read correctly.)

### `assignments` — 3 rows

`id` PK, `subject`, `title` NOT NULL, `description`, `due_date` NOT NULL (string),
`year` INTEGER NOT NULL, `division` NOT NULL, `batch` (NULL = whole division).

## 3. Constraints and relationships — what is actually enforced

* **Unique** `students.email`, `students.roll_number`, `teachers.email`,
  `teachers.token` exist as real UNIQUE indexes **(verified by test)**: the
  duplicate insert raises `IntegrityError`. The API also checks first and returns
  `409`, so a race surfaces as a friendly `409` rather than a 500.
* `Student.approved_by → teachers.id` is declared as a `ForeignKey` in
  `models.py`, but **SQLite does not enforce foreign keys unless
  `PRAGMA foreign_keys=ON`** is set per connection, and `database.py` never sets
  it. FK integrity is therefore enforced by application code only.
* `status` and `role` are Python enums stored as strings. The tables were partly
  built with raw `ALTER TABLE`, so there is **no DB-level CHECK** on the allowed
  values — only the ORM/pydantic layer guards them.
* `create_all()` runs on every backend import and creates missing tables; it does
  not alter existing ones, so a model change needs a manual script.

## 4. Migration history and the mass-approval bug

### The bug (measured 2026-10-12, on a **temporary copy** — the real file was
never opened)

The old `backend/migrate_db.py` ended with a blanket statement:

```sql
UPDATE students SET status = "approved", approved_by = NULL, approved_at = ?
WHERE status = "pending"
```

The `WHERE` is equivalent to plain `status = "pending"`, so it approved **every**
pending row, including brand-new registrations:

```
BEFORE:  pending=2  approved=2  rejected=0  total=4
script : "Auto-approved 2 existing student(s) for backward compatibility"
AFTER :  pending=0  approved=4  rejected=0  total=4
brand-new row -> status=approved, approved_at set
```

### Why there is no automatic backfill any more

The `students` table has **no `created_at` (or any timestamp) column**. A legacy
pre-approval-workflow row is byte-for-byte identical to a brand-new pending
registration (`status='pending'`, `approved_by IS NULL`, `approved_at IS NULL`,
`token IS NULL`). The database alone **cannot** tell the two apart, so any
automatic decision either grants access to an unreviewed account or locks out a
real legacy one. The script therefore **never guesses**.

### The replacement `migrate_db.py` (fail-closed, repeatable)

| mode | behaviour |
| --- | --- |
| `python migrate_db.py` | additive schema migration only (`ADD COLUMN` when absent). **Never changes a status.** Repeat runs are no-ops. |
| `python migrate_db.py --status` | read-only report (`mode=ro` connection): status counts + each pending row, and an explanation of the ambiguity. Writes nothing. |
| `python migrate_db.py --create` | first-time setup: create a **missing** database file + schema. |
| `python migrate_db.py --approve-legacy-ids 4,7 [--apply]` | approve **only the ids you name**. Dry run without `--apply`; refuses (exit 3) and changes nothing if any named id is missing, not `pending`, or already carries approval metadata (all-or-nothing). Takes a `.bak` copy of the file before applying. |

Safeguards:

* There is **no** "approve everything" flag; the only write is scoped to
  `WHERE id = ? AND status = 'pending'`.
* Backfills are recorded in a `schema_migrations` table, so running the same
  backfill twice reports `SKIPPED` (override only with `--force`).
* `approved_by` is left `NULL` by an explicit backfill because the staff member
  is unknown — **prefer the Teacher Panel**, which records it.
* No `datetime.utcnow()`; timezone-aware timestamps only.

Regression tests: `backend/tests/test_migrate_db_safety.py` (existing / new
pending / rejected rows, repeat runs, refusals, and an AST source guard that
fails if a blanket `UPDATE students` ever returns).

### `bootstrap_admin.py`

Inserts the first admin with `ADMIN_PASSWORD` from the environment (≥ 12 chars)
and hashes it with `pwdlib`. It now uses the same CWD-independent resolved path
as the app, so it may be run from anywhere. It prints the admin **email** and a
note, never the password *(inspection)*.

## 5. Data preservation findings

* Column additions in `migrate_db.py` are additive (`ADD COLUMN`), never drops,
  so existing rows keep their data. Re-running prints "duplicate column" messages
  and continues (the loop catches the exception).
* No `DELETE`/`DROP`/`TRUNCATE` appears in any backend script.
* Password hashes and tokens are preserved untouched by the additive migration.
* **Untouched during this review:** no migration, reset, seed or write was run
  against `backend/campussync.db`; its mtime is still 2026-10-11 13:10. The only
  schema interrogation was performed on a temporary **copy** which was deleted.
* Physical backups present in `backend/`: `campussync.db.backup_20261011_112154`,
  `campussync.db.backup_20261011_112224`, `campussync_backup.db`,
  `campussync_backup_20260930_215842.db`, `campussync_before_password_fix.db`.
  Do not delete the newest ones.

## 6. Sensitive data stored

| Data | Where | Notes |
| --- | --- | --- |
| Password hashes | `students.password`, `teachers.password` | argon2 via `pwdlib.PasswordHash.recommended()` |
| Session tokens | `*.token` | plaintext opaque tokens; required by the current design |
| Student PII | `students.name/email/roll_number/…` | needed for the app |
| Profile photo | **nowhere in the DB** | device-only; the `photo_path` column is unused |
| Secrets | `.env` (not in the DB) | `.env` and `*.db` were added to `.gitignore` during this review |

## 7. Teaching features schema (2026-10-13)

New tables (created by `Base.metadata.create_all` at startup and by
`seed_official_data.py`):

| Table | Purpose | Key constraints |
| --- | --- | --- |
| `subjects` | official subject catalogue (name/short/code/faculty/kind) | unique `(name, kind)` |
| `faculty_directory` | faculty code + only the details an official document states | unique `short_code` |
| `lab_directory` | rooms/laboratories (currently only classroom M308) | — |
| `teacher_assignments` | periods a teacher is verified to teach | unique `(teacher_id, subject, division, batch, day, start_time, end_time)` |
| `attendance_records` | one row per student and lecture | unique `(student_id, session_date, slot_start, subject)`; `updated_by`/`updated_at` audit a correction |
| `free_period_claims` | claimed free periods | unique `(teacher_id, claim_date, start_time)` and `(division, batch, claim_date, start_time)` — the second one is what makes a free period a single division-wide slot: every `RELM` claim is stored with `batch = ''`, so two teachers cannot hold the same date and time, including when both requests arrive at once |

New columns (additive `ALTER TABLE ... ADD COLUMN`, never a rewrite):

* `teachers.short_code`, `teachers.can_approve_registrations`
* `assignments.stored_name`, `original_name`, `file_size`, `uploaded_by`, `created_at`
* `attendance_records.updated_by`

Migration command (additive, fail-closed, makes its own backup):

```bash
backend/venv/Scripts/python.exe backend/seed_official_data.py --schema-only        # dry run
backend/venv/Scripts/python.exe backend/seed_official_data.py --apply --schema-only
```

Official-data seed (also additive; corrects four faculty cells to Revision 4 and
fills the subject/faculty/room catalogues):

```bash
backend/venv/Scripts/python.exe backend/seed_official_data.py            # dry run, writes nothing
backend/venv/Scripts/python.exe backend/seed_official_data.py --apply    # apply
```

Neither command deletes a row, touches students/registrations, or rewrites a
password hash. Uploaded PDFs live under `backend/uploads/assignments/` with
server-generated names and are never served statically.

## 8. Announcements (2026-10-20)

`announcements` - created additively; no existing table or row was rewritten.

| column | type | notes |
| --- | --- | --- |
| `id` | INTEGER PK | |
| `title` | VARCHAR NOT NULL | 1-200 chars, validated server-side |
| `message` | TEXT NOT NULL | 1-5000 chars |
| `author_id` | INTEGER NOT NULL | FK -> `teachers.id`; always the posting account |
| `created_at` | DATETIME NOT NULL | UTC |
| `year` | INTEGER NULL | NULL = every year |
| `division` | VARCHAR NULL | NULL = every division; both NULL = college-wide |

The table was created through the sanctioned additive path (never a hand-written
`CREATE TABLE`), after a manual backup of the live file:

```bash
cp backend/campussync.db backend/campussync.db.backup_announcements_$(date +%s)
backend/venv/Scripts/python.exe backend/seed_official_data.py --schema-only          # dry run
backend/venv/Scripts/python.exe backend/seed_official_data.py --schema-only --apply  # creates it
```

That command creates missing tables only and writes no data, so the table starts
empty; existing students/teachers/assignments are untouched.
