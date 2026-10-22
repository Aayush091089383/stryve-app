/// One assignment as the student's Tasks tab receives it from the backend.
class Assignment {
  final int id;
  final String subject;
  final String title;
  final String? description;
  final String dueDate;
  final String? batch;

  /// True when the teacher attached at least one PDF or video.
  final bool hasAttachment;

  /// The first attachment's display name. Kept for the single-file fields the
  /// backend still returns (and for clients that predate [attachments]).
  final String? attachmentName;

  /// Every file posted with this assignment, in upload order.
  final List<AssignmentAttachment> attachments;

  const Assignment({
    required this.id,
    required this.subject,
    required this.title,
    required this.dueDate,
    this.description,
    this.batch,
    this.hasAttachment = false,
    this.attachmentName,
    this.attachments = const [],
  });

  factory Assignment.fromJson(Map<String, dynamic> json) {
    final raw = json['attachments'];
    return Assignment(
      id: json['id'],
      subject: json['subject'],
      title: json['title'],
      description: json['description'],
      dueDate: json['due_date'],
      batch: json['batch'],
      hasAttachment: json['has_attachment'] as bool? ?? false,
      attachmentName: json['original_name'] as String?,
      attachments: raw is List
          ? raw
                .whereType<Map<String, dynamic>>()
                .map(AssignmentAttachment.fromJson)
                .toList()
          : const [],
    );
  }

  /// The files to show for this assignment.
  ///
  /// The backend lists every attachment; an older payload (or a row migrated
  /// from the single-file era) has only the legacy trio, which is described
  /// here as one attachment with id 0 - the "primary file" route.
  List<AssignmentAttachment> get files {
    if (attachments.isNotEmpty) return attachments;
    if (!hasAttachment) return const [];
    return [
      AssignmentAttachment(
        id: 0,
        name: (attachmentName ?? '').trim().isEmpty
            ? 'Attached file'
            : attachmentName!,
        fileSize: 0,
      ),
    ];
  }

  /// The first file, or null when nothing is attached.
  AssignmentAttachment? get primaryFile {
    final all = files;
    return all.isEmpty ? null : all.first;
  }

  /// Lower-case extension of the primary attachment, with the dot (`'.pdf'`,
  /// `'.mp4'`).
  ///
  /// Empty when there is no file name. The name is a display label the uploader
  /// chose, never a path, so nothing here is ever used to open a local file.
  String get attachmentExtension => primaryFile?.extension ?? '';

  /// True when the primary attachment is a video the in-app player can stream.
  ///
  /// The backend stores MP4/MOV/MKV and serves them with the matching content
  /// type; this only decides which screen opens.
  bool get isVideo => primaryFile?.isVideo ?? false;

  /// True when the primary attachment is a PDF.
  bool get isPdf => primaryFile?.isPdf ?? false;

  /// True when there is something to open: an attachment the app can play or
  /// render. A name it does not recognise is treated as a PDF, because that is
  /// what every assignment the app could open before a video existed was.
  bool get isPlayable => hasAttachment && files.isNotEmpty;
}

/// One file attached to an assignment.
class AssignmentAttachment {
  const AssignmentAttachment({
    required this.id,
    required this.name,
    this.fileSize = 0,
  });

  /// The attachment's id, or 0 for a single-file assignment served by the
  /// legacy `/assignments/{id}/file` route.
  final int id;

  /// The uploader's own file name, shown as-is.
  final String name;

  final int fileSize;

  factory AssignmentAttachment.fromJson(Map<String, dynamic> json) {
    return AssignmentAttachment(
      id: (json['id'] as num?)?.toInt() ?? 0,
      name: (json['original_name'] as String?)?.trim() ?? '',
      fileSize: (json['file_size'] as num?)?.toInt() ?? 0,
    );
  }

  bool get isLegacy => id <= 0;

  /// Lower-case extension, with the dot (`'.pdf'`, `'.mp4'`).
  String get extension {
    final trimmed = name.trim();
    final dot = trimmed.lastIndexOf('.');
    if (dot < 0 || dot == trimmed.length - 1) return '';
    return trimmed.substring(dot).toLowerCase();
  }

  bool get isVideo =>
      const <String>{'.mp4', '.mov', '.mkv', '.m4v', '.webm'}.contains(
        extension,
      );

  bool get isPdf => extension == '.pdf';

  /// Where the file itself is read from. Attachment ids and the legacy route
  /// are both authorized by the backend; this never widens what a student may
  /// open.
  String downloadPath(int assignmentId) => isLegacy
      ? '/assignments/$assignmentId/file'
      : '/assignments/$assignmentId/files/$id';
}
