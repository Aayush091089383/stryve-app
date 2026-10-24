import 'dart:math' as math;

/// One recorded lecture for one subject.
class AttendanceLecture {
  const AttendanceLecture({
    required this.date,
    required this.period,
    required this.status,
  });

  /// `YYYY-MM-DD`, exactly as the backend stored it.
  final String date;

  /// The printed period label, e.g. `10:15-11:15`.
  final String period;

  /// `present` or `absent`.
  final String status;

  bool get isPresent => status == 'present';

  factory AttendanceLecture.fromJson(Map<String, dynamic> json) {
    return AttendanceLecture(
      date: (json['date'] as String?)?.trim() ?? '',
      period: (json['period'] as String?)?.trim() ?? '',
      status: ((json['status'] as String?) ?? '').trim().toLowerCase(),
    );
  }
}

/// One subject's attendance, with every lecture behind the percentage.
class SubjectAttendance {
  const SubjectAttendance({
    required this.subject,
    required this.totalClasses,
    required this.attended,
    required this.percentage,
    this.lectures = const [],
  });

  final String subject;
  final int totalClasses;
  final int attended;
  final double percentage;
  final List<AttendanceLecture> lectures;

  /// How many more lectures must be attended, in a row, to reach 75%.
  ///
  /// With `a` attended out of `t` lectures, the smallest `n` with
  /// `(a + n) / (t + n) >= 0.75` is `3t - 4a`. Already at or above 75%, or with
  /// no lectures at all, the answer is zero.
  int get lecturesToReach75 {
    if (totalClasses <= 0) return 0;
    return math.max(0, 3 * totalClasses - 4 * attended);
  }

  bool get isBelowThreshold => totalClasses > 0 && percentage < 75;

  factory SubjectAttendance.fromJson(Map<String, dynamic> json) {
    final lectures =
        ((json['lectures'] as List<dynamic>?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(AttendanceLecture.fromJson)
            .toList()
          ..sort(_lectureOrder);

    return SubjectAttendance(
      subject: (json['subject'] as String?)?.trim() ?? '',
      totalClasses: (json['total_classes'] as num?)?.toInt() ?? 0,
      attended: (json['attended'] as num?)?.toInt() ?? 0,
      percentage: (json['percentage'] as num?)?.toDouble() ?? 0,
      lectures: lectures,
    );
  }
}

/// Newest lecture first, then the later period first.
int _lectureOrder(AttendanceLecture a, AttendanceLecture b) {
  final byDate = b.date.compareTo(a.date);
  if (byDate != 0) return byDate;
  return b.period.compareTo(a.period);
}

/// The signed-in student's whole attendance picture.
class StudentAttendance {
  const StudentAttendance({
    required this.overallPercentage,
    required this.totalClasses,
    required this.attended,
    required this.subjects,
  });

  final double overallPercentage;
  final int totalClasses;
  final int attended;
  final List<SubjectAttendance> subjects;

  bool get hasRecords => totalClasses > 0;

  factory StudentAttendance.fromJson(Map<String, dynamic> json) {
    final subjects =
        ((json['subjects'] as List<dynamic>?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(SubjectAttendance.fromJson)
            .toList()
          ..sort(
            (a, b) =>
                a.subject.toLowerCase().compareTo(b.subject.toLowerCase()),
          );

    return StudentAttendance(
      overallPercentage: (json['overall_percentage'] as num?)?.toDouble() ?? 0,
      totalClasses: (json['total_classes'] as num?)?.toInt() ?? 0,
      attended: (json['attended'] as num?)?.toInt() ?? 0,
      subjects: subjects,
    );
  }
}

/// `2026-10-24` -> `24 Oct 2026`. An unparseable value is returned unchanged,
/// so the row never shows a fabricated date.
String formatAttendanceDate(String isoDate) {
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];

  final parts = isoDate.split('-');
  if (parts.length != 3 || parts[0].length != 4) return isoDate;

  final year = int.tryParse(parts[0]);
  final month = int.tryParse(parts[1]);
  final day = int.tryParse(parts[2]);
  if (year == null || month == null || day == null) return isoDate;
  if (month < 1 || month > 12) return isoDate;
  if (day < 1 || day > 31) return isoDate;

  return '$day ${months[month - 1]} $year';
}
