// Timetable clock formatting.
//
// The API stores 24-hour "HH:mm" strings - the form the official sheet prints -
// and the app shows the civil 12-hour form. A value that is not a plain clock
// string must come back unchanged, so a malformed row can never render blank.
//
// Safety: pure unit test, no backend, no database.

import 'package:flutter_test/flutter_test.dart';

import 'package:campus_sync/timetable.dart';

void main() {
  group('formatClock', () {
    test('keeps the morning hours, adding AM', () {
      expect(formatClock('09:05'), '9:05 AM');
      expect(formatClock('10:15'), '10:15 AM');
      expect(formatClock('11:15'), '11:15 AM');
    });

    test('midnight and noon are 12, never 0', () {
      expect(formatClock('00:30'), '12:30 AM');
      expect(formatClock('12:15'), '12:15 PM');
    });

    test('converts the afternoon and evening hours to PM', () {
      expect(formatClock('13:00'), '1:00 PM');
      expect(formatClock('14:00'), '2:00 PM');
      expect(formatClock('16:15'), '4:15 PM');
      expect(formatClock('17:15'), '5:15 PM');
      expect(formatClock('23:59'), '11:59 PM');
    });

    test('anything that is not HH:mm is returned untouched', () {
      expect(formatClock(''), '');
      expect(formatClock('Lunch'), 'Lunch');
      expect(formatClock('10:15:00'), '10:15:00');
      expect(formatClock('24:00'), '24:00');
    });
  });

  test('an entry renders both ends in 12-hour form', () {
    const entry = TimetableEntry(
      day: 'Monday',
      startTime: '10:15',
      endTime: '11:15',
      subject: 'FPL',
    );

    expect(entry.time, '10:15 AM - 11:15 AM');
  });

  test('the sheet\'s own afternoon rows read as civil times', () {
    const entry = TimetableEntry(
      day: 'Monday',
      startTime: '13:00',
      endTime: '14:00',
      subject: 'M-1',
    );

    expect(entry.time, '1:00 PM - 2:00 PM');
  });
}
