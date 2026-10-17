"""Registry-lookup privacy, abuse limits and the full registration flow.

What is being protected
-----------------------
`GET /students/lookup/{roll_number}` is unauthenticated on purpose: a
first-time student must be able to confirm their roll number before they can
register. It used to answer with the student's full official name for any roll
number in 1..72, which let anyone harvest the registry. It now returns a MASKED
name and is rate limited, and the full name is only disclosed to authenticated
staff (approval queue) and to the student after approval.

These tests run against a THROWAWAY database over real HTTP (in-process
uvicorn), with a small lookup limit so the 429 path is exercised.

RUN
---
    mkdir /tmp/cs-privacy && cd /tmp/cs-privacy
    <repo>/backend/venv/Scripts/python.exe <repo>/backend/tests/test_lookup_privacy.py
"""

import os
import socket
import sys
import tempfile
import threading
import time
from datetime import datetime, timezone
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
TMP_DIR = Path(tempfile.mkdtemp(prefix="cs-privacy-db-")).resolve()
DB_FILE = TMP_DIR / "campussync.db"
if DB_FILE == REAL_DB:
    sys.exit(f"REFUSING TO RUN: {DB_FILE} is the real database.")

LOOKUP_LIMIT = 5
os.environ["DATABASE_URL"] = f"sqlite:///{DB_FILE.as_posix()}"
os.environ["ALLOW_DB_CREATE"] = "1"
os.environ["LOOKUP_RATE_LIMIT_PER_MINUTE"] = str(LOOKUP_LIMIT)

sys.path.insert(0, str(BACKEND_DIR))

import requests  # noqa: E402
import uvicorn  # noqa: E402

import database  # noqa: E402
import main  # noqa: E402
import models  # noqa: E402
from privacy import mask_name  # noqa: E402
from ratelimit import SlidingWindowLimiter  # noqa: E402

if Path(database.DATABASE_PATH or "") != DB_FILE:
    sys.exit(
        f"REFUSING TO RUN: the app resolved {database.DATABASE_PATH}, "
        f"expected the throwaway {DB_FILE}."
    )

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
print(f"test server: {BASE}   (lookup limit: {LOOKUP_LIMIT}/minute)")

db = database.SessionLocal()
registry = main.STUDENT_REGISTRY
registry_names = [record["name"] for record in registry]


def lookup(roll: str):
    """One lookup; resets the limiter first so tests do not interfere."""
    main.lookup_limiter.reset()
    return requests.get(f"{BASE}/students/lookup/{roll}", timeout=10)


# ==========================================================================
section("1. mask_name is an initials mask, not the name")
# ==========================================================================
masked = mask_name("SHUBHAM SURESH AHIRE")
check("first letters of every token are kept", masked.split()[0][0] == "S" and masked.split()[1][0] == "S" and masked.split()[2][0] == "A", masked)
check("every long token is masked", masked == "S****** S***** A****", masked)
check("token count is preserved", len(masked.split()) == 3, masked)
check("mask contains no full word of the original", all(word not in masked for word in ("SHUBHAM", "SURESH", "AHIRE")))
check("single-character tokens are kept as-is", mask_name("A B") == "A B", mask_name("A B"))
check("extra whitespace is normalised", mask_name("  OM   NITIN  PISE ") == "O* N**** P***", mask_name("  OM   NITIN  PISE "))
check("empty name stays empty", mask_name("") == "")
check(
    "every registry name is masked differently from the original",
    all(mask_name(name) != name and "*" in mask_name(name) for name in registry_names),
)
check(
    "no registry name survives masking in full",
    all(name not in mask_name(name) for name in registry_names),
)

# ==========================================================================
section("2. Valid and invalid roll numbers (HTTP)")
# ==========================================================================
response = lookup("1")
check("valid roll -> 200", response.status_code == 200, f"got {response.status_code}")
body = response.json()
check(
    "response carries exactly the registration details",
    set(body) == {"roll_number", "masked_name", "branch", "year", "division", "batch"},
    str(sorted(body)),
)
check("roll number is echoed", body.get("roll_number") == "1", str(body.get("roll_number")))
check("no full-name field in the response", "name" not in body, str(sorted(body)))
official_name_1 = next(r["name"] for r in registry if r["roll_number"] == "1")
check(
    "the registry full name is not returned",
    body.get("masked_name") != official_name_1 and official_name_1 not in response.text,
    response.text[:200],
)
check(
    "the mask matches the registry name's initials",
    body.get("masked_name") == mask_name(official_name_1),
    str(body.get("masked_name")),
)
check("branch/year/division/batch are the official ones", body.get("branch") and body.get("year") == 1 and body.get("division") == "D", str(body))
check(
    "no credential fields leak",
    not any(field in response.text for field in ("password", "token", "email")),
    response.text[:200],
)

unknown = lookup("9999")
check("unknown roll -> 404", unknown.status_code == 404, f"got {unknown.status_code}")
check("404 body uses detail", "detail" in unknown.json(), str(unknown.json())[:200])
non_numeric = lookup("abc")
check("non-numeric roll -> 404", non_numeric.status_code == 404, f"got {non_numeric.status_code}")
check(
    "404 bodies expose no student data",
    not any(name in non_numeric.text for name in registry_names),
)
empty_roll = requests.get(f"{BASE}/students/lookup/", timeout=10)
check(
    "a bare lookup path is not a valid lookup",
    empty_roll.status_code in (404, 405, 307, 308),
    f"got {empty_roll.status_code}",
)

# ==========================================================================
section("3. Enumeration resistance: masking + a real rate limit")
# ==========================================================================
main.lookup_limiter.reset()
statuses = []
collected = []
for roll in range(1, LOOKUP_LIMIT + 3):
    r = requests.get(f"{BASE}/students/lookup/{roll}", timeout=10)
    statuses.append(r.status_code)
    collected.append(r.text)

check(
    f"the first {LOOKUP_LIMIT} lookups succeed",
    all(code == 200 for code in statuses[:LOOKUP_LIMIT]),
    str(statuses),
)
check(
    "the next lookups are refused with 429",
    all(code == 429 for code in statuses[LOOKUP_LIMIT:]) and len(statuses) > LOOKUP_LIMIT,
    str(statuses),
)

throttled = requests.get(f"{BASE}/students/lookup/1", timeout=10)
check("a throttled lookup explains itself with detail", "detail" in throttled.json(), throttled.text[:200])
check("429 sets Retry-After", throttled.headers.get("Retry-After", "").isdigit(), str(throttled.headers))
check(
    "NOT ONE full registry name was disclosed during enumeration",
    not any(name in text for name in registry_names for text in collected),
)
check(
    "only initials were disclosed during enumeration",
    all(("masked_name" in text) or ("detail" in text) for text in collected),
)
check(
    "other endpoints are not affected by the lookup limit",
    all(requests.get(f"{BASE}/", timeout=10).status_code == 200 for _ in range(LOOKUP_LIMIT + 2)),
)
main.lookup_limiter.reset()

# ==========================================================================
section("4. Limiter window behaves (deterministic, injected clock)")
# ==========================================================================
limiter = SlidingWindowLimiter(limit=3, window_seconds=60.0)
clock = 1000.0
allowed = [limiter.check("ip", now=clock + i * 0.5)[0] for i in range(3)]
fourth, retry_after = limiter.check("ip", now=clock + 1.6)
check("under the limit: allowed", all(allowed), str(allowed))
check("over the limit: refused with a retry hint", fourth is False and 0 < retry_after <= 60, f"{fourth} {retry_after}")
check(
    "after the window slides, the same client is allowed again",
    limiter.check("ip", now=clock + 61)[0] is True,
)
check("a different client has its own budget", limiter.check("other-ip", now=clock + 61.1)[0] is True)
zero = SlidingWindowLimiter(limit=0)
check("limit 0 disables limiting", zero.check("ip")[0] is True)

# ==========================================================================
section("5. Complete registration flow (masked lookup -> approval -> login)")
# ==========================================================================
main.lookup_limiter.reset()

admin = models.Teacher(
    name="Seed admin",
    email="privacy.admin@example.com",
    password=main.password_hash.hash("Campus@2026"),
    role="admin",
    is_active=True,
    created_at=datetime.now(timezone.utc),
)
db.add(admin)
db.commit()
db.refresh(admin)

login = requests.post(
    f"{BASE}/teacher/login",
    json={"email": "privacy.admin@example.com", "password": "Campus@2026"},
    timeout=10,
)
check("seed teacher can log in", login.status_code == 200, login.text[:200])
admin_token = login.json().get("token")


def hdr(token=None):
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    return headers


pre = lookup("7")
check("step 1: lookup shows only a masked name", pre.status_code == 200 and "*" in pre.json()["masked_name"], pre.text[:200])

registration = requests.post(
    f"{BASE}/register",
    headers=hdr(),
    json={
        "roll_number": "7",
        "email": "privacy.student7@example.com",
        "password": "Campus@2026",
        "confirm_password": "Campus@2026",
        # a client cannot supply its own official details
        "name": "FAKE NAME",
        "branch": "Fake",
        "year": 4,
        "division": "Z",
        "batch": "D-9",
    },
    timeout=10,
)
check("step 2: registration -> 201", registration.status_code == 201, f"got {registration.status_code} {registration.text[:200]}")
check("step 2: response says pending", registration.json().get("status") == "pending", registration.text[:200])

row = db.query(models.Student).filter(models.Student.roll_number == "7").first()
db.refresh(row)
official_name_7 = next(r["name"] for r in registry if r["roll_number"] == "7")
check("stored name comes from the registry, not the client", row.name == official_name_7, row.name)
check("stored branch/year/division/batch come from the registry", row.year == 1 and row.division == "D" and row.batch != "D-9", f"{row.year} {row.division} {row.batch}")

pending_login = requests.post(
    f"{BASE}/login",
    headers=hdr(),
    json={"email": "privacy.student7@example.com", "password": "Campus@2026"},
    timeout=10,
)
check("step 3: a pending account cannot log in (403)", pending_login.status_code == 403, f"got {pending_login.status_code}")

no_token = requests.get(f"{BASE}/teacher/registrations/pending", headers=hdr(), timeout=10)
check("step 4: the approval queue needs a token (401)", no_token.status_code == 401, f"got {no_token.status_code}")

queue = requests.get(f"{BASE}/teacher/registrations/pending", headers=hdr(admin_token), timeout=10)
check("step 4: staff see the queue", queue.status_code == 200, queue.text[:200])
check(
    "step 4: the FULL official name is disclosed only here, to staff",
    row.id in [item["id"] for item in queue.json()] and official_name_7 in queue.text,
    queue.text[:300],
)

approve = requests.post(
    f"{BASE}/teacher/registrations/{row.id}/approve",
    headers=hdr(admin_token),
    json={},  # the endpoint takes an (empty) ApproveRequest body
    timeout=10,
)
check("step 5: approval -> 200", approve.status_code == 200, approve.text[:200])

final_login = requests.post(
    f"{BASE}/login",
    headers=hdr(),
    json={"email": "privacy.student7@example.com", "password": "Campus@2026"},
    timeout=10,
)
check("step 6: approved student can log in", final_login.status_code == 200, final_login.text[:200])
final_body = final_login.json()
check(
    "step 6: the student sees their own official name after approval",
    final_body.get("name") == official_name_7,
    str(final_body.get("name")),
)
check(
    "step 6: masks are long gone by now (this is the student's own record)",
    final_body.get("roll_number") == "7" and "masked" not in final_login.text,
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
print(f"lookup privacy tests: {len(PASSED)} passed, {len(FAILED)} failed")
for failure in FAILED:
    print(f"  FAILED: {failure}")
print("=" * 72)

server.should_exit = True
thread.join(timeout=10)
db.close()

sys.exit(1 if FAILED else 0)
