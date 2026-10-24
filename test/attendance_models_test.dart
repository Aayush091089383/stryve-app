// Unit tests for the attendance models behind the student dashboard.
//
// The bunk alert is arithmetic, not a guess: `lecturesToReach75` must be the
// smallest number of extra lectures that brings the percentage to 75%, and the
// JSON parsing must never invent a value the backend did not send.

import 'package:flutter_test/flutter_test.dart';
import 'package:stryve/attendance.dart';

SubjectAttendance subject({
  String name = 'Engineering Physics',
  int total = 10,
  int attended = 7,
  double? percentage,
}) => SubjectAttendance(
  subject: name,
  totalClasses: total,
  attended: attended,
  percentage: percentage ?? (total == 0 ? 0 : attended * 100 / total),
);

void main() {
  group('lecturesToReach75', () {
    test('a student already above 75% needs nothing', () {
      expect(subject(total: 60, attended: 49).lecturesToReach75, 0);
      expect(subject(total: 4, attended: 3).lecturesToReach75, 0);
    });

    test('exactly 75% needs nothing', () {
      expect(subject(total: 8, attended: 6).lecturesToReach75, 0);
    });

    test('the answer is the smallest run that reaches 75%', () {
      final needs = subject(total: 10, attended: 7).lecturesToReach75;
      expect(needs, 2);
      // (7 + 2) / (10 + 2) = 75%, and one fewer falls short.
      expect((7 + needs) / (10 + needs), 0.75);
      expect((7 + needs - 1) / (10 + needs - 1), lessThan(0.75));
    });

    test('a student who never attended needs 3 lectures per held lecture', () {
      expect(subject(total: 10, attended: 0).lecturesToReach75, 30);
    });

    test('a subject with no lectures yet needs nothing', () {
      expect(subject(total: 0, attended: 0).lecturesToReach75, 0);
    });
  });

  group('parsing', () {
    test('a full payload is read as sent', () {
      final summary = StudentAttendance.fromJson({
        'overall_percentage': 82.5,
        'total_classes': 40,
        'attended': 33,
        'subjects': [
          {
            'subject': 'Engineering Physics',
            'total_classes': 10,
            'attended': 7,
            'percentage': 70.0,
            'lectures': [
              {
                'date': '2026-10-20',
                'period': '10:15-11:15',
                'status': 'present',
              },
              {
                'date': '2026-10-24',
                'period': '13:00-14:00',
                'status': 'absent',
              },
            ],
          },
        ],
      });

      expect(summary.overallPercentage, 82.5);
      expect(summary.totalClasses, 40);
      expect(summary.attended, 33);
      expect(summary.hasRecords, isTrue);

      final physics = summary.subjects.single;
      expect(physics.subject, 'Engineering Physics');
      expect(physics.isBelowThreshold, isTrue);
      expect(physics.lecturesToReach75, 2);
      expect(physics.lectures.first.date, '2026-10-24');
      expect(physics.lectures.first.isPresent, isFalse);
      expect(physics.lectures.last.isPresent, isTrue);
    });

    test('lectures are newest first even when the backend is not', () {
      final physics = SubjectAttendance.fromJson({
        'subject': 'Physics',
        'total_classes': 3,
        'attended': 3,
        'percentage': 100.0,
        'lectures': [
          {'date': '2026-10-01', 'period': '10:15-11:15', 'status': 'present'},
          {'date': '2026-10-20', 'period': '10:15-11:15', 'status': 'present'},
          {'date': '2026-10-10', 'period': '13:00-14:00', 'status': 'present'},
        ],
      });

      expect(physics.lectures.map((lecture) => lecture.date).toList(), [
        '2026-10-20',
        '2026-10-10',
        '2026-10-01',
      ]);
    });

    test('subjects are alphabetical', () {
      final summary = StudentAttendance.fromJson({
        'overall_percentage': 0,
        'total_classes': 0,
        'attended': 0,
        'subjects': [
          {
            'subject': 'Physics',
            'total_classes': 0,
            'attended': 0,
            'percentage': 0,
          },
          {
            'subject': 'Chemistry',
            'total_classes': 0,
            'attended': 0,
            'percentage': 0,
          },
        ],
      });

      expect(summary.subjects.map((subject) => subject.subject).toList(), [
        'Chemistry',
        'Physics',
      ]);
    });

    test('an empty payload is honest about having no records', () {
      final summary = StudentAttendance.fromJson(const {});

      expect(summary.hasRecords, isFalse);
      expect(summary.overallPercentage, 0);
      expect(summary.subjects, isEmpty);
    });
  });

  group('formatAttendanceDate', () {
    test('formats an ISO date for the lecture rows', () {
      expect(formatAttendanceDate('2026-10-24'), '24 Oct 2026');
      expect(formatAttendanceDate('2026-01-01'), '1 Jan 2026');
      expect(formatAttendanceDate('2026-12-31'), '31 Dec 2026');
    });

    test('an unparseable value is shown unchanged, never invented', () {
      expect(formatAttendanceDate(''), '');
      expect(formatAttendanceDate('24-10-2026'), '24-10-2026');
      expect(formatAttendanceDate('2026-13-01'), '2026-13-01');
    });
  });
}
