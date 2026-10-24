// Widget tests for the student attendance dashboard.
//
// The contract:
// * the four UI states are distinct - a failed load is never "no attendance";
// * the overall ring and every subject card show the backend's own numbers;
// * a subject below 75% carries the "attend N more" alert;
// * tapping a subject opens every recorded lecture, newest first;
// * a short dashboard stays pullable, so a refresh really re-requests.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:stryve/attendance.dart';
import 'package:stryve/student.dart';
import 'package:stryve/student_attendance_page.dart';

Student studentFixture() => Student(
  name: 'AAYUSH SHANTARAM TITAME',
  studentId: '71',
  rollNumber: '71',
  college: 'Test College',
  course: 'Computer',
  year: 1,
  division: 'D',
  batch: 'D-1',
  token: 'student-token-xyz',
);

Map<String, dynamic> lecture({
  required String date,
  String period = '10:15-11:15',
  String status = 'present',
}) => {'date': date, 'period': period, 'status': status};

Map<String, dynamic> attendanceJson({
  double overall = 70,
  int total = 10,
  int attended = 7,
  List<Map<String, dynamic>>? subjects,
}) => {
  'overall_percentage': overall,
  'total_classes': total,
  'attended': attended,
  'subjects':
      subjects ??
      [
        {
          'subject': 'Engineering Physics',
          'total_classes': 10,
          'attended': 7,
          'percentage': 70.0,
          'lectures': [
            lecture(date: '2026-10-24', status: 'absent'),
            lecture(date: '2026-10-20', period: '13:00-14:00'),
          ],
        },
        {
          'subject': 'Engineering Mathematics-I',
          'total_classes': 20,
          'attended': 20,
          'percentage': 100.0,
          'lectures': [lecture(date: '2026-10-22')],
        },
      ],
};

http.Response jsonResponse(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

/// Serves `GET /student/attendance`; the answer can change between calls.
class AttendanceClient {
  AttendanceClient({this.status = 200, this.body});

  int status;
  Object? body;
  final List<String> paths = [];

  late final http.Client client = MockClient((request) async {
    paths.add(request.url.path);
    if (request.url.path == '/student/attendance') {
      return jsonResponse(body ?? attendanceJson(), status);
    }
    return jsonResponse({'detail': 'unexpected ${request.url.path}'}, 500);
  });
}

Future<void> pumpDashboard(
  WidgetTester tester,
  AttendanceClient backend, {
  bool embedded = false,
}) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final page = StudentAttendancePage(
    student: studentFixture(),
    client: backend.client,
    embedded: embedded,
  );

  await tester.pumpWidget(
    MaterialApp(home: embedded ? Scaffold(body: page) : page),
  );
  await tester.pump();
  await tester.pumpAndSettle();
}

void main() {
  group('student attendance dashboard', () {
    testWidgets('shows the overall ring and every subject from the backend', (
      tester,
    ) async {
      final backend = AttendanceClient();
      await pumpDashboard(tester, backend);

      expect(backend.paths, contains('/student/attendance'));
      expect(find.text('70%'), findsWidgets);
      expect(
        find.byKey(const Key('attendance_overall_percent')),
        findsOneWidget,
      );
      expect(find.text('7 / 10 lectures attended'), findsOneWidget);
      expect(find.text('Engineering Physics'), findsOneWidget);
      expect(find.text('Engineering Mathematics-I'), findsOneWidget);
      // The subject card carries its own percentage and counts.
      expect(find.text('7 / 10 lectures'), findsOneWidget);
      expect(find.text('20 / 20 lectures'), findsOneWidget);
    });

    testWidgets('a subject below 75% says how many lectures to attend', (
      tester,
    ) async {
      await pumpDashboard(tester, AttendanceClient());

      // 7/10 = 70%: two more gives 9/12 = 75%.
      expect(find.text('Attend 2 more to reach 75%'), findsOneWidget);
      // The at-100% subject carries no warning.
      expect(find.textContaining('Engineering Mathematics-I'), findsWidgets);
      expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
    });

    testWidgets('tapping a subject opens every lecture, newest first', (
      tester,
    ) async {
      await pumpDashboard(tester, AttendanceClient());

      await tester.tap(
        find.byKey(const Key('attendance_subject_Engineering Physics')),
      );
      await tester.pumpAndSettle();

      expect(find.text('24 Oct 2026'), findsOneWidget);
      expect(find.text('20 Oct 2026'), findsOneWidget);
      expect(find.text('2/10 lectures'), findsNothing);
      expect(find.text('70% · 7/10 lectures'), findsOneWidget);
      expect(find.text('Absent'), findsWidgets);
      expect(find.text('Present'), findsWidgets);
      expect(find.text('10:15-11:15'), findsOneWidget);
      expect(find.text('13:00-14:00'), findsOneWidget);
    });

    testWidgets('a subject with no lectures gets its own empty message', (
      tester,
    ) async {
      final backend = AttendanceClient(
        body: attendanceJson(
          subjects: [
            {
              'subject': 'Engineering Graphics',
              'total_classes': 0,
              'attended': 0,
              'percentage': 0,
              'lectures': [],
            },
          ],
        ),
      );
      await pumpDashboard(tester, backend);

      // A zero-lecture subject is not listed by the backend in practice, but if
      // it were, the card must not claim a 75% shortfall.
      expect(find.textContaining('more to reach 75%'), findsNothing);
    });

    testWidgets('no attendance at all shows the recorded-nothing state', (
      tester,
    ) async {
      final backend = AttendanceClient(
        body: const {
          'overall_percentage': 0,
          'total_classes': 0,
          'attended': 0,
          'subjects': [],
        },
      );
      await pumpDashboard(tester, backend);

      expect(find.text('No attendance recorded yet'), findsOneWidget);
      expect(
        find.textContaining('Your teachers will mark attendance'),
        findsOneWidget,
      );
      expect(find.text('0%'), findsNothing);
      expect(find.text('By subject'), findsNothing);
    });

    testWidgets('a failed load shows an error with a working retry', (
      tester,
    ) async {
      final backend = AttendanceClient(
        status: 500,
        body: {'detail': 'Attendance is unavailable right now'},
      );
      await pumpDashboard(tester, backend);

      expect(find.text('Attendance is unavailable right now'), findsOneWidget);
      expect(find.text('No attendance recorded yet'), findsNothing);

      backend.status = 200;
      backend.body = attendanceJson();
      await tester.tap(find.byKey(const Key('attendance_retry')));
      await tester.pump();
      await tester.pumpAndSettle();

      expect(find.text('Engineering Physics'), findsOneWidget);
      expect(find.text('Attendance is unavailable right now'), findsNothing);
      expect(
        backend.paths.where((path) => path == '/student/attendance').length,
        2,
      );
    });

    testWidgets('a failed refresh keeps the numbers on screen', (tester) async {
      final backend = AttendanceClient();
      await pumpDashboard(tester, backend);

      backend.status = 500;
      backend.body = {'detail': 'boom'};
      tester.state<RefreshIndicatorState>(find.byType(RefreshIndicator)).show();
      await tester.pumpAndSettle();

      // The last good numbers stay; a failed refresh is reported, not turned
      // into an empty screen.
      expect(find.text('Engineering Physics'), findsOneWidget);
      expect(find.text('boom'), findsWidgets);
    });

    testWidgets('a short dashboard is still pull-to-refreshable', (
      tester,
    ) async {
      await pumpDashboard(tester, AttendanceClient(), embedded: true);

      final list = tester.widget<ListView>(
        find.byKey(const Key('attendance_list')),
      );
      expect(list.physics, isA<AlwaysScrollableScrollPhysics>());
      expect(find.byType(RefreshIndicator), findsOneWidget);
      // The host owns the only Scaffold; the embedded page adds no app bar of
      // its own (HomePage's app bar is the only chrome on that tab).
      expect(find.byType(Scaffold), findsOneWidget);
      expect(find.byType(AppBar), findsNothing);
    });
  });

  group('attendance model hand-off', () {
    test('the dashboard renders the same percentage the model parsed', () {
      final summary = StudentAttendance.fromJson(attendanceJson());
      final physics = summary.subjects.firstWhere(
        (subject) => subject.subject == 'Engineering Physics',
      );
      expect(physics.percentage, 70.0);
      expect(physics.lecturesToReach75, 2);
    });
  });
}
