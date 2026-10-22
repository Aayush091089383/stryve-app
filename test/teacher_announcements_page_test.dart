// Widget tests for the Teacher/Admin announcements screen.
//
// Everything runs on in-memory secure storage and a MockClient, so the live
// backend and the real database are never contacted.
//
// Pinned here:
//   * the screen lists the announcements the account may manage, with the
//     bearer token it was given;
//   * a delete asks first - Cancel sends nothing;
//   * confirming sends DELETE to that announcement and removes the row;
//   * a refusal from the backend is shown, and the row stays;
//   * a link in a notice is rendered as a link, not plain text.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:stryve/teacher_announcements_page.dart';
import 'package:stryve/utils/linkified_text.dart';

import 'support/theme_harness.dart';

const String kToken = 'teacher-announcements-token';

Map<String, String> teacherStorage() => {
  'teacher_auth_token': kToken,
  'teacher_token_expiry': DateTime.now()
      .add(const Duration(days: 1))
      .toUtc()
      .toIso8601String(),
  'teacher_id': '5',
  'teacher_name': 'Dr. Meera Rao',
  'teacher_email': 'meera@campussync.edu',
  'teacher_role': 'teacher',
};

Map<String, dynamic> announcementJson({
  int id = 7,
  String title = 'Library notice',
  String message = 'Return borrowed books by Friday.',
  String author = 'Dr. Meera Rao',
  int authorId = 5,
}) => {
  'id': id,
  'title': title,
  'message': message,
  'author_id': authorId,
  'author_name': author,
  'created_at': '2026-10-20T12:46:28.980601',
  'year': null,
  'division': null,
};

http.Response jsonResponse(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

/// Records every request the page makes, so the test can assert the verb, the
/// path and the token rather than only the visible result.
class Recorded {
  final List<http.Request> requests = [];

  List<String> get verbsAndPaths =>
      requests.map((r) => '${r.method} ${r.url.path}').toList();
}

Future<void> pumpPage(
  WidgetTester tester,
  http.Client client, {
  Map<String, String>? storage,
}) async {
  FlutterSecureStorage.setMockInitialValues(storage ?? teacherStorage());

  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    withThemeProvider(
      MaterialApp(home: TeacherAnnouncementsPage(client: client)),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('lists the announcements this account can manage', (
    tester,
  ) async {
    final recorded = Recorded();
    await pumpPage(
      tester,
      MockClient((request) async {
        recorded.requests.add(request);
        return jsonResponse([
          announcementJson(),
          announcementJson(id: 8, title: 'Lab shift', message: 'Lab moves.'),
        ]);
      }),
    );

    expect(find.text('Library notice'), findsOneWidget);
    expect(find.text('Lab shift'), findsOneWidget);
    expect(find.text('2 live'), findsOneWidget);
    expect(recorded.verbsAndPaths, contains('GET /teacher/announcements'));
    expect(recorded.requests.first.headers['Authorization'], 'Bearer $kToken');
  });

  testWidgets('a link in a notice is rendered as a link', (tester) async {
    await pumpPage(
      tester,
      MockClient(
        (request) async => jsonResponse([
          announcementJson(
            message: 'Fill the form at https://forms.example.com/abc',
          ),
        ]),
      ),
    );

    expect(find.byType(LinkifiedText), findsOneWidget);
  });

  testWidgets('deleting asks first and Cancel sends nothing', (tester) async {
    final recorded = Recorded();
    await pumpPage(
      tester,
      MockClient((request) async {
        recorded.requests.add(request);
        return jsonResponse([announcementJson()]);
      }),
    );

    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pumpAndSettle();

    expect(find.text('Delete this announcement?'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(find.text('Library notice'), findsOneWidget);
    expect(
      recorded.verbsAndPaths.where((entry) => entry.startsWith('DELETE')),
      isEmpty,
    );
  });

  testWidgets('confirming deletes that announcement and removes the row', (
    tester,
  ) async {
    final recorded = Recorded();
    await pumpPage(
      tester,
      MockClient((request) async {
        recorded.requests.add(request);
        if (request.method == 'DELETE') {
          return jsonResponse({'message': 'Announcement deleted'});
        }
        return jsonResponse([announcementJson()]);
      }),
    );

    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    expect(find.text('Library notice'), findsNothing);
    expect(find.text('0 live'), findsOneWidget);
    expect(
      recorded.verbsAndPaths,
      contains('DELETE /teacher/announcements/7'),
    );
    expect(
      recorded.requests
          .firstWhere((request) => request.method == 'DELETE')
          .headers['Authorization'],
      'Bearer $kToken',
    );
    expect(find.text('Announcement deleted'), findsOneWidget);
  });

  testWidgets('a refused delete is explained and the row stays', (
    tester,
  ) async {
    await pumpPage(
      tester,
      MockClient((request) async {
        if (request.method == 'DELETE') {
          return jsonResponse({
            'detail': 'You can only delete announcements you posted',
          }, 403);
        }
        return jsonResponse([announcementJson()]);
      }),
    );

    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    expect(
      find.text('You can only delete announcements you posted'),
      findsOneWidget,
    );
    expect(find.text('Library notice'), findsOneWidget);
  });
}
