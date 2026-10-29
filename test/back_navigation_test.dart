// Regression tests for the Android back button on the two signed-in shells.
//
// The contract:
// * a successful login clears the navigation stack, so back cannot return to a
//   login/role screen;
// * the first back press on Home / the Teacher Panel asks for confirmation and
//   the second one within two seconds exits;
// * one press alone never leaves the app.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:stryve/home_page.dart';
import 'package:stryve/login_page.dart';
import 'package:stryve/student.dart';
import 'package:stryve/teacher_panel_page.dart';

String _futureExpiry() =>
    DateTime.now().add(const Duration(days: 1)).toUtc().toIso8601String();

http.Response _json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

Student _student() => Student(
  name: 'AAYUSH SHANTARAM TITAME',
  studentId: '71',
  rollNumber: '71',
  college: 'Test College',
  course: 'AI&DS',
  year: 1,
  division: 'D',
  batch: 'D-3',
  token: 'student-token-xyz',
);

/// Sends the same `flutter/navigation` message the engine sends for a system
/// back gesture. `TestWidgetsFlutterBinding.handlePopRoute` is not public, so
/// the channel is driven directly.
Future<void> _pressSystemBack() {
  return TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(
        'flutter/navigation',
        const JSONMessageCodec().encodeMessage(<String, dynamic>{
          'method': 'popRoute',
        }),
        (_) {},
      );
}

/// Records `SystemNavigator.pop()` calls instead of letting the test binding
/// swallow them.
List<MethodCall> _captureExit(WidgetTester tester) {
  final calls = <MethodCall>[];
  const channel = SystemChannels.platform;
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
    call,
  ) async {
    calls.add(call);
    return null;
  });
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      null,
    ),
  );
  return calls;
}

int _exitCount(List<MethodCall> calls) =>
    calls.where((call) => call.method == 'SystemNavigator.pop').length;

MockClient _homeClient() => MockClient((request) async {
  switch (request.url.path) {
    case '/notifications':
      return _json(const <Object>[]);
    case '/timetable':
      return _json(const <Object>[]);
    case '/student/schedule-changes':
      return _json({
        'date': '2026-10-29',
        'count': 0,
        'changes': const <Object>[],
        'message': 'No schedule changes today.',
      });
  }
  return _json({'detail': 'unexpected ${request.url.path}'}, 500);
});

MockClient _panelClient() => MockClient((request) async {
  switch (request.url.path) {
    case '/teacher/me':
      return _json({
        'id': 5,
        'name': 'Dr. Meera Rao',
        'email': 'meera@campussync.edu',
        'role': 'teacher',
        'is_active': true,
        'short_code': null,
        'can_approve_registrations': false,
        'can_review_registrations': false,
      });
    case '/teacher/assignments':
    case '/teacher/free-periods/claims':
      return _json(const <Object>[]);
    case '/teacher/notifications':
      return _json({'unread_count': 0, 'notifications': const <Object>[]});
  }
  return _json({'detail': 'unexpected ${request.url.path}'}, 500);
});

void main() {
  testWidgets('a student login leaves no login screen under Home', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final client = MockClient((request) async {
      if (request.url.path == '/login' && request.method == 'POST') {
        return _json({
          'message': 'Login successful',
          'token': 'student-token-xyz',
          'token_expires_at': _futureExpiry(),
          'student_id': 71,
          'name': 'AAYUSH SHANTARAM TITAME',
          'email': 'aayush@example.com',
          'branch': 'AI&DS',
          'year': 1,
          'division': 'D',
          'batch': 'D-3',
          'roll_number': '71',
        });
      }
      return _json({'detail': 'unexpected ${request.url.path}'}, 500);
    });

    // Start on a screen that pushes the login page, like Role Selection does,
    // so a stack-clearing bug is observable.
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => LoginPage(client: client)),
              ),
              child: const Text('open login'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open login'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).at(0), 'aayush@example.com');
    await tester.enterText(find.byType(TextField).at(1), 'correct-password');
    await tester.tap(find.text('LOGIN'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();

    expect(find.byType(HomePage), findsOneWidget);
    final navigator = tester.state<NavigatorState>(
      find.byType(Navigator).first,
    );
    expect(
      navigator.canPop(),
      isFalse,
      reason: 'login must clear the role/login routes below Home',
    );
  });

  testWidgets('the student Home needs two back presses to exit', (
    tester,
  ) async {
    final exits = _captureExit(tester);
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: HomePage(student: _student(), client: _homeClient()),
      ),
    );
    await tester.pumpAndSettle();

    await _pressSystemBack();
    await tester.pumpAndSettle();

    expect(find.text('Press back again to exit'), findsOneWidget);
    expect(_exitCount(exits), 0, reason: 'one back press must not exit');
    expect(find.byType(HomePage), findsOneWidget);

    await _pressSystemBack();
    await tester.pumpAndSettle();

    expect(_exitCount(exits), 1, reason: 'the second press within 2s exits');
  });

  testWidgets('the teacher panel needs two back presses to exit', (
    tester,
  ) async {
    final exits = _captureExit(tester);
    FlutterSecureStorage.setMockInitialValues(<String, String>{
      'teacher_auth_token': 'teacher-token-xyz',
      'teacher_token_expiry': _futureExpiry(),
      'teacher_id': '5',
      'teacher_name': 'Dr. Meera Rao',
      'teacher_email': 'meera@campussync.edu',
      'teacher_role': 'teacher',
    });
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(home: TeacherPanelPage(client: _panelClient())),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('Teacher Panel'), findsOneWidget);

    await _pressSystemBack();
    await tester.pumpAndSettle();

    expect(find.text('Press back again to exit'), findsOneWidget);
    expect(_exitCount(exits), 0);

    await _pressSystemBack();
    await tester.pumpAndSettle();

    expect(_exitCount(exits), 1);
  });
}
