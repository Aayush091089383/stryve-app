// Tests for the teacher/admin upload form's Subject field.
//
// The free-text field was replaced by a dropdown of the seven Division D
// subjects so an upload always names the subject the backend stores (the
// backend replaces that subject's text-only row with the file).
//
// Safety: no live backend and no database. Every request is answered by a
// MockClient; the PDF picker is injected, so no OS file dialog opens.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:stryve/services/teacher_auth_service.dart';
import 'package:stryve/teacher_assignments_page.dart';

const String kToken = 'teacher-subject-test-token';

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

const String kPdf = '%PDF-1.4\n1 0 obj\n<< /Type /Catalog >>\nendobj\n%%EOF\n';

Map<String, dynamic> uploadedJson(String subject) => {
  'id': 99,
  'subject': subject,
  'title': 'Physics notes',
  'description': null,
  'due_date': '2026-10-26',
  'year': 1,
  'division': 'D',
  'batch': null,
  'has_attachment': true,
  'original_name': 'notes.pdf',
  'file_size': kPdf.length,
  'uploaded_by': 5,
  'created_at': '2026-10-19T12:00:00',
};

http.Response jsonResponse(Object body, int status) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

Future<void> pumpAssignmentsView(
  WidgetTester tester,
  List<http.Request> sent, {
  List<Object> mine = const [],
  bool openSheet = false,
}) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final client = MockClient((request) async {
    if (request.url.path == '/teacher/assignments/mine') {
      return jsonResponse(mine, 200);
    }
    sent.add(request);
    return jsonResponse(uploadedJson('Engineering Physics'), 201);
  });

  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: TeacherAssignmentsView(
          authService: TeacherAuthService(),
          client: client,
          pickFile: () async =>
              PickedAssignmentFile(name: 'notes.pdf', bytes: utf8.encode(kPdf)),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();

  if (openSheet) {
    await tester.tap(find.text('UPLOAD PDF ASSIGNMENT'));
    await tester.pumpAndSettle();
  }
}

/// A record in the shape `GET /teacher/assignments/mine` returns.
Map<String, dynamic> recordJson({
  required int id,
  required String subject,
  required bool hasAttachment,
  int? uploadedBy,
}) => {
  ...uploadedJson(subject),
  'id': id,
  'title': subject,
  'has_attachment': hasAttachment,
  'uploaded_by': uploadedBy,
};

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues(teacherStorage()));
  tearDown(() => FlutterSecureStorage.setMockInitialValues({}));

  testWidgets('the subject is chosen from the seven-subject dropdown', (
    tester,
  ) async {
    await pumpAssignmentsView(tester, [], openSheet: true);

    expect(find.text('Subject'), findsOneWidget);
    expect(
      find.byType(DropdownButtonFormField<String>),
      findsNWidgets(2),
      reason: 'subject and batch are dropdowns; subject no longer takes text',
    );
    expect(find.textContaining('e.g. Engineering Physics'), findsNothing);

    // Opening the subject menu (the first dropdown) lists all seven subjects.
    await tester.tap(find.byType(DropdownButtonFormField<String>).first);
    await tester.pumpAndSettle();
    for (final subject in kAssignmentSubjects) {
      expect(find.text(subject), findsWidgets, reason: subject);
    }
    expect(kAssignmentSubjects, hasLength(7));
  });

  testWidgets('a subject must be chosen before the upload is submitted', (
    tester,
  ) async {
    await pumpAssignmentsView(tester, [], openSheet: true);

    await tester.enterText(find.byType(TextField).first, 'Physics notes');
    await tester.tap(find.text('UPLOAD'));
    await tester.pumpAndSettle();

    expect(find.text('Please choose the subject.'), findsOneWidget);
  });

  testWidgets('only an uploaded assignment offers Remove', (tester) async {
    await pumpAssignmentsView(
      tester,
      [],
      mine: [
        recordJson(
          id: 1,
          subject: 'Engineering Mathematics-I',
          hasAttachment: false,
        ),
        recordJson(
          id: 2,
          subject: 'Engineering Physics',
          hasAttachment: true,
          uploadedBy: 5,
        ),
      ],
    );

    expect(find.text('Engineering Mathematics-I'), findsOneWidget);
    expect(find.text('Engineering Physics'), findsOneWidget);
    expect(
      find.text('Remove'),
      findsOneWidget,
      reason: 'the placeholder must not offer a Remove button',
    );
    expect(
      find.textContaining('Placeholder'),
      findsOneWidget,
      reason: 'the placeholder is labelled instead',
    );
  });

  testWidgets('the chosen subject is sent as the multipart subject field', (
    tester,
  ) async {
    final sent = <http.Request>[];
    await pumpAssignmentsView(tester, sent, openSheet: true);

    await tester.enterText(find.byType(TextField).first, 'Physics notes');

    await tester.tap(find.byType(DropdownButtonFormField<String>).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Engineering Physics').last);
    await tester.pumpAndSettle();

    await tester.tap(find.text('CHOOSE PDF FILE'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('UPLOAD'));
    await tester.pumpAndSettle();

    expect(sent, hasLength(1));
    expect(sent.single.method, 'POST');
    expect(sent.single.url.path, '/teacher/assignments/upload');
    final body = utf8.decode(sent.single.bodyBytes, allowMalformed: true);
    expect(body, contains('name="subject"'));
    expect(body, contains('Engineering Physics'));
    expect(find.text('Assignment uploaded successfully'), findsOneWidget);
  });
}
