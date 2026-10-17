import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import '../config/environment.dart';
import '../student.dart';

class AuthService {
  static const _storage = FlutterSecureStorage();

  /// Optional injected HTTP client (used by tests). Production code leaves
  /// this null so a short-lived client is created per validation call.
  final http.Client? client;

  AuthService({this.client});

  // Storage keys
  static const String _keyToken = 'auth_token';
  static const String _keyTokenExpiry = 'token_expiry';
  static const String _keyStudentId = 'student_id';
  static const String _keyName = 'name';
  static const String _keyEmail = 'email';
  static const String _keyRollNumber = 'roll_number';
  static const String _keyBranch = 'branch';
  static const String _keyYear = 'year';
  static const String _keyDivision = 'division';
  static const String _keyBatch = 'batch';
  static const String _keyCollege = 'college';
  static const String _keyPhotoPath = 'photo_path';

  /// Save authentication data after successful login
  Future<void> saveAuthData({
    required String token,
    required String tokenExpiresAt,
    required String studentId,
    required String name,
    required String email,
    required String rollNumber,
    required String branch,
    required int year,
    required String division,
    required String batch,
    String college = 'Your College',
  }) async {
    await Future.wait([
      _storage.write(key: _keyToken, value: token),
      _storage.write(key: _keyTokenExpiry, value: tokenExpiresAt),
      _storage.write(key: _keyStudentId, value: studentId),
      _storage.write(key: _keyName, value: name),
      _storage.write(key: _keyEmail, value: email),
      _storage.write(key: _keyRollNumber, value: rollNumber),
      _storage.write(key: _keyBranch, value: branch),
      _storage.write(key: _keyYear, value: year.toString()),
      _storage.write(key: _keyDivision, value: division),
      _storage.write(key: _keyBatch, value: batch),
      _storage.write(key: _keyCollege, value: college),
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

  /// Check if user is authenticated with a valid token
  Future<bool> isAuthenticated() async {
    final token = await getToken();
    return token != null;
  }

  /// Get stored student data (if authenticated)
  Future<Student?> getStudent() async {
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

    // Token valid, now load student data
    try {
      final studentId = await _storage.read(key: _keyStudentId);
      final name = await _storage.read(key: _keyName);
      final email = await _storage.read(key: _keyEmail);
      final rollNumber = await _storage.read(key: _keyRollNumber);
      final branch = await _storage.read(key: _keyBranch);
      final yearStr = await _storage.read(key: _keyYear);
      final division = await _storage.read(key: _keyDivision);
      final batch = await _storage.read(key: _keyBatch);
      final college = await _storage.read(key: _keyCollege);
      final photoPath = await _storage.read(key: _keyPhotoPath);

      if (studentId == null ||
          name == null ||
          email == null ||
          rollNumber == null ||
          branch == null ||
          yearStr == null ||
          division == null ||
          batch == null) {
        // Incomplete data - clear it
        await clearAuthData();
        return null;
      }

      final year = int.tryParse(yearStr);
      if (year == null) {
        await clearAuthData();
        return null;
      }

      return Student(
        name: name,
        studentId: studentId,
        rollNumber: rollNumber,
        college: college ?? 'Your College',
        course: branch,
        year: year,
        division: division,
        batch: batch,
        token: tokenOnly,
        photoPath: photoPath,
      );
    } catch (e) {
      // Error reading data - clear it
      await clearAuthData();
      return null;
    }
  }

  /// Clear only student authentication data (logout)
  /// Does not affect teacher/admin credentials which use separate keys.
  Future<void> clearAuthData() async {
    await Future.wait([
      _storage.delete(key: _keyToken),
      _storage.delete(key: _keyTokenExpiry),
      _storage.delete(key: _keyStudentId),
      _storage.delete(key: _keyName),
      _storage.delete(key: _keyEmail),
      _storage.delete(key: _keyRollNumber),
      _storage.delete(key: _keyBranch),
      _storage.delete(key: _keyYear),
      _storage.delete(key: _keyDivision),
      _storage.delete(key: _keyBatch),
      _storage.delete(key: _keyCollege),
      _storage.delete(key: _keyPhotoPath),
    ]);
  }

  /// Log out of the student session.
  ///
  /// Revokes the token on the backend (best effort) and then clears the local
  /// student credentials. The server call is best effort on purpose: if the
  /// backend is unreachable the user must still be signed out locally, and the
  /// token simply expires later. Teacher credentials are never touched.
  ///
  /// Returns true when the backend confirmed the token was invalidated.
  Future<bool> logout() async {
    final token = await getToken();
    var revoked = false;

    if (token != null) {
      final httpClient = client ?? http.Client();
      final shouldCloseClient = client == null;

      try {
        final response = await httpClient.post(
          Uri.parse('${Environment.backendUrl}/logout'),
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $token',
          },
        );
        revoked = response.statusCode == 200;
      } catch (e) {
        // Unreachable backend - fall through and sign out locally.
      } finally {
        if (shouldCloseClient) {
          httpClient.close();
        }
      }
    }

    await clearAuthData();
    return revoked;
  }

  /// Save profile photo path
  Future<void> savePhotoPath(String path) async {
    await _storage.write(key: _keyPhotoPath, value: path);
  }

  /// Remove profile photo path
  Future<void> removePhotoPath() async {
    await _storage.delete(key: _keyPhotoPath);
  }

  /// Validate the stored student session with the backend.
  ///
  /// Returns:
  /// - `true` if session is valid and student is approved (can proceed to HomePage)
  /// - `false` if session is invalid (401/403) - credentials cleared
  /// - `null` if backend unreachable - credentials preserved for retry
  Future<bool?> validateSession() async {
    final token = await getToken();
    if (token == null) return false;

    final httpClient = client ?? http.Client();
    final shouldCloseClient = client == null;

    try {
      final response = await httpClient.get(
        Uri.parse('${Environment.backendUrl}/me'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token',
        },
      );

      if (response.statusCode == 200) {
        jsonDecode(response.body); // Backend already checks status == "approved"
        // So 200 means approved
        return true;
      } else if (response.statusCode == 401 || response.statusCode == 403) {
        // Invalid/expired token or pending/rejected student
        await clearAuthData();
        return false;
      } else {
        // Other error (5xx, etc.) - treat as unreachable
        return null;
      }
    } catch (e) {
      // Network error - backend unreachable
      return null;
    } finally {
      if (shouldCloseClient) {
        httpClient.close();
      }
    }
  }
}
