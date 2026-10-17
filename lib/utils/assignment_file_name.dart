/// Filenames for assignment PDFs the student explicitly downloads.
///
/// The important property here is that a filename can never escape the folder
/// it is written to and can never be empty: `buildAssignmentPdfFileName` is the
/// only place the app turns a teacher-supplied title into something it puts on
/// the device's shared storage, so it strips path separators and the characters
/// Android, Windows and macOS reject, and always returns a name ending in
/// `.pdf`.
library;

/// Characters that are illegal in a filename on at least one supported
/// platform (Windows is the strictest: `\ / : * ? " < > |`).
final RegExp _illegalCharacters = RegExp(r'[\\/:*?"<>|]+');

/// Control characters (including newlines and tabs) never belong in a name.
final RegExp _controlCharacters = RegExp(r'[\x00-\x1F\x7F]');

final RegExp _whitespaceRuns = RegExp(r'\s+');
final RegExp _separatorRuns = RegExp(r'-{2,}');
final RegExp _danglingSeparators = RegExp(r'^[\s.\-]+|[\s.\-]+$');

/// Device names that Windows still refuses as filenames, even with `.pdf`.
const Set<String> _reservedWindowsNames = {
  'CON', 'PRN', 'AUX', 'NUL',
  'COM1', 'COM2', 'COM3', 'COM4', 'COM5', 'COM6', 'COM7', 'COM8', 'COM9',
  'LPT1', 'LPT2', 'LPT3', 'LPT4', 'LPT5', 'LPT6', 'LPT7', 'LPT8', 'LPT9',
};

/// Longest title part kept, before the `.pdf` extension. Well under the 255
/// byte limit of every platform even when the title is multi-byte.
const int _maxStemLength = 60;

/// Fallback when neither the title nor the subject gives us anything usable.
const String _untitledStem = 'campus-sync-assignment';

/// Builds a safe, meaningful `*.pdf` filename for one assignment.
///
/// The title is preferred (that is what the student recognises), the subject is
/// the fallback, and `assignment-<id>` is the last resort, so the result is
/// never empty and never just `.pdf`.
String buildAssignmentPdfFileName({
  String? title,
  String? subject,
  int? assignmentId,
}) {
  var stem = _stripPdfExtension((title ?? '').trim());
  if (stem.isEmpty) {
    stem = _stripPdfExtension((subject ?? '').trim());
  }

  stem = stem
      // Control characters (newlines, tabs, NUL) become a space rather than
      // vanishing, so "Physics\npractical" does not become one word.
      .replaceAll(_controlCharacters, ' ')
      .replaceAll(_illegalCharacters, '-')
      .replaceAll(_whitespaceRuns, ' ')
      .replaceAll(RegExp(r'-\s+'), '-')
      .replaceAll(RegExp(r'\s+-'), '-')
      .replaceAll(_separatorRuns, '-')
      .trim()
      .replaceAll(_danglingSeparators, '');

  if (stem.isEmpty) {
    stem = assignmentId != null ? 'assignment-$assignmentId' : _untitledStem;
  }

  if (_reservedWindowsNames.contains(stem.toUpperCase())) {
    stem = 'assignment-$stem';
  }

  if (stem.length > _maxStemLength) {
    stem = stem
        .substring(0, _maxStemLength)
        .replaceAll(_danglingSeparators, '');
    if (stem.isEmpty) {
      stem = assignmentId != null ? 'assignment-$assignmentId' : _untitledStem;
    }
  }

  return '$stem.pdf';
}

/// Removes one trailing `.pdf` (any casing) so a title like "Report.pdf" does
/// not become "Report.pdf.pdf".
String _stripPdfExtension(String value) {
  if (value.length > 4 && value.toLowerCase().endsWith('.pdf')) {
    return value.substring(0, value.length - 4).trim();
  }
  return value;
}
