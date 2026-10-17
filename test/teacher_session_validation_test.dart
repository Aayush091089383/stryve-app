// Behavioral tests for teacher/admin session restoration.
//
// Mirrors test/session_validation_test.dart for the teacher path: everything
// runs against in-memory secure storage and a mocked HTTP client, so the live
// backend and the real SQLite database are never touched. The only HTTP the
// opened screens perform (TeacherPanelPage's own refresh calls) is answered by
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

const String kTeacherToken = 'teacher-token-xyz789';
const String kStudentToken = 'student-token-abc123';

String _futureExpiry() =>
    DateTime.now().add(const Duration(days: 1)).toUtc().toIso8601String();

String _pastExpiry() =>
    DateTime.now().subtract(const Duration(days: 1)).toUtc().toIso8601String();

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

/// A complete, locally-unexpired student credential set.
Map<String, String> studentStorage() => {
      'auth_token': kStudentToken,
      'token_expiry': _futureExpiry(),
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

/// Body returned by `/teacher/me` for a valid, active teacher.
const Map<String, dynamic> kTeacherBody = {
  'id': 1,
  'name': 'Admin User',
  'email': 'admin@campusync.edu',
  'role': 'admin',
  'is_active': true,
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

/// Boots the real `AuthCheckPage` with injected (mocked) auth services on a
/// phone-sized surface, so the real screens are not rejected for the 800x600
/// test window being shorter than a phone.
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
  await tester.pump();
}

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));
  tearDown(() => FlutterSecureStorage.setMockInitialValues({}));

  // =========================================================================
  // TeacherAuthService.validateSession - real service, mocked HTTP
  // =========================================================================
  group('TeacherAuthService.validateSession (mocked HTTP)', () {
    test('valid session: calls /teacher/me with the saved bearer token and returns true',
        () async {
      FlutterSecureStorage.setMockInitialValues(teacherStorage());

      var callCount = 0;
      late http.Request seen;
      final service = TeacherAuthService(
        client: MockClient((request) async {
          callCount++;
          seen = request;
          expect(_authorizationOf(request), 'Bearer $kTeacherToken');
          return _json(200, kTeacherBody);
        }),
      );

      expect(await service.validateSession(), isTrue);
      expect(callCount, 1, reason: 'restoring a teacher session must hit /teacher/me once');
      expect(seen.method, 'GET');
      expect(seen.url.path, '/teacher/me');
      expect(seen.url.origin, Uri.parse(Environment.backendUrl).origin);

      // A confirmed session keeps its credentials.
      expect(
        await FlutterSecureStorage().read(key: 'teacher_auth_token'),
        kTeacherToken,
      );
    });

    test('HTTP 401: returns false and clears teacher credentials only', () async {
      FlutterSecureStorage.setMockInitialValues({
        ...teacherStorage(),
        ...studentStorage(),
      });

      var callCount = 0;
      final service = TeacherAuthService(
        client: MockClient((request) async {
          callCount++;
          expect(_authorizationOf(request), 'Bearer $kTeacherToken');
          return _json(401, {'detail': 'Invalid or expired session'});
        }),
      );

      expect(await service.validateSession(), isFalse);
      expect(callCount, 1);

      final storage = FlutterSecureStorage();
      expect(await storage.read(key: 'teacher_auth_token'), isNull);
      expect(await storage.read(key: 'teacher_token_expiry'), isNull);
      expect(await storage.read(key: 'teacher_id'), isNull);
      expect(await storage.read(key: 'teacher_role'), isNull);

      // The student session stored alongside must be untouched.
      expect(await storage.read(key: 'auth_token'), kStudentToken);
      expect(await storage.read(key: 'student_id'), '1');
    });

    test('HTTP 403 (deactivated teacher): returns false and clears teacher credentials',
        () async {
      FlutterSecureStorage.setMockInitialValues(teacherStorage());

      var callCount = 0;
      final service = TeacherAuthService(
        client: MockClient((request) async {
          callCount++;
          return _json(403, {'detail': 'Teacher account is deactivated'});
        }),
      );

      expect(await service.validateSession(), isFalse);
      expect(callCount, 1);

      final storage = FlutterSecureStorage();
      expect(await storage.read(key: 'teacher_auth_token'), isNull);
      expect(await storage.read(key: 'teacher_id'), isNull);
    });

    test('HTTP 500: returns null and preserves credentials (not a confirmed rejection)',
        () async {
      FlutterSecureStorage.setMockInitialValues(teacherStorage());

      final service = TeacherAuthService(
        client: MockClient((request) async => _json(500, {'detail': 'boom'})),
      );

      expect(await service.validateSession(), isNull);
      expect(
        await FlutterSecureStorage().read(key: 'teacher_auth_token'),
        kTeacherToken,
      );
    });

    test('network exception: returns null and preserves credentials for retry',
        () async {
      FlutterSecureStorage.setMockInitialValues(teacherStorage());

      var callCount = 0;
      final service = TeacherAuthService(
        client: MockClient((request) async {
          callCount++;
          throw const SocketException('Connection refused');
        }),
      );

      expect(await service.validateSession(), isNull);
      expect(callCount, 1);
      expect(
        await FlutterSecureStorage().read(key: 'teacher_auth_token'),
        kTeacherToken,
      );
      expect(await FlutterSecureStorage().read(key: 'teacher_id'), '1');
    });

    test('timeout: returns null and preserves credentials for retry', () async {
      FlutterSecureStorage.setMockInitialValues(teacherStorage());

      final service = TeacherAuthService(
        client: MockClient((request) async {
          throw TimeoutException('no response', const Duration(seconds: 10));
        }),
      );

      expect(await service.validateSession(), isNull);
      expect(
        await FlutterSecureStorage().read(key: 'teacher_auth_token'),
        kTeacherToken,
      );
    });

    test('no stored token: returns false without contacting the backend', () async {
      FlutterSecureStorage.setMockInitialValues({});

      var callCount = 0;
      final service = TeacherAuthService(
        client: MockClient((request) async {
          callCount++;
          return _json(200, kTeacherBody);
        }),
      );

      expect(await service.validateSession(), isFalse);
      expect(callCount, 0, reason: 'no token means no /teacher/me request at all');
    });

    test('locally expired token: returns false, clears teacher credentials, skips the network',
        () async {
      FlutterSecureStorage.setMockInitialValues({
        ...teacherStorage(expiry: _pastExpiry()),
        ...studentStorage(),
      });

      var callCount = 0;
      final service = TeacherAuthService(
        client: MockClient((request) async {
          callCount++;
          return _json(200, kTeacherBody);
        }),
      );

      expect(await service.validateSession(), isFalse);
      expect(callCount, 0);

      final storage = FlutterSecureStorage();
      expect(await storage.read(key: 'teacher_auth_token'), isNull);
      // The student session must survive a teacher token expiring.
      expect(await storage.read(key: 'auth_token'), kStudentToken);
    });
  });

  // =========================================================================
  // Teacher credential isolation
  // =========================================================================
  group('TeacherAuthService.clearAuthData (teacher-only)', () {
    test('removes teacher keys and preserves student credentials', () async {
      FlutterSecureStorage.setMockInitialValues({
        ...teacherStorage(),
        ...studentStorage(),
      });

      await TeacherAuthService().clearAuthData();

      final storage = FlutterSecureStorage();
      expect(await storage.read(key: 'teacher_auth_token'), isNull);
      expect(await storage.read(key: 'teacher_role'), isNull);
      expect(await storage.read(key: 'auth_token'), kStudentToken);
      expect(await storage.read(key: 'roll_number'), '71');
    });

    test('clearing teacher auth leaves the student session usable', () async {
      FlutterSecureStorage.setMockInitialValues(studentStorage());

      await TeacherAuthService().clearAuthData();

      final student = await AuthService().getStudent();
      expect(student, isNotNull);
      expect(student!.token, kStudentToken);
      expect(student.studentId, '1');
    });
  });

  // =========================================================================
  // AuthCheckPage teacher gate - real widget tests
  // =========================================================================
  group('AuthCheckPage teacher session restoration (widget tests)', () {
    testWidgets('validated teacher session calls /teacher/me and opens TeacherPanelPage',
        (tester) async {
      FlutterSecureStorage.setMockInitialValues(teacherStorage());

      var meCalls = 0;
      final teacherService = TeacherAuthService(
        client: MockClient((request) async {
          meCalls++;
          expect(request.url.path, '/teacher/me');
          expect(_authorizationOf(request), 'Bearer $kTeacherToken');
          return _json(200, kTeacherBody);
        }),
      );

      await _pumpAuthCheck(tester, teacherAuthService: teacherService);
      await _pumpUntilFound(
        tester,
        find.byType(TeacherPanelPage),
        describing: 'TeacherPanelPage for a validated teacher session',
      );

      expect(meCalls, 1, reason: 'the teacher session must be validated before the panel opens');
      expect(find.byType(RoleSelectionPage), findsNothing);
      expect(find.byType(HomePage), findsNothing);
      expect(
        await FlutterSecureStorage().read(key: 'teacher_auth_token'),
        kTeacherToken,
      );

      await tester.pumpAndSettle();
    });

    testWidgets('HTTP 401 on /teacher/me blocks the panel and clears teacher credentials',
        (tester) async {
      FlutterSecureStorage.setMockInitialValues({
        ...teacherStorage(),
        ...studentStorage(),
      });

      var meCalls = 0;
      final teacherService = TeacherAuthService(
        client: MockClient((request) async {
          meCalls++;
          return _json(401, {'detail': 'Invalid token'});
        }),
      );
      // The stored student session is left unverified (unreachable) so the flow
      // still reaches the teacher branch without clearing student credentials.
      final studentService = AuthService(
        client: MockClient((request) async {
          throw const SocketException('Network is unreachable');
        }),
      );

      await _pumpAuthCheck(
        tester,
        studentAuthService: studentService,
        teacherAuthService: teacherService,
      );
      await _pumpUntilFound(
        tester,
        find.byType(RoleSelectionPage),
        describing: 'RoleSelectionPage after a 401 on /teacher/me',
      );

      expect(meCalls, 1);
      expect(find.byType(TeacherPanelPage), findsNothing);

      final storage = FlutterSecureStorage();
      expect(await storage.read(key: 'teacher_auth_token'), isNull);
      // Student credentials are a separate store and must survive.
      expect(await storage.read(key: 'auth_token'), kStudentToken);

      await tester.pumpAndSettle();
    });

    testWidgets('HTTP 403 on /teacher/me blocks the panel and clears teacher credentials',
        (tester) async {
      FlutterSecureStorage.setMockInitialValues(teacherStorage());

      var meCalls = 0;
      final teacherService = TeacherAuthService(
        client: MockClient((request) async {
          meCalls++;
          return _json(403, {'detail': 'Teacher account is deactivated'});
        }),
      );

      await _pumpAuthCheck(tester, teacherAuthService: teacherService);
      await _pumpUntilFound(
        tester,
        find.byType(RoleSelectionPage),
        describing: 'RoleSelectionPage after a 403 on /teacher/me',
      );

      expect(meCalls, 1);
      expect(find.byType(TeacherPanelPage), findsNothing);
      expect(
        await FlutterSecureStorage().read(key: 'teacher_auth_token'),
        isNull,
      );

      await tester.pumpAndSettle();
    });

    testWidgets('unreachable backend fails closed for teachers and preserves credentials',
        (tester) async {
      FlutterSecureStorage.setMockInitialValues(teacherStorage());

      var meCalls = 0;
      final teacherService = TeacherAuthService(
        client: MockClient((request) async {
          meCalls++;
          throw const SocketException('Network is unreachable');
        }),
      );

      await _pumpAuthCheck(tester, teacherAuthService: teacherService);
      await _pumpUntilFound(
        tester,
        find.byType(RoleSelectionPage),
        describing: 'RoleSelectionPage when /teacher/me is unreachable',
      );

      expect(meCalls, 1);
      expect(find.byType(TeacherPanelPage), findsNothing);

      // Fail closed, but keep the credentials so the teacher can retry.
      final storage = FlutterSecureStorage();
      expect(await storage.read(key: 'teacher_auth_token'), kTeacherToken);
      expect(await storage.read(key: 'teacher_id'), '1');

      await tester.pumpAndSettle();
    });

    testWidgets('locally expired teacher token never opens the panel and never calls the backend',
        (tester) async {
      FlutterSecureStorage.setMockInitialValues(
        teacherStorage(expiry: _pastExpiry()),
      );

      var meCalls = 0;
      final teacherService = TeacherAuthService(
        client: MockClient((request) async {
          meCalls++;
          return _json(200, kTeacherBody);
        }),
      );

      await _pumpAuthCheck(tester, teacherAuthService: teacherService);
      await _pumpUntilFound(
        tester,
        find.byType(RoleSelectionPage),
        describing: 'RoleSelectionPage for an expired local teacher token',
      );

      expect(find.byType(TeacherPanelPage), findsNothing);
      expect(meCalls, 0, reason: 'an expired local teacher token is rejected before /teacher/me');
      expect(
        await FlutterSecureStorage().read(key: 'teacher_auth_token'),
        isNull,
      );

      await tester.pumpAndSettle();
    });

    testWidgets('rejected student session does not stop a validated teacher session',
        (tester) async {
      FlutterSecureStorage.setMockInitialValues({
        ...studentStorage(),
        ...teacherStorage(),
      });

      final studentService = AuthService(
        client: MockClient((request) async => _json(403, {'detail': 'Student not approved'})),
      );
      final teacherService = TeacherAuthService(
        client: MockClient((request) async => _json(200, kTeacherBody)),
      );

      await _pumpAuthCheck(
        tester,
        studentAuthService: studentService,
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
