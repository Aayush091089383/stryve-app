// Widget tests for the announcements feed.
//
// What matters here:
// * the four UI states are distinct - a failed load is never rendered as "no
//   announcements", and the empty state only appears after a successful, empty
//   response;
// * a post shows everything the student needs (title, message, author, date,
//   and the audience when the post is restricted);
// * Home's Announcements card actually opens the feed, so the quick card stops
//   being a dead tile.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:stryve/announcements_page.dart';
import 'package:stryve/home_page.dart';
import 'package:stryve/services/api_cache.dart';
import 'package:stryve/student.dart';

const String kToken = 'test-token';

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

Map<String, dynamic> announcementJson({
  int id = 1,
  String title = 'Mid-term schedule',
  String message = 'Labs move to Friday this week.',
  String authorName = 'Prof. S. M. Gaikwad',
  String createdAt = '2026-10-20T09:30:00',
  int? year,
  String? division,
}) => {
  'id': id,
  'title': title,
  'message': message,
  'author_id': 7,
  'author_name': authorName,
  'created_at': createdAt,
  'year': year,
  'division': division,
};

http.Response jsonResponse(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

/// Serves the feed; `status` and `body` can be changed between requests so a
/// retry can succeed after a failure.
class FeedClient {
  FeedClient({this.status = 200, this.body = const []});

  int status;
  Object body;
  final List<String> paths = [];

  late final http.Client client = MockClient((request) async {
    paths.add(request.url.path);
    if (request.url.path == '/announcements') {
      return jsonResponse(body, status);
    }
    // Everything else Home asks for: an empty list is fine.
    return jsonResponse(const []);
  });
}

Future<void> pumpFeed(WidgetTester tester, FeedClient feed) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MaterialApp(
      home: AnnouncementsPage(student: studentFixture(), client: feed.client),
    ),
  );
  await tester.pump();
  // Let the loading -> content transition finish; the AnimatedSwitcher keeps
  // its outgoing child on stage until then.
  await tester.pumpAndSettle();
}

void main() {
  group('announcements feed', () {
    testWidgets('an empty feed says so', (tester) async {
      final feed = FeedClient();
      await pumpFeed(tester, feed);

      expect(feed.paths, contains('/announcements'));
      expect(find.text('No announcements yet'), findsOneWidget);
      expect(find.text('Try Again'), findsNothing);
    });

    testWidgets('a post shows its title, message, author and date', (
      tester,
    ) async {
      final feed = FeedClient(
        body: [
          announcementJson(
            title: 'Mid-term schedule',
            message: 'Labs move to Friday this week.',
            authorName: 'Prof. S. M. Gaikwad',
            createdAt: '2026-10-20T09:30:00',
          ),
        ],
      );
      await pumpFeed(tester, feed);

      expect(find.text('Mid-term schedule'), findsOneWidget);
      expect(find.text('Labs move to Friday this week.'), findsOneWidget);
      expect(find.text('Prof. S. M. Gaikwad'), findsOneWidget);
      expect(find.text('20 Oct 2026'), findsOneWidget);
      expect(find.text('1 announcement'), findsOneWidget);
      // A college-wide post shows no audience line.
      expect(find.textContaining('Division D'), findsNothing);
      expect(find.text('No announcements yet'), findsNothing);
    });

    testWidgets('a restricted post names its audience', (tester) async {
      final feed = FeedClient(
        body: [announcementJson(year: 1, division: 'D')],
      );
      await pumpFeed(tester, feed);

      expect(find.text('Year 1 • Division D'), findsOneWidget);
    });

    testWidgets('a failed load shows an error, never the empty state', (
      tester,
    ) async {
      final feed = FeedClient(status: 500, body: {'detail': 'boom'});
      await pumpFeed(tester, feed);

      expect(find.textContaining('Could not load announcements (500)'), findsOneWidget);
      expect(find.text('Try Again'), findsOneWidget);
      expect(find.text('No announcements yet'), findsNothing);

      // Retry hits the backend again and renders the real (empty) feed.
      feed.status = 200;
      feed.body = const [];
      await tester.tap(find.text('Try Again'));
      await tester.pump();
      await tester.pumpAndSettle();

      expect(find.text('No announcements yet'), findsOneWidget);
      expect(find.text('Try Again'), findsNothing);
    });
  });

  group('Home quick access', () {
    testWidgets('the Announcements card opens the feed', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      ApiCache.clear();

      final feed = FeedClient();
      await tester.pumpWidget(
        MaterialApp(
          home: HomePage(student: studentFixture(), client: feed.client),
        ),
      );
      await tester.pump();
      await tester.pumpAndSettle();

      await tester.tap(find.text('Announcements'));
      await tester.pump();
      await tester.pumpAndSettle();

      expect(find.byType(AnnouncementsPage), findsOneWidget);
      expect(find.text('No announcements yet'), findsOneWidget);
    });
  });
}
