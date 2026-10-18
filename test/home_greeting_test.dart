// Tests for the student Home header.
//
// The header used to carry a second line - the full stored name plus
// "course • division" - because the greeting took the first token of the name
// and some registry rows are stored family-name-first (roll 4 "SHINDE AJAY
// ANGATRAO", so the token is the surname). That line was removed on request:
// it duplicated the greeting and cluttered the header.
//
// What is pinned here now:
// * the header shows exactly one identity line, "Good <part of day> <First>";
// * the full stored name and the course/division are NOT rendered on Home (the
//   accepted tradeoff is that a family-name-first row greets with the surname -
//   the database has no separate given-name field);
// * the greeting sits below the app bar instead of behind it (Home uses
//   extendBodyBehindAppBar);
// * the longest stored name does not overflow the header at a narrow viewport.
//
// Safety: no live backend and no database. The timetable request is answered by
// a MockClient; any other request is answered by flutter_test's built-in
// HttpOverrides, which returns HTTP 400 without touching the network.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:stryve/home_page.dart';
import 'package:stryve/services/api_cache.dart';
import 'package:stryve/student.dart';

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

/// The single identity line in the header.
final Finder greetingFinder = find.byWidgetPredicate(
  (widget) => widget is Text && (widget.data ?? '').startsWith('Good '),
);

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
  testWidgets('the full stored name is not rendered on Home', (tester) async {
    await pumpHome(
      tester,
      studentNamed(kGivenFirst, rollNumber: '71', course: 'AI&DS', batch: 'D-3'),
    );

    expect(
      textWithData(kGivenFirst),
      findsNothing,
      reason: 'the header no longer repeats the official name',
    );
  });

  testWidgets('the course and division are not rendered on Home', (
    tester,
  ) async {
    await pumpHome(
      tester,
      studentNamed(kSurnameFirst, course: 'Computer', division: 'D'),
    );

    expect(find.text(' \u2022 Computer \u2022 D'), findsNothing);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Text && (widget.data ?? '').contains(' \u2022 '),
      ),
      findsNothing,
      reason: 'no course/division line is left in the header',
    );
  });

  testWidgets('the greeting is time of day plus a title-case first name', (
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
  });

  testWidgets('a family-name-first row greets with the first token', (
    tester,
  ) async {
    // Accepted tradeoff: the greeting token is whatever the registry stores
    // first. The database has no separate given-name field to do better.
    await pumpHome(tester, studentNamed(kSurnameFirst));

    expect(
      tester.widget<Text>(greetingFinder).data,
      matches(RegExp(r'^Good (morning|afternoon|evening) Shinde$')),
    );
    expect(textWithData(kSurnameFirst), findsNothing);
  });

  testWidgets('the header never repeats the stored full name', (tester) async {
    for (final name in [kSurnameFirst, kGivenFirst, kLongName]) {
      await pumpHome(tester, studentNamed(name, rollNumber: name.hashCode.abs().toString()));
      expect(
        textWithData(name),
        findsNothing,
        reason: '"$name" must not appear in the header',
      );
    }
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

  testWidgets('the longest stored name does not overflow the header', (
    tester,
  ) async {
    // 400 logical pixels is narrower than the common phone width.
    await pumpHome(
      tester,
      studentNamed(kLongName, rollNumber: '25', batch: 'D-2'),
      size: const Size(400, 1600),
    );

    expect(
      tester.widget<Text>(greetingFinder).data,
      matches(RegExp(r'^Good (morning|afternoon|evening) Bhagyashri$')),
    );
    expect(textWithData(kLongName), findsNothing);
    // A RenderFlex overflow surfaces here instead of passing silently.
    expect(tester.takeException(), isNull);
  });
}
