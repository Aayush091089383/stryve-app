// Student navigation + timetable day-selector regressions.
//
// What is pinned here:
// * Home starts only the request it needs: the Assignments tab must not call
//   GET /assignments until it is actually opened (it used to load up front,
//   competing with the timetable request);
// * a tab, once opened, keeps its state and never refetches when switching
//   back and forth;
// * the bottom-navigation container has no outline (transparent border) and no
//   drop shadow while keeping its geometry;
// * the day selector pill actually interpolates between its two existing
//   states instead of snapping;
// * the Assignments destination opens the dedicated Assignments screen as a
//   tab body, and it is the only way to assignments (the Home quick-access
//   grid no longer links to TasksPage);
// * Home's scroll view leaves the floating nav bar's footprint clear at the
//   bottom, so the "Latest Update" card is never clipped;
// * the Timetable header carries a back arrow that pops the pushed screen back
//   to Home, and is harmless when Timetable is the root route.
//
// Safety: no live backend, no database. Every request is answered by a
// MockClient; ApiCache is cleared so tests cannot serve each other's data.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:campus_sync/assignments_page.dart';
import 'package:campus_sync/home_page.dart';
import 'package:campus_sync/services/api_cache.dart';
import 'package:campus_sync/student.dart';
import 'package:campus_sync/tasks.dart';
import 'package:campus_sync/timetable.dart';
import 'package:campus_sync/utils/glass_container.dart';
import 'package:campus_sync/utils/sliding_nav_bar.dart';

const String kToken = 'student-navigation-token';

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

Map<String, dynamic> timetableEntry({
  required String day,
  String subject = 'MATH',
}) => {
  'day': day,
  'start_time': '10:15',
  'end_time': '11:15',
  'subject': subject,
  'faculty': 'SMG',
  'room': 'M308',
  'division': 'D',
  'batch': null,
  'is_break': false,
  'is_free_period': false,
  'entry_type': 'lecture',
};

/// Records every path the page asks for and answers each with valid JSON.
class RecordingClient {
  final List<String> paths = [];

  late final http.Client client = MockClient((request) async {
    paths.add(request.url.path);
    if (request.url.path == '/timetable') {
      return http.Response(
        jsonEncode([
          timetableEntry(day: 'Monday'),
          timetableEntry(day: 'Tuesday'),
        ]),
        200,
        headers: {'content-type': 'application/json'},
      );
    }
    if (request.url.path == '/assignments') {
      return http.Response('[]', 200, headers: {'content-type': 'application/json'});
    }
    return http.Response('[]', 200, headers: {'content-type': 'application/json'});
  });
}

Future<void> pumpHomeWith(
  WidgetTester tester,
  RecordingClient recorder, {
  Size size = const Size(1080, 2400),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  ApiCache.clear();

  await tester.pumpWidget(
    MaterialApp(
      home: HomePage(student: studentFixture(), client: recorder.client),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  group('student tab navigation', () {
    testWidgets('Home does not load the Assignments tab until it is opened', (
      tester,
    ) async {
      final recorder = RecordingClient();
      await pumpHomeWith(tester, recorder);

      expect(
        recorder.paths,
        ['/timetable'],
        reason: 'only the visible tab may talk to the backend',
      );
      expect(find.byType(TasksPage), findsNothing);
      // The quick-access grid is five cards, no Tasks card.
      expect(find.byKey(const Key('home_tasks_card')), findsNothing);
      expect(find.text('Tasks'), findsNothing);
      expect(find.text('Attendance'), findsOneWidget);

      // Home scrolls under the floating nav bar, so its padding must include
      // the bar's footprint or the last card sits behind it.
      final homeScroll = tester.widget<SingleChildScrollView>(
        find.byType(SingleChildScrollView),
      );
      final homePadding = homeScroll.padding! as EdgeInsets;
      expect(
        homePadding.bottom,
        greaterThanOrEqualTo(HomePage.kGlassNavInset),
        reason: 'the Latest Update card must clear the nav bar',
      );
      expect(
        homePadding.bottom,
        greaterThan(100),
        reason: 'the nav inset is added to the existing bottom padding',
      );
      // `extendBodyBehindAppBar` paints the body under the app bar, so the
      // header's top inset has to clear it - a fixed 16 spoke a greeting that
      // was hidden behind the bar.
      expect(
        homePadding.top,
        greaterThanOrEqualTo(kToolbarHeight),
        reason: 'the greeting must start below the glass app bar',
      );
      expect(homePadding.left, 20);
      expect(homePadding.right, 20);
    });

    testWidgets('opening Assignments fetches once and switching back does not refetch', (
      tester,
    ) async {
      final recorder = RecordingClient();
      await pumpHomeWith(tester, recorder);

      await tester.tap(find.byKey(const Key('nav_assignments')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.byType(AssignmentsPage), findsOneWidget);
      expect(find.byType(TasksPage), findsNothing);
      expect(find.text('All Assignments'), findsOneWidget);
      expect(
        recorder.paths.where((p) => p == '/assignments'),
        hasLength(1),
      );

      // Home, then back to Assignments: state is kept, so no second request.
      await tester.tap(find.byIcon(Icons.home_outlined));
      await tester.pump();
      expect(find.byType(AssignmentsPage), findsNothing);

      await tester.tap(find.byKey(const Key('nav_assignments')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.byType(AssignmentsPage), findsOneWidget);
      expect(
        recorder.paths.where((p) => p == '/assignments'),
        hasLength(1),
        reason: 'switching tabs must not refetch',
      );
    });

    testWidgets('the Assignments destination opens the dedicated screen', (
      tester,
    ) async {
      final recorder = RecordingClient();
      await pumpHomeWith(tester, recorder);

      await tester.tap(find.byKey(const Key('nav_assignments')));
      await tester.pumpAndSettle();

      expect(find.byType(AssignmentsPage), findsOneWidget);
      expect(
        find.byType(TasksPage),
        findsNothing,
        reason: 'Assignments is its own screen, not the Tasks screen',
      );
      // `embedded` must not bring its own Scaffold/app bar into HomePage's.
      expect(
        find.byType(Scaffold),
        findsOneWidget,
        reason: 'the tab body adds no second Scaffold',
      );
      // The tab body must clear HomePage's floating glass navigation bar.
      expect(
        tester.widget<AssignmentsPage>(find.byType(AssignmentsPage)).bottomInset,
        HomePage.kGlassNavInset,
        reason: 'the embedded list leaves room for the nav bar',
      );
      expect(
        HomePage.kGlassNavInset,
        greaterThan(0),
        reason: 'a zero inset would put the last card behind the bar',
      );
      expect(find.text('All Assignments'), findsOneWidget);
      // Opening it reads the same endpoint exactly once.
      expect(
        recorder.paths.where((p) => p == '/assignments'),
        hasLength(1),
      );
    });

    testWidgets('the bottom navigation container has no outline', (
      tester,
    ) async {
      final recorder = RecordingClient();
      await pumpHomeWith(tester, recorder);

      final navGlass = tester.widget<GlassContainer>(
        find
            .ancestor(
              of: find.byType(SlidingNavBar),
              matching: find.byType(GlassContainer),
            )
            .first,
      );

      expect(navGlass.borderColor, Colors.transparent);
      // ...and no drop shadow, which reads as an outline on a near-white bar.
      expect(navGlass.shadowColor, Colors.transparent);
      // Geometry is untouched.
      expect(navGlass.borderRadius, 24);
      expect(navGlass.padding, const EdgeInsets.symmetric(horizontal: 8, vertical: 8));
    });

    testWidgets('the selected pill slides to its tab instead of snapping', (
      tester,
    ) async {
      final recorder = RecordingClient();
      await pumpHomeWith(tester, recorder);

      final pill = find.byKey(const Key('nav_pill'));
      final bar = find.byType(SlidingNavBar);
      expect(pill, findsOneWidget);

      final slotWidth = tester.getSize(bar).width / 3;
      final pillElement = tester.element(pill);
      final barLeft = tester.getTopLeft(bar).dx;
      final startLeft = tester.getTopLeft(pill).dx;

      // It starts in Home's slot, floating inside it.
      expect(startLeft - barLeft, closeTo(SlidingNavBar.pillInset, 0.5));
      expect(
        tester.getSize(pill).width,
        closeTo(slotWidth - SlidingNavBar.pillInset * 2, 0.5),
      );

      await tester.tap(find.byKey(const Key('nav_assignments')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 125));

      final midway = tester.getTopLeft(pill).dx;
      expect(
        midway,
        greaterThan(startLeft + 1),
        reason: 'half-way through, the pill has already left Home\'s slot',
      );
      expect(
        midway,
        lessThan(startLeft + slotWidth - 1),
        reason: '250 ms have not elapsed, so it must not have arrived yet',
      );

      await tester.pumpAndSettle();

      expect(
        tester.getTopLeft(pill).dx - startLeft,
        closeTo(slotWidth, 1),
        reason: 'the pill lands exactly one slot to the right',
      );
      expect(
        identical(tester.element(pill), pillElement),
        isTrue,
        reason: 'same widget element throughout: it slid, it did not remount',
      );
    });

    testWidgets('every tab label is visible, selected or not', (tester) async {
      final recorder = RecordingClient();
      await pumpHomeWith(tester, recorder);

      final bar = find.byType(SlidingNavBar);
      for (final label in ['Home', 'Assignments', 'Profile']) {
        expect(
          find.descendant(of: bar, matching: find.text(label)),
          findsOneWidget,
          reason: '"$label" stays visible whether or not it is selected',
        );
      }
    });
  });

  group('timetable day pill', () {
    GlassContainer chip(WidgetTester tester, String day) {
      return tester.widget<GlassContainer>(
        find.ancestor(of: find.text(day), matching: find.byType(GlassContainer)).first,
      );
    }

    testWidgets('the selected pill interpolates instead of snapping', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      ApiCache.clear();

      await tester.pumpWidget(
        MaterialApp(
          home: TimetablePage(student: studentFixture(), client: RecordingClient().client),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      // A day that is not the default selection.
      final before = chip(tester, 'Tuesday').opacity;
      expect(before, 0.5);

      await tester.tap(find.text('Tuesday'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 90));

      final mid = chip(tester, 'Tuesday').opacity;
      expect(
        mid,
        greaterThan(0.5),
        reason: 'the pill must be visibly part-way through its transition',
      );
      expect(mid, lessThan(0.8));

      await tester.pumpAndSettle();
      expect(chip(tester, 'Tuesday').opacity, 0.8);
    });

    testWidgets('an unrelated rebuild does not restart the pill tween', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      ApiCache.clear();

      await tester.pumpWidget(
        MaterialApp(
          home: TimetablePage(student: studentFixture(), client: RecordingClient().client),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      await tester.tap(find.text('Tuesday'));
      await tester.pumpAndSettle();
      expect(chip(tester, 'Tuesday').opacity, 0.8);

      // Force a rebuild of the page with no state change.
      tester.element(find.byType(TimetablePage)).markNeedsBuild();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));

      expect(
        chip(tester, 'Tuesday').opacity,
        0.8,
        reason: 'the settled pill must not animate again on a rebuild',
      );
    });
  });

  // Timetable is a pushed route (Home's Quick Access card), so its header
  // carries the way back.
  group('timetable back arrow', () {
    testWidgets('the back arrow pops the pushed Timetable back to Home', (
      tester,
    ) async {
      final recorder = RecordingClient();
      await pumpHomeWith(tester, recorder);

      await tester.tap(find.text('Timetable'));
      await tester.pumpAndSettle();
      expect(find.byType(TimetablePage), findsOneWidget);

      await tester.tap(find.byIcon(Icons.arrow_back_rounded));
      await tester.pumpAndSettle();

      expect(
        find.byType(TimetablePage),
        findsNothing,
        reason: 'the header arrow is the way back to Home',
      );
      expect(find.text('Quick Access'), findsOneWidget);
    });

    testWidgets('the arrow is a no-op when Timetable is the root route', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      ApiCache.clear();

      await tester.pumpWidget(
        MaterialApp(
          home: TimetablePage(
            student: studentFixture(),
            client: RecordingClient().client,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      await tester.tap(find.byIcon(Icons.arrow_back_rounded));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.byType(TimetablePage), findsOneWidget);
    });
  });
}
