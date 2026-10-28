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
    required this.division,
    required this.batch,
    required this.claimedByName,
  });

  final int id;
  final String day;

  /// The printed pair, e.g. "10:15 - 11:15" (24-hour, as on the sheet).
  final String time;

  /// The subject the period was claimed in, when the claim names one.
  final String? subject;

  final String division;

  /// Empty for a whole-division claim; otherwise the batch it applies to.
  final String batch;

  /// Who claimed the period, shown when there is no subject to name.
  final String claimedByName;

  bool get hasSubject => (subject ?? '').trim().isNotEmpty;

  bool get isWholeDivision => batch.trim().isEmpty;

  factory ScheduleChange.fromJson(Map<String, dynamic> json) {
    final subject = (json['subject'] as String?)?.trim();
    return ScheduleChange(
      id: (json['id'] as num?)?.toInt() ?? 0,
      day: (json['day'] as String?)?.trim() ?? '',
      time: (json['time'] as String?)?.trim() ?? '',
      subject: subject == null || subject.isEmpty ? null : subject,
      division: (json['division'] as String?)?.trim() ?? '',
      batch: (json['batch'] as String?)?.trim() ?? '',
      claimedByName: (json['claimed_by_name'] as String?)?.trim() ?? '',
    );
  }
}
