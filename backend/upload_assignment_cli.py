#!/usr/bin/env python3
"""Upload an assignment PDF from a laptop, without the mobile app.

How to run it (from the repository root, on the machine running the backend):

    cd ~/campus_sync && backend/.venv/bin/python backend/upload_assignment_cli.py

On Windows the interpreter lives in ``backend/venv/Scripts/python.exe`` instead:

    cd campus_sync && backend\\venv\\Scripts\\python.exe backend\\upload_assignment_cli.py

The script talks to the **local** backend at ``http://127.0.0.1:8000`` by
default, so the upload goes straight over the loopback interface instead of
round-tripping through ngrok. Point it somewhere else with ``--base-url``:

    ... --base-url https://your-host

What it does: signs in through ``POST /teacher/login`` (JSON body - that is
what the endpoint accepts), then sends the PDF to
``POST /teacher/assignments/upload`` as multipart form-data, exactly like the
teacher view in the app does. Authorization is the backend's decision: a
student account, a deactivated account or a non-PDF file is refused there, and
the script only prints the backend's ``detail`` message.

Nothing is stored locally: the password is read with ``getpass`` (never echoed,
never written to disk, never put on the command line), and the session token
only lives in this process's memory.

Requires ``requests`` (already in the venv). Exits 0 on a successful upload,
1 on any refusal or connection problem, 130 if interrupted with Ctrl-C.
"""

from __future__ import annotations

import argparse
import getpass
import sys
from datetime import date, datetime
from pathlib import Path

import requests

# The laptop's own loopback: fastest path to the backend, no tunnel involved.
DEFAULT_BASE_URL = "http://127.0.0.1:8000"

# The seven subjects of Division D's first-year timetable, in the wording the
# official sheet uses. This is the same list the teacher screen offers
# (`kAssignmentSubjects` in lib/teacher_assignments_page.dart); the label that
# is picked here is the label stored on the assignment, so the two must match.
SUBJECTS = [
    "Engineering Mathematics-I",
    "Engineering Physics",
    "Basic Electrical Engineering",
    "Engineering Graphics",
    "Fundamentals of Programming Languages",
    "Design Thinking & Idea Lab",
    "Professional Communication Skills",
]

DEFAULT_YEAR = "1"
DEFAULT_DIVISION = "D"
DEFAULT_DUE_DATE = "2026-12-31"

# Mirrors settings.MAX_ASSIGNMENT_FILE_MB on the backend. Checked here only so
# a huge file fails before it is read; the backend re-checks and is the
# authority.
MAX_FILE_MB = 10

# requests' connect/read timeouts (seconds): a hung backend must not hang the
# terminal forever, and an upload of a few MB needs more than the default.
TIMEOUT = (5, 60)

REQUEST_TIMEOUT_ERROR = requests.exceptions.Timeout
CONNECTION_ERRORS = (
    requests.exceptions.ConnectionError,
    requests.exceptions.Timeout,
    requests.exceptions.RequestException,
)


def main(argv: list[str] | None = None) -> int:
    args = _parse_args(argv)
    base_url = args.base_url.rstrip("/")

    _banner(base_url)

    try:
        # ------------------------------------------------------------------
        # 1. Sign in.
        # ------------------------------------------------------------------
        email = _ask("Admin/teacher email").strip()
        if not email:
            return _fail("An email address is required.")

        # getpass never echoes the password and falls back to stdin when the
        # terminal has no tty (e.g. piped input), so it works both ways.
        password = getpass.getpass("Password (not echoed): ")
        if not password:
            return _fail("A password is required.")

        token, who = _login(base_url, email, password)
        if token is None:
            return 1
        print(f"\n  Signed in as {who}.\n")

        # ------------------------------------------------------------------
        # 2. The assignment's details.
        # ------------------------------------------------------------------
        subject = _ask_subject()

        title = _ask("Title (e.g. Maths Tutorial 2)").strip()
        if not title:
            return _fail("A title is required.")
        if len(title) > 200:
            return _fail("The title must be at most 200 characters.")

        year = _ask_choice(
            f"Year [1-5] ({DEFAULT_YEAR})", default=DEFAULT_YEAR,
            valid=[str(n) for n in range(1, 6)],
            hint="Enter a year between 1 and 5.",
        )

        division = _ask(
            f"Division ({DEFAULT_DIVISION})", default=DEFAULT_DIVISION
        ).strip().upper() or DEFAULT_DIVISION

        batch = _ask_batch()

        due_date = _ask_due_date()

        instructions = _ask("Instructions for students (optional)").strip()
        if len(instructions) > 2000:
            return _fail("The instructions must be at most 2000 characters.")

        # ------------------------------------------------------------------
        # 3. The PDF.
        # ------------------------------------------------------------------
        pdf_path = _ask_file()

        # ------------------------------------------------------------------
        # 4. Upload.
        # ------------------------------------------------------------------
        summary = [
            ("Subject", subject),
            ("Title", title),
            ("Year", year),
            ("Division", division),
            ("Batch", batch or "whole division"),
            ("Due date", due_date),
            ("File", f"{pdf_path.name} ({_human_size(pdf_path.stat().st_size)})"),
        ]
        print("\n  About to upload:")
        for label, value in summary:
            print(f"    {label:<10} {value}")
        print()

        return _upload(
            base_url=base_url,
            token=token,
            subject=subject,
            title=title,
            year=int(year),
            division=division,
            batch=batch,
            due_date=due_date,
            instructions=instructions,
            pdf_path=pdf_path,
        )
    except KeyboardInterrupt:
        print("\nCancelled.")
        return 130
    except _InputClosed:
        # stdin ended (Ctrl-D, or a pipe that ran out) inside a re-prompt
        # loop: stop instead of asking the same question forever.
        print("\nInput ended before the upload was complete - nothing was sent.")
        return 1


# ---------------------------------------------------------------------------
# HTTP
# ---------------------------------------------------------------------------
def _login(base_url: str, email: str, password: str) -> tuple[str | None, str]:
    """POST /teacher/login and return (token, display name).

    The endpoint takes a JSON body (`TeacherLogin`: email + password) and
    answers with a `token` field; `access_token` is accepted as a fallback so a
    future rename on the server cannot silently break this script.
    """
    url = f"{base_url}/teacher/login"
    try:
        response = requests.post(
            url, json={"email": email, "password": password}, timeout=TIMEOUT
        )
    except requests.exceptions.ConnectionError:
        _fail(
            f"Could not reach the backend at {base_url}.\n"
            "        Start it first:\n"
            "          cd backend && ./venv/Scripts/python.exe -m uvicorn "
            "main:app --port 8000\n"
            "        (on Linux/macOS: backend/.venv/bin/python -m uvicorn "
            "main:app --port 8000)"
        )
        return None, ""
    except REQUEST_TIMEOUT_ERROR:
        _fail(f"The backend at {base_url} did not answer in time.")
        return None, ""
    except requests.exceptions.RequestException as error:
        _fail(f"Login request failed: {error}")
        return None, ""

    if response.status_code != 200:
        _fail(f"Login refused ({response.status_code}): {_error_detail(response)}")
        return None, ""

    try:
        body = response.json()
    except ValueError:
        _fail("Login answered with something that is not JSON.")
        return None, ""

    token = body.get("token") or body.get("access_token")
    if not token:
        _fail("Login succeeded but the response carried no token.")
        return None, ""

    name = body.get("name") or email
    role = body.get("role")
    who = f"{name} ({role})" if role else str(name)
    return str(token), who


def _upload(
    *,
    base_url: str,
    token: str,
    subject: str,
    title: str,
    year: int,
    division: str,
    batch: str,
    due_date: str,
    instructions: str,
    pdf_path: Path,
) -> int:
    """POST the multipart upload and report the result."""
    url = f"{base_url}/teacher/assignments/upload"
    fields = {
        "title": title,
        "subject": subject,
        "description": instructions,
        "due_date": due_date,
        "year": str(year),
        "division": division,
        "batch": batch,
    }

    try:
        with pdf_path.open("rb") as handle:
            response = requests.post(
                url,
                headers={"Authorization": f"Bearer {token}"},
                data=fields,
                files={"file": (pdf_path.name, handle, "application/pdf")},
                timeout=TIMEOUT,
            )
    except CONNECTION_ERRORS as error:
        _fail(f"Upload failed: {error}")
        return 1
    except OSError as error:
        _fail(f"Could not read {pdf_path}: {error}")
        return 1

    if response.status_code == 201:
        try:
            body = response.json()
        except ValueError:
            body = {}
        assignment_id = body.get("id")
        print("  Uploaded successfully.")
        print(f"    Assignment ID  {assignment_id}")
        print(f"    Subject        {body.get('subject', subject)}")
        print(f"    Title          {body.get('title', title)}")
        print(f"    Year/Division  {body.get('year', year)} / "
              f"{body.get('division', division)}")
        print(f"    Batch          {body.get('batch') or 'whole division'}")
        print(f"    Due date       {body.get('due_date', due_date)}")
        return 0

    if response.status_code == 401:
        _fail(
            "The session was rejected (401). Sign in again - a newer login "
            "replaces this one, and only one session is valid at a time."
        )
        return 1

    if response.status_code == 403:
        _fail(
            f"Not allowed (403): {_error_detail(response)}\n"
            "        Only an active teacher or admin account may upload."
        )
        return 1

    _fail(f"Upload refused ({response.status_code}): {_error_detail(response)}")
    return 1


def _error_detail(response: requests.Response) -> str:
    """The backend's own explanation.

    Error responses are `{"detail": ..., "code": ...}`; `message` only appears
    on success payloads, so `detail` is read first and the raw text is the last
    resort.
    """
    try:
        body = response.json()
    except ValueError:
        return (response.text or "").strip()[:300] or "no explanation given"
    if isinstance(body, dict):
        detail = body.get("detail")
        if isinstance(detail, list):
            # FastAPI's own validation errors (422) are a list of
            # {loc, msg} objects; flatten it into one readable line.
            parts = []
            for item in detail:
                if isinstance(item, dict):
                    where = ".".join(
                        str(piece) for piece in item.get("loc", []) if piece != "body"
                    )
                    message = item.get("msg", "invalid value")
                    parts.append(f"{where}: {message}" if where else str(message))
                else:
                    parts.append(str(item))
            if parts:
                return "; ".join(parts)[:300]
        if detail:
            return str(detail)
        if body.get("message"):
            return str(body["message"])
    return str(body)[:300]


# ---------------------------------------------------------------------------
# Prompts
# ---------------------------------------------------------------------------
class _InputClosed(Exception):
    """stdin ended while a prompt was waiting for an answer."""


def _ask(question: str, *, default: str | None = None) -> str:
    """A single line of input; empty input yields `default` (or "").

    Raises `_InputClosed` when stdin is exhausted, so the re-prompt loops
    below (bad subject, bad date, missing file) cannot spin forever.
    """
    suffix = ""
    if default is not None:
        suffix = "" if question.endswith(")") else f" [{default}]"
    try:
        answer = input(f"  {question}{suffix}: ")
    except EOFError as error:
        raise _InputClosed from error
    if answer.strip() or default is None:
        return answer
    return default


def _ask_choice(question: str, *, default: str, valid: list[str], hint: str) -> str:
    """Re-ask until the answer is one of `valid`."""
    while True:
        answer = _ask(question, default=default).strip() or default
        if answer in valid:
            return answer
        print(f"    {hint}")


def _ask_subject() -> str:
    print("  Subjects:")
    for index, subject in enumerate(SUBJECTS, start=1):
        print(f"    {index}. {subject}")
    while True:
        raw = _ask(f"Choose a subject [1-{len(SUBJECTS)}]").strip()
        if raw.isdigit() and 1 <= int(raw) <= len(SUBJECTS):
            return SUBJECTS[int(raw) - 1]
        # Typing the subject name (or a number-prefixed version) also works, so
        # copy/paste from the sheet is enough.
        for subject in SUBJECTS:
            if raw.lower() == subject.lower():
                return subject
        print(f"    Enter a number between 1 and {len(SUBJECTS)}.")


def _ask_batch() -> str:
    """'' = whole division, or D-1/D-2/D-3. Accepts '1', 'd1', 'D-1'."""
    while True:
        raw = _ask("Batch (1/2/3, Enter for the whole division)")
        raw = raw.strip().upper().replace(" ", "")
        if not raw:
            return ""
        if raw in ("1", "2", "3"):
            return f"D-{raw}"
        if raw in ("D-1", "D-2", "D-3", "D1", "D2", "D3"):
            return f"D-{raw[-1]}"
        if raw in ("A", "ALL", "NONE", "-"):
            return ""
        print("    Press Enter for the whole division, or enter 1, 2 or 3.")


def _ask_due_date() -> str:
    """A real calendar date in the backend's `YYYY-MM-DD` format."""
    while True:
        raw = _ask(f"Due date (YYYY-MM-DD) ({DEFAULT_DUE_DATE})",
                   default=DEFAULT_DUE_DATE).strip()
        raw = raw or DEFAULT_DUE_DATE
        try:
            parsed = datetime.strptime(raw, "%Y-%m-%d").date()
        except ValueError:
            print("    Use YYYY-MM-DD, for example 2026-12-31.")
            continue
        if parsed.year < 2000:
            print("    That date looks wrong; use a year of 2000 or later.")
            continue
        if parsed < date.today():
            # Not an error: a teacher may be backfilling material. Just say so.
            print(f"    Note: {parsed.isoformat()} is in the past.")
        return parsed.isoformat()


def _ask_file() -> Path:
    """The PDF, accepting a dragged-and-dropped path (quotes and all)."""
    while True:
        raw = _ask("Path to the PDF (drag and drop the file here)")
        if not raw.strip():
            print("    A file path is required.")
            continue
        path = _clean_path(raw)
        if path is None:
            print("    That path could not be read. Try dragging the file in again.")
            continue
        if not path.exists():
            print(f"    No such file: {path}")
            continue
        if path.is_dir():
            print(f"    That is a folder, not a PDF: {path}")
            continue
        if path.suffix.lower() != ".pdf":
            print("    The file must be a .pdf.")
            continue
        try:
            size = path.stat().st_size
        except OSError as error:
            print(f"    Could not read the file: {error}")
            continue
        if size == 0:
            print("    The file is empty.")
            continue
        if size > MAX_FILE_MB * 1024 * 1024:
            print(f"    The file is {_human_size(size)}; the limit is {MAX_FILE_MB} MB.")
            continue
        try:
            with path.open("rb") as handle:
                head = handle.read(5)
        except OSError as error:
            print(f"    Could not read the file: {error}")
            continue
        if head != b"%PDF-":
            # The backend refuses this too; catching it here saves a round trip
            # and explains it while the path is still on screen.
            print("    That file is not a PDF (it does not start with %PDF-).")
            continue
        return path


def _clean_path(raw: str) -> Path | None:
    """Turn terminal/explorer output into a path.

    Dragging a file in usually pastes one of:
      * a bare path - possibly with spaces ('C:\\Users\\me\\My File.pdf')
      * a quoted path ('"/home/me/My File.pdf"' or "'C:\\My File.pdf'")
      * a file:// URL (some terminals paste that on Windows/macOS)
    """
    text = raw.strip()
    # Strip one pair of surrounding quotes: both Explorer's "Copy as path"
    # and most terminal drag-and-drop paste the path quoted.
    if len(text) >= 2 and text[0] == text[-1] and text[0] in "\"'":
        text = text[1:-1]
    if text.lower().startswith("file://"):
        text = text[len("file://"):]
        # file:///C:/... -> /C:/... ; drop the leading slash before a drive.
        if len(text) >= 3 and text[0] == "/" and text[2] == ":":
            text = text[1:]
    text = text.replace("\\ ", " ") if "\\ " in text else text
    if not text:
        return None
    path = Path(text).expanduser()
    return path


def _human_size(num_bytes: int) -> str:
    size = float(num_bytes)
    for unit in ("B", "KB", "MB"):
        if size < 1024 or unit == "MB":
            return f"{size:.0f} {unit}" if unit == "B" else f"{size:.1f} {unit}"
        size /= 1024
    return f"{size:.1f} MB"


# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
def _banner(base_url: str) -> None:
    print()
    print("  CampusSync - upload an assignment PDF from this computer")
    print(f"  Backend: {base_url}")
    print("  Ctrl-C any time to cancel.")
    print()


def _fail(message: str) -> int:
    print(f"\n  Error: {message}\n", file=sys.stderr)
    return 1


def _parse_args(argv: list[str] | None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Upload an assignment PDF to the CampusSync backend from this "
            "computer, without the mobile app."
        ),
        epilog=(
            "Examples:\n"
            "  backend/.venv/bin/python backend/upload_assignment_cli.py\n"
            "  backend/venv/Scripts/python.exe backend/upload_assignment_cli.py  "
            "(Windows)\n"
            "  backend/.venv/bin/python backend/upload_assignment_cli.py "
            "--base-url https://your-host"
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "--base-url",
        default=DEFAULT_BASE_URL,
        help=f"backend origin (default: {DEFAULT_BASE_URL})",
    )
    return parser.parse_args(argv)


if __name__ == "__main__":
    sys.exit(main())
