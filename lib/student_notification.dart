/// One in-app notification the backend created for this student.
///
/// The backend already scopes the feed to the authenticated student, so the row
/// carries no recipient id - only what is displayed here.
///
/// (`Notification` is a Flutter framework class, which is why this model is
/// [StudentNotification] rather than the obvious shorter name.)
class StudentNotification {
  const StudentNotification({
    required this.id,
    required this.title,
    required this.message,
    required this.isRead,
    this.createdAt,
  });

  final int id;
  final String title;
  final String message;
  final bool isRead;
  final DateTime? createdAt;

  factory StudentNotification.fromJson(Map<String, dynamic> json) {
    final rawCreatedAt = json['created_at'];

    return StudentNotification(
      id: (json['id'] as num?)?.toInt() ?? 0,
      title: (json['title'] as String?)?.trim().isNotEmpty == true
          ? (json['title'] as String).trim()
          : 'Notification',
      message: (json['message'] as String?) ?? '',
      // The feed comes from our own API, where this is always a bool; treat
      // anything else as unread rather than silently losing the badge.
      isRead: json['is_read'] == true,
      createdAt: rawCreatedAt is String
          ? DateTime.tryParse(rawCreatedAt)
          : null,
    );
  }

  StudentNotification copyWith({bool? isRead}) => StudentNotification(
    id: id,
    title: title,
    message: message,
    isRead: isRead ?? this.isRead,
    createdAt: createdAt,
  );
}

/// Number of unread rows in a feed. Shared by the bell badge and the screen so
/// they can never disagree about what "unread" means.
int unreadNotificationCount(List<StudentNotification> notifications) =>
    notifications.where((notification) => !notification.isRead).length;
