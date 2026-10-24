// Behavioral tests for the Admin-only "Create Teacher Account" feature.
//
// Everything runs against in-memory secure storage and a MockClient HTTP
// layer: the live ngrok backend and the real SQLite database are never
// touched, and no real account is created.
//
// Note: whether a *regular teacher's* token is actually refused is enforced
// server-side by `POST /teacher/create`'s `require_admin` dependency. These
// tests cover the client contract (the payload, the auth header, the role) and
// that a regular teacher never even attempts the admin calls.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:stryve/services/teacher_auth_service.dart';
import 'package:stryve/teacher_login_page.dart';
import 'package:stryve/teacher_management_page.dart';
import 'package:stryve/teacher_panel_page.dart';
import 'package:stryve/utils/glass_container.dart';
import 'package:stryve/utils/sliding_nav_bar.dart';

// ---------------------------------------------------------------------------
// Fixtures and helpers
// ---------------------------------------------------------------------------

const String kAdminToken = 'admin-create-token-xyz';
const String kStudentToken = 'student-create-token-abc';

const String kNewTeacherName = 'Prof. Ravi Kulkarni';
const String kNewTeacherEmail = 'ravi.kulkarni@campussync.edu';
const String kNewTeacherPassword = 'Campus@2026';

const String kPendingPath = '/teacher/registrations/pending';
const String kListPath = '/teacher/list';
const String kCreatePath = '/teacher/create';

String _futureExpiry() =>
    DateTime.now().add(const Duration(days: 1)).toUtc().toIso8601String();

Map<String, String> teacherStorage({
  String role = 'admin',
  String name = 'Admin User',
}) => {
  'teacher_auth_token': kAdminToken,
  'teacher_token_expiry': _futureExpiry(),
  'teacher_id': '1',
  'teacher_name': name,
  'teacher_email': 'admin@campussync.edu',
  'teacher_role': role,
};

/// A student session stored alongside the teacher's, so the tests can prove
/// the two never interfere.
Map<String, String> studentStorage() => {
  'auth_token': kStudentToken,
  'token_expiry': _futureExpiry(),
  'student_id': '9',
  'name': 'Stored Student',
  'email': 'stored@example.com',
  'roll_number': '71',
  'branch': 'AI&DS',
  'year': '1',
  'division': 'D',
  'batch': 'D-3',
  'college': 'Test College',
};

/// One account exactly as `GET /teacher/list` (`TeacherOut`) returns it.
Map<String, dynamic> teacherJson({
  int id = 2,
  String name = 'Dr. Meera Rao',
  String email = 'meera@campussync.edu',
  String role = 'teacher',
  bool isActive = true,
}) => {
  'id': id,
  'name': name,
  'email': email,
  'role': role,
  'is_active': isActive,
  'created_at': '2026-10-12T10:00:00',
};

http.Response jsonResponse(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

/// The `TeacherOut` the backend returns for a created account.
http.Response createdResponse(http.Request request) {
  final body = jsonDecode(request.body) as Map<String, dynamic>;
  return jsonResponse(
    teacherJson(
      id: 9,
      name: body['name'] as String,
      email: body['email'] as String,
      role: body['role'] as String,
    ),
    200,
  );
}

/// package:http normalises header casing, so look the header up
/// case-insensitively.
String? _authorizationOf(http.BaseRequest request) {
  for (final entry in request.headers.entries) {
    if (entry.key.toLowerCase() == 'authorization') return entry.value;
  }
  return null;
}

/// Records every request the panel makes.
class _Recorder {
  final List<http.Request> requests = [];

  void add(http.Request request) => requests.add(request);

  List<http.Request> to(String path, {String method = 'GET'}) =>
      requests.where((r) => r.url.path == path && r.method == method).toList();

  List<String> get paths => requests.map((r) => r.url.path).toList();
}

/// A mock backend that answers the three endpoints the panel uses.
MockClient _router({
  List<Map<String, dynamic>> pending = const [],
  Future<http.Response> Function(http.Request request)? onList,
  Future<http.Response> Function(http.Request request)? onCreate,
  void Function(http.Request request)? onRequest,
}) {
  return MockClient((request) async {
    onRequest?.call(request);

    if (request.url.path == kPendingPath && request.method == 'GET') {
      return jsonResponse(pending);
    }
    if (request.url.path == kListPath && request.method == 'GET') {
      if (onList != null) return onList(request);
      return jsonResponse(<Map<String, dynamic>>[]);
    }
    if (request.url.path == kCreatePath && request.method == 'POST') {
      if (onCreate != null) return onCreate(request);
      return createdResponse(request);
    }
    if (request.method == 'PATCH' && request.url.path.endsWith('/status')) {
      final id = int.tryParse(request.url.pathSegments[1]) ?? 0;
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      return jsonResponse(
        teacherJson(id: id, isActive: body['is_active'] as bool? ?? true),
      );
    }
    return jsonResponse({
      'detail': 'unexpected ${request.method} ${request.url.path}',
    }, 500);
  });
}

/// Pumps the real screen with an injected mock client and in-memory storage.
///
/// By default it pumps the admin-only Teacher Management screen. With
/// `management: false` it pumps the Teacher Panel shell, which is how the tests
/// check that a regular teacher never gets (or calls) the admin surface.
///
/// The management screen's session-expiry callback is wired exactly like the
/// panel wires it in production: clear the teacher credentials, then replace
/// the route with the teacher login.
Future<void> _pumpPanel(
  WidgetTester tester,
  http.Client client, {
  String role = 'admin',
  Size size = const Size(1080, 2400),
  bool management = true,
}) async {
  FlutterSecureStorage.setMockInitialValues({
    ...teacherStorage(role: role),
    ...studentStorage(),
  });

  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  if (!management) {
    await tester.pumpWidget(
      MaterialApp(home: TeacherPanelPage(client: client)),
    );
    return;
  }

  final navigatorKey = GlobalKey<NavigatorState>();
  await tester.pumpWidget(
    MaterialApp(
      navigatorKey: navigatorKey,
      home: TeacherManagementPage(
        client: client,
        onSessionExpired: () async {
          await TeacherAuthService().clearAuthData();
          navigatorKey.currentState?.pushAndRemoveUntil(
            MaterialPageRoute(builder: (_) => const TeacherLoginPage()),
            (route) => false,
          );
        },
      ),
    ),
  );
}

Future<void> _pumpUntilFound(
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

/// Matches widgets that actually *render* [value] - a label, badge or message.
///
/// Unlike `find.text`, this deliberately ignores an `EditableText` that merely
/// holds the value in a masked password field: holding a secret is not the
/// same as displaying it.
Finder _renderedText(String value) => find.byWidgetPredicate(
  (widget) => widget is Text && (widget.data ?? '').contains(value),
);

/// Opens the create-teacher dialog from the admin section.
Future<void> _openCreateDialog(WidgetTester tester) async {
  await _pumpUntilFound(tester, find.text('CREATE TEACHER ACCOUNT'));
  await tester.ensureVisible(find.text('CREATE TEACHER ACCOUNT'));
  await tester.pump();
  await tester.tap(find.text('CREATE TEACHER ACCOUNT'));
  await tester.pumpAndSettle();
}

/// Fills the three dialog fields (name, email, password).
Future<void> _fillForm(
  WidgetTester tester, {
  String name = kNewTeacherName,
  String email = kNewTeacherEmail,
  String password = kNewTeacherPassword,
}) async {
  // Scoped to the dialog: the screen behind it may carry its own fields.
  final fields = find.descendant(
    of: find.byType(AlertDialog),
    matching: find.byType(TextField),
  );
  await tester.enterText(fields.at(0), name);
  await tester.enterText(fields.at(1), email);
  await tester.enterText(fields.at(2), password);
  await tester.pump();
}

/// Taps submit, then accepts the confirmation dialog.
Future<void> _submitAndConfirm(WidgetTester tester) async {
  await tester.tap(find.text('CREATE ACCOUNT'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Create'));
  await tester.pumpAndSettle();
}

void main() {
  group('Admin-only access', () {
    testWidgets('an admin sees the create control and the teacher list', (
      tester,
    ) async {
      final recorder = _Recorder();
      final client = _router(
        onList: (request) async => jsonResponse([
          teacherJson(
            id: 1,
            name: 'Admin User',
            email: 'admin@campussync.edu',
            role: 'admin',
          ),
          teacherJson(
            id: 2,
            name: 'Dr. Meera Rao',
            email: 'meera@campussync.edu',
          ),
        ]),
        onRequest: recorder.add,
      );

      await _pumpPanel(tester, client);
      await _pumpUntilFound(tester, find.text('CREATE TEACHER ACCOUNT'));
      await _pumpUntilFound(tester, find.text('Dr. Meera Rao'));

      expect(find.text('Teacher Management (Admin Only)'), findsOneWidget);
      expect(find.text('2 accounts'), findsOneWidget);
      expect(find.text('meera@campussync.edu'), findsOneWidget);

      // Status is carried by the switch alone: the old Active/Inactive pill
      // duplicated it and was removed on request.
      expect(find.text('Active'), findsNothing);
      expect(find.text('Inactive'), findsNothing);
      expect(find.text('Account active'), findsNWidgets(2));

      final listRequests = recorder.to(kListPath);
      expect(listRequests, hasLength(1));
      expect(_authorizationOf(listRequests.single), 'Bearer $kAdminToken');

      // The admin token itself is never rendered.
      expect(find.textContaining(kAdminToken), findsNothing);
    });

    testWidgets(
      'a regular teacher gets no admin surface and never calls the admin endpoints',
      (tester) async {
        final recorder = _Recorder();
        final client = _router(onRequest: recorder.add);

        // The Teacher Panel, as a regular teacher sees it.
        await _pumpPanel(tester, client, role: 'teacher', management: false);
        await _pumpUntilFound(tester, find.text('TEACHER'));

        expect(find.text('Teacher Management (Admin Only)'), findsNothing);
        expect(find.text('CREATE TEACHER ACCOUNT'), findsNothing);
        expect(find.text('Teacher Accounts'), findsNothing);
        expect(find.text('Teacher Management'), findsNothing);
        expect(find.text('ADMIN'), findsNothing);

        // The tabs are shared by both roles, but none of them is an admin
        // surface: no teacher management, no account list.
        final destinations = tester
            .widget<SlidingNavBar>(find.byType(SlidingNavBar))
            .destinations;
        expect(destinations.map((destination) => destination.label).toList(), [
          'Home',
          'Assignments',
          'Approvals',
          'Attendance',
          'Profile',
        ]);

        // ... and the admin-only endpoints are not even attempted.
        expect(recorder.paths, isNot(contains(kListPath)));
        expect(recorder.paths, isNot(contains(kCreatePath)));
      },
    );

    testWidgets(
      'the management screen reports a refusal instead of an empty list',
      (tester) async {
        final client = _router(
          onList: (request) async => jsonResponse({
            'detail': 'Admin access required',
            'code': 'FORBIDDEN',
          }, 403),
        );

        await _pumpPanel(tester, client);
        await _pumpUntilFound(
          tester,
          find.textContaining('Admin access required'),
        );

        expect(find.text('No Teacher Accounts'), findsNothing);
        expect(find.text('0 accounts'), findsNothing);
      },
    );

    testWidgets('the dialog is usable on a narrow phone screen', (
      tester,
    ) async {
      final client = _router();

      await _pumpPanel(tester, client, size: const Size(360, 740));
      await _openCreateDialog(tester);

      expect(find.byType(TextField), findsNWidgets(3));
      expect(find.text('Teacher'), findsOneWidget);
      expect(find.text('Admin'), findsOneWidget);
      expect(find.text('CREATE ACCOUNT'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('Creating accounts', () {
    testWidgets(
      'creating a teacher sends the exact payload and refreshes the list',
      (tester) async {
        final recorder = _Recorder();
        var listCalls = 0;
        final client = _router(
          onList: (request) async {
            listCalls++;
            return jsonResponse(
              listCalls == 1
                  ? [teacherJson(id: 1, name: 'Admin User', role: 'admin')]
                  : [
                      teacherJson(id: 1, name: 'Admin User', role: 'admin'),
                      teacherJson(
                        id: 9,
                        name: kNewTeacherName,
                        email: kNewTeacherEmail,
                      ),
                    ],
            );
          },
          onRequest: recorder.add,
        );

        await _pumpPanel(tester, client);
        await _openCreateDialog(tester);
        expect(find.text('Create Teacher Account'), findsOneWidget);

        await _fillForm(tester);
        await tester.tap(find.text('CREATE ACCOUNT'));
        await tester.pumpAndSettle();

        // Confirmation is required first, and nothing is sent until it is given.
        expect(find.text('Create Teacher Account?'), findsOneWidget);
        expect(recorder.to(kCreatePath, method: 'POST'), isEmpty);

        await tester.tap(find.text('Create'));
        await tester.pumpAndSettle();

        final posts = recorder.to(kCreatePath, method: 'POST');
        expect(posts, hasLength(1));
        expect(_authorizationOf(posts.single), 'Bearer $kAdminToken');
        expect(jsonDecode(posts.single.body), {
          'name': kNewTeacherName,
          'email': kNewTeacherEmail,
          'password': kNewTeacherPassword,
          'role': 'teacher',
        });

        expect(find.text('Create Teacher Account'), findsNothing);
        expect(
          find.text('Teacher account created successfully'),
          findsOneWidget,
        );
        expect(listCalls, 2);
        expect(find.text('2 accounts'), findsOneWidget);
        expect(find.text(kNewTeacherName), findsOneWidget);

        // The password is never echoed into the UI.
        expect(_renderedText(kNewTeacherPassword), findsNothing);
      },
    );

    testWidgets('choosing the Admin role sends role admin', (tester) async {
      final recorder = _Recorder();
      final client = _router(onRequest: recorder.add);

      await _pumpPanel(tester, client);
      await _openCreateDialog(tester);
      await _fillForm(tester);

      await tester.tap(find.text('Admin'));
      await tester.pump();
      await _submitAndConfirm(tester);

      final posts = recorder.to(kCreatePath, method: 'POST');
      expect(posts, hasLength(1));
      expect(jsonDecode(posts.single.body)['role'], 'admin');
      expect(find.text('Teacher account created successfully'), findsOneWidget);
    });

    testWidgets(
      'the password is masked, can be revealed, never shown as text',
      (tester) async {
        final client = _router();

        await _pumpPanel(tester, client);
        await _openCreateDialog(tester);
        await _fillForm(tester);

        final passwordField = find.byType(TextField).at(2);
        expect(tester.widget<TextField>(passwordField).obscureText, isTrue);
        // No widget renders the secret while it is masked.
        expect(_renderedText(kNewTeacherPassword), findsNothing);

        await tester.tap(find.byIcon(Icons.visibility_rounded));
        await tester.pump();
        expect(tester.widget<TextField>(passwordField).obscureText, isFalse);

        await tester.tap(find.byIcon(Icons.visibility_off_rounded));
        await tester.pump();
        expect(tester.widget<TextField>(passwordField).obscureText, isTrue);
      },
    );

    testWidgets('the confirmation step never echoes the password', (
      tester,
    ) async {
      final recorder = _Recorder();
      final client = _router(onRequest: recorder.add);

      await _pumpPanel(tester, client);
      await _openCreateDialog(tester);
      await _fillForm(tester);

      await tester.tap(find.text('CREATE ACCOUNT'));
      await tester.pumpAndSettle();

      // The confirmation names the account and its role, never the secret.
      expect(find.text('Create Teacher Account?'), findsOneWidget);
      expect(_renderedText(kNewTeacherPassword), findsNothing);
      // ...but it does name the account being created.
      expect(_renderedText(kNewTeacherEmail), findsOneWidget);

      // Both dialogs are on screen, so target the topmost Cancel.
      await tester.tap(find.widgetWithText(TextButton, 'Cancel').last);
      await tester.pumpAndSettle();

      // Cancelling the confirmation sends nothing and keeps the form.
      expect(recorder.to(kCreatePath, method: 'POST'), isEmpty);
      expect(find.text('Create Teacher Account'), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField).at(1)).controller!.text,
        kNewTeacherEmail,
      );
    });

    testWidgets('invalid input is rejected locally and nothing is sent', (
      tester,
    ) async {
      final recorder = _Recorder();
      final client = _router(onRequest: recorder.add);

      await _pumpPanel(tester, client);
      await _openCreateDialog(tester);

      // Empty form.
      await tester.tap(find.text('CREATE ACCOUNT'));
      await tester.pumpAndSettle();
      expect(find.text("Enter the teacher's name."), findsOneWidget);
      expect(find.text('Enter an email address.'), findsOneWidget);
      expect(find.text('Enter a password.'), findsOneWidget);
      expect(find.text('Create Teacher Account?'), findsNothing);
      expect(recorder.to(kCreatePath, method: 'POST'), isEmpty);

      // Malformed email and too-short password.
      await _fillForm(tester, email: 'not-an-email', password: 'Abc12');
      await tester.tap(find.text('CREATE ACCOUNT'));
      await tester.pumpAndSettle();
      expect(find.text('Enter a valid email address.'), findsOneWidget);
      expect(find.text('Use at least 8 characters.'), findsOneWidget);
      expect(recorder.to(kCreatePath, method: 'POST'), isEmpty);

      // Long enough, but no digit.
      await _fillForm(tester, password: 'abcdefghij');
      await tester.tap(find.text('CREATE ACCOUNT'));
      await tester.pumpAndSettle();
      expect(
        find.text('Include at least one letter and one number.'),
        findsOneWidget,
      );
      expect(find.text('Create Teacher Account?'), findsNothing);
      expect(recorder.to(kCreatePath, method: 'POST'), isEmpty);
    });

    testWidgets('a duplicate email keeps the form open and explains why', (
      tester,
    ) async {
      final recorder = _Recorder();
      final client = _router(
        onCreate: (request) async =>
            jsonResponse({'detail': 'Email already registered'}, 409),
        onRequest: recorder.add,
      );

      await _pumpPanel(tester, client);
      await _openCreateDialog(tester);
      await _fillForm(tester);
      await _submitAndConfirm(tester);

      expect(find.text('Email already registered'), findsOneWidget);
      expect(find.text('Teacher account created successfully'), findsNothing);

      // The admin can correct the address without retyping everything.
      expect(find.text('Create Teacher Account'), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField).at(1)).controller!.text,
        kNewTeacherEmail,
      );
      expect(recorder.to(kCreatePath, method: 'POST'), hasLength(1));
    });

    testWidgets('backend validation errors are surfaced', (tester) async {
      final client = _router(
        onCreate: (request) async => jsonResponse({
          'detail': [
            {
              'loc': ['body', 'email'],
              'msg': 'value is not a valid email address',
              'type': 'value_error',
            },
          ],
        }, 422),
      );

      await _pumpPanel(tester, client);
      await _openCreateDialog(tester);
      await _fillForm(tester);
      await _submitAndConfirm(tester);

      expect(find.text('value is not a valid email address'), findsOneWidget);
      expect(find.text('Teacher account created successfully'), findsNothing);
    });

    testWidgets('a 403 reports insufficient permission and keeps the session', (
      tester,
    ) async {
      final client = _router(
        onCreate: (request) async =>
            jsonResponse({'detail': 'Admin access required'}, 403),
      );

      await _pumpPanel(tester, client);
      await _openCreateDialog(tester);
      await _fillForm(tester);
      await _submitAndConfirm(tester);

      expect(
        find.text('Your account is not permitted to create teacher accounts.'),
        findsOneWidget,
      );
      expect(find.byType(TeacherLoginPage), findsNothing);
      expect(find.text('Create Teacher Account'), findsOneWidget);
      expect(
        await FlutterSecureStorage().read(key: 'teacher_auth_token'),
        kAdminToken,
      );
    });

    testWidgets('a network failure keeps the form and a retry can succeed', (
      tester,
    ) async {
      final recorder = _Recorder();
      var attempts = 0;
      final client = _router(
        onCreate: (request) async {
          attempts++;
          if (attempts == 1) {
            throw const SocketException('Network is unreachable');
          }
          return createdResponse(request);
        },
        onRequest: recorder.add,
      );

      await _pumpPanel(tester, client);
      await _openCreateDialog(tester);
      await _fillForm(tester);
      await _submitAndConfirm(tester);

      expect(attempts, 1);
      expect(
        find.textContaining('Could not reach the Stryve server'),
        findsOneWidget,
      );
      expect(find.text('Teacher account created successfully'), findsNothing);
      // The typed details survive, so the admin can retry.
      expect(find.text('Create Teacher Account'), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField).at(0)).controller!.text,
        kNewTeacherName,
      );

      await _submitAndConfirm(tester);
      expect(attempts, 2);
      expect(find.text('Teacher account created successfully'), findsOneWidget);
      expect(find.text('Create Teacher Account'), findsNothing);
    });

    testWidgets('the submit action cannot be fired twice', (tester) async {
      final completer = Completer<http.Response>();
      final recorder = _Recorder();
      final client = _router(
        onCreate: (request) async {
          return completer.future;
        },
        onRequest: recorder.add,
      );

      await _pumpPanel(tester, client);
      await _openCreateDialog(tester);
      await _fillForm(tester);

      await tester.tap(find.text('CREATE ACCOUNT'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Create'));
      // Bounded pumps: the request never completes here, so pumpAndSettle would
      // advance the fake clock past the dialog's own request timeout.
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 60));
      }

      expect(recorder.to(kCreatePath, method: 'POST'), hasLength(1));
      expect(find.text('CREATING...'), findsOneWidget);
      expect(
        tester
            .widget<GlassButton>(
              find.widgetWithText(GlassButton, 'CREATING...'),
            )
            .onPressed,
        isNull,
      );

      // Tapping the in-flight button does nothing: no second confirmation,
      // no second request.
      await tester.tap(find.text('CREATING...'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));
      expect(find.text('Create Teacher Account?'), findsNothing);
      expect(recorder.to(kCreatePath, method: 'POST'), hasLength(1));

      completer.complete(
        jsonResponse(
          teacherJson(id: 9, name: kNewTeacherName, email: kNewTeacherEmail),
        ),
      );
      await tester.pumpAndSettle();

      expect(recorder.to(kCreatePath, method: 'POST'), hasLength(1));
      expect(find.text('Teacher account created successfully'), findsOneWidget);
    });

    testWidgets(
      'a 401 while creating clears the admin session and returns to teacher login',
      (tester) async {
        final client = _router(
          onCreate: (request) async => jsonResponse({
            'detail': 'Invalid or expired session, please log in again',
          }, 401),
        );

        await _pumpPanel(tester, client);
        await _openCreateDialog(tester);
        await _fillForm(tester);
        await _submitAndConfirm(tester);
        await _pumpUntilFound(
          tester,
          find.byType(TeacherLoginPage),
          describing: 'TeacherLoginPage after a 401 during creation',
        );

        expect(find.text('Teacher account created successfully'), findsNothing);

        final storage = FlutterSecureStorage();
        expect(await storage.read(key: 'teacher_auth_token'), isNull);
        expect(await storage.read(key: 'teacher_role'), isNull);
        // The student session is untouched.
        expect(await storage.read(key: 'auth_token'), kStudentToken);
      },
    );
  });

  group('Teacher list', () {
    testWidgets('an unreachable teacher list offers a retry', (tester) async {
      var listCalls = 0;
      final client = _router(
        onList: (request) async {
          listCalls++;
          if (listCalls == 1) {
            throw const SocketException('Network is unreachable');
          }
          return jsonResponse([teacherJson(id: 2, name: 'Dr. Meera Rao')]);
        },
      );

      await _pumpPanel(tester, client);
      await _pumpUntilFound(
        tester,
        find.textContaining('Could not reach the Stryve server'),
      );

      expect(find.text('Retry'), findsOneWidget);
      expect(
        await FlutterSecureStorage().read(key: 'teacher_auth_token'),
        kAdminToken,
      );

      await tester.tap(find.text('Retry'));
      await _pumpUntilFound(
        tester,
        find.text('Dr. Meera Rao'),
        describing: 'the teacher list after retrying',
      );

      expect(listCalls, 2);
      expect(find.text('1 accounts'), findsOneWidget);
    });

    testWidgets('an empty teacher list shows an empty state', (tester) async {
      final client = _router();

      await _pumpPanel(tester, client);
      await _pumpUntilFound(tester, find.text('No Teacher Accounts'));

      expect(find.text('0 accounts'), findsOneWidget);
      expect(
        find.text('Accounts you create will appear here.'),
        findsOneWidget,
      );
    });

    testWidgets('a 401 on the teacher list clears the session and signs out', (
      tester,
    ) async {
      final client = _router(
        onList: (request) async => jsonResponse({
          'detail': 'Invalid or expired session, please log in again',
        }, 401),
      );

      await _pumpPanel(tester, client);
      await _pumpUntilFound(
        tester,
        find.byType(TeacherLoginPage),
        describing: 'TeacherLoginPage after a 401 on the teacher list',
      );

      expect(
        await FlutterSecureStorage().read(key: 'teacher_auth_token'),
        isNull,
      );
      expect(
        await FlutterSecureStorage().read(key: 'auth_token'),
        kStudentToken,
      );
    });

    testWidgets('the stored password is masked until the eye is tapped', (
      tester,
    ) async {
      const secret = 'Abc123!@#xyz';
      final client = _router(
        onList: (request) async => jsonResponse(<Map<String, dynamic>>[
          {
            ...teacherJson(
              id: 11,
              name: 'Teacher 1',
              email: 'teacher1@stryve.edu',
            ),
            'plain_password': secret,
          },
        ]),
      );

      await _pumpPanel(tester, client);
      await _pumpUntilFound(tester, find.text('Teacher 1'));

      expect(
        find.text('Password: \u2022\u2022\u2022\u2022\u2022\u2022\u2022\u2022'),
        findsOneWidget,
      );
      expect(find.textContaining(secret), findsNothing);

      await tester.tap(find.byTooltip('Show password'));
      await tester.pump();

      expect(find.text('Password: $secret'), findsOneWidget);
      expect(find.byTooltip('Hide password'), findsOneWidget);

      await tester.tap(find.byTooltip('Hide password'));
      await tester.pump();

      expect(find.textContaining(secret), findsNothing);
    });

    testWidgets('an admin card has no password row at all', (tester) async {
      final client = _router(
        onList: (request) async => jsonResponse(<Map<String, dynamic>>[
          {
            ...teacherJson(
              id: 10,
              name: 'Stryve Admin',
              email: 'Stryve.edu@gmail.com',
              role: 'admin',
            ),
            'can_review_registrations': true,
          },
        ]),
      );

      await _pumpPanel(tester, client);
      await _pumpUntilFound(tester, find.text('Stryve Admin'));

      expect(find.textContaining('Password:'), findsNothing);
      expect(find.text('No stored password for this account'), findsNothing);
      expect(find.byTooltip('Show password'), findsNothing);
      expect(find.byTooltip('Copy password'), findsNothing);
      // The role pill stays - only the status pill went away.
      expect(find.text('ADMIN'), findsOneWidget);
    });

    testWidgets('a teacher card still shows the password row', (tester) async {
      final client = _router(
        onList: (request) async => jsonResponse(<Map<String, dynamic>>[
          {
            ...teacherJson(
              id: 11,
              name: 'Teacher 1',
              email: 'teacher1@stryve.edu',
            ),
            'plain_password': 'Abc123!@#xyz',
          },
        ]),
      );

      await _pumpPanel(tester, client);
      await _pumpUntilFound(tester, find.text('Teacher 1'));

      expect(find.byTooltip('Show password'), findsOneWidget);
      expect(find.text('TEACHER'), findsOneWidget);
    });

    testWidgets('an account with no stored password says so', (tester) async {
      final client = _router(
        onList: (request) async => jsonResponse(<Map<String, dynamic>>[
          teacherJson(id: 2, name: 'Old Teacher'),
        ]),
      );

      await _pumpPanel(tester, client);
      await _pumpUntilFound(tester, find.text('Old Teacher'));

      expect(find.text('No stored password for this account'), findsOneWidget);
      expect(find.byTooltip('Show password'), findsNothing);
    });

    testWidgets('the active switch PATCHes the status endpoint', (
      tester,
    ) async {
      final recorder = _Recorder();
      final client = _router(
        onList: (request) async => jsonResponse(<Map<String, dynamic>>[
          teacherJson(id: 11, name: 'Teacher 1', email: 'teacher1@stryve.edu'),
        ]),
        onRequest: recorder.add,
      );

      await _pumpPanel(tester, client);
      await _pumpUntilFound(tester, find.text('Teacher 1'));

      final activeSwitch = find.descendant(
        of: find.widgetWithText(SwitchListTile, 'Account active'),
        matching: find.byType(Switch),
      );
      expect(activeSwitch, findsOneWidget);

      await tester.tap(activeSwitch);
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }

      final patches = recorder.to('/teacher/11/status', method: 'PATCH');
      expect(patches, hasLength(1), reason: 'one toggle, one request');
      expect(jsonDecode(patches.single.body), {'is_active': false});
      expect(_authorizationOf(patches.single), 'Bearer $kAdminToken');
    });
  });
}
