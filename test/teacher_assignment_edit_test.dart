// The teacher's Edit action on an uploaded assignment.
//
// Safety: no live backend and no database. Every request is answered by a
// MockClient, and the secure storage that holds the token is mocked.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:stryve/services/teacher_auth_service.dart';
import 'package:stryve/teacher_assignments_page.dart';

const String kToken = 'teacher-edit-test-token';

Map<String, String> teacherStorage() => {
  'teacher_auth_token': kToken,
  'teacher_token_expiry': DateTime.now()
      .add(const Duration(days: 1))
      .toUtc()
      .toIso8601String(),
  'teacher_id': '5',
  'teacher_name': 'Mrs. S. M. Gangurde',
  'teacher_email': 'smg@campussync.edu',
  'teacher_role': 'teacher',
};

Map<String, dynamic> record({
  String title = 'Unit 3 worksheet',
  String dueDate = '2026-10-26',
  String? description = 'Solve every question.',
}) => {
  'id': 42,
  'subject': 'Engineering Mathematics-I',
  'title': title,
  'description': description,
  'due_date': dueDate,
  'year': 1,
  'division': 'D',
  'batch': null,
  'has_attachment': true,
  'original_name': 'worksheet.pdf',
  'file_size': 1024,
  'uploaded_by': 5,
  'created_at': '2026-10-19T12:00:00',
};

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues(teacherStorage()));
  tearDown(() => FlutterSecureStorage.setMockInitialValues({}));

  testWidgets('editing one assignment PATCHes the new title, description and '
      'due date, then refreshes the list', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final patched = <String>[];
    var current = record();

    final client = MockClient((request) async {
      if (request.method == 'GET' &&
          request.url.path == '/teacher/assignments/mine') {
        return http.Response(
          jsonEncode([current]),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (request.method == 'PATCH' &&
          request.url.path == '/teacher/assignments/42') {
        patched.add(request.body);
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        current = record(
          title: body['title'] as String,
          dueDate: body['due_date'] as String,
          description: body['description'] as String?,
        );
        return http.Response(
          jsonEncode(current),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response('{}', 404);
    });

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TeacherAssignmentsView(
            authService: TeacherAuthService(),
            client: client,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Unit 3 worksheet'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.edit_outlined));
    await tester.pumpAndSettle();

    expect(find.text('Edit Assignment'), findsOneWidget);
    final titleField = tester.widget<TextField>(find.byType(TextField).first);
    expect(titleField.controller?.text, 'Unit 3 worksheet');
    // The sheet's date button shows the parsed date; the card behind it reads
    // "Due 2026-10-26 • worksheet.pdf", so the exact text is unique.
    expect(find.text('Due 2026-10-26'), findsOneWidget);

    await tester.enterText(
      find.byType(TextField).first,
      'Unit 3 worksheet (revised)',
    );
    await tester.enterText(
      find.byType(TextField).at(1),
      'Solve 1-10. https://example.com/notes',
    );

    await tester.tap(find.text('SAVE CHANGES'));
    await tester.pumpAndSettle();

    expect(patched, hasLength(1), reason: 'one PATCH for one save');
    final sent = jsonDecode(patched.single) as Map<String, dynamic>;
    expect(sent['title'], 'Unit 3 worksheet (revised)');
    expect(sent['description'], 'Solve 1-10. https://example.com/notes');
    expect(sent['due_date'], '2026-10-26');

    // The list reloaded from the backend, so the new title is on the card.
    expect(find.text('Unit 3 worksheet (revised)'), findsOneWidget);
    expect(find.text('Unit 3 worksheet'), findsNothing);
    expect(find.text('Assignment updated'), findsOneWidget);
  });
}
