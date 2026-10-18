// Tests for student logout (`AuthService.logout`).
//
// Uses in-memory secure storage and a MockClient, so no live backend and no
// database are involved. The backend side of this contract (POST /logout
// invalidates the token, and only that student's token) is covered by
// backend/tests/test_backend_security.py.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:stryve/config/environment.dart';
import 'package:stryve/services/auth_service.dart';

const String kStudentToken = 'logout-test-student-token';
const String kTeacherToken = 'logout-test-teacher-token';

String _futureExpiry() =>
    DateTime.now().add(const Duration(days: 1)).toUtc().toIso8601String();

Map<String, String> studentStorage() => {
  'auth_token': kStudentToken,
  'token_expiry': _futureExpiry(),
  'student_id': '1',
  'name': 'Test Student',
  'email': 'test@gmail.com',
  'roll_number': '71',
  'branch': 'AI&DS',
  'year': '1',
  'division': 'D',
  'batch': 'D-3',
  'college': 'Test College',
};

Map<String, String> teacherStorage() => {
  'teacher_auth_token': kTeacherToken,
  'teacher_token_expiry': _futureExpiry(),
  'teacher_id': '1',
  'teacher_name': 'Admin User',
  'teacher_email': 'admin@campussync.edu',
  'teacher_role': 'admin',
};

String? _authorizationOf(http.BaseRequest request) {
  for (final entry in request.headers.entries) {
    if (entry.key.toLowerCase() == 'authorization') return entry.value;
  }
  return null;
}

void main() {
  group('AuthService.logout', () {
    test('revokes the session on the backend and clears only student data', () async {
      FlutterSecureStorage.setMockInitialValues({
        ...studentStorage(),
        ...teacherStorage(),
      });

      final requests = <http.Request>[];
      final client = MockClient((request) async {
        requests.add(request);
        return http.Response(
          jsonEncode({'message': 'Logged out'}),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final revoked = await AuthService(client: client).logout();

      expect(revoked, isTrue);
      expect(requests, hasLength(1));
      expect(requests.single.method, 'POST');
      expect(
        requests.single.url.toString(),
        '${Environment.backendUrl}/logout',
      );
      expect(_authorizationOf(requests.single), 'Bearer $kStudentToken');

      final storage = FlutterSecureStorage();
      expect(await storage.read(key: 'auth_token'), isNull);
      expect(await storage.read(key: 'roll_number'), isNull);
      // The teacher session is unaffected.
      expect(await storage.read(key: 'teacher_auth_token'), kTeacherToken);
      expect(await storage.read(key: 'teacher_role'), 'admin');
    });

    test('still signs the student out when the backend is unreachable', () async {
      FlutterSecureStorage.setMockInitialValues({
        ...studentStorage(),
        ...teacherStorage(),
      });

      var calls = 0;
      final client = MockClient((request) async {
        calls++;
        throw const SocketException('Network is unreachable');
      });

      final revoked = await AuthService(client: client).logout();

      expect(calls, 1);
      expect(revoked, isFalse);
      final storage = FlutterSecureStorage();
      expect(await storage.read(key: 'auth_token'), isNull);
      expect(await storage.read(key: 'teacher_auth_token'), kTeacherToken);
    });

    test('reports a non-200 response as not revoked but still clears locally', () async {
      FlutterSecureStorage.setMockInitialValues(studentStorage());

      final client = MockClient(
        (request) async => http.Response('{"detail":"Invalid token"}', 401),
      );

      final revoked = await AuthService(client: client).logout();

      expect(revoked, isFalse);
      expect(await FlutterSecureStorage().read(key: 'auth_token'), isNull);
    });

    test('with no stored session it does not call the backend', () async {
      FlutterSecureStorage.setMockInitialValues({...teacherStorage()});

      var calls = 0;
      final client = MockClient((request) async {
        calls++;
        return http.Response('{}', 200);
      });

      final revoked = await AuthService(client: client).logout();

      expect(calls, 0);
      expect(revoked, isFalse);
      expect(
        await FlutterSecureStorage().read(key: 'teacher_auth_token'),
        kTeacherToken,
      );
    });
  });
}
