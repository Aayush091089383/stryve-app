"""
Official CampusSync reference data - the ONE place it is written down.

SOURCE OF TRUTH
---------------
"Time Table of FE for Academic Year 2026-27, First Term (Semester - I),
Division: D, Revision: 4, w.e.f. 10/12/2026", Class Room: M308 (Block-11),
Class Coordinator: Mrs. S. M. Gangurde (SMG), supplied by the department.

EVERYTHING HERE WAS READ OFF THAT DOCUMENT. Nothing is invented: where the
document does not state something (full faculty names, e-mail addresses, office
numbers, laboratory room numbers, what the parenthesised suffix on a faculty
cell denotes), the value is left empty and listed in :data:`UNCONFIRMED` so the
UI can say "not available" instead of showing a plausible-looking guess.

Values the department has since confirmed are listed in :data:`CONFIRMED` and
must not be "corrected" back to an older reading.

Consumers
---------
* ``seed_official_data.py`` aligns ``timetable_entries`` with the grid below and
  fills ``subjects`` / ``faculty_directory`` / ``lab_directory``.
* ``main.py`` uses :data:`TIME_SLOTS` to know which periods exist, so "free
  period" and attendance slot validation never has to guess a grid, and
  :data:`FREE_PERIOD_SLOTS` to recognise the periods that are free for every
  class group (shown to teachers as claimable, never shown to students).
"""

from __future__ import annotations

# --------------------------------------------------------------------------
# Timetable identity (printed on the sheet)
# --------------------------------------------------------------------------
ACADEMIC_YEAR = "2026-27"
TERM = "First Term (Semester - I)"
REVISION = "4"
EFFECTIVE_FROM = "10/12/2026"  # exactly as printed (dd/mm/yyyy as used on the sheet)
DIVISION = "D"
CLASS_ROOM = "M308"
CLASS_BLOCK = "Block-11"
CLASS_COORDINATOR = "Mrs. S. M. Gangurde"
CLASS_COORDINATOR_CODE = "SMG"

DAYS = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]

# Period grid in 24h "HH:MM". Breaks are listed separately so a slot lookup can
# never mistake a break for a teachable period. Source: the sheet's Timing column
# (10.15-11.15, 11.15-12.15, LUNCH 12.15-01.00, 01.00-02.00, 02.00-03.00,
# SHORT BREAK 03.00-03.15, 03.15-04.15, 04.15-05.15).
TIME_SLOTS = [
    ("10:15", "11:15"),
    ("11:15", "12:15"),
    ("13:00", "14:00"),
    ("14:00", "15:00"),
    ("15:15", "16:15"),
    ("16:15", "17:15"),
]

BREAKS = [
    ("12:15", "13:00", "LUNCH BREAK"),
    ("15:00", "15:15", "SHORT BREAK"),
]

# Sessions that deliberately span more than one printed period.
#
# The corrected sheet runs these practicals across two periods (and Monday's
# D-3 practical starts at 15:35), so a teacher marks one SESSION rather than two
# halves. They are ordinary classes: not free periods, and NOT part of the
# six-period grid above - free-period availability keeps iterating TIME_SLOTS,
# so a block here can never be offered as a claimable free period.
LAB_BLOCKS = [
    ("10:15", "12:15"),
    ("13:00", "15:00"),
    ("15:35", "17:15"),
]

# Every (start, end) a lecture/attendance session may legitimately use.
SESSION_BLOCKS = TIME_SLOTS + [block for block in LAB_BLOCKS if block not in TIME_SLOTS]

BATCHES = ["D-1", "D-2", "D-3"]

# --------------------------------------------------------------------------
# Subject table (verbatim from the sheet's "Subject Name / Short / Code /
# Faculty / Remark" block)
# --------------------------------------------------------------------------
# (name, short, code, faculty_code, kind)
SUBJECTS = [
    ("Engineering Mathematics-I", "EMI", "BSC-101", "SMG", "theory"),
    ("Engineering Physics", "PHY", "BSC-102", "SPG", "theory"),
    ("Basic Electrical Engineering", "BEE", "ESC-102", "HBW", "theory"),
    ("Engineering Graphics", "EG", "ESC-103", "VTM", "theory"),
    ("Fundamentals of Programming Languages", "FPL", "ESC-105", "RVS", "theory"),
    ("Design Thinking & Idea Lab (Practical)", "DTL", "VSE-102", "SPG/RST", "practical"),
    ("Professional Communication Skills (Tutorial)", "PCS", "AEC-101", "SPK", "tutorial"),
    ("Engineering Mathematics-I (Tutorial)", "EMI", "BSC-101", "SMG", "tutorial"),
    ("Engineering Physics (Practical)", "PHY", "BSC-102", "SPG", "practical"),
    ("Basic Electrical Engineering (Practical)", "BEE", "ESC-102", "HBW", "practical"),
    ("Engineering Graphics (Practical)", "EG", "ESC-103", "VTM", "practical"),
    (
        "Fundamentals of Programming Languages (Practical)",
        "FPL",
        "ESC-105",
        "RVS",
        "practical",
    ),
    ("Co-Curricular Course-I (Practical)", "CCCI", "CCI-101", "HBW", "practical"),
]

# --------------------------------------------------------------------------
# Faculty directory - ONLY what the sheet states.
# --------------------------------------------------------------------------
# The sheet gives faculty INITIALS plus one full name (the class coordinator,
# whose initials appear in brackets). Full names, e-mail addresses, departments,
# offices and phone numbers for the remaining codes are NOT in the document, so
# they stay None. The finder must show "Not available" for them.
FACULTY = [
    {
        "short_code": "SMG",
        "full_name": "Mrs. S. M. Gangurde",
        "role_note": "Class Coordinator (Division D)",
        "verified": True,
    },
    {"short_code": "SPG", "full_name": None, "role_note": None, "verified": False},
    {"short_code": "HBW", "full_name": None, "role_note": None, "verified": False},
    {"short_code": "VTM", "full_name": None, "role_note": None, "verified": False},
    {"short_code": "RVS", "full_name": None, "role_note": None, "verified": False},
    {"short_code": "RST", "full_name": None, "role_note": None, "verified": False},
    {"short_code": "SPK", "full_name": None, "role_note": None, "verified": False},
    {"short_code": "TAS", "full_name": None, "role_note": None, "verified": False},
]

# --------------------------------------------------------------------------
# Laboratory / room directory.
# --------------------------------------------------------------------------
# The sheet names exactly ONE room: the division's own classroom. It gives no
# laboratory numbers, buildings or floors, so those entries do not exist here.
ROOMS = [
    {
        "name": "Division D Classroom",
        "code": "M308",
        "room": "M308",
        "building": "Block-11",
        "floor": None,
        "subject": None,
        "kind": "classroom",
    }
]

# --------------------------------------------------------------------------
# The grid itself.
# --------------------------------------------------------------------------
# (day, start, end, subject, faculty, batch_or_None)
#
# batch=None  -> common lecture for the whole division (D-1, D-2 and D-3)
# batch="D-n" -> that batch's practical/tutorial; students of other batches must
#                never see it.
# is_break entries are added from BREAKS.
TIMETABLE = [
    # ---- Monday
    ("Monday", "10:15", "11:15", "FPL", "RVS", None),
    ("Monday", "11:15", "12:15", "PHY", "SPG", None),
    ("Monday", "13:00", "14:00", "M-1", "SMG", None),
    ("Monday", "14:00", "15:00", "BEE", "HBW", None),
    ("Monday", "15:15", "16:15", "PHY", "SPG", "D-1"),
    ("Monday", "15:15", "16:15", "BEE", "HBW", "D-2"),
    # The D-3 practical starts at 15:35 and runs to the end of the day, not at
    # the 16:15 period boundary (see CONFIRMED).
    ("Monday", "15:35", "17:15", "EG", "VTM", "D-3"),
    # ---- Tuesday
    ("Tuesday", "10:15", "11:15", "PHY", "SPG", "D-2"),
    # D-3's BEE practical runs across both morning periods, to 12:15.
    ("Tuesday", "10:15", "12:15", "BEE", "HBW", "D-3"),
    ("Tuesday", "11:15", "12:15", "EG", "VTM", "D-1"),
    ("Tuesday", "13:00", "14:00", "BEE", "HBW", None),
    ("Tuesday", "14:00", "15:00", "M-1", "SMG", None),
    ("Tuesday", "15:15", "16:15", "RELM", "", None),
    ("Tuesday", "16:15", "17:15", "RELM", "", None),
    # ---- Wednesday
    ("Wednesday", "10:15", "11:15", "EG", "VTM", None),
    ("Wednesday", "11:15", "12:15", "M-1", "SMG", None),
    ("Wednesday", "13:00", "14:00", "DTIL", "RST", "D-2"),
    # D-3's FPL practical runs 13:00-15:00.
    ("Wednesday", "13:00", "15:00", "FPL", "RVS (CCI)", "D-3"),
    ("Wednesday", "14:00", "15:00", "LIB", "TAS", "D-1"),
    ("Wednesday", "15:15", "16:15", "CCC-1", "HBW", None),
    ("Wednesday", "16:15", "17:15", "CCC-1", "HBW", None),
    # ---- Thursday
    ("Thursday", "10:15", "11:15", "RELM", "", None),
    ("Thursday", "11:15", "12:15", "M-1", "SMG / TUT", None),
    ("Thursday", "13:00", "14:00", "FPL", "RVS", None),
    ("Thursday", "14:00", "15:00", "PHY", "SPG", None),
    ("Thursday", "15:15", "16:15", "PCS", "SPK", None),
    ("Thursday", "16:15", "17:15", "PCS", "SPK", None),
    # ---- Friday
    ("Friday", "10:15", "11:15", "PHY", "SPG", None),
    ("Friday", "11:15", "12:15", "EG", "VTM", None),
    # D-3's PHY practical runs 13:00-15:00.
    ("Friday", "13:00", "15:00", "PHY", "SPG", "D-3"),
    ("Friday", "13:00", "14:00", "BEE", "HBW", "D-1"),
    ("Friday", "14:00", "15:00", "EG", "VTM", "D-2"),
    ("Friday", "15:15", "16:15", "DTIL", "SPG", "D-1"),
    ("Friday", "15:15", "16:15", "FPL", "RVS (CCI)", "D-2"),
    ("Friday", "16:15", "17:15", "LIB", "TAS", "D-3"),
    # ---- Saturday
    # D-3's DTIL practical runs across both morning periods, to 12:15.
    ("Saturday", "10:15", "12:15", "DTIL", "RST", "D-3"),
    ("Saturday", "10:15", "11:15", "FPL", "RVS (CCI)", "D-1"),
    ("Saturday", "11:15", "12:15", "LIB", "TAS", "D-2"),
    ("Saturday", "13:00", "14:00", "CCC-1", "HBW", None),
    ("Saturday", "14:00", "15:00", "CCC-1", "HBW", None),
    ("Saturday", "15:15", "16:15", "RELM", "", None),
    ("Saturday", "16:15", "17:15", "RELM", "", None),
]

# --------------------------------------------------------------------------
# Free periods (the sheet prints "RELM")
# --------------------------------------------------------------------------
# CONFIRMED by the department: RELM means a FREE PERIOD - a slot no class group
# is scheduled in, which a teacher may claim in the app. It is NOT a lecture and
# NOT an ordinary break, so it is stored as its own kind of row (see
# ``models.TimetableEntry.is_free_period``):
#   * the student timetable never returns it (a student has nothing to attend),
#   * the teacher's Claim Free Period screen offers it, unclaimed, to any teacher
#     whose account is verified against this timetable,
#   * it is never offered as a period in which a class is taught.
# The five cases below are exactly the ones printed on the sheet; the subject
# cell keeps the sheet's own label ("RELM") so the source stays traceable.
FREE_PERIOD_SUBJECT = "RELM"
FREE_PERIOD_SLOTS = [
    ("Tuesday", "15:15", "16:15"),
    ("Tuesday", "16:15", "17:15"),
    ("Thursday", "10:15", "11:15"),
    ("Saturday", "15:15", "16:15"),
    ("Saturday", "16:15", "17:15"),
]

# Kept under its old name as well: the five weekly "RELM" entries.
RELM_SLOTS = FREE_PERIOD_SLOTS

FREE_PERIOD_KEYS = frozenset(FREE_PERIOD_SLOTS)


def is_free_period_slot(day: str, start_time: str, end_time: str) -> bool:
    """True when this day/period is one of the sheet's free periods."""
    return ((day or "").strip(), start_time, end_time) in FREE_PERIOD_KEYS

# --------------------------------------------------------------------------
# Confirmed by the department (do NOT re-correct these to an older reading)
# --------------------------------------------------------------------------
# These were asked about explicitly, so they are written down here rather than
# left implicit in the grid above.
CONFIRMED = [
    "Saturday 13:00-14:00 is CCC-1 taught by HBW (subject stays 'CCC-1'; "
    "'HBW' is a faculty code, never a subject).",
    "Saturday 14:00-15:00 is CCC-1 taught by HBW (same rule).",
    "The FPL faculty cell is 'RVS (CCI)' with the LETTER I (not the digit 1) "
    "on Wednesday 13:00-14:00 (D-3) and Friday 15:15-16:15 (D-2).",
    "'RELM' means a FREE PERIOD that teachers may claim - not a lecture, not "
    "an ordinary break (see FREE_PERIOD_SLOTS).",
    "Monday has NO free period. Its batch practicals are D-1 Engineering "
    "Physics (SPG), D-2 Basic Electrical Engineering (HBW) and D-3 Engineering "
    "Graphics (VTM) - all three are ordinary batch practicals, never RELM.",
    "The five free periods are DIVISION-WIDE: one slot per period for the whole "
    "of Division D, never four separate Whole division / D-1 / D-2 / D-3 slots.",
    "Practical durations were corrected against the department's sheet: Friday "
    "D-3 PHY and Wednesday D-3 FPL run 13:00-15:00, Tuesday D-3 BEE and Saturday "
    "D-3 DTIL run 10:15-12:15, and Monday's D-3 EG practical runs 15:35-17:15.",
]

# --------------------------------------------------------------------------
# Things this file deliberately does NOT contain
# --------------------------------------------------------------------------
UNCONFIRMED = [
    "Full names for faculty codes SPG, HBW, VTM, RVS, RST, SPK and TAS "
    "(the sheet prints initials only).",
    "E-mail addresses, departments, offices and phone numbers for every "
    "faculty member (not present in the timetable).",
    "Who 'TAS' is and what the 'LIB' (library) slots require.",
    "Laboratory room numbers, blocks and floors for the practical/tutorial "
    "slots (the sheet only names classroom M308, Block-11).",
    "Which faculty run the shared 'DTL' practical marked 'SPG/RST'. The "
    "string 'RVS (CCI)' is confirmed verbatim; what the parenthesised '(CCI)' "
    "denotes is still not stated anywhere in the document.",
    "Whether D-1 and D-2 sit in the printed 03.15-04.15 Monday cell together "
    "with D-3. The D-3 practical's own time is now confirmed as 15:35-17:15 "
    "(see CONFIRMED); PHY (D-1) and BEE (D-2) stay at 15:15 until the sheet is "
    "read again.",
]


__all__ = [
    "ACADEMIC_YEAR",
    "TERM",
    "REVISION",
    "EFFECTIVE_FROM",
    "DIVISION",
    "CLASS_ROOM",
    "CLASS_BLOCK",
    "CLASS_COORDINATOR",
    "CLASS_COORDINATOR_CODE",
    "DAYS",
    "TIME_SLOTS",
    "LAB_BLOCKS",
    "SESSION_BLOCKS",
    "BREAKS",
    "BATCHES",
    "SUBJECTS",
    "FACULTY",
    "ROOMS",
    "TIMETABLE",
    "RELM_SLOTS",
    "FREE_PERIOD_SUBJECT",
    "FREE_PERIOD_SLOTS",
    "FREE_PERIOD_KEYS",
    "is_free_period_slot",
    "CONFIRMED",
    "UNCONFIRMED",
]
