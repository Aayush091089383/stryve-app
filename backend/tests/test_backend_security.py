"""CampusSync backend security & workflow tests.

Exercises the REAL FastAPI app over HTTP (in-process uvicorn on a loopback
port) plus the SQLAlchemy models directly, against a THROWAWAY SQLite
database. It is a plain-Python runner (no pytest/httpx in this venv), and the
functions are named test_* so it also works under pytest later.

SAFETY
------
* The app resolves its database from DATABASE_URL (never from the working
  directory), so this suite points DATABASE_URL at a throwaway file in a
  temporary directory before importing the app, and aborts if the app did not
  pick that file up. The real database is therefore never opened, whatever
  directory the suite is run from.
* Creates accounts only inside that throwaway database.
* Never prints passwords, tokens or password hashes.

RUN
---
    mkdir /tmp/campussync-review && cd /tmp/campussync-review
    python <repo>/backend/tests/test_backend_security.py
"""

import json
import os
import socket
import sys
import tempfile
import threading
import time
from datetime import datetime, timedelta
from pathlib import Path

# --------------------------------------------------------------------------
# Safety guards (before importing the app, which initialises the database)
# --------------------------------------------------------------------------
BACKEND_DIR = Path(__file__).resolve().parent.parent
REAL_DB = (BACKEND_DIR / "campussync.db").resolve()


def stamp_of(path: Path):
    """(size, mtime) of a file, or None when it does not exist."""
    if not path.exists():
        return None
    stat = path.stat()
    return (stat.st_size, stat.st_mtime_ns)


REAL_DB_STAMP = stamp_of(REAL_DB)

TMP_DIR = Path(tempfile.mkdtemp(prefix="cs-security-db-")).resolve()
DB_FILE = TMP_DIR / "campussync.db"

if DB_FILE == REAL_DB:
    sys.exit(f"REFUSING TO RUN: {DB_FILE} is the real database.")

# Point the app at the throwaway file. ALLOW_DB_CREATE is what makes creating
# a brand-new database explicit rather than silent.
os.environ["DATABASE_URL"] = f"sqlite:///{DB_FILE.as_posix()}"
os.environ["ALLOW_DB_CREATE"] = "1"

sys.path.insert(0, str(BACKEND_DIR))

import requests  # noqa: E402
import uvicorn  # noqa: E402

import auth  # noqa: E402
import database  # noqa: E402
import main  # noqa: E402
import models  # noqa: E402
import schemas  # noqa: E402
from exceptions import (  # noqa: E402
    DuplicateEmailError,
    DuplicateRollNumberError,
    TokenExpiredError,
)

# --------------------------------------------------------------------------
# The app MUST have resolved the throwaway database, not the real one.
# --------------------------------------------------------------------------
if Path(database.DATABASE_PATH or "") != DB_FILE:
    sys.exit(
        "REFUSING TO RUN: the app resolved "
        f"{database.DATABASE_PATH}, expected the throwaway {DB_FILE}."
    )
if Path(database.DATABASE_PATH).resolve() == REAL_DB:
    sys.exit("REFUSING TO RUN: the app resolved the real database.")

# --------------------------------------------------------------------------
# Tiny assertion harness
# --------------------------------------------------------------------------
PASSED: list[str] = []
FAILED: list[str] = []


def check(label: str, condition: bool, detail: str = "") -> bool:
    if condition:
        PASSED.append(label)
        print(f"  PASS  {label}")
    else:
        FAILED.append(f"{label} {detail}".strip())
        print(f"  FAIL  {label}  {detail}")
    return bool(condition)


def section(title: str) -> None:
    print(f"\n=== {title} ===")


def status_of(row) -> str:
    """SQLAlchemy Enum columns hold enum members; compare by value."""
    return getattr(row.status, "value", row.status)


def post(path: str, token: str | None, payload) -> requests.Response:
    return requests.post(f"{BASE}{path}", headers=hdr(token), json=payload, timeout=10)


def get(path: str, token: str | None = None) -> requests.Response:
    return requests.get(f"{BASE}{path}", headers=hdr(token), timeout=10)


def expect_http(label: str, func, status: int, detail_contains: str | None = None) -> None:
    """Assert that a direct endpoint call raises HTTPException with `status`."""
    try:
        func()
    except Exception as exc:  # noqa: BLE001 - endpoint guards raise HTTPException
        code = getattr(exc, "status_code", None)
        detail = str(getattr(exc, "detail", exc))
        ok = code == status and (
            detail_contains is None or detail_contains.lower() in detail.lower()
        )
        check(label, ok, f"got {code} ({detail})" if not ok else "")
    else:
        check(label, False, f"no exception raised (expected {status})")


# --------------------------------------------------------------------------
# Server bootstrap
# --------------------------------------------------------------------------
sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
sock.bind(("127.0.0.1", 0))
PORT = sock.getsockname()[1]
BASE = f"http://127.0.0.1:{PORT}"

config = uvicorn.Config(main.app, log_level="warning", access_log=False)
server = uvicorn.Server(config)
# Server.run() is the synchronous wrapper around the async serve() coroutine.
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

db = database.SessionLocal()


def hdr(token: str | None = None) -> dict:
    h = {"Content-Type": "application/json"}
    if token:
        h["Authorization"] = f"Bearer {token}"
    return h


def seed_teacher(email: str, role: str = "teacher", is_active: bool = True):
    """Create an account directly in the throwaway DB (bootstrap equivalent)."""
    t = models.Teacher(
        name=f"Seed {role}",
        email=email,
        password=main.password_hash.hash("Campus@2026"),
        role=role,
        is_active=is_active,
        created_at=datetime.utcnow(),
    )
    db.add(t)
    db.commit()
    db.refresh(t)
    return t


def teacher_login(email: str) -> tuple[str, dict]:
    r = requests.post(
        f"{BASE}/teacher/login",
        headers=hdr(),
        json={"email": email, "password": "Campus@2026"},
        timeout=10,
    )
    return (r.json().get("token") if r.status_code == 200 else None), {
        "status": r.status_code,
        "body": r.json(),
    }


def student_login(email: str):
    r = requests.post(
        f"{BASE}/login",
        headers=hdr(),
        json={"email": email, "password": "Student@2026"},
        timeout=10,
    )
    return r


def register(roll: str, email: str, password: str = "Student@2026"):
    return requests.post(
        f"{BASE}/register",
        headers=hdr(),
        json={
            "roll_number": roll,
            "email": email,
            "password": password,
            "confirm_password": password,
        },
        timeout=10,
    )


# ==========================================================================
# 0. Liveness probe
# ==========================================================================
section("0. Liveness probe (GET /health)")
health_resp = requests.get(f"{BASE}/health", timeout=10)
check(
    "GET /health -> 200 without a token",
    health_resp.status_code == 200,
    f"got {health_resp.status_code} {health_resp.text[:120]}",
)
health_body = health_resp.json() if health_resp.status_code == 200 else {}
check("health body has status ok", health_body.get("status") == "ok", str(health_body))
check(
    "health body names the service",
    health_body.get("service") == "Stryve backend",
    str(health_body),
)
check(
    "health body carries nothing else (no paths, versions or secrets)",
    set(health_body) == {"status", "service"},
    str(health_body),
)
root_resp = requests.get(f"{BASE}/", timeout=10)
check(
    "the existing GET / route still answers and was not replaced",
    root_resp.status_code == 200
    and "running" in str(root_resp.json().get("message", "")).lower(),
    root_resp.text[:120],
)


# ==========================================================================
# 1. Registry integrity
# ==========================================================================
section("1. Student registry integrity")
registry = main.STUDENT_REGISTRY
check("registry has 72 records", len(registry) == 72, f"len={len(registry)}")
check(
    "roll numbers are exactly 1..72",
    sorted(int(s["roll_number"]) for s in registry) == list(range(1, 73)),
)
check("every record is year 1", all(s["year"] == 1 for s in registry))
check("every record is division D", all(s["division"] == "D" for s in registry))
check(
    "every batch is D-1/D-2/D-3",
    all(s["batch"] in {"D-1", "D-2", "D-3"} for s in registry),
)
check(
    "every record has a name and course",
    all(s["name"].strip() and s["course"].strip() for s in registry),
)

lookup = main.lookup_student("1")
registry_name_1 = next(s for s in registry if s["roll_number"] == "1")["name"]
check(
    "lookup(1) echoes roll 1",
    lookup.roll_number == "1",
    f"got {lookup.roll_number!r}",
)
check(
    "lookup(1) returns a MASKED name, not the official full name",
    lookup.masked_name != registry_name_1
    and lookup.masked_name.startswith(registry_name_1.split()[0][0])
    and "*" in lookup.masked_name,
    f"got {lookup.masked_name!r}",
)
check(
    "lookup response has no full-name field",
    "name" not in type(lookup).model_fields,
    str(list(type(lookup).model_fields)),
)
expect_http("lookup of unknown roll -> 404", lambda: main.lookup_student("9999"), 404)

# ==========================================================================
# 2. Student registration
# ==========================================================================
section("2. Student registration (HTTP)")
r = register("1", "seed.student1@example.com")
check("valid registration -> 201", r.status_code == 201, f"got {r.status_code} {r.text[:120]}")
body = r.json()
check("response message says pending approval", "approval" in body.get("message", "").lower())
check("response status is pending", body.get("status") == "pending")

row = db.query(models.Student).filter(models.Student.roll_number == "1").first()
check("stored status is pending", status_of(row) == "pending")
check("official name came from the server registry", row.name == registry[0]["name"])
check("official branch came from the server registry", row.branch == registry[0]["course"])
check("password stored hashed (not plaintext)", row.password != "Student@2026")
check("stored hash verifies against the password", main.password_hash.verify("Student@2026", row.password))

dup_email = register("2", "seed.student1@example.com")
check("duplicate email -> 409", dup_email.status_code == 409, f"got {dup_email.status_code}")
dup_roll = register("1", "other.email@example.com")
check("duplicate roll number -> 409", dup_roll.status_code == 409, f"got {dup_roll.status_code}")
unknown_roll = register("500", "nobody@example.com")
check("unknown roll number -> 404", unknown_roll.status_code == 404, f"got {unknown_roll.status_code}")
check(
    "duplicate attempts created no extra accounts",
    db.query(models.Student).filter(models.Student.email.in_(["other.email@example.com", "nobody@example.com"])).count()
    == 0,
)

mismatch = requests.post(
    f"{BASE}/register",
    headers=hdr(),
    json={
        "roll_number": "3",
        "email": "mismatch@example.com",
        "password": "Student@2026",
        "confirm_password": "Different@2026",
    },
    timeout=10,
)
check("password confirmation mismatch -> 400", mismatch.status_code == 400, f"got {mismatch.status_code}")
check(
    "no account created for the mismatched request",
    db.query(models.Student).filter(models.Student.email == "mismatch@example.com").first() is None,
)

extra = requests.post(
    f"{BASE}/register",
    headers=hdr(),
    json={
        "roll_number": "4",
        "email": "extra@example.com",
        "password": "Student@2026",
        "confirm_password": "Student@2026",
        "name": "CLIENT SUPPLIED NAME",
        "branch": "CLIENT SUPPLIED BRANCH",
        "status": "approved",
    },
    timeout=10,
)
extra_row = db.query(models.Student).filter(models.Student.roll_number == "4").first()
check("client-supplied official fields are ignored", extra.status_code == 201 and extra_row is not None)
if extra_row is not None:
    check("stored name is the registry name, not the client's", extra_row.name == registry[3]["name"])
    check("client cannot self-approve at registration", status_of(extra_row) == "pending")

# Ineligible registry entries (synthetic, in-memory only, removed afterwards)
main.STUDENT_REGISTRY.append(
    {"roll_number": "901", "name": "TEST INELIGIBLE YEAR", "course": "Civil", "year": 2, "division": "D", "batch": "D-1"}
)
main.STUDENT_REGISTRY.append(
    {"roll_number": "902", "name": "TEST INELIGIBLE DIV", "course": "Civil", "year": 1, "division": "A", "batch": "D-1"}
)
try:
    y2 = register("901", "y2@example.com")
    check("second-year roll -> 400 (ineligible)", y2.status_code == 400, f"got {y2.status_code}")
    diva = register("902", "diva@example.com")
    check("division A roll -> 400 (ineligible)", diva.status_code == 400, f"got {diva.status_code}")
    check(
        "ineligible registrations created no accounts",
        db.query(models.Student).filter(models.Student.roll_number.in_(["901", "902"])).count() == 0,
    )
finally:
    for roll in ("901", "902"):
        main.STUDENT_REGISTRY[:] = [s for s in main.STUDENT_REGISTRY if s["roll_number"] != roll]
check("registry restored to 72 records", len(main.STUDENT_REGISTRY) == 72)

# ==========================================================================
# 3. Login and protected student endpoints
# ==========================================================================
section("3. Student login and protected endpoints")
pending_login = student_login("seed.student1@example.com")
check("pending student cannot log in -> 403", pending_login.status_code == 403, f"got {pending_login.status_code}")
_pending_body = pending_login.json()
check(
    "403 login body explains the reason via 'detail' (no 'message' key)",
    "detail" in _pending_body and "message" not in _pending_body,
    f"body keys={sorted(_pending_body)}",
)
# The Flutter login screen must therefore read 'detail', not only 'message'.
print(f"  INFO  pending-login detail: {_pending_body.get('detail')}")

# Approve the student directly in the throwaway DB so login can be exercised.
row.status = "approved"
db.commit()

approved_login = student_login("seed.student1@example.com")
check("approved student login -> 200", approved_login.status_code == 200, f"got {approved_login.status_code}")
student_token = approved_login.json().get("token")
check("login returns a token", bool(student_token))
check("login does not return the password hash", "password" not in approved_login.json())

check("GET /me with no token -> 401", requests.get(f"{BASE}/me", timeout=10).status_code == 401)
check(
    "GET /me with a bogus token -> 401",
    requests.get(f"{BASE}/me", headers=hdr("not-a-real-token"), timeout=10).status_code == 401,
)
me = requests.get(f"{BASE}/me", headers=hdr(student_token), timeout=10)
check("GET /me with the student token -> 200", me.status_code == 200, f"got {me.status_code}")
check("GET /timetable with the student token -> 200", requests.get(f"{BASE}/timetable", headers=hdr(student_token), timeout=10).status_code == 200)
check("GET /assignments with the student token -> 200", requests.get(f"{BASE}/assignments", headers=hdr(student_token), timeout=10).status_code == 200)
check("GET /timetable without a token -> 401", requests.get(f"{BASE}/timetable", timeout=10).status_code == 401)
check("GET /assignments without a token -> 401", requests.get(f"{BASE}/assignments", timeout=10).status_code == 401)

# A pending student's token must not unlock protected student APIs.
other = register("5", "pending.student@example.com")
pending_row = db.query(models.Student).filter(models.Student.roll_number == "5").first()
pending_row.token = auth.generate_token()
pending_row.token_expires_at = auth.generate_token_expiration()
db.commit()
pending_token = pending_row.token
check(
    "pending student's token on /me -> 403",
    requests.get(f"{BASE}/me", headers=hdr(pending_token), timeout=10).status_code == 403,
)
check(
    "pending student's token on /timetable -> 403",
    requests.get(f"{BASE}/timetable", headers=hdr(pending_token), timeout=10).status_code == 403,
)
check(
    "pending student's token on /assignments -> 403",
    requests.get(f"{BASE}/assignments", headers=hdr(pending_token), timeout=10).status_code == 403,
)

# Rejected students are blocked too.
pending_row.status = "rejected"
db.commit()
check(
    "rejected student's token on /me -> 403",
    requests.get(f"{BASE}/me", headers=hdr(pending_token), timeout=10).status_code == 403,
)
check(
    "rejected student cannot log in -> 403",
    student_login("pending.student@example.com").status_code == 403,
)

# ==========================================================================
# 3b. Student login brute-force brake
# ==========================================================================
section("3b. Student login brute-force brake")

# The brake counts FAILED attempts only, per client, and a success clears the
# counter - the same behaviour the teacher portal has always had. Reset first
# so earlier sections cannot have spent the allowance.
main.student_login_limiter.reset()
login_limit = main.settings.STUDENT_LOGIN_RATE_LIMIT_PER_MINUTE

if login_limit <= 0:
    check("student login brake is disabled by configuration", True, "limit=0")
else:
    guesses = [
        requests.post(
            f"{BASE}/login",
            headers=hdr(),
            json={
                "email": "seed.student1@example.com",
                "password": f"Wrong{i}@2026",
            },
            timeout=10,
        )
        for i in range(login_limit)
    ]
    check(
        "wrong passwords are 401 while the allowance lasts",
        all(response.status_code == 401 for response in guesses),
        str([response.status_code for response in guesses]),
    )

    throttled = requests.post(
        f"{BASE}/login",
        headers=hdr(),
        json={"email": "seed.student1@example.com", "password": "WrongAgain@2026"},
        timeout=10,
    )
    check(
        "the attempt after the allowance -> 429",
        throttled.status_code == 429,
        f"got {throttled.status_code}",
    )
    check(
        "429 carries a Retry-After of at least one second",
        (throttled.headers.get("Retry-After") or "0").isdigit()
        and int(throttled.headers.get("Retry-After") or 0) >= 1,
        str(throttled.headers.get("Retry-After")),
    )
    check(
        "429 body uses 'detail' (clients read that first)",
        isinstance(throttled.json().get("detail"), str)
        and "message" not in throttled.json(),
        str(throttled.json())[:120],
    )

    # A blocked client must not be able to guess whether an account exists: the
    # 429 is returned before the email is looked up.
    unknown_while_blocked = requests.post(
        f"{BASE}/login",
        headers=hdr(),
        json={"email": "nobody@example.com", "password": "WrongAgain@2026"},
        timeout=10,
    )
    check(
        "a blocked client is throttled even for an unknown email",
        unknown_while_blocked.status_code == 429,
        f"got {unknown_while_blocked.status_code}",
    )

    # A success must clear the counter. Spend all but one of the allowance,
    # sign in correctly, then spend a full allowance again: those later attempts
    # are all 401 only if the successful sign-in reset the window.
    main.student_login_limiter.reset()
    for i in range(max(0, login_limit - 1)):
        requests.post(
            f"{BASE}/login",
            headers=hdr(),
            json={
                "email": "seed.student1@example.com",
                "password": f"Before{i}@2026",
            },
            timeout=10,
        )

    signed_in = student_login("seed.student1@example.com")
    check(
        "a correct password signs in on the last allowed slot",
        signed_in.status_code == 200,
        f"got {signed_in.status_code}",
    )

    after_reset = [
        requests.post(
            f"{BASE}/login",
            headers=hdr(),
            json={
                "email": "seed.student1@example.com",
                "password": f"After{i}@2026",
            },
            timeout=10,
        ).status_code
        for i in range(login_limit)
    ]
    check(
        "the successful sign-in cleared the failed-attempt counter",
        all(code == 401 for code in after_reset),
        str(after_reset),
    )
    main.student_login_limiter.reset()

recovered = student_login("seed.student1@example.com")
check(
    "a correct password still signs in once the window is clear",
    recovered.status_code == 200,
    f"got {recovered.status_code}",
)
# Signing in again rotates this account's single active token by design, so the
# logout section below must use the token that is current now.
student_token = recovered.json().get("token")

# _client_key is the trust boundary for every limiter: the forwarded header is
# only used when the request itself arrived from this machine.
class _Peer:
    """Minimal stand-in for a Starlette Request (only client/headers are read)."""

    def __init__(self, host: str, headers=None):
        self.client = type("Client", (), {"host": host})()
        self.headers = headers or {}


check(
    "loopback peer: last forwarded hop becomes the key",
    main._client_key(_Peer("127.0.0.1", {"x-forwarded-for": "1.2.3.4, 5.6.7.8"}))
    == "5.6.7.8",
)
check(
    "non-loopback peer: a supplied forwarded header is ignored",
    main._client_key(_Peer("10.0.0.9", {"x-forwarded-for": "1.2.3.4"})) == "10.0.0.9",
)
check(
    "loopback peer without the header keys on the peer",
    main._client_key(_Peer("127.0.0.1")) == "127.0.0.1",
)
check(
    "IPv6 loopback is local too",
    main._client_key(_Peer("::1", {"x-forwarded-for": "9.9.9.9"})) == "9.9.9.9",
)
check(
    "an empty forwarded header falls back to the peer",
    main._client_key(_Peer("127.0.0.1", {"x-forwarded-for": " , "})) == "127.0.0.1",
)

# ==========================================================================
# 4. Logout and expiry
# ==========================================================================
section("4. Logout and token expiry")
check("POST /logout -> 200", requests.post(f"{BASE}/logout", headers=hdr(student_token), timeout=10).status_code == 200)
check(
    "token no longer works after logout -> 401",
    requests.get(f"{BASE}/me", headers=hdr(student_token), timeout=10).status_code == 401,
)

second_login = student_login("seed.student1@example.com")
second_token = second_login.json().get("token")
row = db.query(models.Student).filter(models.Student.roll_number == "1").first()
row.token_expires_at = datetime.utcnow() - timedelta(minutes=5)
db.commit()
check(
    "expired token -> 401",
    requests.get(f"{BASE}/me", headers=hdr(second_token), timeout=10).status_code == 401,
)
db.refresh(row)
check("expired token is cleared in the database", row.token is None)

# ==========================================================================
# 5. Teacher authentication and authorization
# ==========================================================================
section("5. Teacher/admin authentication and authorization")
admin = seed_teacher("seed.admin@example.com", role="admin")
teacher = seed_teacher("seed.teacher@example.com", role="teacher")
inactive = seed_teacher("seed.inactive@example.com", role="teacher", is_active=False)

admin_token, admin_login = teacher_login("seed.admin@example.com")
teacher_token, teacher_login_res = teacher_login("seed.teacher@example.com")
check("admin login -> 200", admin_login["status"] == 200)
check("teacher login -> 200", teacher_login_res["status"] == 200)
check("admin login response includes the role", admin_login["body"].get("role") == "admin")
check("teacher login response includes the role", teacher_login_res["body"].get("role") == "teacher")
check(
    "inactive teacher cannot log in -> 403",
    teacher_login("seed.inactive@example.com")[1]["status"] == 403,
)
check("wrong password -> 401", requests.post(f"{BASE}/teacher/login", json={"email": "seed.teacher@example.com", "password": "Nope@12345"}, timeout=10).status_code == 401)

check("GET /teacher/me with the admin token -> 200", requests.get(f"{BASE}/teacher/me", headers=hdr(admin_token), timeout=10).status_code == 200)
check("GET /teacher/me with the teacher token -> 200", requests.get(f"{BASE}/teacher/me", headers=hdr(teacher_token), timeout=10).status_code == 200)
check(
    "GET /teacher/me with a student token -> 401",
    requests.get(f"{BASE}/teacher/me", headers=hdr(second_token), timeout=10).status_code == 401,
)
check("GET /teacher/me without a token -> 401", requests.get(f"{BASE}/teacher/me", timeout=10).status_code == 401)

check("admin can list teachers -> 200", requests.get(f"{BASE}/teacher/list", headers=hdr(admin_token), timeout=10).status_code == 200)
check(
    "regular teacher CANNOT list teachers -> 403",
    requests.get(f"{BASE}/teacher/list", headers=hdr(teacher_token), timeout=10).status_code == 403,
)
check(
    "student token cannot list teachers -> 401",
    requests.get(f"{BASE}/teacher/list", headers=hdr(second_token), timeout=10).status_code == 401,
)

check("admin can read pending registrations -> 200", requests.get(f"{BASE}/teacher/registrations/pending", headers=hdr(admin_token), timeout=10).status_code == 200)
# The approval workflow is a configurable permission: an admin always has it, a
# regular teacher only when it has been explicitly granted. This suite's teacher
# account starts WITHOUT it, so the 403 below is the new, intended contract.
check(
    "a teacher without the approval permission cannot read pending registrations -> 403",
    requests.get(f"{BASE}/teacher/registrations/pending", headers=hdr(teacher_token), timeout=10).status_code == 403,
)
check(
    "that refusal explains the missing permission",
    "not permitted" in requests.get(
        f"{BASE}/teacher/registrations/pending", headers=hdr(teacher_token), timeout=10
    ).text,
)
check(
    "a teacher cannot grant themselves the approval permission -> 403",
    requests.patch(
        f"{BASE}/teacher/{teacher.id}/permissions",
        headers=hdr(teacher_token),
        json={"can_approve_registrations": True},
        timeout=10,
    ).status_code
    == 403,
)
db.refresh(teacher)
check(
    "the self-grant attempt changed nothing",
    teacher.can_approve_registrations is False,
)
grant = requests.patch(
    f"{BASE}/teacher/{teacher.id}/permissions",
    headers=hdr(admin_token),
    json={"can_approve_registrations": True},
    timeout=10,
)
check("an admin can grant the approval permission -> 200", grant.status_code == 200, f"got {grant.status_code}")
check(
    "the granted permission is reported as effective",
    grant.json().get("can_review_registrations") is True,
)
check(
    "the granted teacher can read pending registrations -> 200",
    requests.get(f"{BASE}/teacher/registrations/pending", headers=hdr(teacher_token), timeout=10).status_code == 200,
)
check(
    "student cannot read pending registrations -> 401",
    requests.get(f"{BASE}/teacher/registrations/pending", headers=hdr(second_token), timeout=10).status_code == 401,
)
inactive_ok, inactive_res = teacher_login("seed.inactive@example.com")
inactive.token = auth.generate_token()
inactive.token_expires_at = auth.generate_token_expiration()
db.commit()
check(
    "an inactive teacher's token is refused -> 403",
    requests.get(f"{BASE}/teacher/me", headers=hdr(inactive.token), timeout=10).status_code == 403,
)

# ==========================================================================
# 6. Teacher creation and the password policy (over HTTP)
# ==========================================================================
section("6. Teacher creation and password policy")
teachers_before = len(requests.get(f"{BASE}/teacher/list", headers=hdr(admin_token), timeout=10).json())

weak_cases = [
    ("Pass1", "too short"),
    ("abcdefghij", "no digit"),
    ("12345678", "no letter"),
]
for index, (password, why) in enumerate(weak_cases):
    r = requests.post(
        f"{BASE}/teacher/create",
        headers=hdr(admin_token),
        json={
            "name": "Weak Candidate",
            "email": f"weak.{index}@example.com",
            "password": password,
            "role": "teacher",
        },
        timeout=10,
    )
    body_text = r.text.lower()
    check(f"weak password rejected ({why}) -> 422", r.status_code == 422, f"got {r.status_code} {r.text[:120]}")
    check(
        f"weak password error explains the rule ({why})",
        r.status_code == 422 and "password" in body_text,
        f"body={r.text[:120]}",
    )

teachers_after = len(requests.get(f"{BASE}/teacher/list", headers=hdr(admin_token), timeout=10).json())
check(
    "no account was created by the rejected requests",
    teachers_before == teachers_after,
    f"before={teachers_before} after={teachers_after}",
)
check(
    "no weak-password account exists in the database",
    db.query(models.Teacher).filter(models.Teacher.email.like("weak.%@example.com")).count() == 0,
)

r = requests.post(
    f"{BASE}/teacher/create",
    headers=hdr(admin_token),
    json={
        "name": "Valid Teacher",
        "email": "valid.teacher@example.com",
        "password": "Campus@2026",
        "role": "teacher",
    },
    timeout=10,
)
check("strong password creates the account -> 200", r.status_code == 200, f"got {r.status_code} {r.text[:120]}")
created = r.json()
check("created account response has the expected fields", set(created) >= {"id", "name", "email", "role", "is_active"})
check("created account is active", created.get("is_active") is True)
check("response never contains a password", "password" not in json.dumps(created).lower())

stored = db.query(models.Teacher).filter(models.Teacher.email == "valid.teacher@example.com").first()
check("new teacher stored with a hashed password", stored is not None and stored.password != "Campus@2026")
if stored:
    check("stored teacher hash verifies", main.password_hash.verify("Campus@2026", stored.password))

dup = requests.post(
    f"{BASE}/teacher/create",
    headers=hdr(admin_token),
    json={"name": "Dup", "email": "valid.teacher@example.com", "password": "Campus@2026", "role": "teacher"},
    timeout=10,
)
check("duplicate teacher email -> 409", dup.status_code == 409, f"got {dup.status_code}")
bad_role = requests.post(
    f"{BASE}/teacher/create",
    headers=hdr(admin_token),
    json={"name": "Bad", "email": "bad.role@example.com", "password": "Campus@2026", "role": "superuser"},
    timeout=10,
)
check("invalid role -> 400", bad_role.status_code == 400, f"got {bad_role.status_code}")
check(
    "invalid role created no account",
    db.query(models.Teacher).filter(models.Teacher.email == "bad.role@example.com").first() is None,
)
check(
    "regular teacher cannot create accounts -> 403",
    requests.post(
        f"{BASE}/teacher/create",
        headers=hdr(teacher_token),
        json={"name": "Nope", "email": "nope@example.com", "password": "Campus@2026", "role": "admin"},
        timeout=10,
    ).status_code
    == 403,
)
check(
    "teacher escalation attempt created no account",
    db.query(models.Teacher).filter(models.Teacher.email == "nope@example.com").first() is None,
)
check(
    "student token cannot create accounts -> 401",
    requests.post(
        f"{BASE}/teacher/create",
        headers=hdr(second_token),
        json={"name": "Nope", "email": "nope2@example.com", "password": "Campus@2026", "role": "admin"},
        timeout=10,
    ).status_code
    == 401,
)

# ==========================================================================
# 7. Approval workflow
# ==========================================================================
section("7. Approval / rejection workflow")
pending_list = requests.get(f"{BASE}/teacher/registrations/pending", headers=hdr(teacher_token), timeout=10).json()
check("pending list is a JSON array", isinstance(pending_list, list))
check("pending list contains only pending students", all(p["status"] == "pending" for p in pending_list))
check("pending list never exposes password fields", all("password" not in p for p in pending_list))
# A fresh pending registration for the approval flow (roll 5 above was rejected
# earlier, which is exactly the state the approve guard must refuse).
register("6", "to.approve@example.com")
approve_target = db.query(models.Student).filter(models.Student.roll_number == "6").first()
target_id = approve_target.id

ok = post(f"/teacher/registrations/{target_id}/approve", teacher_token, {})
check("approve -> 200", ok.status_code == 200, f"got {ok.status_code} {ok.text[:120]}")
check("approve response status approved", ok.json().get("status") == "approved")
db.refresh(approve_target)
check("approved_by records the approving teacher", approve_target.approved_by == teacher.id)
check("approved_at is recorded", approve_target.approved_at is not None)
check("rejection_reason cleared on approve", approve_target.rejection_reason is None)
check(
    "a rejected student cannot be approved -> 400",
    post(f"/teacher/registrations/{pending_row.id}/approve", teacher_token, {}).status_code == 400,
)
check(
    "approving an already-processed registration -> 400",
    post(f"/teacher/registrations/{target_id}/approve", teacher_token, {}).status_code == 400,
)
check(
    "rejecting an approved registration -> 400",
    post(f"/teacher/registrations/{target_id}/reject", teacher_token, {"reason": "x"}).status_code == 400,
)
check(
    "approve unknown student -> 404",
    post("/teacher/registrations/999999/approve", teacher_token, {}).status_code == 404,
)
check(
    "approving a partially approved registration twice leaves one approval",
    db.query(models.Student).filter(models.Student.id == target_id).count() == 1,
)
reject_target = db.query(models.Student).filter(models.Student.roll_number == "2").first()
if reject_target is None:
    register("2", "to.reject@example.com")
    reject_target = db.query(models.Student).filter(models.Student.roll_number == "2").first()
rej = post(
    f"/teacher/registrations/{reject_target.id}/reject",
    teacher_token,
    {"reason": "Incomplete documents"},
)
check("reject -> 200", rej.status_code == 200, f"got {rej.status_code}")
db.refresh(reject_target)
check("rejected status stored", status_of(reject_target) == "rejected")
check("rejection reason stored", reject_target.rejection_reason == "Incomplete documents")
check(
    "rejecting the same registration again -> 400",
    post(f"/teacher/registrations/{reject_target.id}/reject", teacher_token, {"reason": "again"}).status_code == 400,
)
check(
    "student token cannot approve -> 401",
    post(f"/teacher/registrations/{reject_target.id}/approve", second_token, {}).status_code == 401,
)

# ==========================================================================
# 8. Database constraints and data separation
# ==========================================================================
section("8. Database constraints and credential separation")
from sqlalchemy.exc import IntegrityError  # noqa: E402

dup_roll_student = models.Student(
    name="Dup Roll",
    email="dup.roll@example.com",
    roll_number="1",
    branch="Civil",
    year=1,
    division="D",
    batch="D-1",
    password=main.password_hash.hash("Student@2026"),
    status="pending",
)
db.add(dup_roll_student)
try:
    db.commit()
    check("unique roll_number is enforced by the database", False, "duplicate insert succeeded")
except IntegrityError:
    db.rollback()
    check("unique roll_number is enforced by the database", True)

dup_email_student = models.Student(
    name="Dup Email",
    email="seed.student1@example.com",
    roll_number="60",
    branch="Civil",
    year=1,
    division="D",
    batch="D-1",
    password=main.password_hash.hash("Student@2026"),
    status="pending",
)
db.add(dup_email_student)
try:
    db.commit()
    check("unique email is enforced by the database", False, "duplicate insert succeeded")
except IntegrityError:
    db.rollback()
    check("unique email is enforced by the database", True)

# Logging a student out must not disturb the teacher session, and vice versa.
third = student_login("seed.student1@example.com")
third_token = third.json().get("token")
requests.post(f"{BASE}/logout", headers=hdr(third_token), timeout=10)
check("student logout kept the teacher session usable", requests.get(f"{BASE}/teacher/me", headers=hdr(teacher_token), timeout=10).status_code == 200)
requests.post(f"{BASE}/teacher/logout", headers=hdr(teacher_token), timeout=10)
teacher_row = db.query(models.Teacher).filter(models.Teacher.email == "seed.teacher@example.com").first()
db.refresh(teacher_row)
check("teacher logout cleared only the teacher token", teacher_row.token is None)
active_students = db.query(models.Student).filter(models.Student.token.isnot(None)).count()
check("teacher logout left student tokens intact", active_students >= 1)

# Direct dependency checks (unit level)
expect_http("require_admin(teacher) -> 403", lambda: auth.require_admin(teacher), 403)
check("require_admin(admin) returns the admin", auth.require_admin(admin).id == admin.id)
check(
    "require_teacher_or_admin(teacher) allows a teacher",
    auth.require_teacher_or_admin(("teacher", teacher)).id == teacher.id,
)
expect_http(
    "require_teacher_or_admin(student) -> 403",
    lambda: auth.require_teacher_or_admin(("student", row)),
    403,
)
expect_http(
    "get_current_student on an expired token -> 401",
    lambda: (
        setattr(row, "token_expires_at", datetime.utcnow() - timedelta(days=1)),
        setattr(row, "token", "expired-token-value"),
        db.commit(),
        auth.get_current_student(authorization="Bearer expired-token-value", db=db),
    ),
    401,
)
db.refresh(row)
check("expired session token cleared by the dependency", row.token is None)

# ==========================================================================
# The real database must be untouched by this whole run
# ==========================================================================
check(
    "this suite used the throwaway database",
    Path(database.DATABASE_PATH) == DB_FILE and DB_FILE.exists(),
    str(database.DATABASE_PATH),
)
check(
    "real database size/mtime unchanged by this suite",
    stamp_of(REAL_DB) == REAL_DB_STAMP,
    f"before={REAL_DB_STAMP} after={stamp_of(REAL_DB)}",
)

# ==========================================================================
# Summary
# ==========================================================================
print(f"\n{'=' * 60}")
print(f"checks passed: {len(PASSED)}")
print(f"checks failed: {len(FAILED)}")
if FAILED:
    print("\nfailures:")
    for f in FAILED:
        print(f"  - {f}")

server.should_exit = True
thread.join(timeout=10)
db.close()

sys.exit(1 if FAILED else 0)
