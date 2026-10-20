// The dedicated student Assignments screen.
//
// Pinned here:
// * it renders exactly what GET /assignments returns - including the
//   description the Tasks card does not use - and shows READ PDF only where the
//   backend says an attachment exists;
// * loading, empty and error states each render their own UI, and an error is
//   never shown as an empty list;
// * Try Again bypasses the cache and refetches;
// * it never invents a completed state or another endpoint.
//
// Safety: MockClient only. No live backend, no database.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:stryve/assignments_page.dart';
import 'package:stryve/services/api_cache.dart';
import 'package:stryve/student.dart';

const String kToken = 'assignments-page-token';

Student studentFixture() => Student(
  name: 'AAYUSH SHANTARAM TITAME',
  studentId: '71',
  rollNumber: '71',
  college: 'Test College',
  course: 'Computer',
  year: 1,
  division: 'D',
  batch: 'D-1',
  token: kToken,
);

Map<String, dynamic> assignmentJson({
  int id = 1,
  String subject = 'MATH',
  String title = 'Problem Set 4',
  String? description = 'Solve the attached problems.',
  String dueDate = '2026-10-21',
  String? batch,
  bool hasAttachment = true,
  String? originalName = 'problems.pdf',
}) => {
  'id': id,
  'subject': subject,
  'title': title,
  'description': description,
  'due_date': dueDate,
  'year': 1,
  'division': 'D',
  'batch': batch,
  'has_attachment': hasAttachment,
  'original_name': hasAttachment ? originalName : null,
};

http.Response ok(List<Map<String, dynamic>> items) => http.Response(
  jsonEncode(items),
  200,
  headers: {'content-type': 'application/json'},
);

Future<void> pumpAssignments(
  WidgetTester tester,
  http.Client client, {
  Size size = const Size(1080, 2400),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MaterialApp(home: AssignmentsPage(student: studentFixture(), client: client)),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

/// Folders start closed, so any test that asserts a folder's contents opens it
/// first. The assertions themselves are unchanged - they just follow the one
/// tap a student now has to make instead of assuming the old "all open"
/// default.
Future<void> openFolder(WidgetTester tester, String subject) async {
  await tester.tap(find.text(subject));
  await tester.pumpAndSettle();
}

void main() {
  setUp(ApiCache.clear);

  testWidgets('renders the assignments the API returns', (tester) async {
    final client = MockClient(
      (request) async => ok([
        assignmentJson(
          id: 1,
          title: 'Problem Set 4',
          subject: 'MATH',
          description: 'Solve the attached problems.',
          batch: 'D-1',
        ),
        assignmentJson(
          id: 2,
          title: 'Lab Report',
          subject: 'PHY',
          description: null,
          dueDate: '2026-10-28',
          hasAttachment: false,
        ),
      ]),
    );

    await pumpAssignments(tester, client);

    expect(find.text('All Assignments'), findsOneWidget);

    // Every folder is closed on arrival: only the subject headers are there.
    expect(find.text('Problem Set 4'), findsNothing);
    expect(find.text('Lab Report'), findsNothing);

    await openFolder(tester, 'MATH');
    await openFolder(tester, 'PHY');

    expect(find.text('Problem Set 4'), findsOneWidget);
    expect(find.text('Lab Report'), findsOneWidget);
    expect(find.text('MATH'), findsOneWidget);
    expect(find.text('Due: 21 Oct 2026'), findsOneWidget);
    expect(find.text('Due: 28 Oct 2026'), findsOneWidget);
    expect(find.text('D-1'), findsOneWidget);

    // The description is a real API field, shown only on this screen.
    expect(find.text('Solve the attached problems.'), findsOneWidget);

    // Only the assignment that actually has a file offers the action.
    expect(find.text('READ PDF'), findsOneWidget);
  });

  testWidgets('an empty response shows the empty state, not a blank screen', (
    tester,
  ) async {
    await pumpAssignments(tester, MockClient((_) async => ok([])));

    expect(find.text('No assignments yet'), findsOneWidget);
    expect(find.text('READ PDF'), findsNothing);
  });

  testWidgets('a server error is reported with a retry, never as empty', (
    tester,
  ) async {
    await pumpAssignments(
      tester,
      MockClient((_) async => http.Response('{"detail":"boom"}', 500)),
    );

    expect(find.text('Could not load assignments (500)'), findsOneWidget);
    expect(find.text('Try Again'), findsOneWidget);
    expect(find.text('No assignments yet'), findsNothing);
  });

  testWidgets('Try Again bypasses the cache and loads the list', (tester) async {
    var calls = 0;
    final client = MockClient((request) async {
      calls++;
      if (calls == 1) return http.Response('{"detail":"boom"}', 500);
      return ok([assignmentJson()]);
    });

    await pumpAssignments(tester, client);
    expect(find.text('Could not load assignments (500)'), findsOneWidget);

    await tester.tap(find.text('Try Again'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(calls, 2, reason: 'the retry must hit the backend again');
    await openFolder(tester, 'MATH');
    expect(find.text('Problem Set 4'), findsOneWidget);
  });

  testWidgets('a pending request shows the loading state', (tester) async {
    final completer = Completer<http.Response>();
    final client = MockClient((_) => completer.future);

    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(home: AssignmentsPage(student: studentFixture(), client: client)),
    );
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('All Assignments'), findsNothing);

    completer.complete(ok([assignmentJson()]));
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.byType(CircularProgressIndicator), findsNothing);
    await openFolder(tester, 'MATH');
    expect(find.text('Problem Set 4'), findsOneWidget);
  });
}
