import sqlite3

conn = sqlite3.connect(r'C:\Users\amved\Documents\campus_sync\backend\campussync.db')
cursor = conn.cursor()

# Check tables
cursor.execute('SELECT name FROM sqlite_master WHERE type="table"')
print('Tables:', cursor.fetchall())

# Check timetable_entries schema
cursor.execute('PRAGMA table_info(timetable_entries)')
print('\nTimetable entries schema:')
for row in cursor.fetchall():
    print(row)

# Check existing timetable entries (without is_free_period)
cursor.execute('SELECT day, start_time, end_time, subject, faculty, batch, is_break FROM timetable_entries')
print('\nAll timetable entries:')
for row in cursor.fetchall():
    print(row)

# Check for RELM entries specifically
cursor.execute('SELECT id, day, start_time, end_time, subject, faculty, batch, is_break FROM timetable_entries WHERE subject = "RELM"')
print('\nRELM entries:')
for row in cursor.fetchall():
    print(row)

# Check CCC-1 entries
cursor.execute('SELECT id, day, start_time, end_time, subject, faculty, batch FROM timetable_entries WHERE subject = "CCC-1"')
print('\nCCC-1 entries:')
for row in cursor.fetchall():
    print(row)

# Check FPL entries with RVS
cursor.execute('SELECT id, day, start_time, end_time, subject, faculty, batch FROM timetable_entries WHERE subject = "FPL" AND faculty LIKE "RVS%"')
print('\nFPL entries with RVS faculty:')
for row in cursor.fetchall():
    print(row)

# Check students
cursor.execute('SELECT id, name, email, roll_number, status FROM students')
print('\nStudents:')
for row in cursor.fetchall():
    print(row)

# Check teachers
cursor.execute('SELECT id, name, email, role, is_active FROM teachers')
print('\nTeachers:')
for row in cursor.fetchall():
    print(row)

conn.close()