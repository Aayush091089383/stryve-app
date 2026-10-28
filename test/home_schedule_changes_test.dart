// Tests for the Home "Latest Update" card (student-side free period claims).
//
// The contract:
// * today's claims from `GET /student/schedule-changes` are listed with their
//   time and either their subject or who claimed them;
// * an empty list keeps the original "No Schedule Changes" copy;
// * an unreachable/failed request is an error with a Retry, never "no changes" -
//   a student must not be told nothing changed when the app simply could not
//   ask.
//
// No live backend and no database: every request is answered by a MockClient.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:stryve/home_page.dart';
import 'package:stryve/services/api_cache.dart';
import 'package:stryve/student.dart';

Student scheduleStudent() => Student(
  name: 'AAYUSH SHANTARAM TITAME',
  studentId: '71',
  rollNumber: '71',
  college: 'Test College',
  course: 'AI&DS',
  year: 1,
  division: 'D',
  batch: 'D-3',
  token: 'schedule-changes-test-token',
);

Map<String, dynamic> changeJson({
  int id = 1,
  String time = '10:15 - 11:15',
  String? subject,
  String claimedBy = 'Teacher 1',
}) => {
  'id': id,
  'day': 'Thursday',
  'time': time,
  'subject': subject,
  'division': 'D',
  'batch': '',
  'claimed_by_name': claimedBy,
  'is_today': true,
};

http.Response jsonResponse(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

http.Response changesResponse(List<Map<String, dynamic>> changes) =>
    jsonResponse({
      'date': '2026-10-29',
      'count': changes.length,
      'changes': changes,
      'message': changes.isEmpty
          ? 'No schedule changes today.'
          : '${changes.length} free periods claimed today.',
    });

/// Answers `/student/schedule-changes` through [onChanges]; every other
/// request (timetable, notifications) gets an empty, valid list.
http.Client scheduleClient(
  Future<http.Response> Function(http.Request request) onChanges,
) => MockClient((request) async {
  if (request.url.path == '/student/schedule-changes') {
    return onChanges(request);
  }
  return http.Response('[]', 200, headers: {'content-type': 'application/json'});
});

Future<void> pumpHome(WidgetTester tester, http.Client client) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  // The tabs cache responses by token; keep each test independent.
  ApiCache.clear();

  await tester.pumpWidget(
    MaterialApp(home: HomePage(student: scheduleStudent(), client: client)),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  testWidgets('claimed free periods are listed with time and detail', (
    tester,
  ) async {
    await pumpHome(
      tester,
      scheduleClient(
        (_) async => changesResponse([
          changeJson(id: 1),
          changeJson(
            id: 2,
            time: '14:00 - 15:00',
            subject: 'EG',
            claimedBy: 'Teacher 2',
          ),
        ]),
      ),
    );

    expect(find.text('2 Schedule Changes'), findsOneWidget);
    expect(find.text('10:15 - 11:15'), findsOneWidget);
    expect(find.text('14:00 - 15:00'), findsOneWidget);
    // No subject: name who claimed it. With a subject: name the subject.
    expect(find.text('Free period (Teacher 1)'), findsOneWidget);
    expect(find.text('EG — now free period'), findsOneWidget);
    expect(find.text('No Schedule Changes'), findsNothing);
  });

  testWidgets('an empty list keeps the honest "No Schedule Changes" copy', (
    tester,
  ) async {
    await pumpHome(
      tester,
      scheduleClient((_) async => changesResponse(const [])),
    );

    expect(find.text('No Schedule Changes'), findsOneWidget);
    expect(
      find.text('There are no free-period changes for your batch.'),
      findsOneWidget,
    );
    expect(find.byKey(const Key('home_schedule_changes')), findsNothing);
  });

  testWidgets('a failed load shows an error and Retry, never "no changes"', (
    tester,
  ) async {
    var calls = 0;
    await pumpHome(
      tester,
      scheduleClient((_) async {
        calls++;
        if (calls == 1) {
          return jsonResponse({'detail': 'boom'}, 500);
        }
        return changesResponse([changeJson()]);
      }),
    );

    expect(find.text('Could not load schedule updates.'), findsOneWidget);
    expect(find.text('No Schedule Changes'), findsNothing);

    final retry = find.byKey(const Key('home_schedule_changes_retry'));
    await tester.ensureVisible(retry);
    await tester.pumpAndSettle();
    await tester.tap(retry);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('1 Schedule Change'), findsOneWidget);
    expect(find.text('10:15 - 11:15'), findsOneWidget);
    expect(find.text('Could not load schedule updates.'), findsNothing);
  });
}
