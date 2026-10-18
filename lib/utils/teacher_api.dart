import 'dart:convert';

import 'package:http/http.dart' as http;

/// How long a single backend request may take before a screen treats it as
/// "backend unreachable". Without this, a dead network leaves the user staring
/// at a spinner forever.
const Duration kTeacherRequestTimeout = Duration(seconds: 15);

/// Widest the panel content is allowed to grow on a tablet/desktop window.
const double kTeacherMaxContentWidth = 760;

/// Shown whenever the backend could not be reached at all (as opposed to
/// answering with a refusal, which is reported from its own `detail`).
const String kTeacherUnreachableMessage =
    'Could not reach the Stryve server. Check your connection and try again.';

/// Headers for an authenticated JSON call. The backend derives every permission
/// from this token, so no screen ever sends a role or a batch of its own.
Map<String, String> teacherHeaders(String token) => {
  'Content-Type': 'application/json',
  'Authorization': 'Bearer $token',
};

/// Pull a human-readable message out of a FastAPI error body without ever
/// throwing on a non-JSON body (proxies and tunnels return HTML).
///
/// `detail` is read first: `message` only exists on success payloads.
String teacherMessageFromBody(http.Response response) {
  try {
    final decoded = jsonDecode(response.body);
    if (decoded is Map) {
      final detail = decoded['detail'];
      if (detail is String && detail.isNotEmpty) return detail;
      if (detail is List && detail.isNotEmpty) {
        final first = detail.first;
        if (first is Map && first['msg'] is String) {
          return first['msg'] as String;
        }
      }
      final message = decoded['message'];
      if (message is String && message.isNotEmpty) return message;
    }
  } catch (_) {
    // Non-JSON body: fall through to the generic message.
  }
  return 'The request failed (HTTP ${response.statusCode}). Please try again.';
}

/// Parse a JSON body into a list of maps, tolerating anything unexpected.
List<Map<String, dynamic>> teacherJsonList(String body) {
  final decoded = jsonDecode(body);
  if (decoded is! List) return const [];
  return decoded.whereType<Map<String, dynamic>>().toList();
}
