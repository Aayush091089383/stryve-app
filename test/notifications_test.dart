// The student notification feed.
//
// What is pinned here:
// * the Home bell shows the unread count and hides itself when nothing is
//   unread (or when the feed cannot be loaded);
// * tapping the bell opens the Notifications screen, which renders loading,
//   empty, error and populated states distinctly - an error is never an empty
//   state;
// * unread rows are visually distinct from read ones;
// * "Mark all as read" and tapping an unread row both call the backend, and the
//   badge on Home clears after coming back;
// * one system-tray alert is raised for a new unread notification, and none
//   when there is nothing new.
//
// Safety: no live backend, no database and no native notifications plugin. Every
// request is answered by a MockClient; the tray presenter is a fake.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:stryve/home_page.dart';
import 'package:stryve/notifications_page.dart';
import 'package:stryve/services/api_cache.dart';
import 'package:stryve/services/notification_service.dart';
import 'package:stryve/student.dart';

const String kToken = 'notifications-test-token';

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

Map<String, dynamic> notificationRow({
  required int id,
  required String message,
  bool isRead = false,
  String title = 'New assignment',
}) => {
  'id': id,
  'title': title,
  'message': message,
  'is_read': isRead,
  'created_at': '2026-10-19T10:00:00',
};

const Map<String, String> jsonHeaders = {'content-type': 'application/json'};

/// Answers the Home timetable request and serves a mutable notification feed,
/// recording every request so the test can see what was actually sent.
class NotificationApi {
  NotificationApi({List<Map<String, dynamic>>? feed})
    : rows = feed ?? <Map<String, dynamic>>[];

  List<Map<String, dynamic>> rows;

  /// When not 200, GET /notifications answers with this status and an error
  /// body instead of the feed.
  int feedStatus = 200;

  final List<String> calls = [];

  late final http.Client client = MockClient((request) async {
    final path = request.url.path;
    calls.add('${request.method} $path');

    if (path == '/timetable') {
      return http.Response('[]', 200, headers: jsonHeaders);
    }
    if (path == '/assignments') {
      return http.Response('[]', 200, headers: jsonHeaders);
    }

    if (path == '/notifications' && request.method == 'GET') {
      if (feedStatus != 200) {
        return http.Response(
          jsonEncode({'detail': 'Server error', 'code': 'error'}),
          feedStatus,
          headers: jsonHeaders,
        );
      }
      return http.Response(jsonEncode(rows), 200, headers: jsonHeaders);
    }

    if (path == '/notifications/read-all' && request.method == 'PUT') {
      final marked = rows.where((row) => row['is_read'] != true).length;
      rows = [
        for (final row in rows) {...row, 'is_read': true},
      ];
      return http.Response(
        jsonEncode({'message': 'Notifications marked as read', 'marked_read': marked}),
        200,
        headers: jsonHeaders,
      );
    }

    final readMatch = RegExp(r'^/notifications/(\d+)/read$').firstMatch(path);
    if (readMatch != null && request.method == 'PUT') {
      final id = int.parse(readMatch.group(1)!);
      final match = rows.where((row) => row['id'] == id).toList();
      if (match.isEmpty) {
        return http.Response(
          jsonEncode({'detail': 'Notification not found', 'code': 'not_found'}),
          404,
          headers: jsonHeaders,
        );
      }
      rows = [
        for (final row in rows)
          if (row['id'] == id) {...row, 'is_read': true} else row,
      ];
      return http.Response(
        jsonEncode(rows.firstWhere((row) => row['id'] == id)),
        200,
        headers: jsonHeaders,
      );
    }

    return http.Response('[]', 200, headers: jsonHeaders);
  });

  List<String> get writes =>
      calls.where((call) => call.startsWith('PUT ')).toList();
}

class FakeTray implements SystemNotifications {
  final List<String> shown = [];

  @override
  Future<void> show(String title, String body) async {
    shown.add('$title|$body');
  }
}

Future<void> pumpHome(
  WidgetTester tester,
  NotificationApi api, {
  SystemNotifications? tray,
}) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  ApiCache.clear();

  await tester.pumpWidget(
    MaterialApp(
      home: HomePage(
        student: studentFixture(),
        client: api.client,
        systemNotifications: tray,
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

Future<void> openNotifications(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('home_bell')));
  await tester.pumpAndSettle();
}

Badge bellBadge(WidgetTester tester) =>
    tester.widget<Badge>(find.byKey(const Key('home_bell_badge')));

Future<void> pumpNotificationsPage(
  WidgetTester tester,
  NotificationApi api,
) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MaterialApp(
      home: NotificationsPage(student: studentFixture(), client: api.client),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  group('Home bell', () {
    testWidgets('shows the unread count, not the total', (tester) async {
      final api = NotificationApi(
        feed: [
          notificationRow(id: 2, message: 'New assignment uploaded: Physics'),
          notificationRow(
            id: 1,
            message: 'New assignment uploaded: Maths',
            isRead: true,
          ),
        ],
      );

      await pumpHome(tester, api);

      expect(bellBadge(tester).isLabelVisible, isTrue);
      expect(
        find.descendant(
          of: find.byKey(const Key('home_bell_badge')),
          matching: find.text('1'),
        ),
        findsOneWidget,
      );
      expect(api.calls, contains('GET /notifications'));
    });

    testWidgets('hides the badge when everything is read', (tester) async {
      final api = NotificationApi(
        feed: [
          notificationRow(
            id: 1,
            message: 'New assignment uploaded: Maths',
            isRead: true,
          ),
        ],
      );

      await pumpHome(tester, api);

      expect(bellBadge(tester).isLabelVisible, isFalse);
    });

    testWidgets('hides the badge when the feed cannot be loaded', (tester) async {
      final api = NotificationApi()..feedStatus = 500;

      await pumpHome(tester, api);

      expect(bellBadge(tester).isLabelVisible, isFalse);
    });

    testWidgets('tapping the bell opens the Notifications screen', (tester) async {
      final api = NotificationApi(
        feed: [
          notificationRow(id: 7, message: 'New assignment uploaded: Physics'),
        ],
      );

      await pumpHome(tester, api);
      await openNotifications(tester);

      expect(find.byType(NotificationsPage), findsOneWidget);
      expect(
        find.text('New assignment uploaded: Physics'),
        findsOneWidget,
      );
    });

    testWidgets('the badge clears after marking everything read', (tester) async {
      final api = NotificationApi(
        feed: [
          notificationRow(id: 7, message: 'New assignment uploaded: Physics'),
        ],
      );

      await pumpHome(tester, api);
      expect(bellBadge(tester).isLabelVisible, isTrue);

      await openNotifications(tester);
      await tester.tap(find.byKey(const Key('mark_all_read')));
      await tester.pumpAndSettle();

      await tester.pageBack();
      await tester.pumpAndSettle();

      expect(api.calls, contains('PUT /notifications/read-all'));
      expect(bellBadge(tester).isLabelVisible, isFalse);
    });
  });

  group('Notifications screen', () {
    testWidgets('renders unread and read rows distinctly', (tester) async {
      final api = NotificationApi(
        feed: [
          notificationRow(id: 2, message: 'New assignment uploaded: Physics'),
          notificationRow(
            id: 1,
            message: 'New assignment uploaded: Maths',
            isRead: true,
          ),
        ],
      );

      await pumpNotificationsPage(tester, api);

      // The unread row carries the active bell and the read one does not.
      expect(find.byIcon(Icons.notifications_active_rounded), findsOneWidget);
      expect(find.byIcon(Icons.notifications_none_rounded), findsOneWidget);
      expect(find.text('1 unread'), findsOneWidget);
      expect(find.byKey(const Key('mark_all_read')), findsOneWidget);
    });

    testWidgets('tapping an unread row marks just that row read', (tester) async {
      final api = NotificationApi(
        feed: [
          notificationRow(id: 2, message: 'New assignment uploaded: Physics'),
          notificationRow(id: 1, message: 'New assignment uploaded: Maths'),
        ],
      );

      await pumpNotificationsPage(tester, api);
      await tester.tap(find.text('New assignment uploaded: Physics'));
      await tester.pumpAndSettle();

      expect(api.writes, ['PUT /notifications/2/read']);
      expect(find.text('1 unread'), findsOneWidget);
    });

    testWidgets('mark all as read updates every row', (tester) async {
      final api = NotificationApi(
        feed: [
          notificationRow(id: 2, message: 'New assignment uploaded: Physics'),
          notificationRow(id: 1, message: 'New assignment uploaded: Maths'),
        ],
      );

      await pumpNotificationsPage(tester, api);
      await tester.tap(find.byKey(const Key('mark_all_read')));
      await tester.pumpAndSettle();

      expect(api.writes, ['PUT /notifications/read-all']);
      expect(find.text('All caught up'), findsOneWidget);
      expect(find.byIcon(Icons.notifications_active_rounded), findsNothing);
      expect(find.byKey(const Key('mark_all_read')), findsNothing);
    });

    testWidgets('an empty feed is an empty state, not an error', (tester) async {
      final api = NotificationApi();

      await pumpNotificationsPage(tester, api);

      expect(find.text('No notifications yet'), findsOneWidget);
      expect(find.textContaining('Could not load'), findsNothing);
    });

    testWidgets('a failed load shows the error, never an empty state', (
      tester,
    ) async {
      final api = NotificationApi()..feedStatus = 500;

      await pumpNotificationsPage(tester, api);

      expect(find.text('Could not load notifications (500)'), findsOneWidget);
      expect(find.text('No notifications yet'), findsNothing);
      expect(find.text('Try Again'), findsOneWidget);
    });
  });

  group('system tray alert', () {
    testWidgets('new unread notification raises exactly one alert', (
      tester,
    ) async {
      final api = NotificationApi(
        feed: [
          notificationRow(id: 4, message: 'New assignment uploaded: Physics'),
          notificationRow(
            id: 3,
            message: 'New assignment uploaded: Maths',
            isRead: true,
          ),
        ],
      );
      final tray = FakeTray();

      await pumpHome(tester, api, tray: tray);

      expect(tray.shown, ['New assignment|New assignment uploaded: Physics']);
    });

    testWidgets('nothing unread raises no alert', (tester) async {
      final api = NotificationApi(
        feed: [
          notificationRow(
            id: 4,
            message: 'New assignment uploaded: Physics',
            isRead: true,
          ),
        ],
      );
      final tray = FakeTray();

      await pumpHome(tester, api, tray: tray);

      expect(tray.shown, isEmpty);
    });
  });
}
