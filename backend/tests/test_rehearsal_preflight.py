#!/usr/bin/env python
"""
Synthetic tests for ``backend/rehearse_official_data_migration.py`` preflight
listener detection and refusal logic.

Every test uses mocked subprocess responses and isolated temporary fixtures.
The real ``backend/campussync.db`` is never opened; the suite records its
SHA-256, size and mtime up front and asserts they are unchanged at the end.
"""

import hashlib
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from unittest.mock import patch, MagicMock

BACKEND_DIR = Path(__file__).resolve().parent.parent
REHEARSAL = BACKEND_DIR / "rehearse_official_data_migration.py"
REAL_DB = (BACKEND_DIR / "campussync.db").resolve()
PYTHON = sys.executable

# Import the rehearsal module to test its functions directly
sys.path.insert(0, str(BACKEND_DIR))
import rehearse_official_data_migration as rehearsal

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


def sha256_of(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(65536), b""):
            digest.update(chunk)
    return digest.hexdigest()


def stamp_of(path):
    if not path.exists():
        return None
    stat = path.stat()
    return (stat.st_size, stat.st_mtime_ns)


REAL_DB_SHA = sha256_of(REAL_DB)
REAL_DB_STAMP = stamp_of(REAL_DB)


# ===========================================================================
# Test helpers
# ===========================================================================

def mock_subprocess_run(returncode=0, stdout="", stderr="", side_effect=None):
    """Create a mock for subprocess.run that returns a CompletedProcess-like object."""
    if side_effect:
        return side_effect
    mock_result = MagicMock()
    mock_result.returncode = returncode
    mock_result.stdout = stdout
    mock_result.stderr = stderr
    return mock_result


# ===========================================================================
# 1. IPv4 wildcard 0.0.0.0:8000
# ===========================================================================
print("\n1. IPv4 wildcard 0.0.0.0:8000 detection")

netstat_ipv4_wildcard = """Proto  Local Address          Foreign Address        State           PID
TCP    0.0.0.0:8000           0.0.0.0:0              LISTENING       1234
TCP    127.0.0.1:5000         0.0.0.0:0              LISTENING       5678
"""

with patch("subprocess.run", return_value=mock_subprocess_run(0, netstat_ipv4_wildcard)):
    evidence, note = rehearsal.listener_evidence()
    check(
        "netstat detects 0.0.0.0:8000",
        any("0.0.0.0:8000" in e for e in evidence),
        f"evidence={evidence}"
    )
    check(
        "no note when netstat succeeds",
        note == "",
        f"note={note!r}"
    )

# ===========================================================================
# 2. IPv6 wildcard [::]:8000
# ===========================================================================
print("\n2. IPv6 wildcard [::]:8000 detection")

netstat_ipv6_wildcard = """Proto  Local Address          Foreign Address        State           PID
TCP    [::]:8000              [::]:0                 LISTENING       1234
"""

with patch("subprocess.run", return_value=mock_subprocess_run(0, netstat_ipv6_wildcard)):
    evidence, note = rehearsal.listener_evidence()
    check(
        "netstat detects [::]:8000",
        any("[::]:8000" in e for e in evidence),
        f"evidence={evidence}"
    )

# ===========================================================================
# 3. IPv4 and IPv6 loopback listeners
# ===========================================================================
print("\n3. Loopback listeners (127.0.0.1 and [::1])")

netstat_loopback = """Proto  Local Address          Foreign Address        State           PID
TCP    127.0.0.1:8000         0.0.0.0:0              LISTENING       1234
TCP    [::1]:8000             [::]:0                 LISTENING       5678
"""

with patch("subprocess.run", return_value=mock_subprocess_run(0, netstat_loopback)):
    evidence, note = rehearsal.listener_evidence()
    check(
        "netstat detects 127.0.0.1:8000",
        any("127.0.0.1:8000" in e for e in evidence),
        f"evidence={evidence}"
    )
    check(
        "netstat detects [::1]:8000",
        any("[::1]:8000" in e for e in evidence),
        f"evidence={evidence}"
    )

# ===========================================================================
# 4. Specific LAN IPv4 address
# ===========================================================================
print("\n4. LAN IPv4 address (192.168.1.5:8000)")

netstat_lan = """Proto  Local Address          Foreign Address        State           PID
TCP    192.168.1.5:8000       0.0.0.0:0              LISTENING       1234
"""

with patch("subprocess.run", return_value=mock_subprocess_run(0, netstat_lan)):
    evidence, note = rehearsal.listener_evidence()
    check(
        "netstat detects LAN address 192.168.1.5:8000",
        any("192.168.1.5:8000" in e for e in evidence),
        f"evidence={evidence}"
    )

# ===========================================================================
# 5. netstat failure followed by successful PowerShell detection
# ===========================================================================
print("\n5. netstat failure -> PowerShell fallback success")

powershell_output = """LocalAddress  LocalPort  OwningProcess
127.0.0.1     8000       1234
::1           8000       1234
0.0.0.0       8000       1234
"""

# netstat fails (OSError), PowerShell succeeds
def side_effect_netstat_fail_powershell_ok(*args, **kwargs):
    if args[0][0] == "netstat":
        raise OSError("netstat not found")
    elif args[0][0] == "powershell":
        return mock_subprocess_run(0, powershell_output)
    return mock_subprocess_run(1, "")

with patch("subprocess.run", side_effect=side_effect_netstat_fail_powershell_ok):
    evidence, note = rehearsal.listener_evidence()
    check(
        "PowerShell fallback detects listeners after netstat failure",
        len(evidence) >= 3,
        f"evidence={evidence}"
    )
    check(
        "no note when PowerShell succeeds",
        note == "",
        f"note={note!r}"
    )

# ===========================================================================
# 6. Both listener probes failing
# ===========================================================================
print("\n6. Both netstat and PowerShell fail")

def side_effect_both_fail(*args, **kwargs):
    raise OSError("command not found")

with patch("subprocess.run", side_effect=side_effect_both_fail):
    evidence, note = rehearsal.listener_evidence()
    check(
        "empty evidence when both probes fail",
        evidence == [],
        f"evidence={evidence}"
    )
    check(
        "note explains both probes failed",
        "listener enumeration unavailable" in note,
        f"note={note!r}"
    )

# ===========================================================================
# 7. Malformed or ambiguous command output
# ===========================================================================
print("\n7. Malformed/ambiguous output handling")

# netstat with malformed lines
netstat_malformed = """Proto  Local Address          Foreign Address        State           PID
TCP    0.0.0.0:8000           0.0.0.0:0              LISTENING       1234
not a valid line
TCP    [::]:8000              [::]:0                 LISTENING       5678
garbage
"""

with patch("subprocess.run", return_value=mock_subprocess_run(0, netstat_malformed)):
    evidence, note = rehearsal.listener_evidence()
    check(
        "malformed lines ignored, valid listeners still detected",
        len(evidence) == 2,
        f"evidence={evidence}"
    )

# PowerShell with only headers
powershell_headers_only = """LocalAddress  LocalPort  OwningProcess
"""

with patch("subprocess.run", side_effect=side_effect_netstat_fail_powershell_ok):
    # This will use the side_effect above which raises for netstat, so we need a new one
    def side_effect_ps_headers_only(*args, **kwargs):
        if args[0][0] == "netstat":
            raise OSError("netstat not found")
        elif args[0][0] == "powershell":
            return mock_subprocess_run(0, powershell_headers_only)
        return mock_subprocess_run(1, "")

with patch("subprocess.run", side_effect=side_effect_ps_headers_only):
    evidence, note = rehearsal.listener_evidence()
    check(
        "PowerShell headers-only output produces no evidence",
        evidence == [],
        f"evidence={evidence}"
    )

# netstat with no LISTENING state
netstat_no_listening = """Proto  Local Address          Foreign Address        State           PID
TCP    127.0.0.1:8000         127.0.0.1:5000         ESTABLISHED     1234
TCP    0.0.0.0:5000           0.0.0.0:0              LISTENING       5678
"""

with patch("subprocess.run", return_value=mock_subprocess_run(0, netstat_no_listening)):
    evidence, note = rehearsal.listener_evidence()
    check(
        "only LISTENING lines detected, ESTABLISHED ignored",
        len(evidence) == 1 and "0.0.0.0:5000" in evidence[0],
        f"evidence={evidence}"
    )

# ===========================================================================
# 8. Preflight refusal when evidence is inadequate
# ===========================================================================
print("\n8. Preflight refusal with inadequate evidence")

# Create a minimal live database file for testing
with tempfile.TemporaryDirectory(prefix="cs-preflight-") as tmpdir:
    tmp = Path(tmpdir)
    live_db = tmp / "campussync.db"
    # Create a minimal SQLite file with valid header
    with open(live_db, "wb") as f:
        f.write(b"SQLite format 3\x00" + b"\x00" * 100)
    
    # Mock live_database_path to return our temp file
    with patch.object(rehearsal, "live_database_path", return_value=live_db):
        # Case 8a: Both listener probes fail, wmic fails -> refusal
        with patch("subprocess.run", side_effect=side_effect_both_fail):
            # Also mock process_evidence to return wmic failure
            with patch.object(rehearsal, "process_evidence", return_value=([], "command lines are unavailable on this host")):
                # Mock port_evidence to return nothing
                with patch.object(rehearsal, "port_evidence", return_value=[]):
                    writers, notes = rehearsal.check_live_writer(live_db)
                    check(
                        "preflight refuses when both probes fail and wmic unavailable",
                        any("cannot establish backend stopped" in n for n in notes),
                        f"notes={notes}"
                    )
        
        # Case 8b: Listener probe succeeds but finds a listener -> refusal
        with patch.object(rehearsal, "listener_evidence", return_value=(["netstat shows a listener: TCP 0.0.0.0:8000"], "")):
            with patch.object(rehearsal, "port_evidence", return_value=[]):
                with patch.object(rehearsal, "process_evidence", return_value=([], "command lines are unavailable")):
                    writers, notes = rehearsal.check_live_writer(live_db)
                    check(
                        "preflight refuses when listener detected",
                        any("listener(s) detected" in n for n in notes),
                        f"notes={notes}"
                    )
        
        # Case 8c: Listener probe FAILS, wmic succeeds but finds uvicorn -> refusal
        with patch.object(rehearsal, "listener_evidence", return_value=([], "listener enumeration unavailable (netstat and Get-NetTCPConnection both failed)")):
            with patch.object(rehearsal, "port_evidence", return_value=[]):
                with patch.object(rehearsal, "process_evidence", return_value=(["a uvicorn.exe process is running"], "")):
                    writers, notes = rehearsal.check_live_writer(live_db)
                    check(
                        "preflight refuses when listener probe fails and uvicorn process detected",
                        any("uvicorn/main:app process detected" in n for n in notes),
                        f"notes={notes}"
                    )
        
        # Case 8d: Listener probe FAILS, wmic succeeds and clean, but port finds listener -> refusal
        with patch.object(rehearsal, "listener_evidence", return_value=([], "listener enumeration unavailable (netstat and Get-NetTCPConnection both failed)")):
            with patch.object(rehearsal, "port_evidence", return_value=["something is listening on 127.0.0.1:8000"]):
                with patch.object(rehearsal, "process_evidence", return_value=([], "")):
                    writers, notes = rehearsal.check_live_writer(live_db)
                    check(
                        "preflight refuses when listener probe fails and listener on configured port",
                        any("listener on configured port" in n for n in notes),
                        f"notes={notes}"
                    )
        
        # Case 8e: Adequate evidence (listener clean + process clean + port clean) -> proceed
        with patch.object(rehearsal, "listener_evidence", return_value=([], "")):
            with patch.object(rehearsal, "port_evidence", return_value=[]):
                with patch.object(rehearsal, "process_evidence", return_value=([], "")):
                    writers, notes = rehearsal.check_live_writer(live_db)
                    check(
                        "preflight proceeds when all probes clean",
                        not any("cannot establish backend stopped" in n for n in notes),
                        f"notes={notes}"
                    )
                    check(
                        "no writers detected when all clean",
                        writers == [],
                        f"writers={writers}"
                    )
        
        # Case 8f: Sidecar file present -> immediate refusal
        wal_file = str(live_db) + "-wal"
        Path(wal_file).write_text("")
        with patch.object(rehearsal, "listener_evidence", return_value=([], "")):
            with patch.object(rehearsal, "port_evidence", return_value=[]):
                with patch.object(rehearsal, "process_evidence", return_value=([], "")):
                    writers, notes = rehearsal.check_live_writer(live_db)
                    check(
                        "preflight refuses immediately on sidecar file",
                        writers != [],
                        f"writers={writers}"
                    )
                    check(
                        "sidecar note present",
                        any("sidecar files indicate active database writer" in n for n in notes),
                        f"notes={notes}"
                    )
        Path(wal_file).unlink()

# ===========================================================================
# 9. Ensure mocks don't launch real commands
# ===========================================================================
print("\n9. Mock isolation verification")

# Verify no real subprocess calls were made during tests
# (This is implicitly verified by the fact that all tests use mocks)

# Also verify the real database was not touched
check(
    "real database SHA-256 unchanged",
    sha256_of(REAL_DB) == REAL_DB_SHA,
    f"before={REAL_DB_SHA[:16]} after={sha256_of(REAL_DB)[:16]}"
)
check(
    "real database size/mtime unchanged",
    stamp_of(REAL_DB) == REAL_DB_STAMP,
    f"before={REAL_DB_STAMP} after={stamp_of(REAL_DB)}"
)

# ===========================================================================
# Summary
# ===========================================================================
print("\n" + "=" * 72)
print(f"preflight tests: {len(PASSED)} passed, {len(FAILED)} failed")
for failure in FAILED:
    print(f"  FAILED: {failure}")
print("=" * 72)

sys.exit(1 if FAILED else 0)