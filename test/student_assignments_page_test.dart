// The dedicated student Assignments screen.
//
// Pinned here:
// * it renders exactly what GET /assignments returns - including a long
//   description in full - and shows READ PDF only where the backend says an
//   attachment exists;
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

import 'package:stryve/assignment_pdf_viewer_page.dart';
import 'package:stryve/assignments_page.dart';
import 'package:stryve/services/api_cache.dart';
import 'package:stryve/student.dart';
import 'package:stryve/utils/video_surface.dart';
import 'package:stryve/video_player_page.dart';

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
  List<Map<String, dynamic>>? attachments,
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
  'attachments': ?attachments,
};

Map<String, dynamic> attachmentJson(int id, String name, {int size = 1024}) =>
    {'id': id, 'original_name': name, 'file_size': size};

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

    // The description is a real API field, rendered in the card.
    expect(find.text('Solve the attached problems.'), findsOneWidget);

    // Only the assignment that actually has a file offers the action.
    expect(find.text('READ PDF'), findsOneWidget);
  });

  testWidgets('a long description is shown in full, not clipped', (tester) async {
    // The kind of paragraph a teacher pastes in: several sentences and blank
    // lines, well past the old three-line preview.
    final longDescription = List.generate(
      24,
      (i) =>
          'Step ${i + 1}: read the section and write the answer in your own words.',
    ).join('\n');

    await pumpAssignments(
      tester,
      MockClient(
        (_) async => ok([
          assignmentJson(
            id: 4,
            subject: 'DTIL',
            title: 'DTIL 1',
            description: longDescription,
            hasAttachment: false,
            originalName: null,
          ),
        ]),
      ),
    );
    await openFolder(tester, 'DTIL');

    expect(find.text(longDescription), findsOneWidget);
    final rendered = tester.widgetList<Text>(find.byType(Text)).firstWhere(
      (text) => text.textSpan?.toPlainText() == longDescription,
    );
    expect(rendered.maxLines, isNull, reason: 'the whole description wraps');
    expect(tester.takeException(), isNull);
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

  testWidgets('a video attachment says PLAY VIDEO, a PDF keeps READ PDF', (
    tester,
  ) async {
    final client = MockClient(
      (request) async => ok([
        assignmentJson(
          id: 1,
          subject: 'MATH',
          title: 'Recorded lecture',
          originalName: 'lecture.mp4',
        ),
        assignmentJson(
          id: 2,
          subject: 'PHY',
          title: 'Lab notes',
          originalName: 'notes.pdf',
        ),
      ]),
    );

    await pumpAssignments(tester, client);
    await openFolder(tester, 'MATH');
    await openFolder(tester, 'PHY');

    expect(find.text('PLAY VIDEO'), findsOneWidget);
    expect(find.text('READ PDF'), findsOneWidget);
  });

  testWidgets('tapping a video opens the player, never the PDF reader', (
    tester,
  ) async {
    final client = MockClient(
      (request) async => ok([
        assignmentJson(
          id: 7,
          subject: 'MATH',
          title: 'Recorded lecture',
          originalName: 'lecture.mp4',
        ),
      ]),
    );

    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    VideoSource? asked;
    await tester.pumpWidget(
      MaterialApp(
        home: AssignmentsPage(
          student: studentFixture(),
          client: client,
          // The player's own surface is injected: starting the native player in
          // a widget test is exactly what this avoids.
          videoSurfaceFactory: (source) {
            asked = source;
            return const Center(child: Text('FAKE PLAYER'));
          },
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    await openFolder(tester, 'MATH');
    await tester.tap(find.text('PLAY VIDEO'));
    await tester.pumpAndSettle();

    expect(find.byType(VideoPlayerPage), findsOneWidget);
    expect(find.byType(AssignmentPdfViewerPage), findsNothing);
    expect(find.text('FAKE PLAYER'), findsOneWidget);
    // The player asks for the same authorized endpoint the PDF reader uses.
    expect(asked?.url.endsWith('/assignments/7/file'), isTrue, reason: asked?.url);
    expect(asked?.token, kToken);
  });

  testWidgets('a multi-file assignment lists every attachment', (tester) async {
    final client = MockClient(
      (request) async => ok([
        assignmentJson(
          id: 5,
          subject: 'MATH',
          title: 'Unit 1 pack',
          attachments: [
            attachmentJson(51, 'notes.pdf'),
            attachmentJson(52, 'lecture.mp4'),
          ],
        ),
      ]),
    );

    await pumpAssignments(tester, client);
    await openFolder(tester, 'MATH');

    expect(find.text('notes.pdf'), findsOneWidget);
    expect(find.text('lecture.mp4'), findsOneWidget);
    expect(find.text('READ PDF'), findsOneWidget);
    expect(find.text('PLAY VIDEO'), findsOneWidget);
  });

  testWidgets('opening the second video streams that attachment', (
    tester,
  ) async {
    final client = MockClient(
      (request) async => ok([
        assignmentJson(
          id: 9,
          subject: 'MATH',
          title: 'Two recordings',
          attachments: [
            attachmentJson(91, 'part-1.mp4'),
            attachmentJson(92, 'part-2.mp4'),
          ],
        ),
      ]),
    );

    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    VideoSource? asked;
    await tester.pumpWidget(
      MaterialApp(
        home: AssignmentsPage(
          student: studentFixture(),
          client: client,
          videoSurfaceFactory: (source) {
            asked = source;
            return const Center(child: Text('FAKE PLAYER'));
          },
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    await openFolder(tester, 'MATH');
    await tester.tap(find.text('PLAY VIDEO').last);
    await tester.pumpAndSettle();

    expect(find.byType(VideoPlayerPage), findsOneWidget);
    expect(
      asked?.url.endsWith('/assignments/9/files/92'),
      isTrue,
      reason: 'the tapped attachment, not the first one: ${asked?.url}',
    );
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
