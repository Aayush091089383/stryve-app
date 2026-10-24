"""Timetable batch filtering, teacher permissions, attendance, free periods,
assignment uploads and the Faculty/Lab finder.

WHAT IS BEING PROTECTED
-----------------------
* A student only ever sees their own batch's practicals - enforced with the
  batch stored on the authenticated student, never one the client sends.
* Registration approval, teacher creation and permission changes are
  server-side permissions, not hidden buttons.
* Attendance can only be recorded by someone verified to teach that class, and
  one student/lecture cannot be recorded twice.
* A free period is only claimable when the official timetable and the existing
  claims both say so - a practical for one batch is never "free" for the whole
  division.
* Uploaded assignment PDFs are validated, stored under a server-generated name,
  and downloadable only by the students allowed to see that assignment.
* The faculty/room finders never invent a name, e-mail or room.

RUN
---
    mkdir /tmp/cs-teacher && cd /tmp/cs-teacher
    <repo>/backend/venv/Scripts/python.exe <repo>/backend/tests/test_teacher_features.py

Everything runs against a THROWAWAY database in a temp directory and a
temporary upload directory; the real backend/campussync.db is only stamped and
re-stamped to prove this suite never touched it.
"""

import contextlib
import hashlib
import io
import json
import os
import shutil
import socket
import sqlite3
import sys
import tempfile
import threading
import time
from datetime import date, datetime, timedelta
from pathlib import Path

BACKEND_DIR = Path(__file__).resolve().parent.parent
REAL_DB = (BACKEND_DIR / "campussync.db").resolve()
REAL_DB_STAMP = (
    (REAL_DB.stat().st_size, REAL_DB.stat().st_mtime_ns) if REAL_DB.exists() else None
)

TMP_DIR = Path(tempfile.mkdtemp(prefix="cs-teacher-db-")).resolve()
DB_FILE = TMP_DIR / "campussync.db"
UPLOAD_DIR = TMP_DIR / "uploads"
if DB_FILE == REAL_DB:
    sys.exit(f"REFUSING TO RUN: {DB_FILE} is the real database.")

MAX_MB = 1
os.environ["DATABASE_URL"] = f"sqlite:///{DB_FILE.as_posix()}"
os.environ["ALLOW_DB_CREATE"] = "1"
os.environ["UPLOAD_DIR"] = str(UPLOAD_DIR)
os.environ["MAX_ASSIGNMENT_FILE_MB"] = str(MAX_MB)

sys.path.insert(0, str(BACKEND_DIR))

import requests  # noqa: E402
import uvicorn  # noqa: E402
from pwdlib import PasswordHash  # noqa: E402

import database  # noqa: E402
import main  # noqa: E402
import models  # noqa: E402
import official_data  # noqa: E402
import seed_official_data  # noqa: E402

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


# --------------------------------------------------------------------------
# Seed the throwaway database with the official data, then the test accounts
# --------------------------------------------------------------------------
code = seed_official_data.main(["--db", str(DB_FILE), "--apply", "--no-backup"])
if code != 0:
    sys.exit(f"REFUSING TO RUN: seeding the throwaway database failed ({code}).")

sock = socket.socket()
sock.bind(("127.0.0.1", 0))
PORT = sock.getsockname()[1]
BASE = f"http://127.0.0.1:{PORT}"

server = uvicorn.Server(uvicorn.Config(main.app, log_level="warning", access_log=False))
threading.Thread(target=server.run, kwargs={"sockets": [sock]}, daemon=True).start()

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
print(f"temporary uploads : {UPLOAD_DIR}")
print(f"test server       : {BASE}")

db = database.SessionLocal()

# Read-only connection used to prove what actually landed in the database.
# autocommit (isolation_level=None) so every SELECT sees the latest commit.
conn = sqlite3.connect(DB_FILE, isolation_level=None)

STUDENTS = {
    # roll -> (name, branch, batch)
    "1": ("SHUBHAM SURESH AHIRE", "Mechanical", "D-1"),
    "25": ("BHAGYASHRI VITTHALSINGH GIRASE", "Computer", "D-2"),
    "49": ("GOPAL RAJENDRA PATIL", "E&TC", "D-3"),
    "2": ("SIMNA AHAD AKIL", "Electrical", "D-1"),
    "26": ("SAMRUDDHI SAMEER GOVANDE", "Electrical", "D-2"),
    "50": ("TOSHIKA TUSHAR PATIL", "Computer", "D-3"),
    "71": ("AAYUSH SHANTARAM TITAME", "AI&DS", "D-3"),
}

for roll, (name, branch, batch) in STUDENTS.items():
    db.add(
        models.Student(
            name=name,
            email=f"student{roll}@example.com",
            roll_number=roll,
            branch=branch,
            year=1,
            division="D",
            batch=batch,
            password=password_hash.hash(PASSWORD),
            status="approved",
        )
    )

# A student whose stored batch is unusable: the backend must fail closed for
# them (common lectures only), never fall back to "show everything".
db.add(
    models.Student(
        name="INVALID BATCH STUDENT",
        email="badbatch@example.com",
        roll_number="900",
        branch="Computer",
        year=1,
        division="D",
        batch="X-9",
        password=password_hash.hash(PASSWORD),
        status="approved",
    )
)
db.add(
    models.Student(
        name="EMPTY BATCH STUDENT",
        email="emptybatch@example.com",
        roll_number="901",
        branch="Computer",
        year=1,
        division="D",
        batch="",
        password=password_hash.hash(PASSWORD),
        status="approved",
    )
)
db.add(
    models.Student(
        name="PENDING STUDENT",
        email="pending@example.com",
        roll_number="902",
        branch="Computer",
        year=1,
        division="D",
        batch="D-1",
        password=password_hash.hash(PASSWORD),
        status="pending",
    )
)
# A second pending student that is never approved, so "an unapproved student
# cannot be marked" keeps testing what it says even after the approval test.
db.add(
    models.Student(
        name="NEVER APPROVED STUDENT",
        email="pending2@example.com",
        roll_number="903",
        branch="Computer",
        year=1,
        division="D",
        batch="D-1",
        password=password_hash.hash(PASSWORD),
        status="pending",
    )
)

# A pre-existing (text-only, no uploader) assignment record, exactly like the
# ones already in the real database - it must survive every code path here.
db.add(
    models.Assignment(
        subject="C Programming",
        title="Assignment 1",
        description="Write programs covering loops, arrays, and functions.",
        due_date="2026-10-05",
        year=1,
        division="D",
        batch=None,
    )
)

db.add(
    models.Teacher(
        name="Admin User",
        email="admin@campusync.edu",
        password=password_hash.hash(PASSWORD),
        role="admin",
        is_active=True,
        created_at=__import__("datetime").datetime.utcnow(),
    )
)
db.add(
    models.Teacher(
        name="Plain Teacher",
        email="plain@campusync.edu",
        password=password_hash.hash(PASSWORD),
        role="teacher",
        is_active=True,
        # deliberately NOT granted approval rights
        can_approve_registrations=False,
        created_at=__import__("datetime").datetime.utcnow(),
    )
)
db.commit()
db.close()

db = database.SessionLocal()


def login(email, password=PASSWORD):
    response = requests.post(
        f"{BASE}/login", json={"email": email, "password": password}, timeout=10
    )
    if response.status_code != 200:
        sys.exit(f"student login failed for {email}: {response.status_code} {response.text[:200]}")
    return response.json()["token"]


def teacher_login(email, password=PASSWORD):
    response = requests.post(
        f"{BASE}/teacher/login", json={"email": email, "password": password}, timeout=10
    )
    if response.status_code != 200:
        sys.exit(f"teacher login failed for {email}: {response.status_code} {response.text[:200]}")
    return response.json()["token"]


def auth(token):
    return {"Authorization": f"Bearer {token}"}


def make_teacher(name, email, role="teacher"):
    response = requests.post(
        f"{BASE}/teacher/create",
        json={"name": name, "email": email, "password": PASSWORD, "role": role},
        headers=auth(admin_token),
        timeout=10,
    )
    if response.status_code != 200:  # /teacher/create answers 200 (existing behaviour)
        sys.exit(f"could not create {email}: {response.status_code} {response.text[:200]}")
    return response.json()["id"]


def set_permissions(teacher_id, **payload):
    return requests.patch(
        f"{BASE}/teacher/{teacher_id}/permissions",
        json=payload,
        headers=auth(admin_token),
        timeout=10,
    )


TOKENS = {roll: login(f"student{roll}@example.com") for roll in STUDENTS}
TOKENS["bad"] = login("badbatch@example.com")
TOKENS["empty"] = login("emptybatch@example.com")
BAD_TOKEN = TOKENS["bad"]
EMPTY_TOKEN = TOKENS["empty"]

admin_token = teacher_login("admin@campusync.edu")
plain_token = teacher_login("plain@campusync.edu")

smg_id = make_teacher("S M Gangurde", "smg@campusync.edu")
spk_id = make_teacher("S P Kulkarni", "spk@campusync.edu")
smg_token = teacher_login("smg@campusync.edu")  # noqa: F841 (used after permissions)
spk_token = teacher_login("spk@campusync.edu")

TODAY = date.today()
MONDAY = TODAY + timedelta(days=(0 - TODAY.weekday()) % 7)
MONDAY_STR = MONDAY.strftime("%Y-%m-%d")
SUNDAY_STR = (MONDAY + timedelta(days=6)).strftime("%Y-%m-%d")


# Attendance is time-locked to its lecture (15 minutes of grace either side) on
# the college clock. The suite pins that clock, so a teacher's own save is
# testable at whatever hour the suite happens to run; the lock itself is
# exercised deliberately in section 3c.
def freeze_attendance_clock(hour, minute, day=None):
    base = day or MONDAY
    target = datetime(
        base.year,
        base.month,
        base.day,
        hour,
        minute,
        tzinfo=main.COLLEGE_TIMEZONE,
    )
    main._attendance_now = lambda: target
    return target


def _next_named_date(name: str) -> date:
    """The next date (today or later) that falls on ``name`` (Monday-Saturday).

    Claim dates must be today or later - a past date is refused - so every test
    that claims computes its date forward from today instead of using the current
    week's Monday, which may already have gone by.
    """
    for offset in range(14):
        candidate = TODAY + timedelta(days=offset)
        if candidate.strftime("%A") == name:
            return candidate
    raise SystemExit(f"could not find a {name} within two weeks")


NEXT_MONDAY = _next_named_date("Monday")
NEXT_MONDAY_STR = NEXT_MONDAY.strftime("%Y-%m-%d")
NEXT_MONDAY_WEEK2_STR = (NEXT_MONDAY + timedelta(days=7)).strftime("%Y-%m-%d")
NEXT_TUESDAY_STR = _next_named_date("Tuesday").strftime("%Y-%m-%d")

# The free-period days and the times of their free periods, taken from the
# official table so the tests never hard-code a weekday that is not one.
RELM_DAY_NAMES = {day for day, _, _ in official_data.FREE_PERIOD_SLOTS}


def _next_relm_date() -> date:
    """The next date (today or later) the timetable has a free period on."""
    for offset in range(14):
        candidate = TODAY + timedelta(days=offset)
        if candidate.strftime("%A") in RELM_DAY_NAMES:
            return candidate
    raise SystemExit("no free-period day within two weeks")


RELM_DATE = _next_relm_date()
RELM_DATE_STR = RELM_DATE.strftime("%Y-%m-%d")
RELM_DAY_NAME = RELM_DATE.strftime("%A")
RELM_TIMES = [
    (start, end)
    for (day, start, end) in official_data.FREE_PERIOD_SLOTS
    if day == RELM_DAY_NAME
]
RELM_START, RELM_END = RELM_TIMES[0]
# +7 days keeps the same weekday, so these are free-period days too.
RELM_DATE_2_STR = (RELM_DATE + timedelta(days=7)).strftime("%Y-%m-%d")
RELM_DATE_3_STR = (RELM_DATE + timedelta(days=14)).strftime("%Y-%m-%d")
YESTERDAY_STR = (TODAY - timedelta(days=1)).strftime("%Y-%m-%d")
YESTERDAY_NAME = (TODAY - timedelta(days=1)).strftime("%A")

# ==========================================================================
section("1. Timetable: common lectures and batch filtering (HTTP)")
# ==========================================================================
timetables = {
    roll: requests.get(f"{BASE}/timetable", headers=auth(TOKENS[roll]), timeout=10)
    for roll in STUDENTS
}

check("every student got their timetable", all(r.status_code == 200 for r in timetables.values()))

entries = {roll: timetables[roll].json() for roll in STUDENTS}

common = {
    (e["day"], e["start_time"], e["end_time"], e["subject"])
    for e in entries["1"]
    if e["batch"] is None and not e["is_break"]
}
check("the timetable is not empty", len(entries["1"]) > 20, str(len(entries["1"])))
# 24 of the sheet's entries are common lectures; 5 of those are free periods
# ("RELM") that a student must never receive, so 19 remain. This expectation was
# changed together with the RELM rule, not relaxed: the free periods are now
# asserted absent in their own right below.
check(
    "it carries the common lectures, free periods excluded",
    len(common) == 19,
    str(len(common)),
)
check(
    "the API reports the free-period flag on every entry",
    all("is_free_period" in e for e in entries["1"]),
)
check(
    "no student timetable contains a free period",
    not [
        e
        for e in entries["1"]
        if e["is_free_period"]
        or e["subject"].strip().upper() == official_data.FREE_PERIOD_SUBJECT
    ],
    str(
        [
            (e["day"], e["start_time"], e["subject"])
            for e in entries["1"]
            if e["is_free_period"]
        ]
    ),
)
check(
    "no entry is labelled as a free period in a student's timetable",
    "free_period" not in {e["entry_type"] for e in entries["1"]},
    str(sorted({e["entry_type"] for e in entries["1"]})),
)
check(
    "the free periods are not shown as lectures either",
    not [
        e
        for e in entries["1"]
        if e["entry_type"] == "lecture"
        and (e["day"], e["start_time"], e["end_time"])
        in set(official_data.FREE_PERIOD_SLOTS)
    ],
    "a RELM period was returned as a lecture",
)
for roll, batch in (("1", "D-1"), ("25", "D-2"), ("49", "D-3")):
    check(
        f"{batch}: the free periods are excluded from that timetable too",
        not [e for e in entries[roll] if e["is_free_period"]],
        str(
            [
                (e["day"], e["start_time"])
                for e in entries[roll]
                if e["is_free_period"]
            ]
        ),
    )


for roll, batch in (("1", "D-1"), ("25", "D-2"), ("49", "D-3")):
    mine = entries[roll]
    my_common = {
        (e["day"], e["start_time"], e["end_time"], e["subject"])
        for e in mine
        if e["batch"] is None and not e["is_break"]
    }
    check(f"{batch}: sees every common lecture", my_common == common, str(len(my_common)))

    practicals = {
        (e["day"], e["start_time"], e["end_time"], e["subject"])
        for e in mine
        if e["batch"] is not None
    }
    check(f"{batch}: sees no other batch's practical", all(
        e["batch"] == batch for e in mine if e["batch"] is not None
    ))
    check(f"{batch}: sees its own practicals", len(practicals) >= 1, str(len(practicals)))

    labels = {e["batch"]: e["entry_type"] for e in mine if e["batch"] is not None}
    check(f"{batch}: practicals are labelled practical", set(labels.values()) == {"practical"}, str(labels))

# the three batches together must see exactly the whole division timetable
union = {
    (e["day"], e["start_time"], e["end_time"], e["subject"], e["batch"] or "")
    for roll in ("1", "25", "49")
    for e in entries[roll]
    if not e["is_break"]
}
# 42 teaching entries on the sheet = 18 batch practicals + 24 common
# lectures, of which 5 are free periods: 37 entries a student may see.
check(
    "the sheet's 42 teaching entries are all accounted for",
    len(official_data.TIMETABLE) == 37 + len(official_data.FREE_PERIOD_SLOTS),
    str(len(official_data.TIMETABLE)),
)
check(
    "all batches together cover every entry a student may see",
    len(union) == 37,
    str(len(union)),
)
check(
    "the five free periods are exactly what students do not see",
    len(official_data.TIMETABLE) - len(union) == len(official_data.FREE_PERIOD_SLOTS),
    f"{len(official_data.TIMETABLE)} - {len(union)}",
)


common_labels = {e["entry_type"] for e in entries["1"] if e["batch"] is None and not e["is_break"]}
check("common entries are labelled lecture", common_labels == {"lecture"}, str(common_labels))
break_labels = {e["entry_type"] for e in entries["1"] if e["is_break"]}
check("break entries are labelled break", break_labels == {"break"}, str(break_labels))

# a D-1 practical must not be in a D-2 or D-3 timetable
d1_practicals = {(e["day"], e["start_time"], e["subject"]) for e in entries["1"] if e["batch"] == "D-1"}
d2_seen = {(e["day"], e["start_time"], e["subject"]) for e in entries["25"]}
d3_seen = {(e["day"], e["start_time"], e["subject"]) for e in entries["49"]}
check("D-1 practicals never appear in the D-2 timetable", not (d1_practicals & d2_seen), str(d1_practicals & d2_seen))
check("D-1 practicals never appear in the D-3 timetable", not (d1_practicals & d3_seen), str(d1_practicals & d3_seen))

bad_entries = requests.get(f"{BASE}/timetable", headers=auth(BAD_TOKEN), timeout=10).json()
empty_entries = requests.get(f"{BASE}/timetable", headers=auth(EMPTY_TOKEN), timeout=10).json()
check("an invalid stored batch sees common lectures only", all(e["batch"] is None for e in bad_entries), str([e["batch"] for e in bad_entries if e["batch"]]))
check("an empty stored batch sees common lectures only", all(e["batch"] is None for e in empty_entries))
check("an invalid batch still sees the common lectures", len(bad_entries) >= 20, str(len(bad_entries)))
check(
    "an invalid stored batch never receives a free period",
    not [e for e in bad_entries if e["is_free_period"]],
    str([(e["day"], e["start_time"]) for e in bad_entries if e["is_free_period"]]),
)
check(
    "an empty stored batch never receives a free period",
    not [e for e in empty_entries if e["is_free_period"]],
)

# the batch cannot be chosen by the client
forced = requests.get(
    f"{BASE}/timetable?batch=D-2&division=D", headers=auth(TOKENS["1"]), timeout=10
).json()
check(
    "the client cannot ask for another batch's timetable",
    forced == entries["1"],
    "query parameters changed the result",
)

# assignments follow the same rule
assignment_batches = {
    roll: {a["batch"] for a in requests.get(f"{BASE}/assignments", headers=auth(TOKENS[roll]), timeout=10).json()}
    for roll in ("1", "25", "49")
}
check(
    "a student sees no other batch's assignment",
    all(
        all(batch is None or batch.replace("-", "") == roll_batch.replace("-", "") for batch in batches)
        for roll, roll_batch in (("1", "D-1"), ("25", "D-2"), ("49", "D-3"))
        for batches in [assignment_batches[roll]]
    ),
    str(assignment_batches),
)
check("unauthenticated /timetable is rejected", requests.get(f"{BASE}/timetable", timeout=10).status_code == 401)

# ==========================================================================
section("2. Teacher panel permissions (server-side)")
# ==========================================================================
pending_url = f"{BASE}/teacher/registrations/pending"

plain_list = requests.get(pending_url, headers=auth(plain_token), timeout=10)
check("a teacher without the permission cannot list registrations", plain_list.status_code == 403, str(plain_list.status_code))
check("the refusal explains why", "not permitted" in plain_list.text, plain_list.text[:160])

admin_list = requests.get(pending_url, headers=auth(admin_token), timeout=10)
check("an admin can list registrations", admin_list.status_code == 200, str(admin_list.status_code))
check("pending registrations are returned", isinstance(admin_list.json(), list))
check(
    "no password/hash/token is exposed in the pending list",
    not any(word in admin_list.text.lower() for word in ("password", "token", "hash")),
    admin_list.text[:200],
)

pending_id = next(
    (s["id"] for s in admin_list.json() if s["roll_number"] == "902"), None
)
check("the pending test student is listed", pending_id is not None)

if pending_id:
    plain_approve = requests.post(
        f"{BASE}/teacher/registrations/{pending_id}/approve",
        json={},
        headers=auth(plain_token),
        timeout=10,
    )
    check("a teacher without the permission cannot approve", plain_approve.status_code == 403, str(plain_approve.status_code))
    plain_reject = requests.post(
        f"{BASE}/teacher/registrations/{pending_id}/reject",
        json={},
        headers=auth(plain_token),
        timeout=10,
    )
    check("a teacher without the permission cannot reject", plain_reject.status_code == 403)

grant = set_permissions(
    [t for t in requests.get(f"{BASE}/teacher/list", headers=auth(admin_token), timeout=10).json() if t["email"] == "plain@campusync.edu"][0]["id"],
    can_approve_registrations=True,
)
check("an admin can grant the approval permission", grant.status_code == 200, grant.text[:160])
check("the grant is visible in the response", grant.json().get("can_review_registrations") is True)

after_grant = requests.get(pending_url, headers=auth(plain_token), timeout=10)
check("the granted teacher can now list registrations", after_grant.status_code == 200, str(after_grant.status_code))

if pending_id:
    approved = requests.post(
        f"{BASE}/teacher/registrations/{pending_id}/approve",
        json={},
        headers=auth(plain_token),
        timeout=10,
    )
    check("the granted teacher can approve", approved.status_code == 200, approved.text[:160])
    check("the approval is recorded", approved.json().get("status") == "approved")

revoke = set_permissions(grant.json()["id"], can_approve_registrations=False)
check("an admin can revoke the permission", revoke.status_code == 200)
check("the revocation is visible", revoke.json().get("can_review_registrations") is False)
check(
    "the revoked teacher is refused again",
    requests.get(pending_url, headers=auth(plain_token), timeout=10).status_code == 403,
)

check(
    "a teacher cannot create accounts",
    requests.post(
        f"{BASE}/teacher/create",
        json={"name": "Sneaky", "email": "sneaky@campusync.edu", "password": PASSWORD, "role": "admin"},
        headers=auth(plain_token),
        timeout=10,
    ).status_code == 403,
)
check(
    "a teacher cannot list teacher accounts",
    requests.get(f"{BASE}/teacher/list", headers=auth(plain_token), timeout=10).status_code == 403,
)
check(
    "a teacher cannot change permissions",
    requests.patch(
        f"{BASE}/teacher/{smg_id}/permissions",
        json={"can_approve_registrations": True},
        headers=auth(plain_token),
        timeout=10,
    ).status_code == 403,
)
check(
    "a student token cannot reach the approval queue",
    requests.get(pending_url, headers=auth(TOKENS["1"]), timeout=10).status_code == 401,
)

teacher_list = requests.get(f"{BASE}/teacher/list", headers=auth(admin_token), timeout=10).json()
check("the teacher list carries no credential fields", all(
    not ({"password", "token", "hash"} & set(row.keys())) for row in teacher_list
))
check("the teacher list exposes the effective permission", all("can_review_registrations" in row for row in teacher_list))
check("the admin's effective permission is true", any(row["role"] == "admin" and row["can_review_registrations"] for row in teacher_list))

# -------------------------------------------------------------------------
# link the faculty short code -> verified teaching assignments
# -------------------------------------------------------------------------
check(
    "no teacher is linked to a faculty code by default",
    all(row["short_code"] in (None, "") for row in teacher_list),
    str([row["short_code"] for row in teacher_list]),
)

link = set_permissions(smg_id, short_code="SMG")
check("an admin can link a faculty short code", link.status_code == 200, link.text[:160])
check("the short code is stored", link.json().get("short_code") == "SMG")

clash = set_permissions(spk_id, short_code="SMG")
check("the same short code cannot be linked twice", clash.status_code == 409, str(clash.status_code))

smg_assignments = requests.get(
    f"{BASE}/teacher/assignments", headers=auth(smg_token), timeout=10
).json()
check("linking created the teacher's verified assignments", len(smg_assignments) >= 4, str(len(smg_assignments)))
check(
    "every created assignment matches the official timetable",
    all(
        any(
            entry[0] == a["day"]
            and entry[1] == a["start_time"]
            and entry[2] == a["end_time"]
            and entry[3] == a["subject"]
            for entry in official_data.TIMETABLE
        )
        for a in smg_assignments
    ),
    str(smg_assignments[:3]),
)
check("a teacher with no short code has no invented assignments", requests.get(
    f"{BASE}/teacher/assignments", headers=auth(plain_token), timeout=10
).json() == [])

manual = requests.post(
    f"{BASE}/teacher/{spk_id}/assignments",
    json={"subject": "PCS", "subject_code": "AEC-101", "division": "D", "batch": "", "day": "Thursday", "start_time": "15:15", "end_time": "16:15"},
    headers=auth(admin_token),
    timeout=10,
)
check("an admin can add an assignment manually", manual.status_code == 201, manual.text[:160])
check(
    "the same assignment cannot be added twice",
    requests.post(
        f"{BASE}/teacher/{spk_id}/assignments",
        json={"subject": "PCS", "subject_code": "AEC-101", "division": "D", "batch": "", "day": "Thursday", "start_time": "15:15", "end_time": "16:15"},
        headers=auth(admin_token),
        timeout=10,
    ).status_code == 409,
)

# ==========================================================================
section("3. Lecture-wise attendance")
# ==========================================================================
freeze_attendance_clock(13, 5)  # inside the Monday 13:00-14:00 lecture
attendance_body = {
    "subject": "M-1",
    "division": "D",
    "batch": "",
    "session_date": MONDAY_STR,
    "slot_start": "13:00",
    "slot_end": "14:00",
    "records": [],
}

# a teacher with no verified assignment for PHY
no_assignment = dict(attendance_body)
no_assignment["subject"] = "PHY"
no_assignment["records"] = [{"student_id": 1, "status": "present"}]
refused = requests.post(f"{BASE}/teacher/attendance", json=no_assignment, headers=auth(smg_token), timeout=10)
check("an unassigned subject is refused", refused.status_code == 403, str(refused.status_code))
check("the refusal names the missing assignment", "not assigned" in refused.text, refused.text[:200])

d1_ids = [
    s["id"]
    for s in requests.get(f"{BASE}/teacher/classes?division=D&batch=D-1", headers=auth(smg_token), timeout=10).json()
]
approved_d1 = {
    row[0]
    for row in conn.execute(
        "SELECT id FROM students WHERE division='D' AND batch='D-1' AND status='approved'"
    )
}
check(
    "the class list is exactly the approved students of that batch",
    set(d1_ids) == approved_d1,
    f"api={sorted(d1_ids)} db={sorted(approved_d1)}",
)
check(
    "a pending student is not in the class list",
    conn.execute("SELECT id FROM students WHERE roll_number='903'").fetchone()[0] not in d1_ids,
)

all_ids = requests.get(f"{BASE}/teacher/classes?division=D", headers=auth(smg_token), timeout=10).json()
check("the whole-division class list includes every approved student", len(all_ids) >= 8, str(len(all_ids)))
check("the class list carries no credentials", all(
    not ({"password", "token", "email"} & set(row.keys())) for row in all_ids
))

body = dict(attendance_body)
body["records"] = [{"student_id": sid, "status": "present"} for sid in d1_ids[:2]]
created = requests.post(f"{BASE}/teacher/attendance", json=body, headers=auth(admin_token), timeout=10)
check("attendance saves", created.status_code == 200, created.text[:200])
check("two records were created", created.json().get("created") == 2, str(created.json()))

same = requests.post(f"{BASE}/teacher/attendance", json=body, headers=auth(admin_token), timeout=10)
check("saving the same lecture again creates no duplicate", same.json().get("created") == 0, str(same.json()))
check("nothing was corrected when nothing changed", same.json().get("corrected") == 0, str(same.json()))

row_count = conn.execute(
    "SELECT COUNT(*) FROM attendance_records WHERE subject='M-1' AND session_date=? AND slot_start='13:00'",
    (MONDAY_STR,),
).fetchone()[0]
check("the database holds one row per student and lecture", row_count == 2, str(row_count))

corrected_body = dict(attendance_body)
corrected_body["records"] = [{"student_id": d1_ids[0], "status": "absent"}, {"student_id": d1_ids[1], "status": "present"}]
corrected = requests.post(f"{BASE}/teacher/attendance", json=corrected_body, headers=auth(admin_token), timeout=10)
check("a correction is applied", corrected.json().get("corrected") == 1, str(corrected.json()))
row_count = conn.execute(
    "SELECT COUNT(*) FROM attendance_records WHERE subject='M-1' AND session_date=? AND slot_start='13:00'",
    (MONDAY_STR,),
).fetchone()[0]
check("a correction does not add a row", row_count == 2, str(row_count))
audit = conn.execute(
    "SELECT status, updated_by, updated_at FROM attendance_records WHERE student_id=? AND session_date=?",
    (d1_ids[0], MONDAY_STR),
).fetchone()
check("the correction is recorded with who and when", audit[0] == "absent" and audit[1] is not None and audit[2] is not None, str(audit))

saved = requests.get(
    f"{BASE}/teacher/attendance?subject=M-1&division=D&session_date={MONDAY_STR}&slot_start=13:00&slot_end=14:00",
    headers=auth(smg_token),
    timeout=10,
)
check("the saved session can be read back", saved.status_code == 200, saved.text[:160])
check(
    "the saved statuses are returned",
    {r["status"] for r in saved.json()} == {"present", "absent"},
    str(saved.json()),
)

bad_slot = dict(attendance_body)
bad_slot["records"] = [{"student_id": d1_ids[0], "status": "present"}]
bad_slot["slot_start"] = "09:00"
bad_slot["slot_end"] = "10:00"
check(
    "a period outside the official grid is refused",
    requests.post(f"{BASE}/teacher/attendance", json=bad_slot, headers=auth(admin_token), timeout=10).status_code == 400,
)
bad_date = dict(attendance_body)
bad_date["records"] = [{"student_id": d1_ids[0], "status": "present"}]
bad_date["session_date"] = "13-10-2026"
check(
    "a malformed date is refused",
    requests.post(f"{BASE}/teacher/attendance", json=bad_date, headers=auth(admin_token), timeout=10).status_code == 400,
)
bad_status = dict(attendance_body)
bad_status["records"] = [{"student_id": d1_ids[0], "status": "maybe"}]
check(
    "an unknown status is refused",
    requests.post(f"{BASE}/teacher/attendance", json=bad_status, headers=auth(admin_token), timeout=10).status_code == 422,
)
dupe = dict(attendance_body)
dupe["records"] = [{"student_id": d1_ids[0], "status": "present"}, {"student_id": d1_ids[0], "status": "absent"}]
check(
    "the same student twice in one request is refused",
    requests.post(f"{BASE}/teacher/attendance", json=dupe, headers=auth(admin_token), timeout=10).status_code == 400,
)

d2_id = STUDENTS and requests.get(f"{BASE}/teacher/classes?division=D&batch=D-2", headers=auth(smg_token), timeout=10).json()[0]["id"]
wrong_batch = dict(attendance_body)
wrong_batch["batch"] = "D-1"
wrong_batch["records"] = [{"student_id": d2_id, "status": "present"}]
check(
    "a student of another batch is refused",
    requests.post(f"{BASE}/teacher/attendance", json=wrong_batch, headers=auth(admin_token), timeout=10).status_code == 400,
)

pending_student_id = conn.execute("SELECT id FROM students WHERE roll_number='903'").fetchone()[0]
unapproved = dict(attendance_body)
unapproved["records"] = [{"student_id": pending_student_id, "status": "present"}]
check(
    "an unapproved student cannot be marked",
    requests.post(f"{BASE}/teacher/attendance", json=unapproved, headers=auth(admin_token), timeout=10).status_code == 400,
)
check(
    # A valid student token is authenticated but not permitted: 403, not 401.
    "a student token cannot save attendance -> 403",
    requests.post(f"{BASE}/teacher/attendance", json=attendance_body, headers=auth(TOKENS["1"]), timeout=10).status_code == 403,
)
check(
    "attendance without a session date is refused",
    requests.get(f"{BASE}/teacher/attendance?subject=M-1", headers=auth(smg_token), timeout=10).status_code == 400,
)

# --------------------------------------------------------------------------
# The swipe-attendance endpoints and the student's subject dashboard
# --------------------------------------------------------------------------
roster = requests.get(
    f"{BASE}/teacher/attendance/students?year=1&division=D",
    headers=auth(smg_token),
    timeout=10,
)
check("the class roster endpoint answers", roster.status_code == 200, roster.text[:160])
roster_rows = roster.json()
roster_rolls = [row["roll_number"] for row in roster_rows]
check(
    "the roster is sorted by roll number ascending",
    roster_rolls == sorted(roster_rolls, key=int),
    str(roster_rolls),
)
check(
    "a pending student is not in the roster",
    "903" not in roster_rolls,
    str(roster_rolls),
)
check(
    "the roster carries no credentials",
    all(not ({"password", "token", "email"} & set(row.keys())) for row in roster_rows),
)
check(
    "the roster honours the year filter",
    requests.get(
        f"{BASE}/teacher/attendance/students?year=2&division=D",
        headers=auth(smg_token),
        timeout=10,
    ).json() == [],
)
check(
    "a student token cannot read a class roster -> 403",
    requests.get(
        f"{BASE}/teacher/attendance/students?division=D",
        headers=auth(TOKENS["1"]),
        timeout=10,
    ).status_code == 403,
)

submit_body = {
    "class_date": MONDAY_STR,
    "period": "13:00-14:00",
    "subject": "M-1",
    "division": "D",
    "batch": "",
    "records": [{"student_id": sid, "status": "present"} for sid in d1_ids[:2]],
}
submitted = requests.post(
    f"{BASE}/teacher/attendance/submit", json=submit_body, headers=auth(smg_token), timeout=10
)
check("a whole sheet saves through the swipe endpoint", submitted.status_code == 200, submitted.text[:200])
check(
    "the submit response tallies the sheet",
    submitted.json().get("total") == 2
    and submitted.json().get("present") == 2
    and submitted.json().get("absent") == 0,
    str(submitted.json()),
)
check(
    "an unchanged re-submit creates no duplicate rows",
    requests.post(
        f"{BASE}/teacher/attendance/submit", json=submit_body, headers=auth(smg_token), timeout=10
    ).json().get("created") == 0,
)
check(
    "a period outside the official grid is refused by the swipe endpoint",
    requests.post(
        f"{BASE}/teacher/attendance/submit",
        json={**submit_body, "period": "09:00-10:00"},
        headers=auth(smg_token),
        timeout=10,
    ).status_code == 400,
)
check(
    "an unassigned subject is refused by the swipe endpoint",
    requests.post(
        f"{BASE}/teacher/attendance/submit",
        json={**submit_body, "subject": "PHY"},
        headers=auth(smg_token),
        timeout=10,
    ).status_code == 403,
)
check(
    "a student token cannot submit attendance -> 403",
    requests.post(
        f"{BASE}/teacher/attendance/submit", json=submit_body, headers=auth(TOKENS["1"]), timeout=10
    ).status_code == 403,
)

history = requests.get(
    f"{BASE}/teacher/attendance/history?subject=M-1", headers=auth(smg_token), timeout=10
)
check("the session history answers", history.status_code == 200, history.text[:160])
history_rows = [
    row
    for row in history.json()
    if row["class_date"] == MONDAY_STR and row["period"] == "13:00-14:00"
]
check("the saved lecture is in the history", len(history_rows) == 1, str(history.json()))
check(
    "the history tallies the whole lecture, not only the caller's rows",
    history_rows and history_rows[0]["total"] == 2 and history_rows[0]["present"] == 2,
    str(history_rows),
)
check(
    "a teacher sees no history for a lecture they never took",
    requests.get(
        f"{BASE}/teacher/attendance/history", headers=auth(plain_token), timeout=10
    ).json() == [],
)
check(
    "a student token cannot read lecture history -> 403",
    requests.get(
        f"{BASE}/teacher/attendance/history", headers=auth(TOKENS["1"]), timeout=10
    ).status_code == 403,
)

# A second subject for student 1, so the per-subject breakdown has something to
# sort and the overall total is more than one lecture.
requests.post(
    f"{BASE}/teacher/attendance/submit",
    json={
        "class_date": MONDAY_STR,
        "period": "15:15-16:15",
        "subject": "Engineering Physics",
        "division": "D",
        "batch": "D-1",
        "records": [{"student_id": d1_ids[0], "status": "absent"}],
    },
    headers=auth(admin_token),
    timeout=10,
)

roll_one_id = conn.execute("SELECT id FROM students WHERE roll_number='1'").fetchone()[0]
roll_one_token = TOKENS["1"]
mine_summary = requests.get(f"{BASE}/student/attendance", headers=auth(roll_one_token), timeout=10)
check("the student attendance endpoint answers", mine_summary.status_code == 200, mine_summary.text[:200])
summary_body = mine_summary.json()
rows_for_one = conn.execute(
    "SELECT subject, status FROM attendance_records WHERE student_id=?", (roll_one_id,)
).fetchall()
check(
    "the student summary counts exactly that student's lectures",
    summary_body.get("total_classes") == len(rows_for_one),
    f"api={summary_body.get('total_classes')} db={len(rows_for_one)}",
)
check(
    "the student summary counts only present rows as attended",
    summary_body.get("attended") == sum(1 for _, status in rows_for_one if status == "present"),
    str(summary_body),
)
check(
    "the subjects are listed alphabetically",
    [row["subject"] for row in summary_body["subjects"]]
    == sorted([row["subject"] for row in summary_body["subjects"]], key=str.lower),
    str([row["subject"] for row in summary_body["subjects"]]),
)
check(
    "each subject carries its own lectures, newest first",
    all(
        [lecture["date"] for lecture in subject["lectures"]]
        == sorted([lecture["date"] for lecture in subject["lectures"]], reverse=True)
        for subject in summary_body["subjects"]
    ),
    str(summary_body["subjects"]),
)
check(
    "a subject percentage matches its own counts",
    all(
        subject["percentage"]
        == round(subject["attended"] * 100 / subject["total_classes"], 1)
        for subject in summary_body["subjects"]
    ),
    str(summary_body["subjects"]),
)
check(
    "a student with no attendance gets an empty, honest summary",
    requests.get(f"{BASE}/student/attendance", headers=auth(TOKENS["25"]), timeout=10).json()
    == {"overall_percentage": 0.0, "total_classes": 0, "attended": 0, "subjects": []},
)
check(
    "a teacher token is not a student session -> 401",
    requests.get(f"{BASE}/student/attendance", headers=auth(smg_token), timeout=10).status_code == 401,
)

# ==========================================================================
section("3b. Class roster: attendance before a student registers")
# ==========================================================================
check(
    "only an admin may list the class roster -> 403 for a teacher",
    requests.get(
        f"{BASE}/admin/roster", headers=auth(smg_token), timeout=10
    ).status_code == 403,
)
check(
    # Admin routes answer 401 to a student session (get_current_teacher), the
    # same as every other admin endpoint; 403 is reserved for a real teacher
    # without the role.
    "a student token cannot read the class roster -> 401",
    requests.get(
        f"{BASE}/admin/roster", headers=auth(TOKENS["1"]), timeout=10
    ).status_code == 401,
)

listed = requests.get(
    f"{BASE}/admin/roster?year=1&division=D", headers=auth(admin_token), timeout=10
)
check("an admin can list the class roster", listed.status_code == 200, listed.text[:160])
check(
    "the throwaway roster starts empty",
    listed.json() == [],
    str(listed.json())[:160],
)

roster_payload = {
    "roll_number": "8801",
    "name": "ROSTER ONLY STUDENT",
    "year": 1,
    "division": "D",
    "batch": "D-1",
}
added_entry = requests.post(
    f"{BASE}/admin/roster/add", json=roster_payload, headers=auth(admin_token), timeout=10
)
check("a roster entry can be added", added_entry.status_code == 200, added_entry.text[:200])
check(
    "a new roster entry has no account",
    added_entry.json().get("registered_student_id") is None,
    str(added_entry.json()),
)
check(
    "re-adding the same roll updates instead of duplicating",
    requests.post(
        f"{BASE}/admin/roster/add",
        json={**roster_payload, "name": "ROSTER ONLY STUDENT (FIXED)"},
        headers=auth(admin_token),
        timeout=10,
    ).status_code == 200,
)
check(
    "one roster row per roll number",
    conn.execute("SELECT COUNT(*) FROM class_roster WHERE roll_number='8801'").fetchone()[0] == 1,
)
check(
    "the corrected name is stored",
    conn.execute("SELECT name FROM class_roster WHERE roll_number='8801'").fetchone()[0]
    == "ROSTER ONLY STUDENT (FIXED)",
)
check(
    "an unknown batch is refused",
    requests.post(
        f"{BASE}/admin/roster/add",
        json={**roster_payload, "roll_number": "999", "batch": "D-9"},
        headers=auth(admin_token),
        timeout=10,
    ).status_code == 422,
)
check(
    "a blank roll number is refused",
    requests.post(
        f"{BASE}/admin/roster/add",
        json={**roster_payload, "roll_number": "   "},
        headers=auth(admin_token),
        timeout=10,
    ).status_code == 422,
)

sheet = requests.get(
    f"{BASE}/teacher/attendance/students?year=1&division=D&batch=D-1",
    headers=auth(smg_token),
    timeout=10,
)
check("the class sheet answers for a teacher", sheet.status_code == 200, sheet.text[:160])
sheet_rows = sheet.json()
unregistered = [row for row in sheet_rows if row["roll_number"] == "8801"]
check(
    "the unregistered roster student is on the class sheet",
    len(unregistered) == 1,
    str([row["roll_number"] for row in sheet_rows]),
)
check(
    "the roster student has no account id and says so",
    unregistered
    and unregistered[0]["id"] is None
    and unregistered[0]["is_registered"] is False,
    str(unregistered),
)
check(
    "registered students are still listed and flagged as registered",
    any(row["is_registered"] for row in sheet_rows),
    str(sheet_rows)[:200],
)
check(
    "the class sheet stays in roll order with the roster entry in place",
    [row["roll_number"] for row in sheet_rows]
    == sorted([row["roll_number"] for row in sheet_rows], key=int),
    str([row["roll_number"] for row in sheet_rows]),
)

roster_mark = {
    "class_date": MONDAY_STR,
    "period": "13:00-14:00",
    "subject": "M-1",
    "division": "D",
    "batch": "D-1",
    "records": [{"roll_number": "8801", "status": "present"}],
}
marked = requests.post(
    f"{BASE}/teacher/attendance/submit",
    json=roster_mark,
    headers=auth(admin_token),
    timeout=10,
)
check(
    "attendance can be marked for an unregistered roll number",
    marked.status_code == 200,
    marked.text[:200],
)
stored = conn.execute(
    "SELECT student_id, roll_number, status FROM attendance_records "
    "WHERE roll_number='8801' AND session_date=?",
    (MONDAY_STR,),
).fetchone()
check(
    "the row keeps the roll number with no account attached yet",
    stored is not None and stored[0] is None and stored[1] == "8801" and stored[2] == "present",
    str(stored),
)
check(
    "an unknown roll number cannot be marked",
    requests.post(
        f"{BASE}/teacher/attendance/submit",
        json={**roster_mark, "records": [{"roll_number": "8898", "status": "present"}]},
        headers=auth(admin_token),
        timeout=10,
    ).status_code == 400,
)
check(
    "the same roll number twice in one sheet is refused",
    requests.post(
        f"{BASE}/teacher/attendance/submit",
        json={
            **roster_mark,
            "records": [
                {"roll_number": "8801", "status": "present"},
                {"roll_number": "8801", "status": "absent"},
            ],
        },
        headers=auth(admin_token),
        timeout=10,
    ).status_code == 400,
)

read_back = requests.get(
    f"{BASE}/teacher/attendance?subject=M-1&division=D&batch=D-1"
    f"&session_date={MONDAY_STR}&slot_start=13:00&slot_end=14:00",
    headers=auth(admin_token),
    timeout=10,
)
check(
    "a lecture marked from the roster reads back by roll number",
    any(
        row["roll_number"] == "8801" and row["status"] == "present"
        for row in read_back.json()
    ),
    read_back.text[:200],
)

# A CSV import: one header row, two students, one unreadable line.
roster_csv = (
    "roll_number,name,batch\n"
    "8802,CSV STUDENT ONE,D-2\n"
    "8804,CSV STUDENT TWO,D-2\n"
    "onlyarollnumber\n"
)
imported = requests.post(
    f"{BASE}/admin/roster/upload",
    files={"file": ("roster.csv", roster_csv.encode("utf-8"), "text/csv")},
    data={"year": "1", "division": "D"},
    headers=auth(admin_token),
    timeout=10,
)
check("a CSV roster imports", imported.status_code == 200, imported.text[:200])
check(
    "the import reports what landed and what did not",
    imported.json().get("added") == 2 and imported.json().get("skipped") == 1,
    str(imported.json()),
)
check(
    "the unreadable line is named in the errors",
    any("Line 4" in message for message in imported.json().get("errors", [])),
    str(imported.json()),
)
reimported = requests.post(
    f"{BASE}/admin/roster/upload",
    files={"file": ("roster.csv", roster_csv.encode("utf-8"), "text/csv")},
    data={"year": "1", "division": "D"},
    headers=auth(admin_token),
    timeout=10,
)
check(
    "re-importing the same file updates instead of duplicating",
    reimported.json().get("added") == 0 and reimported.json().get("updated") == 2,
    str(reimported.json()),
)
check(
    "the CSV import created exactly two rows",
    conn.execute(
        "SELECT COUNT(*) FROM class_roster WHERE roll_number IN ('8802','8804')"
    ).fetchone()[0]
    == 2,
)
check(
    "an empty upload is refused",
    requests.post(
        f"{BASE}/admin/roster/upload",
        files={"file": ("roster.csv", b"", "text/csv")},
        data={"year": "1", "division": "D"},
        headers=auth(admin_token),
        timeout=10,
    ).status_code == 400,
)

# The promise of the feature: when that roll number finally registers, the
# lectures already marked for it are in their account with no re-entry.
late_token = "late-registration-token"
conn.execute(
    "INSERT INTO students (email, roll_number, password, name, branch, year, division, "
    "batch, token, token_expires_at, status) VALUES (?,?,?,?,?,?,?,?,?,?,?)",
    (
        "roster.only@example.edu",
        "8801",
        password_hash.hash(PASSWORD),
        "ROSTER ONLY STUDENT (FIXED)",
        "Computer",
        1,
        "D",
        "D-1",
        late_token,
        (datetime.utcnow() + timedelta(days=1)).isoformat(sep=" "),
        "approved",
    ),
)
conn.commit()
late_summary = requests.get(
    f"{BASE}/student/attendance", headers=auth(late_token), timeout=10
)
check(
    "a student who registers later inherits the lectures marked for their roll",
    late_summary.status_code == 200
    and late_summary.json().get("total_classes") == 1
    and late_summary.json().get("attended") == 1,
    late_summary.text[:200],
)
check(
    "the inherited lecture is the one that was marked",
    late_summary.json()["subjects"][0]["subject"] == "M-1"
    and late_summary.json()["subjects"][0]["percentage"] == 100.0,
    str(late_summary.json())[:200],
)
# The next save of that lecture attaches the account id to the row that
# already existed, so the link is repaired without touching the history.
requests.post(
    f"{BASE}/teacher/attendance/submit",
    json=roster_mark,
    headers=auth(admin_token),
    timeout=10,
)
linked = conn.execute(
    "SELECT student_id, status FROM attendance_records WHERE roll_number='8801'"
).fetchone()
check(
    "a later save attaches the account id to the existing row",
    linked is not None and linked[0] is not None and linked[1] == "present",
    str(linked),
)
check(
    "attaching the account did not add a second row",
    conn.execute(
        "SELECT COUNT(*) FROM attendance_records WHERE roll_number='8801'"
    ).fetchone()[0]
    == 1,
)

entry_id = next(
    row["id"]
    for row in requests.get(
        f"{BASE}/admin/roster?year=1&division=D", headers=auth(admin_token), timeout=10
    ).json()
    if row["roll_number"] == "8802"
)
check(
    "a student token cannot delete a roster entry -> 401",
    requests.delete(
        f"{BASE}/admin/roster/{entry_id}", headers=auth(TOKENS["1"]), timeout=10
    ).status_code == 401,
)
removed = requests.delete(
    f"{BASE}/admin/roster/{entry_id}", headers=auth(admin_token), timeout=10
)
check("a roster entry can be removed", removed.status_code == 200, removed.text[:160])
check(
    "the removed roll number is gone but its marked lecture survives",
    conn.execute("SELECT COUNT(*) FROM class_roster WHERE roll_number='8802'").fetchone()[0] == 0
    and conn.execute("SELECT COUNT(*) FROM attendance_records WHERE roll_number='8801'").fetchone()[0] == 1,
)
check(
    "deleting an entry that is already gone -> 404",
    requests.delete(
        f"{BASE}/admin/roster/{entry_id}", headers=auth(admin_token), timeout=10
    ).status_code == 404,
)

# ==========================================================================
section("3c. Attendance is time-locked to its lecture")
# ==========================================================================
lock_body = {
    "class_date": MONDAY_STR,
    "period": "13:00-14:00",
    "subject": "M-1",
    "division": "D",
    "batch": "",
    "records": [{"roll_number": "1", "status": "present"}],
}


def submit_as_teacher():
    return requests.post(
        f"{BASE}/teacher/attendance/submit",
        json=lock_body,
        headers=auth(smg_token),
        timeout=10,
    )


freeze_attendance_clock(12, 30)
too_early = submit_as_teacher()
check(
    "marking a lecture long before it starts is refused",
    too_early.status_code == 403,
    str(too_early.status_code) + " " + too_early.text[:160],
)
check(
    "the refusal says when the sheet opens",
    "12:45 PM" in too_early.text,
    too_early.text[:220],
)
check(
    "the refusal names the college clock",
    "IST" in too_early.text,
    too_early.text[:220],
)

freeze_attendance_clock(12, 50)
check(
    "the sheet opens 15 minutes before the period",
    submit_as_teacher().status_code == 200,
)

freeze_attendance_clock(14, 10)
check(
    "the sheet stays open 15 minutes after the period ends",
    submit_as_teacher().status_code == 200,
)

freeze_attendance_clock(14, 20)
too_late = submit_as_teacher()
check(
    "marking a lecture after the grace window is refused",
    too_late.status_code == 403,
    str(too_late.status_code) + " " + too_late.text[:160],
)
check(
    "the refusal says when the sheet closes",
    "2:15 PM" in too_late.text,
    too_late.text[:220],
)

freeze_attendance_clock(13, 5, day=MONDAY + timedelta(days=1))
wrong_day = submit_as_teacher()
check(
    "a lecture cannot be marked on another calendar day",
    wrong_day.status_code == 403,
    str(wrong_day.status_code) + " " + wrong_day.text[:160],
)
check(
    "its refusal names the lecture's own date",
    MONDAY_STR in wrong_day.text,
    wrong_day.text[:220],
)

check(
    "a student token is still refused before any clock rule -> 403",
    requests.post(
        f"{BASE}/teacher/attendance/submit",
        json=lock_body,
        headers=auth(TOKENS["1"]),
        timeout=10,
    ).status_code == 403,
)

freeze_attendance_clock(23, 30)
check(
    "an admin can still correct a lecture after the fact",
    requests.post(
        f"{BASE}/teacher/attendance/submit",
        json=lock_body,
        headers=auth(admin_token),
        timeout=10,
    ).status_code == 200,
)
freeze_attendance_clock(13, 5)  # leave the rest of the suite inside the lecture

# ==========================================================================
section("4. Claim free period")
# ==========================================================================
unlinked = requests.get(
    f"{BASE}/teacher/free-periods?date={MONDAY_STR}", headers=auth(plain_token), timeout=10
).json()
check("an unlinked teacher is reported as not linked to a faculty code", unlinked["has_verified_assignments"] is False)
check(
    "an admin-created teacher may claim free periods without any extra grant",
    unlinked["can_claim_free_periods"] is True,
    str(unlinked["can_claim_free_periods"]),
)
check("the message explains what is missing", "faculty code" in (unlinked["message"] or ""), str(unlinked["message"])[:200])
check(
    "no per-batch gap is offered without a verified timetable link",
    all(not slot["eligible"] for slot in unlinked["slots"] if not slot["is_free_period"]),
    str([s for s in unlinked["slots"] if s["eligible"]]),
)
check(
    "Monday offers no free period to anyone",
    not any(slot["is_free_period"] for slot in unlinked["slots"]),
    str([s for s in unlinked["slots"] if s["is_free_period"]]),
)
unlinked_claim = requests.post(
    f"{BASE}/teacher/free-periods/claim",
    json={"day": "Monday", "start_time": "16:15", "end_time": "17:15", "division": "D", "batch": "D-1", "claim_date": NEXT_MONDAY_STR},
    headers=auth(plain_token),
    timeout=10,
)
check(
    "an unlinked teacher cannot claim a per-batch gap period",
    unlinked_claim.status_code == 409,
    str(unlinked_claim.status_code),
)

availability = requests.get(
    f"{BASE}/teacher/free-periods?date={MONDAY_STR}", headers=auth(smg_token), timeout=10
).json()
check("a linked teacher is verified", availability["has_verified_assignments"] is True)
check("the availability lists the official periods", len(availability["slots"]) >= 20, str(len(availability["slots"])))

teaching_slot = next(
    (s for s in availability["slots"] if s["start_time"] == "13:00" and s["batch"] == ""), None
)
check("a period the teacher teaches is not eligible", teaching_slot is not None and not teaching_slot["eligible"])
check("and says that the teacher teaches it", "You teach" in (teaching_slot or {}).get("reason", ""), str(teaching_slot))

d1_slot = next((s for s in availability["slots"] if s["start_time"] == "15:15" and s["batch"] == "D-1"), None)
check("another batch's practical blocks that batch's slot", d1_slot is not None and "PHY" in (d1_slot.get("reason") or ""), str(d1_slot))

whole = next((s for s in availability["slots"] if s["start_time"] == "15:15" and s["batch"] == ""), None)
check("a period with any batch class is not free for the whole division", whole is not None and not whole["eligible"], str(whole))

# Monday 15:15 has all three batches in class (the corrected D-3 EG practical
# starts at 15:35); at 16:15 only D-1 and D-2 are free.
eligible = {(s["start_time"], s["batch"]) for s in availability["slots"] if s["eligible"]}
check(
    "exactly the genuinely free batch periods are eligible",
    eligible == {("16:15", "D-1"), ("16:15", "D-2")},
    str(sorted(eligible)),
)
check(
    "no whole-division period is offered while any batch is in class",
    not any(s["batch"] == "" for s in availability["slots"] if s["eligible"]),
    str([s for s in availability["slots"] if s["eligible"]]),
)

claim = requests.post(
    f"{BASE}/teacher/free-periods/claim",
    json={"day": "Monday", "start_time": "16:15", "end_time": "17:15", "division": "D", "batch": "D-1", "claim_date": NEXT_MONDAY_STR, "subject": "M-1"},
    headers=auth(smg_token),
    timeout=10,
)
check("a verified free period can be claimed", claim.status_code == 201, claim.text[:200])
check("the claim is stored for the right date and slot", claim.json().get("claim_date") == NEXT_MONDAY_STR and claim.json().get("batch") == "D-1", str(claim.json()))

again = requests.post(
    f"{BASE}/teacher/free-periods/claim",
    json={"day": "Monday", "start_time": "16:15", "end_time": "17:15", "division": "D", "batch": "D-1", "claim_date": NEXT_MONDAY_STR},
    headers=auth(smg_token),
    timeout=10,
)
check("the same teacher cannot claim the same period twice", again.status_code == 409, str(again.status_code))
check("the refusal explains the conflict", "already claimed" in again.text.lower(), again.text[:200])

other = requests.post(
    f"{BASE}/teacher/free-periods/claim",
    json={"day": "Monday", "start_time": "16:15", "end_time": "17:15", "division": "D", "batch": "D-1", "claim_date": NEXT_MONDAY_STR},
    headers=auth(spk_token),
    timeout=10,
)
check("another teacher cannot claim the same class period", other.status_code == 409, str(other.status_code))

wrong_day = requests.post(
    f"{BASE}/teacher/free-periods/claim",
    json={"day": "Tuesday", "start_time": "15:15", "end_time": "16:15", "division": "D", "batch": "D-3", "claim_date": NEXT_MONDAY_STR},
    headers=auth(spk_token),
    timeout=10,
)
check("a claim whose day does not match the date is refused", wrong_day.status_code == 400, str(wrong_day.status_code))

wrong_slot = requests.post(
    f"{BASE}/teacher/free-periods/claim",
    json={"day": "Monday", "start_time": "09:00", "end_time": "10:00", "division": "D", "batch": "D-3", "claim_date": NEXT_MONDAY_STR},
    headers=auth(spk_token),
    timeout=10,
)
check("a period outside the official grid cannot be claimed", wrong_slot.status_code == 400, str(wrong_slot.status_code))

next_week = requests.post(
    f"{BASE}/teacher/free-periods/claim",
    json={"day": "Monday", "start_time": "16:15", "end_time": "17:15", "division": "D", "batch": "D-1", "claim_date": NEXT_MONDAY_WEEK2_STR},
    headers=auth(smg_token),
    timeout=10,
)
check("the same weekday can be claimed on another date", next_week.status_code == 201, next_week.text[:200])

claims = requests.get(f"{BASE}/teacher/free-periods/claims", headers=auth(smg_token), timeout=10).json()
check("the teacher's claims are listed", len(claims) == 2, str(claims))
check("claims carry date, time and batch", all({"claim_date", "start_time", "end_time", "batch"} <= set(c) for c in claims))

day_view = requests.get(f"{BASE}/teacher/free-periods?date={NEXT_MONDAY_STR}", headers=auth(smg_token), timeout=10).json()
check("the day view reports the existing claim", len(day_view["claims"]) == 1, str(day_view["claims"]))
still_eligible = {(s["start_time"], s["batch"]) for s in day_view["slots"] if s["eligible"]}
check(
    "the claimed period is no longer offered as eligible",
    ("16:15", "D-1") not in still_eligible,
    str(sorted(still_eligible)),
)
check(
    "the periods that are still free remain offered",
    still_eligible == {("16:15", "D-2")},
    str(sorted(still_eligible)),
)

spk_day = requests.get(f"{BASE}/teacher/free-periods?date={NEXT_MONDAY_STR}", headers=auth(spk_token), timeout=10).json()
check("another teacher does not see the first teacher's claim as theirs", spk_day["claims"] == [], str(spk_day["claims"]))
check("and is told the class group is taken", any(
    s["batch"] == "D-1" and s["start_time"] == "16:15" and "Another teacher" in (s["reason"] or "")
    for s in spk_day["slots"]
), str([s for s in spk_day["slots"] if s["start_time"] == "16:15"]))

release = requests.delete(
    f"{BASE}/teacher/free-periods/claims/{claims[0]['id']}", headers=auth(smg_token), timeout=10
)
check("a teacher can release their own claim", release.status_code == 200, release.text[:160])
check(
    "another teacher cannot release someone else's claim",
    requests.delete(
        f"{BASE}/teacher/free-periods/claims/{claims[1]['id']}", headers=auth(spk_token), timeout=10
    ).status_code == 403,
)

sunday = requests.get(f"{BASE}/teacher/free-periods?date={SUNDAY_STR}", headers=auth(smg_token), timeout=10).json()
check("Sunday has no periods", sunday["slots"] == [], str(sunday["slots"])[:120])

# --------------------------------------------------------------------------
# The sheet's five free periods ("RELM") are what this feature exists for:
# ONE division-wide slot each, claimable by any active teacher account.
# --------------------------------------------------------------------------
relm_day = requests.get(
    f"{BASE}/teacher/free-periods?date={RELM_DATE_STR}",
    headers=auth(smg_token),
    timeout=10,
).json()
relm_whole = [
    s for s in relm_day["slots"] if s["is_free_period"] and s["batch"] == ""
]
check(
    "the day's free periods are reported as free periods",
    {(s["start_time"], s["end_time"]) for s in relm_whole} == set(RELM_TIMES),
    str(sorted((s["start_time"], s["end_time"]) for s in relm_whole)),
)
check(
    "a free period is offered to a verified teacher",
    all(s["eligible"] for s in relm_whole),
    str(relm_whole),
)
check(
    "a free period is never reported as a class",
    all(s["subject"] is None for s in relm_whole),
    str([s["subject"] for s in relm_whole]),
)
check(
    "a free period is exactly ONE division-wide slot, not four batch slots",
    all(s["batch"] == "" for s in relm_day["slots"] if s["is_free_period"])
    and len([s for s in relm_day["slots"] if s["is_free_period"]]) == len(RELM_TIMES),
    str([(s["start_time"], s["batch"]) for s in relm_day["slots"] if s["is_free_period"]]),
)
check(
    "a period with a class in it is not reported as a free period",
    all(
        (s["start_time"], s["end_time"]) in set(RELM_TIMES)
        for s in relm_day["slots"]
        if s["is_free_period"]
    ),
    str([(s["start_time"], s["batch"]) for s in relm_day["slots"] if s["is_free_period"]]),
)

# --------------------------------------------------------------------------
# A teacher account created by an admin (the college's Gmail address) can claim
# a free period with NO extra permission grant and NO faculty code.
# --------------------------------------------------------------------------
GMAIL_EMAIL = "fresh.faculty.2026@gmail.com"
gmail_id = make_teacher("Fresh Faculty", GMAIL_EMAIL)
gmail_token = teacher_login(GMAIL_EMAIL)

gmail_me = requests.get(f"{BASE}/teacher/me", headers=auth(gmail_token), timeout=10).json()
check("the admin-created teacher can log in", gmail_me.get("role") == "teacher", str(gmail_me))
check(
    "...without any registration-approval permission",
    gmail_me.get("can_review_registrations") is False,
    str(gmail_me.get("can_review_registrations")),
)
check(
    "...and without a faculty code or any teaching assignment",
    gmail_me.get("short_code") in (None, "")
    and requests.get(
        f"{BASE}/teacher/assignments", headers=auth(gmail_token), timeout=10
    ).json()
    == [],
)

gmail_view = requests.get(
    f"{BASE}/teacher/free-periods?date={RELM_DATE_STR}",
    headers=auth(gmail_token),
    timeout=10,
).json()
check(
    "the fresh account is allowed to claim free periods",
    gmail_view["can_claim_free_periods"] is True,
    str(gmail_view["can_claim_free_periods"]),
)
check(
    "its own classes are not known, and the API says so",
    gmail_view["has_verified_assignments"] is False
    and "faculty code" in (gmail_view["message"] or ""),
    str(gmail_view["message"])[:200],
)
check(
    "the division-wide free period is offered to it",
    any(
        s["start_time"] == RELM_START and s["batch"] == "" and s["eligible"]
        for s in gmail_view["slots"]
    ),
    str([s for s in gmail_view["slots"] if s["is_free_period"]]),
)

gmail_claim = requests.post(
    f"{BASE}/teacher/free-periods/claim",
    json={
        "day": RELM_DAY_NAME,
        "start_time": RELM_START,
        "end_time": RELM_END,
        "division": "D",
        "batch": "",
        "claim_date": RELM_DATE_STR,
    },
    headers=auth(gmail_token),
    timeout=10,
)
check(
    "an admin-created teacher can claim a valid division-wide free period",
    gmail_claim.status_code == 201,
    gmail_claim.text[:200],
)
check(
    "the claim is stored as a whole-division slot",
    gmail_claim.json().get("batch") == ""
    and gmail_claim.json().get("division") == "D"
    and gmail_claim.json().get("start_time") == RELM_START,
    str(gmail_claim.json()),
)

gmail_after = requests.get(
    f"{BASE}/teacher/free-periods?date={RELM_DATE_STR}",
    headers=auth(gmail_token),
    timeout=10,
).json()
check(
    "the claim shows up as claimed on their own view",
    any(
        c["start_time"] == RELM_START and c["claim_date"] == RELM_DATE_STR
        for c in gmail_after["claims"]
    ),
    str(gmail_after["claims"]),
)
check(
    "and the slot is no longer offered to them as available",
    not any(
        s["start_time"] == RELM_START and s["eligible"]
        for s in gmail_after["slots"]
    ),
    str([s for s in gmail_after["slots"] if s["start_time"] == RELM_START]),
)

# The whole slot is reserved: a second teacher cannot take the same date+time.
smg_same_slot = requests.post(
    f"{BASE}/teacher/free-periods/claim",
    json={
        "day": RELM_DAY_NAME,
        "start_time": RELM_START,
        "end_time": RELM_END,
        "division": "D",
        "batch": "",
        "claim_date": RELM_DATE_STR,
    },
    headers=auth(smg_token),
    timeout=10,
)
check(
    "a second teacher cannot claim the same division-wide slot",
    smg_same_slot.status_code == 409
    and "already claimed" in smg_same_slot.text.lower(),
    smg_same_slot.text[:200],
)

smg_view = requests.get(
    f"{BASE}/teacher/free-periods?date={RELM_DATE_STR}",
    headers=auth(smg_token),
    timeout=10,
).json()
check(
    "and that teacher is shown the slot as taken, not theirs",
    not any(
        s["start_time"] == RELM_START and s["eligible"]
        for s in smg_view["slots"]
    )
    and all(c["start_time"] != RELM_START for c in smg_view["claims"]),
    str([s for s in smg_view["slots"] if s["start_time"] == RELM_START]),
)
check(
    "no batch on its own can claim a free period",
    all(
        not any(
            s["start_time"] == RELM_START and s["batch"] == batch
            for s in smg_view["slots"]
        )
        for batch in official_data.BATCHES
    ),
    str([s for s in smg_view["slots"] if s["start_time"] == RELM_START]),
)

# A per-batch request for a free period is refused outright, and the refusal is
# about the batch - the same slot for the whole division is claimable.
batch_claim = requests.post(
    f"{BASE}/teacher/free-periods/claim",
    json={
        "day": RELM_DAY_NAME,
        "start_time": RELM_START,
        "end_time": RELM_END,
        "division": "D",
        "batch": "D-1",
        "claim_date": RELM_DATE_2_STR,
    },
    headers=auth(smg_token),
    timeout=10,
)
check(
    "D-1 cannot claim a free period on its own",
    batch_claim.status_code == 409 and "whole of Division D" in batch_claim.text,
    batch_claim.text[:200],
)
check(
    "and neither can D-2 or D-3",
    all(
        requests.post(
            f"{BASE}/teacher/free-periods/claim",
            json={
                "day": RELM_DAY_NAME,
                "start_time": RELM_START,
                "end_time": RELM_END,
                "division": "D",
                "batch": batch,
                "claim_date": RELM_DATE_2_STR,
            },
            headers=auth(smg_token),
            timeout=10,
        ).status_code
        == 409
        for batch in ("D-2", "D-3")
    ),
)

relm_own_claim = requests.post(
    f"{BASE}/teacher/free-periods/claim",
    json={
        "day": RELM_DAY_NAME,
        "start_time": RELM_START,
        "end_time": RELM_END,
        "division": "D",
        "batch": "",
        "claim_date": RELM_DATE_2_STR,
    },
    headers=auth(smg_token),
    timeout=10,
)
check(
    "the same slot claimed division-wide works",
    relm_own_claim.status_code == 201,
    relm_own_claim.text[:200],
)
check(
    "the same teacher cannot claim it twice",
    requests.post(
        f"{BASE}/teacher/free-periods/claim",
        json={
            "day": RELM_DAY_NAME,
            "start_time": RELM_START,
            "end_time": RELM_END,
            "division": "D",
            "batch": "",
            "claim_date": RELM_DATE_2_STR,
        },
        headers=auth(smg_token),
        timeout=10,
    ).status_code
    == 409,
)
check(
    "a per-batch attempt is refused even after the slot is taken",
    requests.post(
        f"{BASE}/teacher/free-periods/claim",
        json={
            "day": RELM_DAY_NAME,
            "start_time": RELM_START,
            "end_time": RELM_END,
            "division": "D",
            "batch": "D-2",
            "claim_date": RELM_DATE_2_STR,
        },
        headers=auth(spk_token),
        timeout=10,
    ).status_code
    == 409,
)

gmail_release = requests.delete(
    f"{BASE}/teacher/free-periods/claims/{gmail_claim.json()['id']}",
    headers=auth(gmail_token),
    timeout=10,
)
check(
    "the admin-created teacher can release their own claim",
    gmail_release.status_code == 200,
    gmail_release.text[:160],
)

# --------------------------------------------------------------------------
# Dates: a period that has already passed can never be claimed.
# --------------------------------------------------------------------------
past_claim = requests.post(
    f"{BASE}/teacher/free-periods/claim",
    json={
        "day": YESTERDAY_NAME,
        "start_time": "13:00",
        "end_time": "14:00",
        "division": "D",
        "batch": "",
        "claim_date": YESTERDAY_STR,
    },
    headers=auth(smg_token),
    timeout=10,
)
check(
    "yesterday cannot be claimed",
    past_claim.status_code == 400,
    f"{past_claim.status_code} {past_claim.text[:160]}",
)
check(
    "the refusal says the date is in the past",
    "past" in past_claim.text.lower(),
    past_claim.text[:200],
)
check(
    "and it names the college clock",
    "college clock" in past_claim.text.lower(),
    past_claim.text[:240],
)

released_slot_today = requests.post(
    f"{BASE}/teacher/free-periods/claim",
    json={
        "day": RELM_DAY_NAME,
        "start_time": RELM_START,
        "end_time": RELM_END,
        "division": "D",
        "batch": "",
        "claim_date": RELM_DATE_STR,
    },
    headers=auth(smg_token),
    timeout=10,
)
check(
    "today or a later date is still claimable",
    released_slot_today.status_code == 201
    and RELM_DATE >= TODAY,
    f"{released_slot_today.status_code} {released_slot_today.text[:160]}",
)
stored_claim_dates = [
    c["claim_date"]
    for c in requests.get(
        f"{BASE}/teacher/free-periods/claims", headers=auth(smg_token), timeout=10
    ).json()
]
check(
    "every stored claim is for today or later",
    bool(stored_claim_dates)
    and all(claim_date >= TODAY.isoformat() for claim_date in stored_claim_dates),
    str(stored_claim_dates),
)

# A period the teacher teaches is never claimable.
teaches_it = requests.post(
    f"{BASE}/teacher/free-periods/claim",
    json={
        "day": "Tuesday",
        "start_time": "14:00",
        "end_time": "15:00",
        "division": "D",
        "batch": "",
        "claim_date": NEXT_TUESDAY_STR,
    },
    headers=auth(smg_token),
    timeout=10,
)
check(
    "a period the teacher teaches cannot be claimed",
    teaches_it.status_code == 409 and "You teach" in teaches_it.text,
    teaches_it.text[:200],
)

# A period a class group is scheduled in is never claimable.
class_in_it = requests.post(
    f"{BASE}/teacher/free-periods/claim",
    json={
        "day": "Tuesday",
        "start_time": "10:15",
        "end_time": "11:15",
        "division": "D",
        "batch": "D-2",
        "claim_date": NEXT_TUESDAY_STR,
    },
    headers=auth(smg_token),
    timeout=10,
)
check(
    "a period with a scheduled class cannot be claimed",
    class_in_it.status_code == 409 and "Class scheduled" in class_in_it.text,
    class_in_it.text[:200],
)

# (The earlier per-batch free-period block was replaced by the division-wide
# free-period tests above: a free period is one slot for the whole division.)

# --------------------------------------------------------------------------
# A period another teacher is assigned to is never free, even when the printed
# grid has no class in that cell. This is tested on a per-batch gap (Monday
# 16:15, D-2 - D-3 is in its EG practical) rather than on a free period:
# nothing is ever assigned to a free period, so an assignment there would be an
# invented one.
# --------------------------------------------------------------------------
manual = requests.post(
    f"{BASE}/teacher/{spk_id}/assignments",
    json={
        "subject": "M-1",
        "division": "D",
        "batch": "D-2",
        "day": "Monday",
        "start_time": "16:15",
        "end_time": "17:15",
    },
    headers=auth(admin_token),
    timeout=10,
)
check(
    "an admin can assign a colleague to a class group and period",
    manual.status_code == 201,
    manual.text[:200],
)

blocked = requests.get(
    f"{BASE}/teacher/free-periods?date={NEXT_MONDAY_STR}",
    headers=auth(smg_token),
    timeout=10,
).json()
smg_slot = next(
    (
        s
        for s in blocked["slots"]
        if s["start_time"] == "16:15" and s["batch"] == "D-2"
    ),
    None,
)
check(
    "a period assigned to another teacher is no longer free",
    smg_slot is not None and not smg_slot["eligible"],
    str(smg_slot),
)
check(
    "and the reason names the other assignment",
    "Another teacher is assigned" in ((smg_slot or {}).get("reason") or ""),
    str(smg_slot),
)
blocked_claim = requests.post(
    f"{BASE}/teacher/free-periods/claim",
    json={
        "day": "Monday",
        "start_time": "15:15",
        "end_time": "16:15",
        "division": "D",
        "batch": "D-2",
        "claim_date": NEXT_MONDAY_WEEK2_STR,
    },
    headers=auth(admin_token),
    timeout=10,
)
check(
    "and claiming it is refused",
    blocked_claim.status_code == 409,
    blocked_claim.text[:200],
)
check(
    "the teacher who holds the assignment is not blocked by their own row",
    not any(
        s["start_time"] == "16:15" and s["batch"] == "D-2" and "Another teacher" in (s["reason"] or "")
        for s in requests.get(
            f"{BASE}/teacher/free-periods?date={NEXT_MONDAY_STR}",
            headers=auth(spk_token),
            timeout=10,
        ).json()["slots"]
    ),
)

if manual.status_code == 201:
    requests.delete(
        f"{BASE}/teacher/{spk_id}/assignments/{manual.json()['id']}",
        headers=auth(admin_token),
        timeout=10,
    )
    manual_assignment_gone = requests.get(
        f"{BASE}/teacher/{spk_id}/assignments",
        headers=auth(admin_token),
        timeout=10,
    ).json()
    check(
        "removing the assignment gives the period back",
        all(
            not (
                row["day"] == "Monday"
                and row["start_time"] == "16:15"
                and row["batch"] == "D-2"
            )
            for row in manual_assignment_gone
        ),
        str(manual_assignment_gone),
    )

# --------------------------------------------------------------------------
# Two teachers claiming the same free period at the same moment.
# --------------------------------------------------------------------------
concurrent_results: list[tuple[int, str]] = []
concurrent_lock = threading.Lock()


def _race_claim(token):
    response = requests.post(
        f"{BASE}/teacher/free-periods/claim",
        json={
            "day": RELM_DAY_NAME,
            "start_time": RELM_START,
            "end_time": RELM_END,
            "division": "D",
            "batch": "",
            "claim_date": RELM_DATE_3_STR,
        },
        headers=auth(token),
        timeout=15,
    )
    with concurrent_lock:
        concurrent_results.append((response.status_code, response.text))
    return response


racers = [
    threading.Thread(target=_race_claim, args=(token,))
    for token in (smg_token, spk_token)
]
for racer in racers:
    racer.start()
for racer in racers:
    racer.join(timeout=20)

statuses = sorted(status for status, _ in concurrent_results)
loser_body = next(
    (body.lower() for status, body in concurrent_results if status != 201), ""
)
check(
    "simultaneous claims for one free period resolve to exactly one winner",
    statuses == [201, 409],
    str(concurrent_results),
)
check(
    "the losing teacher gets an explanation, not a crash or a silent success",
    loser_body.strip() != ""
    and any(
        phrase in loser_body
        for phrase in ("already claimed", "another teacher", "refresh")
    ),
    loser_body[:200],
)
race_claims = requests.get(
    f"{BASE}/teacher/free-periods/claims", headers=auth(smg_token), timeout=10
).json()
check(
    "exactly one claim row exists for the raced slot",
    sum(
        1
        for c in race_claims
        if c["claim_date"] == RELM_DATE_3_STR and c["start_time"] == RELM_START
    )
    + sum(
        1
        for c in requests.get(
            f"{BASE}/teacher/free-periods/claims", headers=auth(spk_token), timeout=10
        ).json()
        if c["claim_date"] == RELM_DATE_3_STR and c["start_time"] == RELM_START
    )
    == 1,
)

# ==========================================================================
section("5. Assignment PDF upload / download")
# ==========================================================================
PDF_BYTES = b"%PDF-1.4\n1 0 obj\n<< /Type /Catalog >>\nendobj\ntrailer\n<<>>\n%%EOF\n"
upload_url = f"{BASE}/teacher/assignments/upload"


def upload(token, *, filename="notes.pdf", content_type="application/pdf", data=None, payload=None, content=None):
    body = {
        "title": "Revision sheet",
        "subject": "M-1",
        "due_date": MONDAY_STR,
        "year": "1",
        "division": "D",
        "description": "Solve all questions",
        "batch": "",
    }
    body.update(payload or {})
    return requests.post(
        upload_url,
        headers=auth(token),
        data=body,
        files={"file": (filename, data if data is not None else (content or PDF_BYTES), content_type)},
        timeout=20,
    )


created_upload = upload(admin_token)
check("a teacher can upload a PDF", created_upload.status_code == 201, created_upload.text[:200])
check("the upload returns the metadata", created_upload.json().get("subject") == "M-1" and created_upload.json().get("has_attachment") is True, str(created_upload.json())[:200])

stored = conn.execute(
    "SELECT stored_name, original_name, file_size, uploaded_by FROM assignments WHERE id=?",
    (created_upload.json()["id"],),
).fetchone()
check("the stored name is server-generated", stored[0].endswith(".pdf") and stored[0] != "notes.pdf", str(stored[0]))
check("the original name is only kept for display", stored[1] == "notes.pdf", str(stored[1]))
check("the size is recorded", stored[2] == len(PDF_BYTES), str(stored[2]))
check("the uploader is recorded", stored[3] is not None, str(stored[3]))
check("exactly one file is written to the upload directory", len(list(UPLOAD_DIR.glob('*.pdf'))) == 1, str(list(UPLOAD_DIR.glob('*.pdf'))))
check("the file content is stored verbatim", (UPLOAD_DIR / stored[0]).read_bytes() == PDF_BYTES)

not_pdf = upload(admin_token, filename="notes.txt", content_type="text/plain")
check("a non-PDF content type is refused", not_pdf.status_code == 415, str(not_pdf.status_code))
fake_pdf = upload(admin_token, data=b"this is not a pdf", content_type="application/pdf")
check("a forged PDF is refused", fake_pdf.status_code == 415, str(fake_pdf.status_code))
empty_pdf = upload(admin_token, data=b"", content_type="application/pdf")
check("an empty file is refused", empty_pdf.status_code == 400, str(empty_pdf.status_code))
oversize = upload(admin_token, data=b"%PDF-1.4\n" + b"x" * (MAX_MB * 1024 * 1024), content_type="application/pdf")
check("a file above the size limit is refused", oversize.status_code == 413, str(oversize.status_code))
no_title = upload(admin_token, payload={"title": "   "})
check("a missing title is refused", no_title.status_code == 400, str(no_title.status_code))
bad_year = upload(admin_token, payload={"year": "9"})
check("an invalid year is refused", bad_year.status_code == 400, str(bad_year.status_code))
bad_batch = upload(admin_token, payload={"batch": "D-9"})
check("an invalid batch is refused", bad_batch.status_code == 400, str(bad_batch.status_code))
bad_date = upload(admin_token, payload={"due_date": "12/10/2026"})
check("an invalid due date is refused", bad_date.status_code == 400, str(bad_date.status_code))
check("a student cannot upload -> 403", upload(TOKENS["1"]).status_code == 403)
check(
    "an unauthenticated upload is refused",
    requests.post(upload_url, files={"file": ("n.pdf", PDF_BYTES, "application/pdf")}, timeout=10).status_code == 401,
)

batch_upload = upload(admin_token, payload={"batch": "D-1", "title": "D-1 only"})
check("a batch-restricted upload is accepted", batch_upload.status_code == 201, batch_upload.text[:200])

d1_assignments = requests.get(f"{BASE}/assignments", headers=auth(TOKENS["1"]), timeout=10).json()
d2_assignments = requests.get(f"{BASE}/assignments", headers=auth(TOKENS["25"]), timeout=10).json()
d1_ids_seen = {a["id"] for a in d1_assignments}
d2_ids_seen = {a["id"] for a in d2_assignments}
check("the division-wide upload is visible to D-1", created_upload.json()["id"] in d1_ids_seen)
check("the division-wide upload is visible to D-2", created_upload.json()["id"] in d2_ids_seen)
check("the D-1 upload is visible to D-1", batch_upload.json()["id"] in d1_ids_seen)
check("the D-1 upload is NOT visible to D-2", batch_upload.json()["id"] not in d2_ids_seen)

# --------------------------------------------------------------------------
# Uploading a subject replaces that class group's text-only placeholder, so the
# student sees one card per subject. Only the same subject/year/division - and
# only rows without a PDF - may be removed.
# --------------------------------------------------------------------------
conn.execute(
    "INSERT INTO assignments (subject, title, due_date, year, division, batch) VALUES (?, ?, ?, ?, ?, ?)",
    ("Engineering Physics", "Physics placeholder", MONDAY_STR, 1, "D", None),
)
placeholder_id = conn.execute("SELECT last_insert_rowid()").fetchone()[0]
conn.execute(
    "INSERT INTO assignments (subject, title, due_date, year, division, batch) VALUES (?, ?, ?, ?, ?, ?)",
    ("Engineering Physics", "Second year placeholder", MONDAY_STR, 2, "D", None),
)
other_year_id = conn.execute("SELECT last_insert_rowid()").fetchone()[0]

replacing_upload = upload(admin_token, payload={"subject": "Engineering Physics", "title": "Physics notes"})
check("uploading a subject is accepted", replacing_upload.status_code == 201, replacing_upload.text[:200])
check(
    "the subject's text-only placeholder is replaced",
    conn.execute("SELECT COUNT(*) FROM assignments WHERE id=?", (placeholder_id,)).fetchone()[0] == 0,
)
phy_rows = conn.execute(
    "SELECT id, stored_name FROM assignments WHERE subject='Engineering Physics' AND year=1 AND division='D'"
).fetchall()
check(
    "exactly one card remains for the subject",
    len(phy_rows) == 1 and phy_rows[0][1] is not None,
    str(phy_rows),
)
check(
    "a placeholder for another year is untouched",
    conn.execute("SELECT COUNT(*) FROM assignments WHERE id=?", (other_year_id,)).fetchone()[0] == 1,
)
check(
    "a placeholder for another subject is untouched",
    conn.execute("SELECT COUNT(*) FROM assignments WHERE id=1").fetchone()[0] == 1,
)
phy_cards = [
    a for a in requests.get(f"{BASE}/assignments", headers=auth(TOKENS["1"]), timeout=10).json()
    if a["subject"] == "Engineering Physics"
]
check(
    "the student sees one card for that subject, and it is the file",
    len(phy_cards) == 1 and phy_cards[0]["has_attachment"] is True,
    str(phy_cards)[:300],
)

mine = requests.get(f"{BASE}/teacher/assignments/mine", headers=auth(admin_token), timeout=10).json()
check("a teacher sees the assignments they uploaded", {a["id"] for a in mine} >= {created_upload.json()["id"], batch_upload.json()["id"]})
check("the list does not include other people's uploads", all(a["uploaded_by"] is not None for a in mine))
check("uploader listing carries no stored path", all("stored_name" not in a for a in mine))

download = requests.get(f"{BASE}/assignments/{created_upload.json()['id']}/file", headers=auth(TOKENS["1"]), timeout=10)
check("a student can download an assignment for their class", download.status_code == 200, str(download.status_code))
check("the download is a PDF", download.headers.get("content-type", "").startswith("application/pdf"), str(download.headers.get("content-type")))
check("the downloaded bytes match", download.content == PDF_BYTES)
check(
    "a student of another batch cannot download a batch assignment",
    requests.get(f"{BASE}/assignments/{batch_upload.json()['id']}/file", headers=auth(TOKENS["25"]), timeout=10).status_code == 403,
)
check(
    "the batch assignment's own batch can download it",
    requests.get(f"{BASE}/assignments/{batch_upload.json()['id']}/file", headers=auth(TOKENS["1"]), timeout=10).status_code == 200,
)
check(
    "an unauthenticated download is refused",
    requests.get(f"{BASE}/assignments/{created_upload.json()['id']}/file", timeout=10).status_code == 401,
)
check(
    "an assignment without a file returns 404",
    requests.get(f"{BASE}/assignments/1/file", headers=auth(TOKENS["1"]), timeout=10).status_code == 404,
)

# --------------------------------------------------------------------------
# Several files on one assignment: each is its own row, its own download, and a
# rejected file takes the whole upload with it (nothing half-stored).
# --------------------------------------------------------------------------
SECOND_PDF = b"%PDF-1.4\n2 0 obj\n<< /Type /Catalog /Pages 3 0 R >>\nendobj\n%%EOF\n"


def upload_many(token, items, payload=None):
    body = {
        "title": "Multi-file sheet",
        "subject": "EG",
        "due_date": MONDAY_STR,
        "year": "1",
        "division": "D",
        "description": "Read both parts",
        "batch": "",
    }
    body.update(payload or {})
    return requests.post(
        upload_url,
        headers=auth(token),
        data=body,
        files=[("files", item) for item in items],
        timeout=20,
    )


multi = upload_many(
    admin_token,
    [
        ("part-1.pdf", PDF_BYTES, "application/pdf"),
        ("part-2.pdf", SECOND_PDF, "application/pdf"),
    ],
)
check("several files can be attached to one assignment", multi.status_code == 201, multi.text[:200])
multi_id = multi.json()["id"]
multi_attachments = multi.json().get("attachments") or []
check(
    "the upload returns every attachment in upload order",
    [a["original_name"] for a in multi_attachments] == ["part-1.pdf", "part-2.pdf"],
    str(multi_attachments)[:300],
)
check(
    "each attachment has its own id",
    len({a["id"] for a in multi_attachments}) == 2,
    str(multi_attachments)[:300],
)
check(
    "the legacy single-file columns describe the first file",
    multi.json().get("original_name") == "part-1.pdf"
    and multi.json().get("has_attachment") is True,
    str(multi.json())[:300],
)

multi_rows = conn.execute(
    "SELECT id, stored_name, original_name, file_size FROM assignment_attachments"
    " WHERE assignment_id=? ORDER BY id",
    (multi_id,),
).fetchall()
check("every attachment is its own row", len(multi_rows) == 2, str(multi_rows))
check(
    "the rows keep the names the uploader chose",
    [r[2] for r in multi_rows] == ["part-1.pdf", "part-2.pdf"],
    str(multi_rows),
)
check(
    "each file is stored under a server-generated name",
    all(r[1].endswith(".pdf") and r[1] != r[2] for r in multi_rows),
    str(multi_rows),
)
check(
    "every file is written to disk",
    all((UPLOAD_DIR / r[1]).read_bytes() in (PDF_BYTES, SECOND_PDF) for r in multi_rows),
    str(multi_rows),
)

student_multi = next(
    (
        a
        for a in requests.get(f"{BASE}/assignments", headers=auth(TOKENS["1"]), timeout=10).json()
        if a["id"] == multi_id
    ),
    None,
)
check(
    "the student listing carries every attachment",
    student_multi is not None and len(student_multi.get("attachments") or []) == 2,
    str(student_multi)[:300],
)

for index, expected in enumerate((PDF_BYTES, SECOND_PDF)):
    fetched = requests.get(
        f"{BASE}/assignments/{multi_id}/files/{multi_rows[index][0]}",
        headers=auth(TOKENS["1"]),
        timeout=10,
    )
    check(
        f"attachment {index + 1} downloads with its own bytes",
        fetched.status_code == 200 and fetched.content == expected,
        f"{fetched.status_code} {len(fetched.content)} bytes",
    )
check(
    "the legacy single-file route serves the first attachment",
    requests.get(
        f"{BASE}/assignments/{multi_id}/file", headers=auth(TOKENS["1"]), timeout=10
    ).content
    == PDF_BYTES,
)
check(
    "an attachment id from another assignment is refused",
    requests.get(
        f"{BASE}/assignments/{multi_id}/files/{created_upload.json()['attachments'][0]['id']}",
        headers=auth(TOKENS["1"]),
        timeout=10,
    ).status_code
    == 404,
)
check(
    "an unauthenticated attachment download is refused",
    requests.get(
        f"{BASE}/assignments/{multi_id}/files/{multi_rows[0][0]}", timeout=10
    ).status_code
    == 401,
)

too_many = upload_many(
    admin_token,
    [(f"x{i}.pdf", PDF_BYTES, "application/pdf") for i in range(main.MAX_ASSIGNMENT_ATTACHMENTS + 1)],
)
check(
    "more files than the limit are refused",
    too_many.status_code == 400,
    str(too_many.status_code),
)
files_before = len(list(UPLOAD_DIR.iterdir()))
partial = upload_many(
    admin_token,
    [
        ("ok.pdf", PDF_BYTES, "application/pdf"),
        ("not-a-pdf.pdf", b"this is not a pdf", "application/pdf"),
    ],
)
check("one invalid file refuses the whole upload", partial.status_code == 415, str(partial.status_code))
check(
    "and leaves no file behind",
    len(list(UPLOAD_DIR.iterdir())) == files_before,
    str(len(list(UPLOAD_DIR.iterdir()))),
)
check(
    "and no assignment row",
    conn.execute(
        "SELECT COUNT(*) FROM assignments WHERE title='Multi-file sheet'"
    ).fetchone()[0]
    == 1,
)

multi_deleted = requests.delete(
    f"{BASE}/teacher/assignments/{multi_id}", headers=auth(admin_token), timeout=10
)
check("a multi-file upload can be removed", multi_deleted.status_code == 200, multi_deleted.text[:160])
check(
    "its attachment rows go with it",
    conn.execute(
        "SELECT COUNT(*) FROM assignment_attachments WHERE assignment_id=?", (multi_id,)
    ).fetchone()[0]
    == 0,
)
check(
    "and so do all of its files",
    all(not (UPLOAD_DIR / r[1]).exists() for r in multi_rows),
)

deleted = requests.delete(f"{BASE}/teacher/assignments/{created_upload.json()['id']}", headers=auth(admin_token), timeout=10)
check("a teacher can delete their own upload", deleted.status_code == 200, deleted.text[:160])
check("the file is removed from disk", not (UPLOAD_DIR / stored[0]).exists())
placeholder_delete = requests.delete(
    f"{BASE}/teacher/assignments/1", headers=auth(admin_token), timeout=10
)
check(
    "a text-only placeholder cannot be deleted",
    placeholder_delete.status_code == 400,
    str(placeholder_delete.status_code),
)
check(
    "the refusal says how to replace it",
    placeholder_delete.json().get("detail")
    == "Cannot delete a subject placeholder. Upload a file to replace it.",
    placeholder_delete.text[:200],
)
check(
    "and it is still there afterwards",
    conn.execute("SELECT COUNT(*) FROM assignments WHERE id=1").fetchone()[0] == 1,
)
check(
    "it is still visible to the students it was written for",
    any(a["id"] == 1 and a["batch"] is None for a in requests.get(f"{BASE}/assignments", headers=auth(TOKENS["1"]), timeout=10).json()),
)
check(
    "a different teacher cannot delete someone else's upload",
    requests.delete(f"{BASE}/teacher/assignments/{batch_upload.json()['id']}", headers=auth(spk_token), timeout=10).status_code == 403,
)

# ==========================================================================
section("5b. Announcements: who may withdraw one")
# ==========================================================================
# A notice can be withdrawn only by the account that posted it, or an admin.
# The rule is enforced by the backend, so a teacher who never sees another
# teacher's post still cannot delete it by guessing the id.
announce_url = f"{BASE}/teacher/announcements"

teacher_notice = requests.post(
    announce_url,
    data={"title": "Delete me", "message": "Details at https://example.com/notice"},
    headers=auth(plain_token),
    timeout=10,
)
check("a teacher can post an announcement", teacher_notice.status_code == 201, teacher_notice.text[:160])
teacher_notice_id = teacher_notice.json()["id"]

mine_list = requests.get(announce_url, headers=auth(plain_token), timeout=10)
check("a teacher lists the announcements they can manage", mine_list.status_code == 200, mine_list.text[:160])
check(
    "the listing includes their own post",
    teacher_notice_id in {a["id"] for a in mine_list.json()},
    str([a["id"] for a in mine_list.json()]),
)
check(
    "the listing carries the author name",
    all(a.get("author_name") for a in mine_list.json()),
    str(mine_list.json())[:200],
)
check(
    "a teacher does not list a colleague's post",
    teacher_notice_id not in {a["id"] for a in requests.get(announce_url, headers=auth(spk_token), timeout=10).json()},
)
check(
    "a colleague cannot delete it",
    requests.delete(f"{announce_url}/{teacher_notice_id}", headers=auth(spk_token), timeout=10).status_code == 403,
)
check(
    "a student cannot delete it",
    requests.delete(f"{announce_url}/{teacher_notice_id}", headers=auth(TOKENS["1"]), timeout=10).status_code == 403,
)
check(
    "an unauthenticated delete is refused",
    requests.delete(f"{announce_url}/{teacher_notice_id}", timeout=10).status_code == 401,
)
check(
    "the post is still in the student feed after the refused deletes",
    teacher_notice_id in {a["id"] for a in requests.get(f"{BASE}/announcements", headers=auth(TOKENS["1"]), timeout=10).json()},
)
check(
    "the author can withdraw their own announcement",
    requests.delete(f"{announce_url}/{teacher_notice_id}", headers=auth(plain_token), timeout=10).status_code == 200,
)
check(
    "it is gone from the student feed",
    teacher_notice_id not in {a["id"] for a in requests.get(f"{BASE}/announcements", headers=auth(TOKENS["1"]), timeout=10).json()},
)
check(
    "the row is gone, not hidden",
    conn.execute("SELECT COUNT(*) FROM announcements WHERE id=?", (teacher_notice_id,)).fetchone()[0] == 0,
)
check(
    "deleting it again is a 404",
    requests.delete(f"{announce_url}/{teacher_notice_id}", headers=auth(plain_token), timeout=10).status_code == 404,
)

# A notice may be filed under one of the seven official subjects. "Common" is
# the absence of a subject in the request and is stored as NULL.
subject_notice = requests.post(
    announce_url,
    data={
        "title": "Physics tutorial",
        "message": "Bring the lab manual on Friday.",
        "subject": "Engineering Physics",
    },
    headers=auth(plain_token),
    timeout=10,
)
check("a post can be filed under a subject", subject_notice.status_code == 201, subject_notice.text[:160])
check(
    "the created post returns its subject",
    subject_notice.json().get("subject") == "Engineering Physics",
    subject_notice.text[:200],
)
subject_notice_id = subject_notice.json().get("id")
check(
    "the student feed carries the subject",
    "Engineering Physics" in {
        a.get("subject") for a in requests.get(f"{BASE}/announcements", headers=auth(TOKENS["1"]), timeout=10).json()
    },
    "subject field missing from the student feed",
)
check(
    "the filing is stored, not inferred from the title",
    conn.execute("SELECT subject FROM announcements WHERE id=?", (subject_notice_id,)).fetchone()[0]
    == "Engineering Physics",
)
check(
    "a subject outside the seven is refused",
    requests.post(
        announce_url,
        data={"title": "Not a subject", "message": "x", "subject": "Astrology"},
        headers=auth(plain_token),
        timeout=10,
    ).status_code == 400,
)
common_notice = requests.post(
    announce_url,
    data={"title": "Common notice", "message": "No subject attached."},
    headers=auth(plain_token),
    timeout=10,
)
check("a post without a subject is accepted", common_notice.status_code == 201, common_notice.text[:160])
check(
    "a Common post is stored as NULL, not an empty string",
    conn.execute("SELECT subject FROM announcements WHERE id=?", (common_notice.json().get("id"),)).fetchone()[0]
    is None,
)
requests.delete(f"{announce_url}/{common_notice.json().get('id')}", headers=auth(plain_token), timeout=10)
requests.delete(f"{announce_url}/{subject_notice_id}", headers=auth(plain_token), timeout=10)

admin_notice = requests.post(
    announce_url,
    data={"title": "Admin notice", "message": "Posted by a teacher"},
    headers=auth(plain_token),
    timeout=10,
)
check("a second notice is posted for the admin case", admin_notice.status_code == 201, admin_notice.text[:160])
admin_notice_id = admin_notice.json()["id"]
check(
    "an admin lists every announcement",
    admin_notice_id in {a["id"] for a in requests.get(announce_url, headers=auth(admin_token), timeout=10).json()},
)
check(
    "an admin can withdraw someone else's announcement",
    requests.delete(f"{announce_url}/{admin_notice_id}", headers=auth(admin_token), timeout=10).status_code == 200,
)
check(
    "the admin list no longer carries it",
    admin_notice_id not in {a["id"] for a in requests.get(announce_url, headers=auth(admin_token), timeout=10).json()},
)


# ==========================================================================
section("6. Notifications for a new assignment")
# ==========================================================================
# Uploading an assignment notifies exactly the students who can see it: the
# same year/division, every approved student for a division-wide upload, and
# only the matching batch for a batch-specific one. Pending accounts are skipped.

def notifications_for(message):
    return conn.execute(
        """
        SELECT s.roll_number, n.is_read
        FROM notifications n
        JOIN students s ON s.id = n.student_id
        WHERE n.message = ?
        """,
        (message,),
    ).fetchall()


division_probe = upload(
    admin_token, payload={"title": "Notification probe", "subject": "Skills"}
)
check("the notification probe uploaded", division_probe.status_code == 201, division_probe.text[:200])
division_message = "New assignment uploaded: Notification probe"
division_rows = notifications_for(division_message)
# Derived from the database, not a hard-coded list: earlier sections approve
# some accounts, so "every approved student" is read from the same rows the
# endpoint reads.
approved_rolls = {
    row[0]
    for row in conn.execute(
        "SELECT roll_number FROM students WHERE year=1 AND division='D' AND status='approved'"
    )
}
check(
    "a division-wide upload notifies every approved student in the class",
    {row[0] for row in division_rows} == approved_rolls,
    f"got={sorted(row[0] for row in division_rows)} expected={sorted(approved_rolls)}",
)
check(
    "every notification starts unread",
    all(row[1] == 0 for row in division_rows),
    str(division_rows),
)
check(
    "a pending account receives no notification",
    conn.execute(
        """
        SELECT COUNT(*) FROM notifications n
        JOIN students s ON s.id = n.student_id
        WHERE s.roll_number = '903'
        """
    ).fetchone()[0]
    == 0,
)
check(
    "the never-approved student is the only class member left out",
    {row[0] for row in division_rows}
    == {
        row[0]
        for row in conn.execute(
            "SELECT roll_number FROM students WHERE year=1 AND division='D' AND roll_number != '903'"
        )
    },
    str(sorted(row[0] for row in division_rows)),
)

batch_probe = upload(
    admin_token,
    payload={"title": "Notification probe D-1", "subject": "Skills lab", "batch": "D-1"},
)
check("the batch notification probe uploaded", batch_probe.status_code == 201, batch_probe.text[:200])
batch_rows = notifications_for("New assignment uploaded: Notification probe D-1")
check(
    "a batch upload notifies only that batch",
    {row[0] for row in batch_rows}
    == {
        row[0]
        for row in conn.execute(
            "SELECT roll_number FROM students WHERE year=1 AND division='D' AND batch='D-1' AND status='approved'"
        )
    },
    str(sorted(row[0] for row in batch_rows)),
)

feed_response = requests.get(f"{BASE}/notifications", headers=auth(TOKENS["1"]), timeout=10)
check("a student can read their notifications", feed_response.status_code == 200, feed_response.text[:200])
feed = feed_response.json()
check("the feed is not empty", len(feed) > 0, str(feed)[:200])
check(
    "the newest notification comes first",
    [n["id"] for n in feed] == sorted((n["id"] for n in feed), reverse=True),
    str([n["id"] for n in feed]),
)
check(
    "the feed carries no other student's id",
    all("student_id" not in n for n in feed),
    str(feed[0])[:200],
)
check(
    "the feed contains the division-wide notification, unread",
    any(n["message"] == division_message and n["is_read"] is False for n in feed),
    str([n["message"] for n in feed])[:200],
)
member_only = requests.get(f"{BASE}/notifications", headers=auth(TOKENS["25"]), timeout=10).json()
check(
    "another batch does not receive the D-1 notification",
    all(n["message"] != "New assignment uploaded: Notification probe D-1" for n in member_only),
    str([n["message"] for n in member_only])[:200],
)
check(
    "an unauthenticated notification read is refused",
    requests.get(f"{BASE}/notifications", timeout=10).status_code == 401,
)

probe_notification = next(n for n in feed if n["message"] == division_message)
foreign_read = requests.put(
    f"{BASE}/notifications/{probe_notification['id']}/read",
    headers=auth(TOKENS["25"]),
    timeout=10,
)
check(
    "a student cannot mark another student's notification read",
    foreign_read.status_code == 404,
    str(foreign_read.status_code),
)
check(
    "and it is still unread",
    conn.execute(
        "SELECT is_read FROM notifications WHERE id=?", (probe_notification["id"],)
    ).fetchone()[0]
    == 0,
)

owned_read = requests.put(
    f"{BASE}/notifications/{probe_notification['id']}/read",
    headers=auth(TOKENS["1"]),
    timeout=10,
)
check("the owner can mark it read", owned_read.status_code == 200, owned_read.text[:200])
check("the response says it is read", owned_read.json().get("is_read") is True, owned_read.text[:200])
check(
    "marking it read twice is harmless",
    requests.put(
        f"{BASE}/notifications/{probe_notification['id']}/read",
        headers=auth(TOKENS["1"]),
        timeout=10,
    ).status_code
    == 200,
)
check(
    "an unknown notification id returns 404",
    requests.put(
        f"{BASE}/notifications/999999/read", headers=auth(TOKENS["1"]), timeout=10
    ).status_code
    == 404,
)

read_all = requests.put(f"{BASE}/notifications/read-all", headers=auth(TOKENS["25"]), timeout=10)
check("mark-all-as-read succeeds", read_all.status_code == 200, read_all.text[:200])
check(
    "it reports how many rows changed",
    read_all.json().get("marked_read", 0) >= 1,
    read_all.text[:200],
)
check(
    "student 25 now has no unread notification",
    not [n for n in requests.get(f"{BASE}/notifications", headers=auth(TOKENS["25"]), timeout=10).json() if not n["is_read"]],
)
check(
    "a second mark-all is a no-op",
    requests.put(f"{BASE}/notifications/read-all", headers=auth(TOKENS["25"]), timeout=10).json().get("marked_read")
    == 0,
)
check(
    "student 1's own read state is untouched by student 25's mark-all",
    next(
        n for n in requests.get(f"{BASE}/notifications", headers=auth(TOKENS["1"]), timeout=10).json()
        if n["id"] == probe_notification["id"]
    )["is_read"]
    is True,
)

# ==========================================================================
section("7. Faculty Finder / Lab Finder")
# ==========================================================================
faculty_all = requests.get(f"{BASE}/faculty", headers=auth(TOKENS["1"]), timeout=10)
check("a student can read the faculty directory", faculty_all.status_code == 200, str(faculty_all.status_code))
faculty = faculty_all.json()
check("the directory is populated from the official sheet", len(faculty) == 8, str(len(faculty)))
smg = next((f for f in faculty if f["short_code"] == "SMG"), None)
check("the coordinator's name comes from the sheet", smg and smg["full_name"] == "Mrs. S. M. Gangurde", str(smg))
check("the coordinator's record is marked verified", smg and smg["is_verified"] is True)
check("their subjects are the official ones", smg and {s["short_name"] for s in smg["subjects"]} == {"EMI"}, str(smg and smg["subjects"]))
spg = next((f for f in faculty if f["short_code"] == "SPG"), None)
check("an unknown full name stays empty", spg and spg["full_name"] is None, str(spg))
check("an unknown e-mail stays empty", spg and spg["email"] is None)
check("an unknown office stays empty", spg and spg["office"] is None)
check("an unknown phone stays empty", spg and spg["phone"] is None)
check("the display name falls back to the printed code", spg and spg["display_name"] == "SPG")
check("no fabricated placeholder text is returned", not any(
    value and value.strip().lower() in {"unknown", "n/a", "tbd", "not available"} for f in faculty for value in (f["full_name"], f["email"], f["office"], f["phone"])
))

search_name = requests.get(f"{BASE}/faculty?q=gangurde", headers=auth(TOKENS["1"]), timeout=10).json()
check("searching by name works", [f["short_code"] for f in search_name] == ["SMG"], str(search_name))
search_subject = requests.get(f"{BASE}/faculty?q=physics", headers=auth(TOKENS["1"]), timeout=10).json()
check("searching by subject works", {f["short_code"] for f in search_subject} == {"SPG"}, str([f["short_code"] for f in search_subject]))
search_code = requests.get(f"{BASE}/faculty?q=hbw", headers=auth(TOKENS["1"]), timeout=10).json()
check("searching by code works", [f["short_code"] for f in search_code] == ["HBW"])
empty_search = requests.get(f"{BASE}/faculty?q=zzzz", headers=auth(TOKENS["1"]), timeout=10).json()
check("an unmatched search returns an empty list", empty_search == [])
check(
    "the faculty endpoint is not public",
    requests.get(f"{BASE}/faculty", timeout=10).status_code == 401,
)

labs = requests.get(f"{BASE}/labs", headers=auth(TOKENS["1"]), timeout=10).json()
check("the room directory returns the official classroom", [l["code"] for l in labs] == ["M308"], str(labs))
check("its block is the one on the sheet", labs and labs[0]["building"] == "Block-11")
check("an unknown floor stays empty", labs and labs[0]["floor"] is None)
check("no laboratory is invented", all(l["kind"] == "classroom" for l in labs), str(labs))
labs_search = requests.get(f"{BASE}/labs?q=m308", headers=auth(TOKENS["1"]), timeout=10).json()
check("searching rooms by code works", len(labs_search) == 1)
check("an unmatched room search returns empty", requests.get(f"{BASE}/labs?q=zzz", headers=auth(TOKENS["1"]), timeout=10).json() == [])

status = requests.get(f"{BASE}/directory/status", headers=auth(TOKENS["1"]), timeout=10).json()
check("the status reports the counts", status["faculty_count"] == 8 and status["lab_count"] == 1, str(status))
check("the status lists what data is still missing", len(status["missing_data"]) >= 4, str(len(status["missing_data"])))
check("the missing list names the laboratory gap", any("aborator" in item for item in status["missing_data"]), str(status["missing_data"])[:200])

# ==========================================================================
section("8. Official data honesty")
# ==========================================================================
check("only the coordinator has a full name in the source data", [
    f["short_code"] for f in official_data.FACULTY if f["full_name"]
] == ["SMG"])
check("no e-mail is invented in the source data", all("email" not in f for f in official_data.FACULTY))
check("the grid matches the printed sheet's 42 teaching entries", len(official_data.TIMETABLE) == 42, str(len(official_data.TIMETABLE)))
check("the printed room is the only room recorded", [r["room"] for r in official_data.ROOMS] == ["M308"])
check("every batch code in the grid is a real batch", all(
    entry[5] is None or entry[5] in official_data.BATCHES for entry in official_data.TIMETABLE
))
check("every faculty code in the grid is catalogued", all(
    token in {f["short_code"] for f in official_data.FACULTY}
    for entry in official_data.TIMETABLE
    for token in entry[4].replace("(", " ").replace(")", " ").split()
    if token
    and token not in {"CCI", "/", "TUT"}
    and not token.lower().startswith("relm")
))

# --------------------------------------------------------------------------
# The department's confirmed corrections, read straight out of the database.
# --------------------------------------------------------------------------
saturday_ccc1 = conn.execute(
    "SELECT start_time, subject, faculty, batch FROM timetable_entries "
    "WHERE division = 'D' AND day = 'Saturday' AND subject = 'CCC-1' "
    "ORDER BY start_time"
).fetchall()
check(
    "both Saturday entries keep the subject CCC-1",
    [row[:2] for row in saturday_ccc1] == [("13:00", "CCC-1"), ("14:00", "CCC-1")],
    str(saturday_ccc1),
)
check(
    "both Saturday CCC-1 entries are taught by HBW",
    [row[2] for row in saturday_ccc1] == ["HBW", "HBW"],
    str(saturday_ccc1),
)
check(
    "HBW is a faculty code, never a subject",
    conn.execute("SELECT 1 FROM timetable_entries WHERE subject = 'HBW'").fetchone()
    is None,
)
check(
    "CCC-1 stays a whole-division entry, not a batch practical",
    all(row[3] is None for row in saturday_ccc1),
    str(saturday_ccc1),
)

# The sheet prints a plain "RVS" in some cells and "RVS (CCI)" in others; only
# the parenthesised cells are the ones that were corrected.
fpl_faculty = conn.execute(
    "SELECT day, start_time, faculty FROM timetable_entries "
    "WHERE division = 'D' AND subject = 'FPL' AND faculty LIKE 'RVS%' "
    "ORDER BY day, start_time"
).fetchall()
check(
    "an FPL cell is either plain 'RVS' or 'RVS (CCI)' - nothing else",
    all(row[2] in {"RVS", "RVS (CCI)"} for row in fpl_faculty),
    str(fpl_faculty),
)
check(
    "every parenthesised FPL cell is 'RVS (CCI)'",
    all(
        row[2] == "RVS (CCI)"
        for row in fpl_faculty
        if row[2] != "RVS"
    ),
    str(fpl_faculty),
)
check(
    "Wednesday D-3 and Friday D-2 FPL use the letter I, not the digit 1",
    {
        (row[0], row[1], row[2])
        for row in fpl_faculty
        if row[0] in {"Wednesday", "Friday"}
    }
    == {
        ("Wednesday", "13:00", "RVS (CCI)"),
        ("Friday", "15:15", "RVS (CCI)"),
    },
    str(fpl_faculty),
)
check(
    "no timetable cell anywhere keeps the '(CC1)' spelling",
    conn.execute(
        "SELECT 1 FROM timetable_entries WHERE faculty LIKE '%(CC1)%'"
    ).fetchone()
    is None,
)

free_rows = conn.execute(
    "SELECT day, start_time, end_time, subject, faculty, is_break, is_free_period "
    "FROM timetable_entries WHERE is_free_period = 1 ORDER BY day, start_time"
).fetchall()
check(
    "exactly the sheet's five free periods are flagged as free periods",
    {(row[0], row[1], row[2]) for row in free_rows}
    == set(official_data.FREE_PERIOD_SLOTS),
    str(free_rows),
)
check(
    "the five free periods kept their exact day, start and end",
    len(free_rows) == 5
    and all(
        (row[0], row[1], row[2]) in official_data.FREE_PERIOD_KEYS
        for row in free_rows
    ),
    str(free_rows),
)
check(
    "a free period is not stored as a break",
    all(row[5] == 0 for row in free_rows),
    str([(row[0], row[1], row[5]) for row in free_rows]),
)
check(
    "a free period carries no faculty (nobody is assigned to it)",
    all((row[4] or "") == "" for row in free_rows),
    str([(row[0], row[1], row[4]) for row in free_rows]),
)
check(
    "the free periods keep the sheet's own label",
    all(row[3] == official_data.FREE_PERIOD_SUBJECT for row in free_rows),
    str([row[3] for row in free_rows]),
)
check(
    "no free period is batch-specific",
    conn.execute(
        "SELECT 1 FROM timetable_entries WHERE is_free_period = 1 AND batch IS NOT NULL"
    ).fetchone()
    is None,
)

# --------------------------------------------------------------------------
# Monday: three ordinary batch practicals and NO free period at all.
# --------------------------------------------------------------------------
monday_rows = conn.execute(
    "SELECT start_time, end_time, subject, faculty, batch, is_break, is_free_period "
    "FROM timetable_entries WHERE division = 'D' AND day = 'Monday' "
    "ORDER BY start_time, batch"
).fetchall()
check(
    "Monday has no free period",
    not [row for row in monday_rows if row[6]],
    str(monday_rows),
)
check(
    "no Monday row carries the RELM label",
    not [
        row
        for row in monday_rows
        if row[2].strip().upper() == official_data.FREE_PERIOD_SUBJECT
    ],
    str([row[:3] for row in monday_rows]),
)
monday_practicals = {(row[2], row[3], row[4]) for row in monday_rows if row[4]}
check(
    "Monday's batch practicals are exactly the three confirmed entries",
    monday_practicals
    == {("PHY", "SPG", "D-1"), ("BEE", "HBW", "D-2"), ("EG", "VTM", "D-3")},
    str(sorted(monday_practicals)),
)
check(
    "none of them is a free period or a break",
    all(row[5] == 0 and row[6] == 0 for row in monday_rows if row[4]),
    str([row for row in monday_rows if row[4]]),
)
check(
    "Monday's closing practicals sit in its last two periods",
    {row[1] for row in monday_rows if row[4]} == {"16:15", "17:15"},
    str(sorted((row[0], row[1]) for row in monday_rows if row[4])),
)
check(
    "Monday is not one of the free-period days",
    "Monday" not in {day for day, _, _ in official_data.FREE_PERIOD_SLOTS},
)

# --------------------------------------------------------------------------
# Reseeding must change nothing else: no student, teacher, password hash,
# assignment, attendance or claim row may be rewritten by a second run.
# --------------------------------------------------------------------------
def snapshot() -> dict:
    tables = (
        "students",
        "teachers",
        "timetable_entries",
        "assignments",
        "attendance_records",
        "free_period_claims",
        "teacher_assignments",
        "subjects",
        "faculty_directory",
        "lab_directory",
    )
    return {
        table: conn.execute(
            f"SELECT * FROM {table} ORDER BY id"
        ).fetchall()
        for table in tables
    }


before_snapshot = snapshot()
second_run = seed_official_data.main(["--db", str(DB_FILE), "--apply", "--no-backup"])
after_snapshot = snapshot()

check("a second seeding run succeeds and is idempotent", second_run == 0, str(second_run))
for table in ("students", "teachers"):
    check(
        f"{table}: rows and password hashes are byte-for-byte identical after reseeding",
        before_snapshot[table] == after_snapshot[table]
        and len(before_snapshot[table]) == len(after_snapshot[table]),
        "a row or a stored hash changed",
    )
for table in (
    "timetable_entries",
    "assignments",
    "attendance_records",
    "free_period_claims",
    "teacher_assignments",
    "subjects",
    "faculty_directory",
    "lab_directory",
):
    check(
        f"{table}: unchanged by reseeding",
        before_snapshot[table] == after_snapshot[table],
        "a row changed",
    )
check(
    "the corrected rows did not drift back to the old reading",
    all(
        row[2] == "HBW"
        for row in conn.execute(
            "SELECT day, start_time, faculty FROM timetable_entries "
            "WHERE subject = 'CCC-1' AND day = 'Saturday'"
        ).fetchall()
    ),
)

db.close()
conn.close()

# ==========================================================================
section("9. The real database was not touched")
# ==========================================================================
real_stamp = (REAL_DB.stat().st_size, REAL_DB.stat().st_mtime_ns) if REAL_DB.exists() else None
check("real database size/mtime unchanged by this suite", real_stamp == REAL_DB_STAMP, f"before={REAL_DB_STAMP} after={real_stamp}")

# ==========================================================================
section("10. The seeder's dry run writes nothing")
# ==========================================================================
# A copy is used, and the new column is dropped from it first, so the dry run is
# exercised on a database in the state the real one is in today (not migrated).
dry_dir = Path(tempfile.mkdtemp(prefix="cs-dryrun-")).resolve()
dry_db = dry_dir / "campussync.db"
# Safety: this copy is deliberately mutated below (never the real database, and
# never the suite's own seeded database either).
if (
    dry_dir.parent != Path(tempfile.gettempdir()).resolve()
    or dry_db in {REAL_DB, DB_FILE}
):
    sys.exit(f"REFUSING TO RUN: {dry_db} is not a throwaway copy.")
shutil.copy2(DB_FILE, dry_db)

# Shape the copy into the state the REAL database is in today: schema not yet
# migrated, the timetable present with the four disputed cells as read by the
# earlier import, the five "RELM" rows stored as breaks, and no directory data.
unmigrate = sqlite3.connect(dry_db)
unmigrate.execute("ALTER TABLE timetable_entries DROP COLUMN is_free_period")
unmigrate.execute("DELETE FROM subjects")
unmigrate.execute("DELETE FROM faculty_directory")
unmigrate.execute("DELETE FROM lab_directory")
unmigrate.execute(
    "UPDATE timetable_entries SET faculty = 'DPK' "
    "WHERE day = 'Saturday' AND subject = 'CCC-1'"
)
unmigrate.execute(
    "UPDATE timetable_entries SET faculty = 'RVS (CC1)' "
    "WHERE faculty = 'RVS (CCI)' AND day IN ('Wednesday', 'Friday')"
)
unmigrate.execute(
    "UPDATE timetable_entries SET is_break = 1 "
    "WHERE subject = 'RELM'"
)
unmigrate.commit()
unmigrate.close()


def dry_fingerprint():
    return (
        hashlib.sha256(dry_db.read_bytes()).hexdigest(),
        sorted(p.name for p in dry_dir.iterdir()),
        [
            row[1]
            for row in sqlite3.connect(dry_db).execute(
                "PRAGMA table_info(timetable_entries)"
            )
        ],
    )


before_dry = dry_fingerprint()
dry_output = io.StringIO()
with contextlib.redirect_stdout(dry_output):
    dry_code = seed_official_data.main(["--db", str(dry_db)])
dry_text = dry_output.getvalue()
after_dry = dry_fingerprint()

check("a dry run works on a not-yet-migrated database", dry_code == 0, str(dry_code))
check(
    "it reports the additive column it would add",
    "add column timetable_entries.is_free_period" in dry_text,
    dry_text[:400],
)
check(
    "the dry run does not add the column",
    "is_free_period" not in after_dry[2],
    str(after_dry[2]),
)
check(
    "the target database is byte-identical after a dry run",
    before_dry[0] == after_dry[0],
    f"{before_dry[0]} -> {after_dry[0]}",
)
check(
    "a dry run creates no file next to the database (no backup, no journal)",
    before_dry[1] == after_dry[1],
    f"{before_dry[1]} -> {after_dry[1]}",
)
check(
    "the dry run still reports the free-period plan",
    "free periods set  : 5" in dry_text,
    dry_text[:600],
)
check(
    "the dry run still reports the break flags it would fix",
    "break flags fixed : 5" in dry_text,
    dry_text[:900],
)
check(
    "the dry run still reports the four faculty corrections",
    "faculty corrected : 4" in dry_text
    and "DPK -> HBW" in dry_text
    and "RVS (CC1) -> RVS (CCI)" in dry_text,
    dry_text[-900:],
)
check(
    "the dry run still reports the data it would load",
    "subjects new      : 13" in dry_text
    and "faculty new       : 8" in dry_text
    and "rooms new         : 1" in dry_text,
    dry_text[:600],
)
check(
    "the dry run reports no timetable entry as missing",
    "entries missing   : 0" in dry_text,
    dry_text[-900:],
)
shutil.rmtree(dry_dir, ignore_errors=True)

# ==========================================================================
section("11. A database the additive migration has not reached fails LOUDLY")
# ==========================================================================
# The live database is in exactly this state today: the additive
# ``timetable_entries.is_free_period`` column has not been added yet. The
# backend must never answer such a database with a schedule it cannot compute -
# a free period is not handed to a student as a lecture, and an error is never
# rendered as an empty timetable. This pins both halves: the loud failure, and
# the fact that the sanctioned additive step is enough to bring it back without
# touching any other table's data.
from datetime import datetime  # noqa: E402

from sqlalchemy import create_engine  # noqa: E402
from sqlalchemy.orm import sessionmaker  # noqa: E402

unmigrated_dir = Path(tempfile.mkdtemp(prefix="cs-unmigrated-")).resolve()
unmigrated_db = unmigrated_dir / "campussync.db"
if (
    unmigrated_dir.parent != Path(tempfile.gettempdir()).resolve()
    or unmigrated_db in {REAL_DB, DB_FILE}
):
    sys.exit(f"REFUSING TO RUN: {unmigrated_db} is not a throwaway copy.")
shutil.copy2(DB_FILE, unmigrated_db)


def parts_session(path):
    """A session of its own, so a failed select cannot poison the next query."""
    return sessionmaker(bind=create_engine(f"sqlite:///{path.as_posix()}"))()


# Shape the copy like the live database: the added column is gone, the five
# "RELM" rows are still stored as breaks, and the four disputed faculty cells
# still carry the earlier reading.
shape = sqlite3.connect(unmigrated_db)
shape.execute("ALTER TABLE timetable_entries DROP COLUMN is_free_period")
shape.execute("DELETE FROM subjects")
shape.execute("DELETE FROM faculty_directory")
shape.execute("DELETE FROM lab_directory")
shape.execute(
    "UPDATE timetable_entries SET faculty = 'DPK' "
    "WHERE day = 'Saturday' AND subject = 'CCC-1'"
)
shape.execute(
    "UPDATE timetable_entries SET faculty = 'RVS (CC1)' "
    "WHERE subject = 'FPL' AND day IN ('Wednesday', 'Friday')"
)
shape.execute("UPDATE timetable_entries SET is_break = 1 WHERE subject = 'RELM'")
shape.commit()
shape.close()

shape_cols = [
    row[1]
    for row in sqlite3.connect(unmigrated_db).execute(
        "PRAGMA table_info(timetable_entries)"
    )
]
check(
    "the throwaway copy really is in the live database's shape",
    "is_free_period" not in shape_cols,
    str(shape_cols),
)

probe = parts_session(unmigrated_db)
probe_student = models.Student(
    name="UNMIGRATED PROBE",
    email="unmigrated.probe@example.com",
    roll_number="8899",
    branch="Computer",
    year=1,
    division="D",
    batch="D-1",
    password="not-a-real-hash",
    status=models.StudentStatus.approved,
)
probe.add(probe_student)
probe.commit()

raised = None
try:
    main._student_timetable_entries(probe, probe_student)
except Exception as exc:  # the failure itself is what is under test here
    raised = exc

check(
    "a timetable query against a not-yet-migrated database raises instead of answering",
    raised is not None,
    "a schedule was returned for a database this revision cannot read",
)
check(
    "the failure names the missing column (loud, never a silently wrong schedule)",
    raised is not None and "is_free_period" in str(raised),
    f"{type(raised).__name__}: {str(raised)[:120]}" if raised else "nothing raised",
)

# The other endpoint that fails in this state: the free-period availability query
# filters on the same missing column. A teacher account is created here (the
# teachers table is unaffected by the missing timetable column).
probe_teacher_session = parts_session(unmigrated_db)
probe_teacher_session.add(
    models.Teacher(
        name="UNMIGRATED PROBE TEACHER",
        email="unmigrated.teacher@example.com",
        password="not-a-real-hash",
        role=models.TeacherRole.teacher,
        is_active=True,
        created_at=datetime.now(),
        short_code=None,
        can_approve_registrations=False,
    )
)
probe_teacher_session.commit()

tuesday = next(
    day
    for day in (date.today() + timedelta(days=offset) for offset in range(1, 8))
    if day.weekday() == 1
)

free_raised = None
try:
    free_session = parts_session(unmigrated_db)
    main._free_period_availability(
        free_session,
        free_session.query(models.Teacher)
        .filter(models.Teacher.email == "unmigrated.teacher@example.com")
        .first(),
        tuesday,
    )
except Exception as exc:  # the failure itself is what is under test here
    free_raised = exc

check(
    "the free-period endpoint fails just as loudly in that state",
    free_raised is not None and "is_free_period" in str(free_raised),
    f"{type(free_raised).__name__}: {str(free_raised)[:120]}"
    if free_raised
    else "nothing raised",
)

# The official slot table is the second opinion every filter falls back on. On a
# database where the column is absent the rows are still readable column by
# column, and the official table must still recognise exactly the five free
# periods - while the stored break flag is still the wrong reading.
official_rows = parts_session(unmigrated_db).query(
    models.TimetableEntry.id,
    models.TimetableEntry.day,
    models.TimetableEntry.start_time,
    models.TimetableEntry.end_time,
    models.TimetableEntry.subject,
    models.TimetableEntry.batch,
    models.TimetableEntry.is_break,
).filter(models.TimetableEntry.division == "D").all()
free_from_official = sorted(
    (row.day, row.start_time, row.end_time)
    for row in official_rows
    if (row.subject or "").strip().upper() == official_data.FREE_PERIOD_SUBJECT
    and official_data.is_free_period_slot(row.day, row.start_time, row.end_time)
)
check(
    "the official table still identifies the five free periods without the column",
    free_from_official == sorted(official_data.FREE_PERIOD_SLOTS),
    f"got {free_from_official}",
)
relm_rows = [
    row
    for row in official_rows
    if (row.subject or "").strip().upper() == official_data.FREE_PERIOD_SUBJECT
]
check(
    "in that state every free period is stored as an ordinary break, so the official table is what keeps it out of a schedule",
    len(relm_rows) == len(official_data.FREE_PERIOD_SLOTS)
    and all(row.is_break for row in relm_rows),
    str([(row.id, row.is_break) for row in relm_rows]),
)

# The sanctioned additive step, and nothing else.
schema_out = io.StringIO()
with contextlib.redirect_stdout(schema_out):
    schema_rc = seed_official_data.main(
        ["--db", str(unmigrated_db), "--schema-only", "--apply"]
    )
check("the sanctioned additive step succeeds on that database", schema_rc == 0, str(schema_rc))

repaired = sqlite3.connect(unmigrated_db)
repaired_cols = [
    row[1] for row in repaired.execute("PRAGMA table_info(timetable_entries)")
]
counts_after = (
    repaired.execute("SELECT COUNT(*) FROM subjects").fetchone()[0],
    repaired.execute("SELECT COUNT(*) FROM faculty_directory").fetchone()[0],
    repaired.execute("SELECT COUNT(*) FROM lab_directory").fetchone()[0],
)
saturday_ccc = repaired.execute(
    "SELECT faculty FROM timetable_entries WHERE day = 'Saturday' AND subject = 'CCC-1'"
).fetchall()
relm_flags = repaired.execute(
    "SELECT is_break, is_free_period FROM timetable_entries WHERE subject = 'RELM' ORDER BY id"
).fetchall()
fpl_cells = repaired.execute(
    "SELECT faculty FROM timetable_entries WHERE subject = 'FPL' AND day IN ('Wednesday', 'Friday')"
).fetchall()
repaired.close()

check("it adds exactly the missing column", "is_free_period" in repaired_cols, str(repaired_cols))
check(
    "--schema-only imports no reference data",
    counts_after == (0, 0, 0),
    f"subjects/faculty/labs = {counts_after}",
)
check(
    "--schema-only corrects no faculty cell",
    all(row[0] == "DPK" for row in saturday_ccc)
    and all(row[0] == "RVS (CC1)" for row in fpl_cells),
    f"{saturday_ccc} {fpl_cells}",
)
check(
    "--schema-only changes no break/free-period flag",
    all(is_break == 1 and free == 0 for is_break, free in relm_flags),
    str(relm_flags),
)

reader = parts_session(unmigrated_db)
recovered = main._student_timetable_entries(
    reader,
    reader.query(models.Student)
    .filter(models.Student.roll_number == "8899")
    .first(),
)
check(
    "the timetable can be read again after the additive step",
    len(recovered) > 0,
    str(len(recovered)),
)
check(
    "and no free period reaches the student, even though its stored flag is still the break reading",
    not [
        entry
        for entry in recovered
        if official_data.is_free_period_slot(
            entry.day, entry.start_time, entry.end_time
        )
    ],
    str(
        [
            (entry.day, entry.start_time, entry.subject)
            for entry in recovered
            if official_data.is_free_period_slot(
                entry.day, entry.start_time, entry.end_time
            )
        ]
    ),
)
check(
    "no free period is ever labelled a lecture to a student",
    all(
        entry.entry_type != "lecture"
        for entry in recovered
        if official_data.is_free_period_slot(
            entry.day, entry.start_time, entry.end_time
        )
    ),
    str([(entry.day, entry.start_time, entry.entry_type) for entry in recovered]),
)

# --------------------------------------------------------------------------
# The second half of the production sequence: `seed_official_data.py --apply`.
# Step (a) ran above and touched no data; this step has to correct the timetable
# and load the reference tables while leaving every user row byte-for-byte alone.
# --------------------------------------------------------------------------
USER_TABLES = (
    "students",
    "teachers",
    "teacher_assignments",
    "assignments",
    "attendance_records",
    "free_period_claims",
)


def user_snapshot(path):
    """Every user-owned row, compared but never printed (hashes, tokens)."""
    con = sqlite3.connect(path)
    try:
        return {
            table: con.execute(f"SELECT * FROM {table} ORDER BY id").fetchall()
            for table in USER_TABLES
        }
    finally:
        con.close()


def free_period_slots(path, day_date):
    """The free periods the API reports for that date, as plain tuples."""
    session = parts_session(path)
    teacher = (
        session.query(models.Teacher)
        .filter(models.Teacher.email == "unmigrated.teacher@example.com")
        .first()
    )
    availability = main._free_period_availability(session, teacher, day_date)
    return [
        (slot.start_time, slot.end_time, slot.batch, slot.reason, slot.eligible)
        for slot in availability.slots
        if slot.is_free_period
    ]


before_apply = user_snapshot(unmigrated_db)
check(
    "the throwaway copy holds user data in every table step (b) must preserve",
    all(before_apply[table] for table in USER_TABLES),
    str({table: len(before_apply[table]) for table in USER_TABLES}),
)

tuesday_after_schema_only = free_period_slots(unmigrated_db, tuesday)
check(
    "step (a) alone already reports the official free periods as free periods",
    len(tuesday_after_schema_only) == 2
    and all(
        row[2] == "" and "Class scheduled" not in (row[3] or "")
        for row in tuesday_after_schema_only
    ),
    str(tuesday_after_schema_only),
)

with contextlib.redirect_stdout(io.StringIO()):
    apply_rc = seed_official_data.main(
        ["--db", str(unmigrated_db), "--apply", "--no-backup"]
    )
check("step (b) succeeds on the same copy", apply_rc == 0, str(apply_rc))

applied = sqlite3.connect(unmigrated_db)
counts_final = (
    applied.execute("SELECT COUNT(*) FROM subjects").fetchone()[0],
    applied.execute("SELECT COUNT(*) FROM faculty_directory").fetchone()[0],
    applied.execute("SELECT COUNT(*) FROM lab_directory").fetchone()[0],
)
saturday_ccc_final = applied.execute(
    "SELECT faculty FROM timetable_entries WHERE day = 'Saturday' AND subject = 'CCC-1'"
).fetchall()
fpl_final = applied.execute(
    "SELECT faculty FROM timetable_entries "
    "WHERE subject = 'FPL' AND day IN ('Wednesday', 'Friday')"
).fetchall()
relm_final = applied.execute(
    "SELECT id, is_break, is_free_period FROM timetable_entries "
    "WHERE subject = 'RELM' ORDER BY id"
).fetchall()
applied.close()
after_apply = user_snapshot(unmigrated_db)

check(
    "step (b) loads the official reference tables (13 / 8 / 1)",
    counts_final == (13, 8, 1),
    str(counts_final),
)
check(
    "step (b) applies the Saturday CCC-1 faculty correction",
    bool(saturday_ccc_final) and all(row[0] == "HBW" for row in saturday_ccc_final),
    str(saturday_ccc_final),
)
check(
    "step (b) applies the RVS (CC1) -> RVS (CCI) correction",
    bool(fpl_final) and all(row[0] == "RVS (CCI)" for row in fpl_final),
    str(fpl_final),
)
check(
    "step (b) stores the five free periods as free periods (break 0, flag 1)",
    len(relm_final) == len(official_data.FREE_PERIOD_SLOTS)
    and all(is_break == 0 and free == 1 for _, is_break, free in relm_final),
    str(relm_final),
)
check(
    "step (b) preserves every student/teacher/session/assignment/attendance/claim row",
    all(before_apply[table] == after_apply[table] for table in USER_TABLES),
    str(
        [
            table
            for table in USER_TABLES
            if before_apply[table] != after_apply[table]
        ]
    ),
)

final_session = parts_session(unmigrated_db)
final_entries = main._student_timetable_entries(
    final_session,
    final_session.query(models.Student)
    .filter(models.Student.roll_number == "8899")
    .first(),
)
check(
    "the corrected timetable holds the same periods as before the correction",
    len(final_entries) == len(recovered),
    f"{len(recovered)} -> {len(final_entries)}",
)
check(
    "and no free period reaches the student afterwards either",
    not [
        entry
        for entry in final_entries
        if official_data.is_free_period_slot(
            entry.day, entry.start_time, entry.end_time
        )
    ],
    str([(entry.day, entry.start_time) for entry in final_entries]),
)

tuesday_after_apply = free_period_slots(unmigrated_db, tuesday)
check(
    "step (b) does not change which free periods the teacher is offered",
    tuesday_after_apply == tuesday_after_schema_only,
    f"{tuesday_after_schema_only} -> {tuesday_after_apply}",
)

# Idempotency: running the data step a second time must be a no-op.
before_second_apply = hashlib.sha256(unmigrated_db.read_bytes()).hexdigest()
with contextlib.redirect_stdout(io.StringIO()):
    second_rc = seed_official_data.main(
        ["--db", str(unmigrated_db), "--apply", "--no-backup"]
    )
check("a second data step still succeeds", second_rc == 0, str(second_rc))
check(
    "a second data step changes not one byte of the database",
    before_second_apply == hashlib.sha256(unmigrated_db.read_bytes()).hexdigest(),
)
check(
    "and leaves the user data untouched as well",
    user_snapshot(unmigrated_db) == after_apply,
)

shutil.rmtree(unmigrated_dir, ignore_errors=True)

real_stamp_end = (
    (REAL_DB.stat().st_size, REAL_DB.stat().st_mtime_ns) if REAL_DB.exists() else None
)
check(
    "the real database is still untouched after every step of this suite",
    real_stamp_end == REAL_DB_STAMP,
    f"before={REAL_DB_STAMP} after={real_stamp_end}",
)

print("\n" + "=" * 72)
print(f"teacher feature tests: {len(PASSED)} passed, {len(FAILED)} failed")
for failure in FAILED:
    print(f"  FAILED: {failure}")
print("=" * 72)
sys.exit(1 if FAILED else 0)
