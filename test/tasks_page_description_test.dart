// The student Tasks list must show the assignment description the backend
// returns. This was the one student surface that dropped the field while
// building its cards, so a text-only assignment ("Read chapter 4") looked
// like it had no instructions at all.
//
// Safety: MockClient only, no live backend and no database.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:stryve/services/api_cache.dart';
import 'package:stryve/student.dart';
import 'package:stryve/tasks.dart';

void main() {
  setUp(ApiCache.clear);
  tearDown(ApiCache.clear);

  testWidgets('a text-only assignment shows its full description', (
    tester,
  ) async {
    final description = List.generate(
      20,
      (i) => 'Paragraph ${i + 1}: read the section and answer the questions.',
    ).join('\n');

    final client = MockClient(
      (_) async => http.Response(
        jsonEncode([
          {
            'id': 3,
            'subject': 'DTIL',
            'title': 'DTIL 1',
            'description': description,
            'due_date': '2026-10-31',
            'year': 1,
            'division': 'D',
            'batch': null,
            'has_attachment': false,
            'original_name': null,
          },
        ]),
        200,
        headers: {'content-type': 'application/json'},
      ),
    );

    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: TasksPage(
          student: Student(
            name: 'Test Student',
            studentId: '1',
            rollNumber: '71',
            college: 'Test College',
            course: 'AI&DS',
            year: 1,
            division: 'D',
            batch: 'D-1',
            token: 'tasks-description-token',
          ),
          client: client,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('DTIL 1'), findsOneWidget);
    expect(find.text(description), findsOneWidget);

    final rendered = tester.widgetList<Text>(find.byType(Text)).firstWhere(
      (text) => text.textSpan?.toPlainText() == description,
    );
    expect(rendered.maxLines, isNull);
    expect(tester.takeException(), isNull);
  });
}
