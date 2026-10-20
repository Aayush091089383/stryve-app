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

  const Announcement({
    required this.id,
    required this.title,
    required this.message,
    required this.authorId,
    required this.authorName,
    required this.createdAt,
    this.year,
    this.division,
  });

  factory Announcement.fromJson(Map<String, dynamic> json) {
    return Announcement(
      id: (json['id'] as num?)?.toInt() ?? 0,
      title: (json['title'] as String?) ?? '',
      message: (json['message'] as String?) ?? '',
      authorId: (json['author_id'] as num?)?.toInt() ?? 0,
      authorName: (json['author_name'] as String?) ?? 'CampusSync',
      createdAt: (json['created_at'] as String?) ?? '',
      year: (json['year'] as num?)?.toInt(),
      division: json['division'] as String?,
    );
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
