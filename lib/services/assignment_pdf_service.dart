/// Reading and saving one assignment PDF.
///
/// Everything here goes through the existing authenticated endpoint
/// (`GET /assignments/{id}/file`) with the student's bearer token, so the
/// backend stays the only thing that decides whether this student may see the
/// file (course, year, division and batch). The app never builds a public or
/// unauthenticated URL, and it never works around a 403.
///
/// Viewing and saving are deliberately separate: [AssignmentPdfService.load]
/// brings the bytes into memory for the viewer, and [saveAssignmentPdf] is the
/// only thing that ever writes to the device - and only when the student taps
/// Download.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:file_saver/file_saver.dart';
import 'package:http/http.dart' as http;

import '../config/environment.dart';

/// Why an assignment PDF could not be opened.
enum AssignmentPdfFailure {
  /// The session is gone or the token was rejected (HTTP 401).
  unauthorized,

  /// The account exists but may not read this assignment (HTTP 403).
  forbidden,

  /// No such assignment, no attachment, or the stored file is missing (404).
  missing,

  /// The backend answered with an error it could not explain (5xx / other).
  server,

  /// The request never reached the backend.
  network,

  /// The backend answered 200 with no bytes.
  empty,
}

/// One attempt to load an assignment PDF into memory.
class AssignmentPdfResult {
  /// The PDF bytes, on success.
  const AssignmentPdfResult.loaded(Uint8List this.bytes)
      : failure = null,
        detail = null,
        statusCode = 200;

  /// A failure, with a message that is safe to show to the student.
  const AssignmentPdfResult.failed(
    AssignmentPdfFailure this.failure, {
    this.detail,
    this.statusCode,
  }) : bytes = null;

  /// The bytes to render, or null when the load failed.
  final Uint8List? bytes;

  /// Why the load failed, or null on success.
  final AssignmentPdfFailure? failure;

  /// The backend's own explanation (`detail`), when it sent one.
  final String? detail;

  /// The HTTP status, when there was a response at all.
  final int? statusCode;

  bool get ok => bytes != null;

  bool get isUnauthorized => failure == AssignmentPdfFailure.unauthorized;

  /// The message a screen should show for this result.
  String get message {
    switch (failure) {
      case AssignmentPdfFailure.unauthorized:
        return 'Your session has expired. Please sign in again.';
      case AssignmentPdfFailure.forbidden:
        return detail ?? 'You are not permitted to open this assignment.';
      case AssignmentPdfFailure.missing:
        return detail ?? 'This assignment has no PDF to open.';
      case AssignmentPdfFailure.empty:
        return 'The attached PDF is empty.';
      case AssignmentPdfFailure.server:
        // The app supplies its own explanation for a PDF it could not render;
        // the backend's wording wins when it sent one.
        if (detail != null) return detail!;
        return 'Stryve could not prepare this PDF'
            '${statusCode == null ? '' : ' ($statusCode)'}. Please try again.';
      case AssignmentPdfFailure.network:
        return 'Could not reach Stryve. Check your internet connection '
            'and try again.';
      case null:
        return '';
    }
  }
}

/// Loads an assignment's PDF bytes through the authorized endpoint.
typedef AssignmentPdfLoad = Future<AssignmentPdfResult> Function(
    int assignmentId);

class AssignmentPdfService {
  /// [client] and [baseUrl] exist for tests; production uses the defaults.
  const AssignmentPdfService({
    this.client,
    required this.token,
    this.baseUrl,
  });

  final http.Client? client;
  final String token;
  final String? baseUrl;

  String get _baseUrl => baseUrl ?? Environment.backendUrl;

  Map<String, String> get _headers => {
        'Authorization': 'Bearer $token',
        'Accept': 'application/pdf',
      };

  /// Fetches the PDF for [assignmentId] into memory.
  ///
  /// Nothing is written to disk here - the bytes are handed straight to the
  /// viewer. A Download is a separate, explicit action.
  Future<AssignmentPdfResult> load(int assignmentId) async {
    final uri = Uri.parse('$_baseUrl/assignments/$assignmentId/file');

    http.Response response;
    try {
      response = await (client?.get(uri, headers: _headers) ??
          http.get(uri, headers: _headers));
    } catch (_) {
      return const AssignmentPdfResult.failed(AssignmentPdfFailure.network);
    }

    if (response.statusCode == 200) {
      if (response.bodyBytes.isEmpty) {
        return const AssignmentPdfResult.failed(AssignmentPdfFailure.empty);
      }
      return AssignmentPdfResult.loaded(response.bodyBytes);
    }

    return AssignmentPdfResult.failed(
      _failureFor(response.statusCode),
      detail: _detailMessage(response),
      statusCode: response.statusCode,
    );
  }

  static AssignmentPdfFailure _failureFor(int statusCode) {
    if (statusCode == 401) return AssignmentPdfFailure.unauthorized;
    if (statusCode == 403) return AssignmentPdfFailure.forbidden;
    if (statusCode == 404) return AssignmentPdfFailure.missing;
    return AssignmentPdfFailure.server;
  }

  /// Reads the backend's `detail` first - `message` only appears on success
  /// payloads - and ignores anything that is not a string.
  static String? _detailMessage(http.Response response) {
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map && decoded['detail'] is String) {
        final detail = (decoded['detail'] as String).trim();
        return detail.isEmpty ? null : detail;
      }
    } catch (_) {
      // Non-JSON body (a proxy error page, for example): use our own wording.
    }
    return null;
  }
}

/// The outcome of an explicit Download tap.
class PdfSaveOutcome {
  const PdfSaveOutcome.saved({required this.fileName, required this.location})
      : cancelled = false,
        error = null;

  const PdfSaveOutcome.cancelled()
      : fileName = null,
        location = null,
        cancelled = true,
        error = null;

  const PdfSaveOutcome.failed(String this.error)
      : fileName = null,
        location = null,
        cancelled = false;

  final String? fileName;

  /// Human-readable destination ("Downloads", or the full path on desktop).
  final String? location;

  /// True when the student dismissed the system save dialog.
  final bool cancelled;

  /// A message to show when the save failed.
  final String? error;

  bool get ok => fileName != null && location != null;
}

/// Saves the PDF bytes on the student's request.
typedef AssignmentPdfSave = Future<PdfSaveOutcome> Function(
    Uint8List bytes, String fileName);

/// Writes a downloaded assignment PDF where the student can find it.
///
/// On Android 10+ this goes straight into the shared `Downloads` collection
/// through MediaStore, which needs no storage permission and never replaces an
/// existing file - Android keeps both, renaming the new one. If that is not
/// available (Android 9 and below, where it would need `WRITE_EXTERNAL_STORAGE`,
/// or any MediaStore failure) it falls back to the system Save dialog, where the
/// student picks the location and Android again refuses to overwrite. On
/// Windows/macOS/Linux the first step already writes into the user's Downloads
/// folder.
///
/// Only ever called from the Download button.
Future<PdfSaveOutcome> saveAssignmentPdf(
  Uint8List bytes,
  String fileName,
) async {
  final stem = _stemOf(fileName);

  // 1. The device's own Downloads folder, without a dialog.
  try {
    final location = await FileSaver.instance.saveToDownloads(
      name: stem,
      bytes: bytes,
      fileExtension: 'pdf',
      mimeType: MimeType.pdf,
    );
    if (location != null && location.trim().isNotEmpty) {
      return PdfSaveOutcome.saved(
        fileName: fileName,
        location: _describe(location, fileName),
      );
    }
  } catch (_) {
    // Fall through to the dialog below rather than failing the download.
  }

  // 2. The system Save dialog (SAF on Android). Reached on older Android and
  // when the student's device cannot write to Downloads directly.
  try {
    final chosen = await FileSaver.instance.saveAs(
      name: stem,
      bytes: bytes,
      fileExtension: 'pdf',
      mimeType: MimeType.pdf,
      dialogTitle: 'Save assignment',
    );
    if (chosen == null || chosen.trim().isEmpty) {
      return const PdfSaveOutcome.cancelled();
    }
    return PdfSaveOutcome.saved(
      fileName: fileName,
      location: _describe(chosen, fileName),
    );
  } catch (_) {
    return const PdfSaveOutcome.failed(
      'Could not save the PDF. Please try again.',
    );
  }
}

/// The filename without its extension: `file_saver` adds `pdf` itself, and a
/// name of "Report.pdf.pdf" would be wrong.
String _stemOf(String fileName) {
  final trimmed = fileName.trim();
  if (trimmed.toLowerCase().endsWith('.pdf')) {
    return trimmed.substring(0, trimmed.length - 4);
  }
  return trimmed;
}

/// Where the file ended up, in words a student can act on.
String _describe(String raw, String fileName) {
  final value = raw.trim();
  // Android hands back a MediaStore content URI, which is not something a
  // student can read; the collection it points at is the useful fact.
  if (value.startsWith('content://')) return 'Downloads';
  if (value == fileName) return 'Downloads';
  return value;
}
