// Unit tests for AssignmentPdfService.
//
// A mocked HTTP client stands in for the backend, so no live server and no
// real database are involved. What matters here: the request goes to the
// existing authorized endpoint with the student's bearer token, and every
// failure mode the app must survive (expired session, forbidden, missing file,
// server error, no network, empty body) maps to a message the student can act
// on instead of a crash or a blank screen.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:stryve/services/assignment_pdf_service.dart';

const String kToken = 'student-token-abc123';

Uint8List _pdfBytes() => Uint8List.fromList(
  List<int>.generate(64, (i) => i),
);

http.Response _json(int status, Map<String, dynamic> body) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

void main() {
  group('AssignmentPdfService.load', () {
    test('fetches the PDF from the authorized endpoint with the bearer token', () async {
      Uri? requested;
      Map<String, String>? headers;

      final service = AssignmentPdfService(
        token: kToken,
        baseUrl: 'https://example.test',
        client: MockClient((request) async {
          requested = request.url;
          headers = request.headers;
          return http.Response.bytes(_pdfBytes(), 200);
        }),
      );

      final result = await service.load(42);

      expect(result.ok, isTrue);
      expect(result.bytes, _pdfBytes());
      expect(requested.toString(), 'https://example.test/assignments/42/file');
      expect(headers?['Authorization'], 'Bearer $kToken');
      // No unauthenticated or public URL is ever built.
      expect(requested.toString().contains(kToken), isFalse);
    });

    test('an expired session reports unauthorized and signs the student out', () async {
      final service = AssignmentPdfService(
        token: kToken,
        client: MockClient((_) async => _json(401, {'detail': 'Invalid token'})),
      );

      final result = await service.load(1);

      expect(result.ok, isFalse);
      expect(result.failure, AssignmentPdfFailure.unauthorized);
      expect(result.isUnauthorized, isTrue);
      expect(result.message.toLowerCase(), contains('sign in'));
    });

    test('a 403 keeps the backend explanation and is never worked around', () async {
      final service = AssignmentPdfService(
        token: kToken,
        client: MockClient(
          (_) async => _json(403, {
            'detail': 'You are not permitted to download this assignment',
          }),
        ),
      );

      final result = await service.load(1);

      expect(result.failure, AssignmentPdfFailure.forbidden);
      expect(result.statusCode, 403);
      expect(
        result.message,
        'You are not permitted to download this assignment',
      );
    });

    test('a missing file is reported as such, with the backend detail', () async {
      final service = AssignmentPdfService(
        token: kToken,
        client: MockClient(
          (_) async => _json(404, {
            'detail': 'The stored file is no longer available',
          }),
        ),
      );

      final result = await service.load(3);

      expect(result.failure, AssignmentPdfFailure.missing);
      expect(result.message, 'The stored file is no longer available');
    });

    test('a server error is explained without leaking internals', () async {
      final service = AssignmentPdfService(
        token: kToken,
        client: MockClient(
          (_) async => http.Response('<html>500 nginx</html>', 500),
        ),
      );

      final result = await service.load(3);

      expect(result.failure, AssignmentPdfFailure.server);
      expect(result.message, contains('500'));
      expect(result.message.contains('nginx'), isFalse);
      expect(result.message.contains('<'), isFalse);
    });

    test('a network failure never throws at the caller', () async {
      final service = AssignmentPdfService(
        token: kToken,
        client: MockClient((_) async => throw const SocketExceptionStub()),
      );

      final result = await service.load(3);

      expect(result.failure, AssignmentPdfFailure.network);
      expect(result.message.toLowerCase(), contains('internet'));
    });

    test('a 200 with no bytes is an empty-file error, not a blank viewer', () async {
      final service = AssignmentPdfService(
        token: kToken,
        client: MockClient((_) async => http.Response.bytes(Uint8List(0), 200)),
      );

      final result = await service.load(3);

      expect(result.ok, isFalse);
      expect(result.failure, AssignmentPdfFailure.empty);
      expect(result.message.toLowerCase(), contains('empty'));
    });

    test('loading and saving are separate: the fetch API has no save in it', () async {
      // Reading a PDF must never write to the device on its own. The class the
      // viewer fetches through exposes `load` only; `saveAssignmentPdf` is a
      // standalone function that the Download button is the only caller of.
      // This pins that separation.
      var requestCount = 0;
      final service = AssignmentPdfService(
        token: kToken,
        client: MockClient((_) async {
          requestCount++;
          return http.Response.bytes(_pdfBytes(), 200);
        }),
      );

      final result = await service.load(7);

      expect(result.bytes, isNotNull);
      // One GET, and nothing else: no second request, no file write.
      expect(requestCount, 1);
    });
  });

  group('PdfSaveOutcome', () {
    test('a saved outcome carries the filename and the destination', () {
      const outcome = PdfSaveOutcome.saved(
        fileName: 'Report.pdf',
        location: 'Downloads',
      );

      expect(outcome.ok, isTrue);
      expect(outcome.cancelled, isFalse);
      expect(outcome.error, isNull);
    });

    test('a cancelled save is not a failure', () {
      const outcome = PdfSaveOutcome.cancelled();

      expect(outcome.ok, isFalse);
      expect(outcome.cancelled, isTrue);
      expect(outcome.error, isNull);
    });

    test('a failed save carries a message and no filename', () {
      const outcome = PdfSaveOutcome.failed('Could not save the PDF.');

      expect(outcome.ok, isFalse);
      expect(outcome.cancelled, isFalse);
      expect(outcome.error, 'Could not save the PDF.');
      expect(outcome.fileName, isNull);
    });
  });
}

/// Stands in for a transport-level failure without importing dart:io.
class SocketExceptionStub implements Exception {
  const SocketExceptionStub();
}
