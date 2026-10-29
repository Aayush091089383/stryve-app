/// The sheet's short code for each of the seven official Division D subjects.
///
/// Attendance is stored under the same label the timetable prints (`M-1`,
/// `PHY`, ...), while the admin picker offers the full official name. This map
/// bridges the two for the attendance API only - the picker and the review
/// screen keep showing the official name.
///
/// A teacher's subjects already come from `teacher_assignments` as codes, so
/// the lookup leaves those unchanged.
const Map<String, String> kSubjectAliasMap = <String, String>{
  'Engineering Mathematics-I': 'M-1',
  'Engineering Physics': 'PHY',
  'Basic Electrical Engineering': 'BEE',
  'Engineering Graphics': 'EG',
  'Fundamentals of Programming Languages': 'FPL',
  'Design Thinking & Idea Lab': 'DTIL',
  'Professional Communication Skills': 'PCS',
};

/// The subject label attendance is stored under.
///
/// Official names become the timetable's code; anything else (a teacher's own
/// assignment subject) is returned unchanged, so both roles write one column.
String attendanceSubjectFor(String subject) =>
    kSubjectAliasMap[subject] ?? subject;

/// The official name for a timetable code, or the label unchanged.
///
/// The schedule-change card must read "Engineering Graphics is cancelled",
/// while the sheet stores "EG". A full name (or an unknown label such as
/// "LIB") is returned as it is, so nothing is guessed.
String subjectLabelFor(String subject) {
  final cleaned = subject.trim();
  if (cleaned.isEmpty) return cleaned;

  for (final entry in kSubjectAliasMap.entries) {
    if (entry.value.toUpperCase() == cleaned.toUpperCase()) return entry.key;
  }
  return cleaned;
}
