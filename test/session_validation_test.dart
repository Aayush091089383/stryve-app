// Behavioral tests for student session restoration.
//
// Everything here runs against in-memory secure storage and a mocked HTTP
// client (`package:http/testing.dart`). The live backend and the real SQLite
// database are never touched: `AuthCheckPage` is always pumped with an
// injected `AuthService(client: MockClient(...))`, and the only HTTP traffic
// produced by the screens it opens (HomePage/TeacherPanelPage) is answered by
// flutter_test's built-in 400-returning HttpOverrides.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:campus_sync/config/environment.dart';
import 'package:campus_sync/main.dart';
import 'package:campus_sync/services/auth_service.dart';
import 'package:campus_sync/services/teacher_auth_service.dart';

// ---------------------------------------------------------------------------
// Fixtures and helpers
// ---------------------------------------------------------------------------

const String kStudentToken = 'student-token-abc123';
const String kTeacherToken = 'teacher-token-xyz789';

String _futureExpiry() =>
    DateTime.now().add(const Duration(days: 1)).toUtc().toIso8601String();

String _pastExpiry() =>
    DateTime.now().subtract(const Duration(days: 1)).toUtc().toIso8601String();

/// A complete, locally-unexpired student credential set.
Map<String, String> studentStorage({
  String token = kStudentToken,
  String? expiry,
}) =>
    {
      'auth_token': token,
      'token_expiry': expiry ?? _futureExpiry(),
      'student_id': '1',
      'name': 'Test Student',
      'email': 'test@example.com',
      'roll_number': '71',
      'branch': 'AI&DS',
      'year': '1',
      'division': 'D',
      'batch': 'D-3',
      'college': 'Test College',
    };

/// A complete, locally-unexpired teacher credential set.
Map<String, String> teacherStorage({
  String token = kTeacherToken,
  String? expiry,
}) =>
    {
      'teacher_auth_token': token,
      'teacher_token_expiry': expiry ?? _futureExpiry(),
      'teacher_id': '1',
      'teacher_name': 'Admin User',
      'teacher_email': 'admin@campusync.edu',
      'teacher_role': 'admin',
    };

/// Body returned by the backend `/me` endpoint for an approved student.
const Map<String, dynamic> kApprovedStudentBody = {
  'id': 1,
  'name': 'Test Student',
  'email': 'test@example.com',
  'roll_number': '71',
  'branch': 'AI&DS',
  'year': 1,
  'division': 'D',
  'batch': 'D-3',
  'status': 'approved',
};

http.Response _json(int status, Map<String, dynamic> body) => http.Response(
      jsonEncode(body),
      status,
      headers: {'content-type': 'application/json'},
    );

/// package:http normalises header casing, so look the header up case-insensitively.
String? _authorizationOf(http.BaseRequest request) {
  for (final entry in request.headers.entries) {
    if (entry.key.toLowerCase() == 'authorization') return entry.value;
  }
  return null;
}

/// Pumps frames until [finder] matches, or fails after [maxFrames].
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
    fail('Expected ${describing ?? 'the target widget'} to appear '
        'within $maxFrames frames, but it never did.');
  }
}

/// Boots the real `AuthCheckPage` with injected (mocked) auth services.
///
/// The surface is resized to a phone-like viewport first: the real screens
/// (`RoleSelectionPage`, `TeacherPanelPage`) are laid out for a phone, and the
/// default 800x600 test surface makes them overflow their column by a few
/// pixels, which would fail the test for a layout reason unrelated to auth.
Future<void> _pumpAuthCheck(
  WidgetTester tester, {
  AuthService? studentAuthService,
  TeacherAuthService? teacherAuthService,
}) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MaterialApp(
      home: AuthCheckPage(
        studentAuthService: studentAuthService ?? AuthService(),
        teacherAuthService: teacherAuthService ?? TeacherAuthService(),
      ),
    ),
  );
  // Let initState's async work start.
  await tester.pump();
}

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));
  tearDown(() => FlutterSecureStorage.setMockInitialValues({}));

  // =========================================================================
  // AuthService.validateSession - real service, mocked HTTP
  // =========================================================================
  group('AuthService.validateSession (mocked HTTP)', () {
    test('approved session: calls /me with the saved bearer token and returns true',
        () async {
      FlutterSecureStorage.setMockInitialValues(studentStorage());

      var callCount = 0;
      late http.Request seen;
      final client = MockClient((request) async {
        callCount++;
        seen = request;
        expect(_authorizationOf(request), 'Bearer $kStudentToken');
        return _json(200, kApprovedStudentBody);
      });

      final result = await AuthService(client: client).validateSession();

      expect(result, isTrue);
      expect(callCount, 1, reason: 'restoring a session must hit /me exactly once');
      expect(seen.url.path, '/me');
      expect(seen.url.origin, Uri.parse(Environment.backendUrl).origin);
      expect(seen.method, 'GET');

      // A valid session must not discard the stored credentials.
      final storage = FlutterSecureStorage();
      expect(await storage.read(key: 'auth_token'), kStudentToken);
      expect(await storage.read(key: 'student_id'), '1');
    });

    test('HTTP 401: returns false and clears student credentials', () async {
      FlutterSecureStorage.setMockInitialValues(studentStorage());

      var callCount = 0;
      final client = MockClient((request) async {
        callCount++;
        expect(_authorizationOf(request), 'Bearer $kStudentToken');
        return _json(401, {'detail': 'Invalid or expired token'});
      });

      final result = await AuthService(client: client).validateSession();

      expect(result, isFalse);
      expect(callCount, 1);

      final storage = FlutterSecureStorage();
      expect(await storage.read(key: 'auth_token'), isNull);
      expect(await storage.read(key: 'token_expiry'), isNull);
      expect(await storage.read(key: 'student_id'), isNull);
      expect(await storage.read(key: 'name'), isNull);
    });

    test('HTTP 403: returns false (unapproved student) and clears student credentials',
        () async {
      FlutterSecureStorage.setMockInitialValues(studentStorage());

      var callCount = 0;
      final client = MockClient((request) async {
        callCount++;
        return _json(403, {'detail': 'Student not approved'});
      });

      final result = await AuthService(client: client).validateSession();

      expect(result, isFalse);
      expect(callCount, 1);

      final storage = FlutterSecureStorage();
      expect(await storage.read(key: 'auth_token'), isNull);
      expect(await storage.read(key: 'student_id'), isNull);
    });

    test('HTTP 500: returns null (backend unusable) and preserves credentials', () async {
      FlutterSecureStorage.setMockInitialValues(studentStorage());

      final client = MockClient((request) async => _json(500, {'detail': 'boom'}));

      expect(await AuthService(client: client).validateSession(), isNull);
      expect(
        await FlutterSecureStorage().read(key: 'auth_token'),
        kStudentToken,
      );
    });

    test('network exception: returns null and preserves credentials for retry',
        () async {
      FlutterSecureStorage.setMockInitialValues(studentStorage());

      var callCount = 0;
      final client = MockClient((request) async {
        callCount++;
        throw const SocketException('Connection refused');
      });

      final result = await AuthService(client: client).validateSession();

      expect(result, isNull);
      expect(callCount, 1);
      expect(
        await FlutterSecureStorage().read(key: 'auth_token'),
        kStudentToken,
      );
      expect(await FlutterSecureStorage().read(key: 'student_id'), '1');
    });

    test('timeout: returns null and preserves credentials for retry', () async {
      FlutterSecureStorage.setMockInitialValues(studentStorage());

      final client = MockClient((request) async {
        throw TimeoutException('no response', const Duration(seconds: 10));
      });

      expect(await AuthService(client: client).validateSession(), isNull);
      expect(
        await FlutterSecureStorage().read(key: 'auth_token'),
        kStudentToken,
      );
    });

    test('no stored token: returns false without contacting the backend', () async {
      FlutterSecureStorage.setMockInitialValues({});

      var callCount = 0;
      final client = MockClient((request) async {
        callCount++;
        return _json(200, kApprovedStudentBody);
      });

      expect(await AuthService(client: client).validateSession(), isFalse);
      expect(callCount, 0, reason: 'no token means no /me request at all');
    });

    test('locally expired token: returns false, clears credentials, skips the network',
        () async {
      FlutterSecureStorage.setMockInitialValues(
        studentStorage(expiry: _pastExpiry()),
      );

      var callCount = 0;
      final client = MockClient((request) async {
        callCount++;
        return _json(200, kApprovedStudentBody);
      });

      expect(await AuthService(client: client).validateSession(), isFalse);
      expect(callCount, 0);
      expect(await FlutterSecureStorage().read(key: 'auth_token'), isNull);
    });
  });

  // =========================================================================
  // AuthService.getStudent - restored from secure storage only
  // =========================================================================
  group('AuthService.getStudent (secure storage)', () {
    test('returns the stored Student for an unexpired session', () async {
      FlutterSecureStorage.setMockInitialValues(studentStorage());

      final student = await AuthService().getStudent();

      expect(student, isNotNull);
      expect(student!.name, 'Test Student');
      expect(student.studentId, '1');
      expect(student.rollNumber, '71');
      expect(student.course, 'AI&DS');
      expect(student.year, 1);
      expect(student.division, 'D');
      expect(student.batch, 'D-3');
      expect(student.token, kStudentToken);
    });

    test('returns null and clears credentials for an expired token', () async {
      FlutterSecureStorage.setMockInitialValues(
        studentStorage(expiry: _pastExpiry()),
      );

      expect(await AuthService().getStudent(), isNull);
      expect(await FlutterSecureStorage().read(key: 'auth_token'), isNull);
    });

    test('returns null when no token is stored', () async {
      FlutterSecureStorage.setMockInitialValues({});
      expect(await AuthService().getStudent(), isNull);
    });

    test('returns null and clears credentials for a malformed expiry', () async {
      FlutterSecureStorage.setMockInitialValues(
        studentStorage(expiry: 'not-a-date'),
      );

      expect(await AuthService().getStudent(), isNull);
      expect(await FlutterSecureStorage().read(key: 'auth_token'), isNull);
    });

    test('returns null and clears credentials for incomplete student data', () async {
      final partial = studentStorage()..remove('roll_number');
      FlutterSecureStorage.setMockInitialValues(partial);

      expect(await AuthService().getStudent(), isNull);
      expect(await FlutterSecureStorage().read(key: 'auth_token'), isNull);
    });
  });

  // =========================================================================
  // clearAuthData - student-only deletion
  // =========================================================================
  group('AuthService.clearAuthData (student-only)', () {
    test('removes student keys and preserves teacher credentials', () async {
      FlutterSecureStorage.setMockInitialValues({
        ...studentStorage(),
        ...teacherStorage(),
      });

      final storage = FlutterSecureStorage();
      expect(await storage.read(key: 'auth_token'), isNotNull);
      expect(await storage.read(key: 'teacher_auth_token'), isNotNull);

      await AuthService().clearAuthData();

      expect(await storage.read(key: 'auth_token'), isNull);
      expect(await storage.read(key: 'student_id'), isNull);
      expect(await storage.read(key: 'teacher_auth_token'), kTeacherToken);
      expect(await storage.read(key: 'teacher_role'), 'admin');
    });

    test('clearing student auth leaves the teacher session usable', () async {
      FlutterSecureStorage.setMockInitialValues(teacherStorage());

      final teacherAuth = TeacherAuthService();
      expect(await teacherAuth.getTeacher(), isNotNull);

      await AuthService().clearAuthData();

      final teacherAfter = await teacherAuth.getTeacher();
      expect(teacherAfter, isNotNull);
      expect(teacherAfter!.email, 'admin@campusync.edu');
      expect(teacherAfter.role, 'admin');
      expect(teacherAfter.isAdmin, isTrue);
    });
  });

  // =========================================================================
  // AuthCheckPage - real widget tests of the restoration flow
  // =========================================================================
  group('AuthCheckPage session restoration (widget tests)', () {
    testWidgets('approved session calls /me and opens HomePage', (tester) async {
      FlutterSecureStorage.setMockInitialValues(studentStorage());

      var meCalls = 0;
      final service = AuthService(
        client: MockClient((request) async {
          meCalls++;
          expect(request.url.path, '/me');
          expect(_authorizationOf(request), 'Bearer $kStudentToken');
          return _json(200, kApprovedStudentBody);
        }),
      );

      await _pumpAuthCheck(tester, studentAuthService: service);
      await _pumpUntilFound(
        tester,
        find.byType(HomePage),
        describing: 'HomePage for an approved session',
      );

      expect(meCalls, 1, reason: 'the restored session must be validated with /me');
      expect(find.byType(RoleSelectionPage), findsNothing);
      expect(find.byType(TeacherPanelPage), findsNothing);

      // The validated session keeps its credentials.
      expect(
        await FlutterSecureStorage().read(key: 'auth_token'),
        kStudentToken,
      );

      await tester.pumpAndSettle();
    });

    testWidgets('HTTP 401 on /me opens RoleSelectionPage and clears student credentials',
        (tester) async {
      FlutterSecureStorage.setMockInitialValues(studentStorage());

      var meCalls = 0;
      final service = AuthService(
        client: MockClient((request) async {
          meCalls++;
          return _json(401, {'detail': 'Invalid token'});
        }),
      );

      await _pumpAuthCheck(tester, studentAuthService: service);
      await _pumpUntilFound(
        tester,
        find.byType(RoleSelectionPage),
        describing: 'RoleSelectionPage after a 401',
      );

      expect(meCalls, 1);
      expect(find.byType(HomePage), findsNothing);

      final storage = FlutterSecureStorage();
      expect(await storage.read(key: 'auth_token'), isNull);
      expect(await storage.read(key: 'student_id'), isNull);

      await tester.pumpAndSettle();
    });

    testWidgets('HTTP 403 (pending/rejected student) opens RoleSelectionPage and clears credentials',
        (tester) async {
      FlutterSecureStorage.setMockInitialValues(studentStorage());

      var meCalls = 0;
      final service = AuthService(
        client: MockClient((request) async {
          meCalls++;
          return _json(403, {'detail': 'Student not approved'});
        }),
      );

      await _pumpAuthCheck(tester, studentAuthService: service);
      await _pumpUntilFound(
        tester,
        find.byType(RoleSelectionPage),
        describing: 'RoleSelectionPage after a 403',
      );

      expect(meCalls, 1);
      expect(find.byType(HomePage), findsNothing);
      expect(await FlutterSecureStorage().read(key: 'auth_token'), isNull);

      await tester.pumpAndSettle();
    });

    testWidgets('unreachable backend never opens HomePage and preserves credentials',
        (tester) async {
      FlutterSecureStorage.setMockInitialValues(studentStorage());

      var meCalls = 0;
      final service = AuthService(
        client: MockClient((request) async {
          meCalls++;
          throw const SocketException('Network is unreachable');
        }),
      );

      await _pumpAuthCheck(tester, studentAuthService: service);
      await _pumpUntilFound(
        tester,
        find.byType(RoleSelectionPage),
        describing: 'RoleSelectionPage when the backend is unreachable',
      );

      expect(meCalls, 1);
      expect(find.byType(HomePage), findsNothing);

      // Credentials survive so the student can retry once back online.
      final storage = FlutterSecureStorage();
      expect(await storage.read(key: 'auth_token'), kStudentToken);
      expect(await storage.read(key: 'student_id'), '1');
      expect(await storage.read(key: 'token_expiry'), isNotNull);

      await tester.pumpAndSettle();
    });

    testWidgets('locally expired token never opens HomePage and never calls /me',
        (tester) async {
      FlutterSecureStorage.setMockInitialValues(
        studentStorage(expiry: _pastExpiry()),
      );

      var meCalls = 0;
      final service = AuthService(
        client: MockClient((request) async {
          meCalls++;
          return _json(200, kApprovedStudentBody);
        }),
      );

      await _pumpAuthCheck(tester, studentAuthService: service);
      await _pumpUntilFound(
        tester,
        find.byType(RoleSelectionPage),
        describing: 'RoleSelectionPage for an expired local token',
      );

      expect(find.byType(HomePage), findsNothing);
      expect(meCalls, 0, reason: 'an expired local token is rejected before /me');
      expect(await FlutterSecureStorage().read(key: 'auth_token'), isNull);

      await tester.pumpAndSettle();
    });

    testWidgets('no stored student session falls through to RoleSelectionPage',
        (tester) async {
      FlutterSecureStorage.setMockInitialValues({});

      var meCalls = 0;
      final service = AuthService(
        client: MockClient((request) async {
          meCalls++;
          return _json(200, kApprovedStudentBody);
        }),
      );

      await _pumpAuthCheck(tester, studentAuthService: service);
      await _pumpUntilFound(
        tester,
        find.byType(RoleSelectionPage),
        describing: 'RoleSelectionPage with no stored session',
      );

      expect(meCalls, 0);
      expect(find.byType(HomePage), findsNothing);

      await tester.pumpAndSettle();
    });

    testWidgets('valid teacher session still routes to TeacherPanelPage', (tester) async {
      FlutterSecureStorage.setMockInitialValues(teacherStorage());

      // Teacher sessions are now validated against /teacher/me before the
      // panel opens, so the mocked teacher service must confirm the session.
      final teacherService = TeacherAuthService(
        client: MockClient((request) async {
          expect(request.url.path, '/teacher/me');
          return _json(200, {
            'id': 1,
            'name': 'Admin User',
            'email': 'admin@campusync.edu',
            'role': 'admin',
            'is_active': true,
          });
        }),
      );

      await _pumpAuthCheck(tester, teacherAuthService: teacherService);
      await _pumpUntilFound(
        tester,
        find.byType(TeacherPanelPage),
        describing: 'TeacherPanelPage for a valid teacher session',
      );

      expect(find.byType(RoleSelectionPage), findsNothing);
      expect(find.byType(HomePage), findsNothing);
      expect(
        await FlutterSecureStorage().read(key: 'teacher_auth_token'),
        kTeacherToken,
      );

      await tester.pumpAndSettle();
    });

    testWidgets('expired teacher session routes to RoleSelectionPage', (tester) async {
      FlutterSecureStorage.setMockInitialValues(
        teacherStorage(expiry: _pastExpiry()),
      );

      await _pumpAuthCheck(tester);
      await _pumpUntilFound(
        tester,
        find.byType(RoleSelectionPage),
        describing: 'RoleSelectionPage for an expired teacher session',
      );

      expect(find.byType(TeacherPanelPage), findsNothing);
      expect(find.byType(HomePage), findsNothing);
      expect(
        await FlutterSecureStorage().read(key: 'teacher_auth_token'),
        isNull,
      );

      await tester.pumpAndSettle();
    });

    testWidgets('invalid student session does not consume or clear the teacher session',
        (tester) async {
      FlutterSecureStorage.setMockInitialValues({
        ...studentStorage(),
        ...teacherStorage(),
      });

      final service = AuthService(
        client: MockClient((request) async => _json(403, {'detail': 'Not approved'})),
      );
      final teacherService = TeacherAuthService(
        client: MockClient((request) async => _json(200, {
              'id': 1,
              'name': 'Admin User',
              'email': 'admin@campusync.edu',
              'role': 'admin',
              'is_active': true,
            })),
      );

      await _pumpAuthCheck(
        tester,
        studentAuthService: service,
        teacherAuthService: teacherService,
      );
      await _pumpUntilFound(
        tester,
        find.byType(TeacherPanelPage),
        describing: 'TeacherPanelPage after the student session was rejected',
      );

      final storage = FlutterSecureStorage();
      expect(await storage.read(key: 'auth_token'), isNull);
      expect(await storage.read(key: 'teacher_auth_token'), kTeacherToken);

      await tester.pumpAndSettle();
    });
  });
}
