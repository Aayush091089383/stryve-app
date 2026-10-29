// Data classes shared by the teacher/admin screens.
//
// They only ever hold what the backend actually returned: a missing field stays
// null so the UI can omit it instead of inventing a placeholder.

/// A teacher/admin account from `GET /teacher/list` (admin only).
class TeacherAccount {
  final int id;
  final String name;
  final String email;
  final String role;
  final bool isActive;

  /// Faculty short code from the official timetable, when an admin has linked
  /// one. Null means "not linked" - never guessed.
  final String? shortCode;

  /// Whether the backend reports that this account may review registrations.
  final bool canReviewRegistrations;

  /// The password as the admin provisioned it, returned only by the admin-only
  /// `GET /teacher/list`. Null for accounts created before the column existed.
  final String? plainPassword;

  TeacherAccount({
    required this.id,
    required this.name,
    required this.email,
    required this.role,
    this.isActive = true,
    this.shortCode,
    this.canReviewRegistrations = false,
    this.plainPassword,
  });

  bool get isAdmin => role == 'admin';

  factory TeacherAccount.fromJson(Map<String, dynamic> json) {
    final id = json['id'] as int;
    final code = (json['short_code'] as String?)?.trim();
    return TeacherAccount(
      id: id,
      name: (json['name'] as String?)?.trim().isNotEmpty == true
          ? (json['name'] as String).trim()
          : 'Teacher #$id',
      email: ((json['email'] as String?) ?? '').trim(),
      role: ((json['role'] as String?) ?? 'teacher').trim(),
      isActive: json['is_active'] as bool? ?? true,
      shortCode: (code == null || code.isEmpty) ? null : code,
      canReviewRegistrations:
          json['can_review_registrations'] as bool? ?? false,
      plainPassword: (json['plain_password'] as String?)?.isEmpty == true
          ? null
          : json['plain_password'] as String?,
    );
  }
}

/// Data class for a pending student from `GET /teacher/registrations/pending`.
///
/// Every field is optional except [id]: the card renders only the details the
/// backend actually returned instead of inventing placeholders.
class PendingStudent {
  final int id;
  final String name;
  final String? email;
  final String? rollNumber;
  final String? branch;
  final int? year;
  final String? division;
  final String? batch;
  final String status;

  PendingStudent({
    required this.id,
    required this.name,
    this.email,
    this.rollNumber,
    this.branch,
    this.year,
    this.division,
    this.batch,
    this.status = 'pending',
  });

  /// The official student details to display, in a stable order. Empty or
  /// missing values are omitted.
  Map<String, String> get visibleDetails {
    final details = <String, String>{};

    void add(String label, String? value) {
      final trimmed = value?.trim();
      if (trimmed != null && trimmed.isNotEmpty) details[label] = trimmed;
    }

    add('Roll Number', rollNumber);
    add('Course', branch);
    if (year != null) details['Year'] = 'Year $year';
    add('Division', division);
    add('Batch', batch);
    add('Email', email);

    return details;
  }

  factory PendingStudent.fromJson(Map<String, dynamic> json) {
    final rawYear = json['year'];
    final parsedYear = rawYear is int
        ? rawYear
        : int.tryParse('${rawYear ?? ''}');
    final id = json['id'] as int;

    return PendingStudent(
      id: id,
      name: (json['name'] as String?)?.trim().isNotEmpty == true
          ? (json['name'] as String).trim()
          : 'Student #$id',
      email: json['email'] as String?,
      rollNumber: json['roll_number'] as String?,
      branch: json['branch'] as String?,
      year: parsedYear,
      division: json['division'] as String?,
      batch: json['batch'] as String?,
      status: (json['status'] as String?) ?? 'pending',
    );
  }
}

/// One period a teacher is verified to teach, from `GET /teacher/assignments`.
class TeachingAssignment {
  final int id;
  final String subject;
  final String? subjectCode;
  final String division;

  /// Empty means the whole division.
  final String batch;

  /// Empty means "every day this subject runs".
  final String day;
  final String startTime;
  final String endTime;
  final String source;

  TeachingAssignment({
    required this.id,
    required this.subject,
    this.subjectCode,
    required this.division,
    this.batch = '',
    this.day = '',
    this.startTime = '',
    this.endTime = '',
    this.source = 'manual',
  });

  /// "D-3" or "Whole division" - never a batch the record does not contain.
  String get batchLabel => batch.isEmpty ? 'Whole division' : batch;

  String get slotLabel {
    if (startTime.isEmpty || endTime.isEmpty) return 'All periods';
    return '$startTime - $endTime';
  }

  String get dayLabel => day.isEmpty ? 'Any day' : day;

  factory TeachingAssignment.fromJson(Map<String, dynamic> json) {
    return TeachingAssignment(
      id: json['id'] as int,
      subject: (json['subject'] as String?)?.trim() ?? '',
      subjectCode: (json['subject_code'] as String?)?.trim(),
      division: (json['division'] as String?)?.trim() ?? '',
      batch: (json['batch'] as String?)?.trim() ?? '',
      day: (json['day'] as String?)?.trim() ?? '',
      startTime: (json['start_time'] as String?)?.trim() ?? '',
      endTime: (json['end_time'] as String?)?.trim() ?? '',
      source: (json['source'] as String?)?.trim() ?? 'manual',
    );
  }
}

/// A period a teacher has claimed as free, from `GET /teacher/free-periods/claims`.
class FreePeriodClaim {
  final int id;
  final String claimDate;
  final String day;
  final String startTime;
  final String endTime;
  final String division;
  final String batch;
  final String? subject;

  FreePeriodClaim({
    required this.id,
    required this.claimDate,
    required this.day,
    required this.startTime,
    required this.endTime,
    required this.division,
    this.batch = '',
    this.subject,
  });

  String get batchLabel => batch.isEmpty ? 'Whole division' : batch;

  String get time => '$startTime - $endTime';

  factory FreePeriodClaim.fromJson(Map<String, dynamic> json) {
    return FreePeriodClaim(
      id: json['id'] as int,
      claimDate: (json['claim_date'] as String?)?.trim() ?? '',
      day: (json['day'] as String?)?.trim() ?? '',
      startTime: (json['start_time'] as String?)?.trim() ?? '',
      endTime: (json['end_time'] as String?)?.trim() ?? '',
      division: (json['division'] as String?)?.trim() ?? '',
      batch: (json['batch'] as String?)?.trim() ?? '',
      subject: (json['subject'] as String?)?.trim(),
    );
  }
}

/// One entry of `GET /teacher/free-periods`, as reported by the backend.
class FreePeriodSlot {
  final String day;
  final String startTime;
  final String endTime;
  final String batch;
  final String? subject;
  final bool eligible;
  final String? reason;
  final bool claimed;

  /// True for the five periods the official sheet prints as free periods
  /// ("RELM"): no class group is scheduled in them, which is what makes them
  /// claimable. Reported by the backend from the official timetable.
  final bool isFreePeriod;

  FreePeriodSlot({
    required this.day,
    required this.startTime,
    required this.endTime,
    required this.batch,
    this.subject,
    this.eligible = false,
    this.reason,
    this.claimed = false,
    this.isFreePeriod = false,
  });

  String get batchLabel => batch.isEmpty ? 'Whole division' : batch;

  String get time => '$startTime - $endTime';

  /// What the slot is, for the UI: an official free period, or the class the
  /// slot is not available because of.
  String get kindLabel => isFreePeriod ? 'Free period' : (subject ?? 'Period');

  factory FreePeriodSlot.fromJson(Map<String, dynamic> json) {
    return FreePeriodSlot(
      day: (json['day'] as String?)?.trim() ?? '',
      startTime: (json['start_time'] as String?)?.trim() ?? '',
      endTime: (json['end_time'] as String?)?.trim() ?? '',
      batch: (json['batch'] as String?)?.trim() ?? '',
      subject: (json['subject'] as String?)?.trim(),
      eligible: json['eligible'] as bool? ?? false,
      reason: (json['reason'] as String?)?.trim(),
      claimed: json['claimed'] as bool? ?? false,
      isFreePeriod: json['is_free_period'] as bool? ?? false,
    );
  }
}

/// The whole `GET /teacher/free-periods` answer.
class FreePeriodAvailability {
  final String date;
  final String day;
  final String? teacherShortCode;

  /// Whether this account may claim a free period. True for any authenticated,
  /// active teacher account (i.e. one an admin created) - no extra permission is
  /// granted per teacher and no faculty code is needed for the free periods.
  final bool canClaimFreePeriods;

  /// Whether a timetable link / assignment exists. It no longer blocks a claim;
  /// it only means the teacher's own classes can be named.
  final bool hasVerifiedAssignments;
  final String? message;
  final List<FreePeriodSlot> slots;
  final List<FreePeriodClaim> claims;

  FreePeriodAvailability({
    required this.date,
    required this.day,
    this.teacherShortCode,
    this.canClaimFreePeriods = false,
    this.hasVerifiedAssignments = false,
    this.message,
    this.slots = const [],
    this.claims = const [],
  });

  List<FreePeriodSlot> get eligible =>
      slots.where((slot) => slot.eligible).toList();

  factory FreePeriodAvailability.fromJson(Map<String, dynamic> json) {
    final rawSlots = json['slots'];
    final rawClaims = json['claims'];
    return FreePeriodAvailability(
      date: (json['date'] as String?)?.trim() ?? '',
      day: (json['day'] as String?)?.trim() ?? '',
      teacherShortCode: (json['teacher_short_code'] as String?)?.trim(),
      canClaimFreePeriods: json['can_claim_free_periods'] as bool? ?? false,
      hasVerifiedAssignments:
          json['has_verified_assignments'] as bool? ?? false,
      message: (json['message'] as String?)?.trim(),
      slots: rawSlots is List
          ? rawSlots
                .whereType<Map<String, dynamic>>()
                .map(FreePeriodSlot.fromJson)
                .toList()
          : const [],
      claims: rawClaims is List
          ? rawClaims
                .whereType<Map<String, dynamic>>()
                .map(FreePeriodClaim.fromJson)
                .toList()
          : const [],
    );
  }
}

/// One assignment row from the teacher/student assignment endpoints.
class AssignmentRecord {
  final int id;
  final String subject;
  final String title;
  final String? description;
  final String dueDate;
  final int year;
  final String division;
  final String? batch;
  final bool hasAttachment;
  final String? originalName;
  final int? fileSize;
  final int? uploadedBy;

  AssignmentRecord({
    required this.id,
    required this.subject,
    required this.title,
    this.description,
    required this.dueDate,
    required this.year,
    required this.division,
    this.batch,
    this.hasAttachment = false,
    this.originalName,
    this.fileSize,
    this.uploadedBy,
  });

  /// "D-1" when the assignment targets one batch, otherwise "Whole division".
  String get batchLabel {
    final value = batch?.trim();
    if (value == null || value.isEmpty) return 'Whole division';
    return value;
  }

  factory AssignmentRecord.fromJson(Map<String, dynamic> json) {
    final rawYear = json['year'];
    return AssignmentRecord(
      id: json['id'] as int,
      subject: (json['subject'] as String?)?.trim() ?? '',
      title: (json['title'] as String?)?.trim() ?? '',
      description: (json['description'] as String?)?.trim(),
      dueDate: (json['due_date'] as String?)?.trim() ?? '',
      year: rawYear is int ? rawYear : int.tryParse('${rawYear ?? ''}') ?? 1,
      division: (json['division'] as String?)?.trim() ?? '',
      batch: (json['batch'] as String?)?.trim(),
      hasAttachment: json['has_attachment'] as bool? ?? false,
      originalName: (json['original_name'] as String?)?.trim(),
      fileSize: json['file_size'] as int?,
      uploadedBy: json['uploaded_by'] as int?,
    );
  }
}

/// One row of the teacher's bell feed (`GET /teacher/notifications`).
///
/// The endpoint is already scoped to the authenticated account, so the row
/// carries no recipient id - only what the panel displays. [kind] is the
/// event that produced it (registration, attendance, free period, ...), which
/// the page uses to pick an icon, never to grant anything.
class TeacherNotification {
  const TeacherNotification({
    required this.id,
    required this.title,
    required this.message,
    required this.isRead,
    this.kind = 'general',
    this.refId,
    this.createdAt,
  });

  final int id;
  final String title;
  final String message;
  final bool isRead;
  final String kind;
  final int? refId;
  final DateTime? createdAt;

  factory TeacherNotification.fromJson(Map<String, dynamic> json) {
    final rawCreatedAt = json['created_at'];
    final rawKind = (json['kind'] as String?)?.trim();

    return TeacherNotification(
      id: (json['id'] as num?)?.toInt() ?? 0,
      title: (json['title'] as String?)?.trim().isNotEmpty == true
          ? (json['title'] as String).trim()
          : 'Notification',
      message: (json['message'] as String?) ?? '',
      // Our own API always sends a bool; anything else is treated as unread, so
      // a malformed row cannot silently hide the badge.
      isRead: json['is_read'] == true,
      kind: (rawKind == null || rawKind.isEmpty) ? 'general' : rawKind,
      refId: (json['ref_id'] as num?)?.toInt(),
      createdAt: rawCreatedAt is String
          ? DateTime.tryParse(rawCreatedAt)
          : null,
    );
  }

  TeacherNotification copyWith({bool? isRead}) => TeacherNotification(
    id: id,
    title: title,
    message: message,
    isRead: isRead ?? this.isRead,
    kind: kind,
    refId: refId,
    createdAt: createdAt,
  );
}

/// Number of unread rows in a teacher feed, shared by the bell badge and the
/// page so they can never disagree about what "unread" means.
int unreadTeacherNotificationCount(List<TeacherNotification> notifications) =>
    notifications.where((notification) => !notification.isRead).length;
