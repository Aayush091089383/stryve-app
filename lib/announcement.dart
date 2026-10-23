import 'assignment.dart';

/// One announcement as the student feed and the poster's confirmation see it.
///
/// The model lives on its own so the student feed ([AnnouncementsPage]) and the
/// teacher compose screen ([TeacherAnnouncementsPage]) share one parser instead
/// of two look-alikes. Everything the backend sends is read-only: an
/// announcement is a record of something that was posted and is never edited in
/// the app.
class Announcement {
  final int id;
  final String title;
  final String message;

  /// The teacher account that posted it, resolved server-side - the client
  /// never sends an author.
  final int authorId;
  final String authorName;

  /// Raw ISO timestamp from the backend ("2026-10-20T12:46:28.980601").
  final String createdAt;

  /// Restrictions set by the poster. null means "no restriction on this
  /// field", so both null is a college-wide notice.
  final int? year;
  final String? division;

  /// The official subject this notice is filed under, or null for "Common" -
  /// a general notice tied to no single subject. Older posts carry null too.
  final String? subject;

  /// PDFs/videos posted with the notice, in upload order. Empty for a text-only
  /// announcement, which is what every post was before files were supported.
  final List<AssignmentAttachment> attachments;

  const Announcement({
    required this.id,
    required this.title,
    required this.message,
    required this.authorId,
    required this.authorName,
    required this.createdAt,
    this.year,
    this.division,
    this.subject,
    this.attachments = const [],
  });

  factory Announcement.fromJson(Map<String, dynamic> json) {
    final raw = json['attachments'];
    // An empty string and null both mean Common; the backend stores null.
    final rawSubject = (json['subject'] as String?)?.trim() ?? '';
    return Announcement(
      id: (json['id'] as num?)?.toInt() ?? 0,
      title: (json['title'] as String?) ?? '',
      message: (json['message'] as String?) ?? '',
      authorId: (json['author_id'] as num?)?.toInt() ?? 0,
      authorName: (json['author_name'] as String?) ?? 'CampusSync',
      createdAt: (json['created_at'] as String?) ?? '',
      year: (json['year'] as num?)?.toInt(),
      division: json['division'] as String?,
      subject: rawSubject.isEmpty ? null : rawSubject,
      attachments: raw is List
          ? raw
                .whereType<Map<String, dynamic>>()
                .map(AssignmentAttachment.fromJson)
                .toList()
          : const [],
    );
  }

  /// True when at least one PDF or video is attached.
  bool get hasAttachments => attachments.isNotEmpty;

  /// The first file, or null when the notice is text-only.
  AssignmentAttachment? get primaryFile =>
      attachments.isEmpty ? null : attachments.first;

  /// The kind of the first attachment, mirroring [Assignment]. The feed still
  /// checks each file individually, because one notice can carry both kinds.
  bool get isVideo => primaryFile?.isVideo ?? false;
  bool get isPdf => primaryFile?.isPdf ?? false;

  /// Authorized download path for one of this notice's files.
  String filePath(AssignmentAttachment file) =>
      '/announcements/$id/files/${file.id}';

  /// The subject as the feed shows it: the official label, or "Common" when
  /// the notice is not tied to one subject.
  String get subjectLabel {
    final value = (subject ?? '').trim();
    return value.isEmpty ? 'Common' : value;
  }

  /// True when the post is limited to one year or one division.
  bool get isRestricted => year != null || division != null;

  /// Who the post is for: "Year 1 • Division D", "Year 1", "Division D", or
  /// null for a college-wide notice (the feed then shows nothing extra).
  String? get audienceLabel {
    final parts = <String>[
      if (year != null) 'Year $year',
      if (division != null && division!.isNotEmpty) 'Division $division',
    ];
    return parts.isEmpty ? null : parts.join(' • ');
  }

  /// The posting date in the app's "20 Oct 2026" wording.
  String get postedLabel => formatAnnouncementDate(createdAt);
}

/// Formats a backend timestamp as "20 Oct 2026".
///
/// Same day/month wording as [formatAssignmentDueDate] so the feed and the
/// assignment cards read alike; anything unparseable is shown as-is rather than
/// hidden.
String formatAnnouncementDate(String raw) {
  try {
    final date = DateTime.parse(raw);
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
    return '${date.day} ${months[date.month - 1]} ${date.year}';
  } catch (_) {
    return raw;
  }
}
