"""Push notifications: device-token storage and the upload -> FCM hand-off.

WHAT IS BEING PROTECTED
-----------------------
* A device token is stored for the authenticated student only - never for an
  id the client sends.
* A token belongs to a phone, not an account: signing in as a different student
  on the same phone moves the row, so the previous student stops receiving that
  class's assignment alerts.
* Logging out (DELETE) only ever removes the caller's own row.
* An upload of an assignment still creates the in-app notifications exactly as
  before, and additionally queues ONE push per registered device of the
  recipients - with Google mocked out, because this suite must never send a
  real notification or touch a real Firebase project.
* A token FCM rejects permanently is pruned from the database.
* Push is best effort: with FCM disabled (or no credential) the send is a
  silent no-op and never raises.

RUN
---
    mkdir /tmp/cs-fcm && cd /tmp/cs-fcm
    <repo>/backend/.venv/bin/python <repo>/backend/tests/test_fcm_push.py

Everything runs against a THROWAWAY database in a temp directory; the real
backend/campussync.db is only stamped and re-stamped to prove this suite never
touched it.
"""

import os
import socket
import sys
import tempfile
import threading
import time
from datetime import datetime, timedelta
from pathlib import Path

BACKEND_DIR = Path(__file__).resolve().parent.parent
REAL_DB = (BACKEND_DIR / "campussync.db").resolve()


def stamp_of(path: Path):
    if not path.exists():
        return None
    stat = path.stat()
    return (stat.st_size, stat.st_mtime_ns)


REAL_DB_STAMP = stamp_of(REAL_DB)

# --------------------------------------------------------------------------
# Throwaway database + app environment (set BEFORE importing the app)
# --------------------------------------------------------------------------
TMP_DIR = Path(tempfile.mkdtemp(prefix="cs-fcm-db-")).resolve()
DB_FILE = TMP_DIR / "campussync.db"
UPLOAD_DIR = TMP_DIR / "uploads"
if DB_FILE == REAL_DB:
    sys.exit(f"REFUSING TO RUN: {DB_FILE} is the real database.")

os.environ["DATABASE_URL"] = f"sqlite:///{DB_FILE.as_posix()}"
os.environ["ALLOW_DB_CREATE"] = "1"
os.environ["UPLOAD_DIR"] = str(UPLOAD_DIR)
# The real service-account file exists on the operator's machine; this suite
# must never initialise Firebase, so push is switched off at the settings level.
os.environ["FCM_ENABLED"] = "0"

sys.path.insert(0, str(BACKEND_DIR))

import requests  # noqa: E402
import uvicorn  # noqa: E402
from pwdlib import PasswordHash  # noqa: E402

import database  # noqa: E402
import firebase_service  # noqa: E402
import main  # noqa: E402
import models  # noqa: E402

if Path(database.DATABASE_PATH or "") != DB_FILE:
    sys.exit(
        f"REFUSING TO RUN: the app resolved {database.DATABASE_PATH}, "
        f"expected the throwaway {DB_FILE}."
    )

PASSWORD = "TestPassw0rd!23"
password_hash = PasswordHash.recommended()

PASSED = []
FAILED = []


def check(label, condition, detail=""):
    if condition:
        PASSED.append(label)
        print(f"  PASS  {label}")
    else:
        FAILED.append(f"{label} {detail}".strip())
        print(f"  FAIL  {label}  {detail}")
    return bool(condition)


def section(title):
    print(f"\n=== {title} ===")


sock = socket.socket()
sock.bind(("127.0.0.1", 0))
PORT = sock.getsockname()[1]
BASE = f"http://127.0.0.1:{PORT}"

server = uvicorn.Server(uvicorn.Config(main.app, log_level="warning", access_log=False))
thread = threading.Thread(target=server.run, kwargs={"sockets": [sock]}, daemon=True)
thread.start()

ready = False
for _ in range(100):
    try:
        if requests.get(f"{BASE}/", timeout=2).status_code == 200:
            ready = True
            break
    except requests.RequestException:
        time.sleep(0.1)
if not ready:
    sys.exit("server did not start")

print(f"throwaway database: {DB_FILE}")
print(f"test server: {BASE}")


def wait_for(predicate, timeout=8.0):
    """Background tasks run after the response; poll instead of sleeping."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        if predicate():
            return True
        time.sleep(0.05)
    return predicate()


db = database.SessionLocal()
registry = {record["roll_number"]: record for record in main.STUDENT_REGISTRY}


def make_student(roll: str, token: str) -> models.Student:
    record = registry[roll]
    student = models.Student(
        name=record["name"],
        email=f"fcm-student-{roll}@example.com",
        roll_number=roll,
        branch=record["course"],
        year=record["year"],
        division=record["division"],
        batch=record["batch"],
        password=password_hash.hash(PASSWORD),
        status=models.StudentStatus.approved,
        token=token,
        token_expires_at=datetime.utcnow() + timedelta(days=1),
    )
    db.add(student)
    db.commit()
    db.refresh(student)
    return student


student_a = make_student("1", "fcm-student-token-a")
student_b = make_student("2", "fcm-student-token-b")

teacher = models.Teacher(
    name="FCM Teacher",
    email="fcm-teacher@example.com",
    password=password_hash.hash(PASSWORD),
    role=models.TeacherRole.teacher,
    is_active=True,
    token="fcm-teacher-token",
    token_expires_at=datetime.utcnow() + timedelta(days=1),
    created_at=datetime.utcnow(),
)
db.add(teacher)
db.commit()
db.refresh(teacher)

# Plain values, so the checks below never touch a detached ORM instance.
STUDENT_A_ID = student_a.id
STUDENT_B_ID = student_b.id
STUDENT_A_TOKEN = student_a.token
STUDENT_B_TOKEN = student_b.token
TEACHER_TOKEN = teacher.token
db.close()

AUTH_A = {"Authorization": f"Bearer {STUDENT_A_TOKEN}"}
AUTH_B = {"Authorization": f"Bearer {STUDENT_B_TOKEN}"}
AUTH_TEACHER = {"Authorization": f"Bearer {TEACHER_TOKEN}"}
TOKEN = "fcm-device-token-0001"

PDF_BYTES = b"%PDF-1.4\n1 0 obj\n<<>>\nendobj\ntrailer\n<<>>\n%%EOF\n"


def token_rows():
    session = database.SessionLocal()
    try:
        return session.query(models.FcmToken).order_by(models.FcmToken.id).all()
    finally:
        session.close()


def register(token: str, headers, label: str, expected=200):
    response = requests.post(
        f"{BASE}/notifications/device-token",
        json={"token": token},
        headers=headers,
        timeout=10,
    )
    check(
        f"{label} -> {expected}",
        response.status_code == expected,
        f"got {response.status_code}: {response.text[:120]}",
    )
    return response


def upload(title: str, subject: str):
    return requests.post(
        f"{BASE}/teacher/assignments/upload",
        headers=AUTH_TEACHER,
        files={"file": ("assignment.pdf", PDF_BYTES, "application/pdf")},
        data={
            "title": title,
            "subject": subject,
            "due_date": "2026-11-01",
            "year": "1",
            "division": "D",
            "batch": "",
            "description": "FCM test upload",
        },
        timeout=20,
    )


# ==========================================================================
section("1. Token registration is authenticated and idempotent")
# ==========================================================================
response = requests.post(
    f"{BASE}/notifications/device-token",
    json={"token": TOKEN},
    timeout=10,
)
check(
    "anonymous registration is refused",
    response.status_code in (401, 403),
    f"got {response.status_code}",
)

first = register(TOKEN, AUTH_A, "registering a device as student A")
rows = token_rows()
check("one row stored", len(rows) == 1, str([(r.student_id, r.token) for r in rows]))
check("row belongs to the caller", rows and rows[0].student_id == STUDENT_A_ID)
check("the response never echoes the token", TOKEN not in first.text, first.text)

register(TOKEN, AUTH_A, "re-registering the same token")
check("re-registering the same token adds no row", len(token_rows()) == 1)

register("fcm-device-token-0002", AUTH_A, "registering a second device")
check(
    "a second device is a second row",
    len(token_rows()) == 2,
    str(len(token_rows())),
)

# ==========================================================================
section("2. A handed-over phone moves to the new student")
# ==========================================================================
register(TOKEN, AUTH_B, "registering the handed-over phone as student B")
rows = [row for row in token_rows() if row.token == TOKEN]
check(
    "the token now belongs to the student who signed in",
    len(rows) == 1 and rows[0].student_id == STUDENT_B_ID,
    str([(r.student_id, r.token) for r in rows]),
)

response = requests.delete(
    f"{BASE}/notifications/device-token",
    params={"token": TOKEN},
    headers=AUTH_A,
    timeout=10,
)
check(
    "another student cannot unregister a token they do not own",
    response.status_code == 200
    and any(row.token == TOKEN for row in token_rows()),
    f"got {response.status_code}",
)

# ==========================================================================
section("3. An upload pushes to each recipient's registered device")
# ==========================================================================
calls = []


def fake_send(tokens, title, body, data=None):
    calls.append({"tokens": list(tokens), "title": title, "body": body, "data": data})
    return firebase_service.PushResult(delivered=len(tokens))


real_send = firebase_service.send_push_notification
firebase_service.send_push_notification = fake_send
try:
    response = upload("Push test one", "FCM-Subject-1")
    check("upload succeeds", response.status_code == 201, response.text[:200])
    assignment_id = response.json().get("id") if response.status_code == 201 else None

    check("a push was queued", wait_for(lambda: len(calls) >= 1), str(len(calls)))
    call = calls[0] if calls else {}
    check(
        "both of the student's devices are addressed",
        sorted(call.get("tokens", [])) == [TOKEN, "fcm-device-token-0002"],
        str(call.get("tokens")),
    )
    check(
        "the push text matches the in-app notification",
        call.get("title") == "New assignment"
        and call.get("body") == "New assignment uploaded: Push test one",
        f"{call.get('title')!r} / {call.get('body')!r}",
    )
    check(
        "the payload carries the assignment id, never anything private",
        call.get("data", {}).get("type") == "assignment"
        and call.get("data", {}).get("assignment_id") == assignment_id,
        str(call.get("data")),
    )

    session = database.SessionLocal()
    try:
        in_app = (
            session.query(models.Notification)
            .filter(models.Notification.student_id == STUDENT_B_ID)
            .all()
        )
    finally:
        session.close()
    check(
        "the in-app notification is still written",
        len(in_app) == 1
        and in_app[0].message == "New assignment uploaded: Push test one",
        str([(n.title, n.message) for n in in_app]),
    )

    # ======================================================================
    section("4. Tokens FCM rejects permanently are pruned")
    # ======================================================================
    def reject_send(tokens, title, body, data=None):
        return firebase_service.PushResult(
            delivered=0, failed=len(tokens), invalid_tokens=list(tokens)
        )

    firebase_service.send_push_notification = reject_send
    response = upload("Push test two", "FCM-Subject-2")
    check("upload still succeeds when push fails", response.status_code == 201)

    check(
        "dead tokens are deleted",
        wait_for(lambda: token_rows() == []),
        str([(r.student_id, r.token) for r in token_rows()]),
    )
finally:
    firebase_service.send_push_notification = real_send

# ==========================================================================
section("5. With FCM off, sending is a silent no-op")
# ==========================================================================
check(
    "push reports itself disabled",
    firebase_service.is_enabled() is False,
)
result = firebase_service.send_push_notification(["any-token"], "t", "b")
check(
    "a disabled send returns an empty result and does not raise",
    result.delivered == 0 and result.failed == 0 and result.invalid_tokens == [],
    str(result),
)

# ==========================================================================
section("6. The real database was not touched")
# ==========================================================================
check(
    "this suite used the throwaway database",
    Path(database.DATABASE_PATH) == DB_FILE,
    str(database.DATABASE_PATH),
)
check(
    "real database size/mtime unchanged by this suite",
    stamp_of(REAL_DB) == REAL_DB_STAMP,
    f"before={REAL_DB_STAMP} after={stamp_of(REAL_DB)}",
)

print("\n" + "=" * 72)
print(f"fcm push tests: {len(PASSED)} passed, {len(FAILED)} failed")
for failure in FAILED:
    print(f"  FAILED: {failure}")
print("=" * 72)

server.should_exit = True
thread.join(timeout=10)

sys.exit(1 if FAILED else 0)
