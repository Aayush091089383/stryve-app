import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import '../config/environment.dart';

/// Service for managing teacher/admin authentication data separately from student auth.
/// Uses FlutterSecureStorage for secure token storage.
class TeacherAuthService {
  static const _storage = FlutterSecureStorage();

  /// Optional injected HTTP client (used by tests). Production code leaves
  /// this null so a short-lived client is created per validation call.
  final http.Client? client;

  TeacherAuthService({this.client});

  // Storage keys (prefixed to avoid collision with student auth)
  static const String _keyToken = 'teacher_auth_token';
  static const String _keyTokenExpiry = 'teacher_token_expiry';
  static const String _keyTeacherId = 'teacher_id';
  static const String _keyName = 'teacher_name';
  static const String _keyEmail = 'teacher_email';
  static const String _keyRole = 'teacher_role';

  /// Save authentication data after successful teacher/admin login
  Future<void> saveAuthData({
    required String token,
    required String tokenExpiresAt,
    required int teacherId,
    required String name,
    required String email,
    required String role,
  }) async {
    await Future.wait([
      _storage.write(key: _keyToken, value: token),
      _storage.write(key: _keyTokenExpiry, value: tokenExpiresAt),
      _storage.write(key: _keyTeacherId, value: teacherId.toString()),
      _storage.write(key: _keyName, value: name),
      _storage.write(key: _keyEmail, value: email),
      _storage.write(key: _keyRole, value: role),
    ]);
  }

  /// Get stored authentication token
  Future<String?> getToken() async {
    final token = await _storage.read(key: _keyToken);

    // Check if token is expired
    if (token != null) {
      final expiryStr = await _storage.read(key: _keyTokenExpiry);
      if (expiryStr != null) {
        try {
          final expiry = DateTime.parse(expiryStr);
          if (DateTime.now().isAfter(expiry)) {
            // Token expired - clear it
            await clearAuthData();
            return null;
          }
        } catch (e) {
          // Invalid expiry format - clear it
          await clearAuthData();
          return null;
        }
      }
    }

    return token;
  }

  /// Check if teacher/admin is authenticated with a valid token
  Future<bool> isAuthenticated() async {
    final token = await getToken();
    return token != null;
  }

  /// Get stored teacher data (if authenticated)
  Future<TeacherData?> getTeacher() async {
    // Quick check: token exists and not expired
    final tokenOnly = await _storage.read(key: _keyToken);
    if (tokenOnly == null) return null;

    final expiryStr = await _storage.read(key: _keyTokenExpiry);
    if (expiryStr != null) {
      try {
        final expiry = DateTime.parse(expiryStr);
        if (DateTime.now().isAfter(expiry)) {
          await clearAuthData();
          return null;
        }
      } catch (e) {
        await clearAuthData();
        return null;
      }
    }

    // Token valid, now load teacher data
    try {
      final teacherIdStr = await _storage.read(key: _keyTeacherId);
      final name = await _storage.read(key: _keyName);
      final email = await _storage.read(key: _keyEmail);
      final role = await _storage.read(key: _keyRole);

      if (teacherIdStr == null ||
          name == null ||
          email == null ||
          role == null) {
        // Incomplete data - clear it
        await clearAuthData();
        return null;
      }

      return TeacherData(
        id: int.parse(teacherIdStr),
        name: name,
        email: email,
        role: role,
        token: tokenOnly,
      );
    } catch (e) {
      // Error reading data - clear it
      await clearAuthData();
      return null;
    }
  }

  /// Clear only teacher/admin authentication data (logout).
  ///
  /// Only the teacher-prefixed keys are removed, so signing a teacher out can
  /// never destroy a student session stored alongside it.
  Future<void> clearAuthData() async {
    await Future.wait([
      _storage.delete(key: _keyToken),
      _storage.delete(key: _keyTokenExpiry),
      _storage.delete(key: _keyTeacherId),
      _storage.delete(key: _keyName),
      _storage.delete(key: _keyEmail),
      _storage.delete(key: _keyRole),
    ]);
  }

  /// Validate the stored teacher session with the backend `/teacher/me`.
  ///
  /// Returns:
  /// - `true` if the session is valid and the account is active
  ///   (the caller may open the teacher panel)
  /// - `false` if the session is rejected (401 invalid/expired token, or 403
  ///   deactivated account) - teacher credentials are cleared
  /// - `null` if the backend could not be reached, or answered with anything
  ///   other than 200/401/403 - teacher credentials are preserved for retry
  ///
  /// Callers must fail closed on `null`: never open the teacher panel without
  /// a confirmed `true`.
  Future<bool?> validateSession() async {
    final token = await getToken();
    if (token == null) return false;

    final httpClient = client ?? http.Client();
    final shouldCloseClient = client == null;

    try {
      final response = await httpClient.get(
        Uri.parse('${Environment.backendUrl}/teacher/me'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token',
        },
      );

      if (response.statusCode == 200) {
        // The backend has already verified the token and the account's active
        // state, so a 200 is a confirmed valid teacher session.
        return true;
      } else if (response.statusCode == 401 || response.statusCode == 403) {
        // Invalid/expired token, or deactivated teacher account.
        await clearAuthData();
        return false;
      } else {
        // Server error, proxy error, ... - not a confirmed rejection.
        return null;
      }
    } catch (e) {
      // Network error - backend unreachable.
      return null;
    } finally {
      if (shouldCloseClient) {
        httpClient.close();
      }
    }
  }

  /// Check if the authenticated user is an admin
  Future<bool> isAdmin() async {
    final teacher = await getTeacher();
    return teacher?.role == 'admin';
  }
}

/// Simple data class for teacher information
class TeacherData {
  final int id;
  final String name;
  final String email;
  final String role;
  final String token;

  TeacherData({
    required this.id,
    required this.name,
    required this.email,
    required this.role,
    required this.token,
  });

  bool get isAdmin => role == 'admin';
}