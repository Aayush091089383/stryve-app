// Push notification wiring.
//
// What is pinned here:
// * Home starts push for the signed-in student, with that student's own token -
//   the phone is never registered for an account it is not signed in as;
// * push is silent when it cannot start: a blank session token or a platform
//   without Firebase must not throw, and must not make a request;
// * disposing a service that never started is safe.
//
// Safety: no live backend, no Firebase project, no native plugin. Firebase is
// not initialised in the test environment, so the service's own failure path is
// what runs; every HTTP call goes through a MockClient that records itself.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:stryve/home_page.dart';
import 'package:stryve/services/push_notification_service.dart';
import 'package:stryve/student.dart';

const String kToken = 'push-test-token';

Student studentFixture() => Student(
  name: 'AAYUSH SHANTARAM TITAME',
  studentId: '71',
  rollNumber: '71',
  college: 'Test College',
  course: 'Computer',
  year: 1,
  division: 'D',
  batch: 'D-3',
  token: kToken,
);

/// Records what Home asked of it instead of touching Firebase.
class RecordingPushService extends PushNotificationService {
  final List<String> startedWith = [];
  bool disposed = false;

  @override
  Future<void> start({required String authToken, VoidCallback? onMessage}) async {
    startedWith.add(authToken);
  }

  @override
  Future<void> dispose() async {
    disposed = true;
  }
}

void main() {
  testWidgets('Home registers this phone with the signed-in student', (
    tester,
  ) async {
    final requests = <String>[];
    final client = MockClient((request) async {
      requests.add(request.url.path);
      return http.Response('[]', 200, headers: {'content-type': 'application/json'});
    });

    final push = RecordingPushService();

    await tester.pumpWidget(
      MaterialApp(
        home: HomePage(
          student: studentFixture(),
          client: client,
          pushNotifications: push,
        ),
      ),
    );
    await tester.pump();

    expect(push.startedWith, [kToken]);

    // The page is torn down the way a logout would tear it down.
    await tester.pumpWidget(const SizedBox.shrink());
    expect(push.disposed, isTrue);
  });

  test('an unavailable Firebase is a silent no-op, not an error', () async {
    final requests = <String>[];
    final client = MockClient((request) async {
      requests.add(request.url.path);
      return http.Response('{}', 200);
    });

    // The test environment has no Firebase app, which is exactly the "no
    // google-services.json / no Play Services" case on a real phone: the
    // service must swallow it and leave the app untouched.
    final service = PushNotificationService(client: client);
    await service.start(authToken: kToken);
    await service.dispose();

    expect(requests, isEmpty);
  });

  test('a blank session token starts nothing and calls nothing', () async {
    final requests = <String>[];
    final client = MockClient((request) async {
      requests.add(request.url.path);
      return http.Response('{}', 200);
    });

    final service = PushNotificationService(client: client);
    await service.start(authToken: '   ');
    await service.dispose();

    expect(requests, isEmpty);
  });
}
