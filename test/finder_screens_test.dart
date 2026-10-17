// Behavioural tests for the two new Student Panel finder screens.
//
// Everything runs against a MockClient, so the live backend is never contacted.
// Covered: the screens open from Home, the search term is sent to the backend,
// loading/empty/error states are distinct, a retry works, and a field the
// official records do not contain is shown as "Not available" rather than being
// invented.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:campus_sync/faculty_finder_page.dart';
import 'package:campus_sync/home_page.dart';
import 'package:campus_sync/lab_finder_page.dart';
import 'package:campus_sync/student.dart';

const String kToken = 'student-finder-token-xyz';

Student testStudent() => Student(
  name: 'AAYUSH SHANTARAM TITAME',
  studentId: '71',
  rollNumber: '71',
  college: 'Test College',
  course: 'AI&DS',
  year: 1,
  division: 'D',
  batch: 'D-3',
  token: kToken,
);

http.Response jsonResponse(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

/// One faculty record exactly as `GET /faculty` returns it: only the coordinator
/// has a full name, everything else is null.
Map<String, dynamic> facultyJson({
  int id = 1,
  String code = 'SMG',
  String? fullName = 'Mrs. S. M. Gangurde',
  String? roleNote = 'Class Coordinator (Division D)',
  bool verified = true,
  List<Map<String, dynamic>> subjects = const [],
}) => {
  'id': id,
  'short_code': code,
  'display_name': fullName ?? code,
  'full_name': fullName,
  'department': null,
  'email': null,
  'office': null,
  'phone': null,
  'role_note': roleNote,
  'is_verified': verified,
  'subjects': subjects.isEmpty
      ? [
          {
            'name': 'Engineering Mathematics-I',
            'short_name': 'EMI',
            'code': 'BSC-101',
            'kind': 'theory',
            'faculty_code': code,
          },
        ]
      : subjects,
};

Map<String, dynamic> labJson({
  int id = 1,
  String name = 'Division D Classroom',
  String? code = 'M308',
  String? room = 'M308',
  String? building = 'Block-11',
  String? floor,
}) => {
  'id': id,
  'name': name,
  'code': code,
  'room': room,
  'building': building,
  'floor': floor,
  'subject': null,
  'kind': 'classroom',
  'is_verified': true,
};

Future<void> pumpUntilFound(
  WidgetTester tester,
  Finder finder, {
  int maxFrames = 80,
  String? describing,
}) async {
  for (var i = 0; i < maxFrames; i++) {
    if (finder.evaluate().isNotEmpty) return;
    await tester.pump(const Duration(milliseconds: 20));
  }
  if (finder.evaluate().isEmpty) {
    fail(
      'Expected ${describing ?? 'the target widget'} to appear '
      'within $maxFrames frames, but it never did.',
    );
  }
}

void main() {
  group('Faculty Finder', () {
    testWidgets('lists the official faculty records', (tester) async {
      final client = MockClient(
        (request) async =>
            jsonResponse([facultyJson(), facultyJson(id: 2, code: 'SPG', fullName: null, roleNote: null, verified: false)]),
      );

      await tester.pumpWidget(
        MaterialApp(home: FacultyFinderPage(student: testStudent(), client: client)),
      );
      await pumpUntilFound(tester, find.text('Mrs. S. M. Gangurde'));

      expect(find.text('SPG'), findsOneWidget);
      // Subjects come from the catalogue that belongs to the code.
      expect(find.textContaining('EMI'), findsWidgets);
      // The search box is present and usable on a phone.
      expect(find.byType(TextField), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('never invents a field the records do not contain', (
      tester,
    ) async {
      final client = MockClient(
        (request) async => jsonResponse([
          facultyJson(id: 2, code: 'SPG', fullName: null, roleNote: null, verified: false),
        ]),
      );

      await tester.pumpWidget(
        MaterialApp(home: FacultyFinderPage(student: testStudent(), client: client)),
      );
      await pumpUntilFound(tester, find.text('SPG'));

      // Unknown full name / office / email / phone are reported as unavailable,
      // never replaced by a plausible-looking placeholder.
      expect(find.text('Not available'), findsWidgets);
      expect(find.textContaining('@'), findsNothing);
      expect(find.textContaining('+91'), findsNothing);
      expect(
        find.textContaining('Department of'),
        findsNothing,
      );
    });

    testWidgets('sends the search term to the backend', (tester) async {
      final queries = <String>[];
      final client = MockClient((request) async {
        queries.add(request.url.queryParameters['q'] ?? '');
        final q = request.url.queryParameters['q'] ?? '';
        return jsonResponse(
          q.isEmpty
              ? [facultyJson()]
              : q.toLowerCase().contains('gangurde')
              ? [facultyJson()]
              : <Map<String, dynamic>>[],
        );
      });

      await tester.pumpWidget(
        MaterialApp(home: FacultyFinderPage(student: testStudent(), client: client)),
      );
      await pumpUntilFound(tester, find.text('Mrs. S. M. Gangurde'));

      await tester.enterText(find.byType(TextField), 'gangurde');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();

      expect(queries.last, 'gangurde');
      // The name appears twice in one card (heading + full-name row).
      expect(find.text('Mrs. S. M. Gangurde'), findsWidgets);
    });

    testWidgets('an unmatched search shows an empty state, not an error', (
      tester,
    ) async {
      final client = MockClient(
        (request) async => jsonResponse(<Map<String, dynamic>>[]),
      );

      await tester.pumpWidget(
        MaterialApp(home: FacultyFinderPage(student: testStudent(), client: client)),
      );
      await pumpUntilFound(
        tester,
        find.textContaining('No faculty records available yet'),
      );

      await tester.enterText(find.byType(TextField), 'zzz');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();

      expect(find.textContaining('No faculty member matches "zzz"'), findsOneWidget);
      expect(find.text('Try Again'), findsNothing);
    });

    testWidgets('a failure shows an error with a working retry', (tester) async {
      var calls = 0;
      final client = MockClient((request) async {
        calls++;
        if (calls == 1) {
          return jsonResponse({'detail': 'boom'}, 500);
        }
        return jsonResponse([facultyJson()]);
      });

      await tester.pumpWidget(
        MaterialApp(home: FacultyFinderPage(student: testStudent(), client: client)),
      );
      await pumpUntilFound(tester, find.textContaining('boom'));

      // An error is never rendered as an empty result.
      expect(find.textContaining('No faculty records'), findsNothing);

      await tester.tap(find.text('Try Again'));
      await tester.pumpAndSettle();
      await pumpUntilFound(tester, find.text('Mrs. S. M. Gangurde'));
      expect(calls, 2);
    });
  });

  group('Lab Finder', () {
    testWidgets('lists the recorded rooms from the official sheet', (
      tester,
    ) async {
      final client = MockClient(
        (request) async => jsonResponse([labJson()]),
      );

      await tester.pumpWidget(
        MaterialApp(home: LabFinderPage(student: testStudent(), client: client)),
      );
      await pumpUntilFound(tester, find.text('Division D Classroom'));

      expect(find.text('M308'), findsWidgets);
      expect(find.text('Block-11'), findsOneWidget);
      expect(find.text('Classroom'), findsOneWidget);
      // No floor is recorded anywhere, so none is shown.
      expect(find.text('Not available'), findsWidgets);
    });

    testWidgets('searching by room code works and unmatched codes stay empty', (
      tester,
    ) async {
      final queries = <String>[];
      final client = MockClient((request) async {
        final q = request.url.queryParameters['q'] ?? '';
        queries.add(q);
        if (q.isEmpty || 'm308'.contains(q.toLowerCase())) {
          return jsonResponse([labJson()]);
        }
        return jsonResponse(<Map<String, dynamic>>[]);
      });

      await tester.pumpWidget(
        MaterialApp(home: LabFinderPage(student: testStudent(), client: client)),
      );
      await pumpUntilFound(tester, find.text('Division D Classroom'));

      await tester.enterText(find.byType(TextField), 'm308');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(queries.last, 'm308');
      expect(find.text('Division D Classroom'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'zzz');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(find.textContaining('No room matches "zzz"'), findsOneWidget);
    });

    testWidgets('an empty directory explains what data is missing', (
      tester,
    ) async {
      final client = MockClient(
        (request) async => jsonResponse(<Map<String, dynamic>>[]),
      );

      await tester.pumpWidget(
        MaterialApp(home: LabFinderPage(student: testStudent(), client: client)),
      );
      await pumpUntilFound(
        tester,
        find.textContaining('No laboratory locations recorded yet'),
      );

      expect(
        find.textContaining('Room numbers, blocks and floors come from the department'),
        findsOneWidget,
      );
    });

    testWidgets('a failure shows an error with a working retry', (tester) async {
      var calls = 0;
      final client = MockClient((request) async {
        calls++;
        if (calls == 1) {
          return jsonResponse({'detail': 'unavailable'}, 503);
        }
        return jsonResponse([labJson()]);
      });

      await tester.pumpWidget(
        MaterialApp(home: LabFinderPage(student: testStudent(), client: client)),
      );
      await pumpUntilFound(tester, find.textContaining('unavailable'));
      expect(find.textContaining('No laboratory locations'), findsNothing);

      await tester.tap(find.text('Try Again'));
      await tester.pumpAndSettle();
      await pumpUntilFound(tester, find.text('Division D Classroom'));
      expect(calls, 2);
    });
  });

  group('Student home entry points', () {
    testWidgets('Home offers Faculty Finder and Labs, and opens the finder', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      // HomePage reads the timetable itself; in a widget test every live request
      // fails fast, which is exactly its error state - the quick-access cards
      // must still work.
      await tester.pumpWidget(MaterialApp(home: HomePage(student: testStudent())));
      await tester.pump(const Duration(milliseconds: 50));

      await pumpUntilFound(tester, find.text('Faculty Finder'));
      expect(find.text('Labs'), findsOneWidget);

      await tester.tap(find.text('Faculty Finder'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.byType(FacultyFinderPage), findsOneWidget);

      // Drain the finder's own (failing) request before the test ends.
      await tester.pumpAndSettle(const Duration(seconds: 1));
    });
  });
}
