// Behavioral tests for the student registration lookup and login flow.
//
// Everything runs against a MockClient HTTP layer: the live backend and the
// real SQLite database are never touched and no real account is created.
//
// These tests pin down client behaviour that the backend contract depends on:
//   * the register page consumes the MASKED name the public lookup returns
//     (it must never expect the official full name);
//   * the roll-number field debounces, so typing does not hammer an
//     unauthenticated, rate-limited endpoint;
//   * a 429 from that endpoint is surfaced as a rate-limit message, not as
//     "roll number not found";
//   * a pending/rejected account's real reason (the backend's `detail`) is
//     shown on login instead of "Invalid email or password".

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:campus_sync/login_page.dart';

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

const String kOfficialName = 'SHUBHAM SURESH AHIRE';
const String kMaskedName = 'S****** S***** A****';

/// Successful lookup payload as the backend now returns it.
Map<String, dynamic> lookupBody({String roll = '7'}) => {
  'roll_number': roll,
  'masked_name': kMaskedName,
  'branch': 'Computer',
  'year': 1,
  'division': 'D',
  'batch': 'D-3',
};

/// Records every request the widget makes and answers from a route table.
class RecordingClient {
  RecordingClient(this._handler);

  final Future<http.Response> Function(http.Request request) _handler;
  final List<http.Request> requests = [];

  late final MockClient client = MockClient((request) async {
    requests.add(request);
    return _handler(request);
  });

  List<String> get paths => requests.map((r) => r.url.path).toList();

  List<http.Request> get lookupRequests =>
      requests.where((r) => r.url.path.startsWith('/students/lookup')).toList();

  List<http.Request> get loginRequests =>
      requests.where((r) => r.url.path == '/login').toList();

  List<http.Request> get registerRequests =>
      requests.where((r) => r.url.path == '/register').toList();
}

http.Response json200(Map<String, dynamic> body) =>
    http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json'});

http.Response jsonError(int status, String detail) => http.Response(
  jsonEncode({'detail': detail, 'code': 'ERROR'}),
  status,
  headers: {'content-type': 'application/json'},
);

Widget wrap(Widget child) => MaterialApp(home: child);

/// Give the page enough room that the submit button is on screen.
/// (The registration form is long; the default 800x600 test viewport cuts the
/// button off, and a real tap must be delivered.)
void useTallViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(1200, 2600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

void main() {
  group('student registration lookup', () {
    testWidgets('shows the masked name from the lookup, never a full name', (
      tester,
    ) async {
      final recorder = RecordingClient((request) async => json200(lookupBody()));
      await tester.pumpWidget(wrap(StudentRegisterPage(client: recorder.client)));

      await tester.enterText(find.byType(TextField).first, '7');
      await tester.pump(const Duration(milliseconds: 500)); // let the debounce fire
      await tester.pumpAndSettle();

      expect(recorder.lookupRequests.length, 1);
      expect(recorder.lookupRequests.single.url.path, '/students/lookup/7');

      expect(find.text('Verified Student Details'), findsOneWidget);
      expect(find.text('Name (masked)'), findsOneWidget);
      expect(find.text(kMaskedName), findsOneWidget);
      expect(
        find.text(kOfficialName),
        findsNothing,
        reason: 'the public lookup must not deliver the official full name',
      );
      expect(find.text('Computer'), findsOneWidget);
      expect(find.text('D-3'), findsOneWidget);
    });

    testWidgets('debounces typing into a single lookup request', (tester) async {
      final recorder = RecordingClient((request) async => json200(lookupBody(roll: '72')));
      await tester.pumpWidget(wrap(StudentRegisterPage(client: recorder.client)));

      final field = find.byType(TextField).first;
      await tester.enterText(field, '7');
      await tester.pump(const Duration(milliseconds: 100));
      await tester.enterText(field, '72');
      await tester.pump(const Duration(milliseconds: 100));
      await tester.enterText(field, '721');
      await tester.pump(const Duration(milliseconds: 100));

      expect(
        recorder.lookupRequests,
        isEmpty,
        reason: 'nothing should be sent while the student is still typing',
      );

      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();

      expect(recorder.lookupRequests.length, 1, reason: 'one request per typing pause');
      expect(recorder.lookupRequests.single.url.path, '/students/lookup/721');
    });

    testWidgets('a 429 is reported as rate limiting, not as a wrong roll number', (
      tester,
    ) async {
      final recorder = RecordingClient(
        (request) async => jsonError(429, 'Too many roll number lookups. Please wait a moment and try again.'),
      );
      await tester.pumpWidget(wrap(StudentRegisterPage(client: recorder.client)));

      await tester.enterText(find.byType(TextField).first, '7');
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();

      expect(find.textContaining('Too many roll number lookups'), findsOneWidget);
      expect(find.text('Verified Student Details'), findsNothing);
    });

    testWidgets('an unknown roll number shows the backend detail and no details card', (
      tester,
    ) async {
      final recorder = RecordingClient(
        (request) async => jsonError(404, 'Roll number not found in college registry.'),
      );
      await tester.pumpWidget(wrap(StudentRegisterPage(client: recorder.client)));

      await tester.enterText(find.byType(TextField).first, '999');
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();

      expect(find.textContaining('Roll number not found'), findsOneWidget);
      expect(find.text('Verified Student Details'), findsNothing);
    });

    testWidgets('registration is blocked until a lookup has succeeded', (tester) async {
      useTallViewport(tester);
      final recorder = RecordingClient((request) async => json200(lookupBody()));
      await tester.pumpWidget(wrap(StudentRegisterPage(client: recorder.client)));

      final fields = find.byType(TextField);
      await tester.enterText(fields.at(0), '7');
      await tester.enterText(fields.at(1), 'campus.csync.student7@gmail.com');
      await tester.enterText(fields.at(2), 'Campus@2026');
      await tester.enterText(fields.at(3), 'Campus@2026');

      await tester.tap(find.text('SUBMIT FOR APPROVAL'));
      await tester.pumpAndSettle();

      expect(recorder.registerRequests, isEmpty);
      expect(find.textContaining('wait for lookup to complete'), findsOneWidget);
    });

    testWidgets('a completed lookup sends only roll number, email and password', (
      tester,
    ) async {
      useTallViewport(tester);
      final recorder = RecordingClient((request) async {
        if (request.url.path.startsWith('/students/lookup')) {
          return json200(lookupBody());
        }
        return json200({
          'message': 'Registration submitted for approval',
          'student_id': 12,
          'status': 'pending',
        });
      });
      await tester.pumpWidget(wrap(StudentRegisterPage(client: recorder.client)));

      final fields = find.byType(TextField);
      await tester.enterText(fields.at(0), '7');
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();

      await tester.enterText(fields.at(1), 'campus.csync.student7@gmail.com');
      await tester.enterText(fields.at(2), 'Campus@2026');
      await tester.enterText(fields.at(3), 'Campus@2026');
      await tester.tap(find.text('SUBMIT FOR APPROVAL'));
      await tester.pumpAndSettle();

      expect(recorder.registerRequests.length, 1);
      final body = jsonDecode(recorder.registerRequests.single.body) as Map<String, dynamic>;
      expect(body.keys.toSet(), {'roll_number', 'email', 'password', 'confirm_password'});
      expect(body['roll_number'], '7');
      expect(
        jsonEncode(body),
        isNot(contains(kMaskedName)),
        reason: 'official details are derived server-side, never sent by the client',
      );
      expect(find.textContaining('approval'), findsWidgets);
    });
  });

  group('student login error reporting', () {
    testWidgets('a pending account shows the backend reason, not "invalid password"', (
      tester,
    ) async {
      final recorder = RecordingClient(
        (request) async => jsonError(
          403,
          'Your account is pending approval or has been rejected. Please contact administration.',
        ),
      );
      await tester.pumpWidget(wrap(LoginPage(client: recorder.client)));

      final fields = find.byType(TextField);
      await tester.enterText(fields.at(0), 'campus.csync.student7@gmail.com');
      await tester.enterText(fields.at(1), 'Campus@2026');
      await tester.tap(find.text('LOGIN'));
      await tester.pumpAndSettle();

      expect(find.textContaining('pending approval'), findsOneWidget);
      expect(find.text('Invalid email or password'), findsNothing);
    });

    testWidgets('invalid credentials still report the real 401 detail', (tester) async {
      final recorder = RecordingClient(
        (request) async => jsonError(401, 'Invalid email or password'),
      );
      await tester.pumpWidget(wrap(LoginPage(client: recorder.client)));

      final fields = find.byType(TextField);
      await tester.enterText(fields.at(0), 'nobody@example.com');
      await tester.enterText(fields.at(1), 'Wrong@2026');
      await tester.tap(find.text('LOGIN'));
      await tester.pumpAndSettle();

      expect(find.text('Invalid email or password'), findsOneWidget);
    });
  });

  // -------------------------------------------------------------------------
  // Network failures and non-404 failures (no backend reachable)
  // -------------------------------------------------------------------------
  group('student registration network errors', () {
    testWidgets('a failed lookup connection shows a connection message and no details card', (
      tester,
    ) async {
      final recorder = RecordingClient(
        (request) async => throw http.ClientException('connection refused'),
      );
      await tester.pumpWidget(wrap(StudentRegisterPage(client: recorder.client)));

      await tester.enterText(find.byType(TextField).first, '7');
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();

      expect(recorder.lookupRequests.length, 1);
      expect(find.textContaining('Could not connect to server'), findsOneWidget);
      expect(
        find.text('Verified Student Details'),
        findsNothing,
        reason: 'a failed lookup must never be rendered as a valid result',
      );
    });

    testWidgets('an ineligible roll number surfaces the backend detail, not "not found"', (
      tester,
    ) async {
      final recorder = RecordingClient(
        (request) async => jsonError(
          400,
          'Only first-year students are eligible for registration.',
        ),
      );
      await tester.pumpWidget(wrap(StudentRegisterPage(client: recorder.client)));

      await tester.enterText(find.byType(TextField).first, '34');
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();

      expect(find.textContaining('Only first-year students'), findsOneWidget);
      expect(find.text('Verified Student Details'), findsNothing);
    });

    testWidgets('a failed registration connection shows a message and keeps the page', (
      tester,
    ) async {
      useTallViewport(tester);
      final recorder = RecordingClient((request) async {
        if (request.url.path.startsWith('/students/lookup')) {
          return json200(lookupBody());
        }
        throw http.ClientException('connection refused');
      });
      await tester.pumpWidget(wrap(StudentRegisterPage(client: recorder.client)));

      final fields = find.byType(TextField);
      await tester.enterText(fields.at(0), '7');
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();

      await tester.enterText(fields.at(1), 'campus.csync.student7@gmail.com');
      await tester.enterText(fields.at(2), 'Campus@2026');
      await tester.enterText(fields.at(3), 'Campus@2026');
      await tester.tap(find.text('SUBMIT FOR APPROVAL'));
      await tester.pumpAndSettle();

      expect(recorder.registerRequests.length, 1);
      expect(
        find.textContaining('Could not connect to CampusSync server'),
        findsOneWidget,
      );
      expect(
        find.text('Create Student Account'),
        findsOneWidget,
        reason: 'a network error must not pop the registration page',
      );
    });
  });
}
