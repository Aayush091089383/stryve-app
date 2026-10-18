// Regression tests for the student Home greeting.
//
// The greeting used to render `student.name.split(' ').first`, i.e. it assumed
// the first token of the stored name is the student's given name. That is not
// true for every registry row (roll 4 is stored as "SHINDE AJAY ANGATRAO", and
// roll 5 as "JAGTAP SIMA ASHOK"), so the line could present a surname where the
// student's own name belongs. These tests pin the corrected behaviour: the whole
// stored name is rendered, the ellipsis absorbs a long name, and the course and
// division stay visible.
//
// Safety: no live backend and no database. The timetable request is answered by
// a MockClient; any other request is answered by flutter_test's built-in
// HttpOverrides, which returns HTTP 400 without touching the network.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:campus_sync/home_page.dart';
import 'package:campus_sync/services/api_cache.dart';
import 'package:campus_sync/student.dart';

// ---------------------------------------------------------------------------
// Fixtures and helpers
// ---------------------------------------------------------------------------

/// A stored name whose FIRST token is the family name, not the given name.
/// Taken from the registry (roll 4).
const String kSurnameFirst = 'SHINDE AJAY ANGATRAO';

/// The reporter's own row (roll 71), stored given/father/family.
const String kGivenFirst = 'AAYUSH SHANTARAM TITAME';

/// The longest stored name in the registry (roll 25), used for the narrow
/// viewport case.
const String kLongName = 'BHAGYASHRI VITTHALSINGH GIRASE';

Student studentNamed(
  String name, {
  String rollNumber = '4',
  String course = 'Computer',
  String division = 'D',
  String batch = 'D-1',
}) => Student(
  name: name,
  studentId: rollNumber,
  rollNumber: rollNumber,
  college: 'Test College',
  course: course,
  year: 1,
  division: division,
  batch: batch,
  // Unique per roll so an ApiCache entry left by another test can never be
  // served here.
  token: 'greeting-test-token-$rollNumber',
);

/// Answers the timetable request with an empty list. The greeting is part of the
/// page header, so it renders without depending on the live backend.
http.Client emptyTimetableClient() => MockClient(
  (request) async =>
      http.Response('[]', 200, headers: {'content-type': 'application/json'}),
);

Finder textWithData(String data) =>
    find.byWidgetPredicate((widget) => widget is Text && widget.data == data);

Future<void> pumpHome(
  WidgetTester tester,
  Student student, {
  Size size = const Size(1080, 2400),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  // The tabs cache responses by token; keep each test independent of the others.
  ApiCache.clear();

  await tester.pumpWidget(
    MaterialApp(home: HomePage(student: student, client: emptyTimetableClient())),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  testWidgets(
    'a surname-first stored name is rendered in full, not reduced to its first token',
    (tester) async {
      await pumpHome(tester, studentNamed(kSurnameFirst));

      final nameFinder = textWithData(kSurnameFirst);
      expect(
        nameFinder,
        findsOneWidget,
        reason: 'the greeting must show the whole stored name',
      );

      final nameText = tester.widget<Text>(nameFinder);
      expect(nameText.maxLines, 1);
      expect(nameText.overflow, TextOverflow.ellipsis);

      // The old behaviour presented the first token as if it were the name.
      expect(find.text(kSurnameFirst.split(' ').first), findsNothing);
      expect(find.text('SHINDE \u2022 Computer \u2022 D'), findsNothing);
      expect(find.textContaining('SHINDE \u2022'), findsNothing);
    },
  );

  testWidgets('the course and division stay visible beside the name', (
    tester,
  ) async {
    await pumpHome(
      tester,
      studentNamed(kSurnameFirst, course: 'Computer', division: 'D'),
    );

    expect(find.text(' \u2022 Computer \u2022 D'), findsOneWidget);
  });

  testWidgets('a long name at a narrow viewport does not overflow the header', (
    tester,
  ) async {
    // 400 logical pixels is narrower than the common phone width, so the name
    // has to truncate rather than overflow the row.
    await pumpHome(
      tester,
      studentNamed(kLongName, rollNumber: '25', batch: 'D-2'),
      size: const Size(400, 1600),
    );

    final nameFinder = textWithData(kLongName);
    expect(nameFinder, findsOneWidget);
    expect(tester.widget<Text>(nameFinder).maxLines, 1);

    // A RenderFlex overflow surfaces here instead of passing silently.
    expect(tester.takeException(), isNull);
  });

  testWidgets('a given-first stored name is still shown in full', (
    tester,
  ) async {
    await pumpHome(
      tester,
      studentNamed(kGivenFirst, rollNumber: '71', course: 'AI&DS', batch: 'D-3'),
    );

    expect(textWithData(kGivenFirst), findsOneWidget);
    expect(find.text(kGivenFirst.split(' ').first), findsNothing);
  });

  // -------------------------------------------------------------------------
  // Welcome line: time-of-day + title-case first name, and actually visible.
  // -------------------------------------------------------------------------

  final Finder greetingFinder = find.byWidgetPredicate(
    (widget) => widget is Text && (widget.data ?? '').startsWith('Good '),
  );

  testWidgets('the welcome line greets the first name in title case', (
    tester,
  ) async {
    await pumpHome(
      tester,
      studentNamed(kGivenFirst, rollNumber: '71', course: 'AI&DS', batch: 'D-3'),
    );

    expect(greetingFinder, findsOneWidget);
    expect(
      tester.widget<Text>(greetingFinder).data,
      matches(RegExp(r'^Good (morning|afternoon|evening) Aayush$')),
    );
    // The full official name is still on its own line, not folded into the
    // greeting (registry rows are not all stored given-name-first).
    expect(textWithData(kGivenFirst), findsOneWidget);
  });

  testWidgets('a family-name-first row is greeted with its first token, '
      'and keeps the full name', (tester) async {
    await pumpHome(tester, studentNamed(kSurnameFirst));

    expect(
      tester.widget<Text>(greetingFinder).data,
      matches(RegExp(r'^Good (morning|afternoon|evening) Shinde$')),
    );
    expect(
      textWithData(kSurnameFirst),
      findsOneWidget,
      reason: 'the full stored name stays visible on its own line',
    );
  });

  testWidgets('the welcome line sits below the app bar, not behind it', (
    tester,
  ) async {
    // Home uses extendBodyBehindAppBar, so the body starts at y=0 and the
    // header used to be painted under the translucent bar - the greeting was
    // in the tree but unreadable.
    await pumpHome(tester, studentNamed(kGivenFirst, rollNumber: '71'));

    final greetingTop = tester.getTopLeft(greetingFinder).dy;
    final appBarBottom = tester.getBottomLeft(find.byType(AppBar)).dy;

    expect(
      greetingTop,
      greaterThanOrEqualTo(appBarBottom),
      reason: 'the greeting must clear the app bar, not hide behind it',
    );
    expect(
      greetingTop,
      lessThanOrEqualTo(appBarBottom + 24),
      reason: 'and sit right below it - the app bar is not counted twice',
    );
    expect(tester.widget<Text>(greetingFinder).style!.color!.a, 1.0);
  });
}
