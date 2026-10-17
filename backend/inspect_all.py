import sqlite3
import os
from datetime import datetime

def inspect_db(path, label):
    if not os.path.exists(path):
        print(f"{label}: NOT FOUND at {path}")
        return
    stat = os.stat(path)
    print(f"\n=== {label} ===")
    print(f"  Path: {path}")
    print(f"  Size: {stat.st_size} bytes")
    print(f"  Modified: {datetime.fromtimestamp(stat.st_mtime)}")
    
    conn = sqlite3.connect(path)
    cursor = conn.cursor()
    
    # Integrity
    cursor.execute("PRAGMA integrity_check;")
    integrity = cursor.fetchone()[0]
    print(f"  Integrity: {integrity}")
    
    # Table counts
    tables_to_check = [
        'students', 'teachers', 'timetable_entries', 
        'assignments', 'attendance_records', 
        'free_period_claims', 'teacher_assignments',
        'subjects', 'faculty_directory', 'lab_directory'
    ]
    
    for table in tables_to_check:
        try:
            cursor.execute(f"SELECT COUNT(*) FROM {table}")
            count = cursor.fetchone()[0]
            print(f"  {table}: {count}")
        except Exception as e:
            print(f"  {table}: ERROR - {e}")
    
    # Detailed timetable breakdown
    print("\n  Timetable breakdown:")
    cursor.execute("""
        SELECT subject, COUNT(*) as cnt, 
               MIN(CASE WHEN is_break THEN 1 ELSE 0 END) as has_break,
               MIN(CASE WHEN is_free_period THEN 1 ELSE 0 END) as has_free_period
        FROM timetable_entries 
        GROUP BY subject
        ORDER BY cnt DESC
    """)
    for row in cursor.fetchall():
        print(f"  {row[0]}: {row[1]} entries (break={row[2]}, free_period={row[3]})")
    
    # RELM details
    print("\nRELM entries:")
    cursor.execute("""
        SELECT id, day, start_time, end_time, subject, faculty, batch, is_break, is_free_period
        FROM timetable_entries WHERE subject = 'RELM'
    """)
    for row in cursor.fetchall():
        print(f"  id={row[0]} {row[1]} {row[2]}-{row[3]} sub={row[4]} fac={row[5]} batch={row[6]} break={row[7]} free={row[8]}")
    
    # CCC-1
    cursor.execute("""
        SELECT id, day, start_time, end_time, subject, faculty, batch, is_break
        FROM timetable_entries WHERE subject = 'CCC-1'
    """)
    print("\nCCC-1 entries:")
    for row in cursor.fetchall():
        print(f"  id={row[0]} {row[1]} {row[2]}-{row[3]} sub={row[4]} fac={row[5]} batch={row[6]} break={row[7]}")
    
    # FPL with RVS
    cursor.execute("""
        SELECT id, day, start_time, end_time, subject, faculty, batch 
        FROM timetable_entries WHERE subject = 'FPL' AND faculty LIKE 'RVS%'
    """)
    print("\nFPL with RVS faculty:")
    for row in cursor.fetchall():
        print(f"  id={row[0]} {row[1]} {row[2]}-{row[3]} sub={row[3]} fac={row[4]} batch={row[5]}")
    
    conn.close()
    print()

# Inspect all relevant databases
dbs = [
    (r"C:\Users\amved\Documents\campus_sync\backend\campussync.db", "LIVE DB"),
    (r"C:\Users\amved\Documents\campus_sync_backup\backend\campussync.db.backup_20261011_112224", "BACKUP 20261011_112224"),
    (r"C:\Users\amved\Documents\campus_sync_backup\backend\campussync.db.backup_20261011_112154", "BACKUP 20261011_112154"),
    (r"C:\Users\amved\Documents\campus_sync_backup\backend\campussync.db.backup_20261010_2344", "BACKUP 20261010_2344"),
    (r"C:\Users\amved\Documents\campus_sync_backup\backend\campussync.db.backup_20261011_112224", "BACKUP 20261011_112224"),
    (r"C:\Users\amved\Documents\campus_sync_backup\backend\campussync.db.backup_20261011_112154", "BACKUP 20261011_112154"),
]

for path, label in dbs:
    inspect_db(path, label)