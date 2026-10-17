import sqlite3

conn = sqlite3.connect(r'C:\Users\amved\Documents\campus_sync\backend\campussync.db')
cursor = conn.cursor()

# Check which additive columns are missing
cursor.execute('PRAGMA table_info(timetable_entries)')
print('timetable_entries columns:')
for row in cursor.fetchall():
    print(f'  {row[1]}')

cursor.execute('PRAGMA table_info(teachers)')
print('\nteachers columns:')
for row in cursor.fetchall():
    print(f'  {row[1]}')

cursor.execute('PRAGMA table_info(assignments)')
print('\nassignments columns:')
for row in cursor.fetchall():
    print(f'  {row[1]}')

cursor.execute('PRAGMA table_info(attendance_records)')
print('\nattendance_records columns:')
for row in cursor.fetchall():
    print(f'  {row[1]}')

conn.close()