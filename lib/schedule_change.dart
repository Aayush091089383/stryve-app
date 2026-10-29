/// One claimed free period, from `GET /student/schedule-changes`.
///
/// The backend already scopes the list to today's claims for the student's own
/// division and batch (whole-division claims included), so this model never
/// filters anything itself: what it receives is what the student should see.
class ScheduleChange {
  const ScheduleChange({
    required this.id,
    required this.day,
    required this.time,
    this.subject,
    this.cancelledSubject,
    required this.division,
    required this.batch,
    required this.claimedByName,
    this.claimedByCode = '',
  });

  final int id;
  final String day;

  /// The printed pair, e.g. "10:15 - 11:15" (24-hour, as on the sheet).
  final String time;

  /// The subject the period was claimed in, when the claim names one.
  final String? subject;

  /// The class this period frees the student from. Falls back to [subject]
  /// when talking to a backend that predates the dedicated field.
  final String? cancelledSubject;

  final String division;

  /// Empty for a whole-division claim; otherwise the batch it applies to.
  final String batch;

  /// Who claimed the period.
  final String claimedByName;

  /// The claimant's faculty code ("SMG"), or empty when the account has none.
  final String claimedByCode;

  /// The code the timetable prints when known, otherwise the account name.
  String get claimedByLabel =>
      claimedByCode.trim().isEmpty ? claimedByName : claimedByCode.trim();

  bool get hasCancelledSubject =>
      (cancelledSubject ?? '').trim().isNotEmpty;

  bool get hasSubject => (subject ?? '').trim().isNotEmpty;

  bool get isWholeDivision => batch.trim().isEmpty;

  factory ScheduleChange.fromJson(Map<String, dynamic> json) {
    final subject = (json['subject'] as String?)?.trim();
    final cancelled = (json['cancelled_subject'] as String?)?.trim();
    return ScheduleChange(
      id: (json['id'] as num?)?.toInt() ?? 0,
      day: (json['day'] as String?)?.trim() ?? '',
      time: (json['time'] as String?)?.trim() ?? '',
      subject: subject == null || subject.isEmpty ? null : subject,
      cancelledSubject: cancelled == null || cancelled.isEmpty
          ? (subject == null || subject.isEmpty ? null : subject)
          : cancelled,
      division: (json['division'] as String?)?.trim() ?? '',
      batch: (json['batch'] as String?)?.trim() ?? '',
      claimedByName: (json['claimed_by_name'] as String?)?.trim() ?? '',
      claimedByCode: (json['claimed_by_code'] as String?)?.trim() ?? '',
    );
  }
}
