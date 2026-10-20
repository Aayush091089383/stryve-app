/// One assignment as the student's Tasks tab receives it from the backend.
class Assignment {
  final int id;
  final String subject;
  final String title;
  final String? description;
  final String dueDate;
  final String? batch;

  /// True when the teacher attached a PDF or a video the student may open.
  final bool hasAttachment;
  final String? attachmentName;

  const Assignment({
    required this.id,
    required this.subject,
    required this.title,
    required this.dueDate,
    this.description,
    this.batch,
    this.hasAttachment = false,
    this.attachmentName,
  });

  factory Assignment.fromJson(Map<String, dynamic> json) {
    return Assignment(
      id: json['id'],
      subject: json['subject'],
      title: json['title'],
      description: json['description'],
      dueDate: json['due_date'],
      batch: json['batch'],
      hasAttachment: json['has_attachment'] as bool? ?? false,
      attachmentName: json['original_name'] as String?,
    );
  }

  /// Lower-case extension of the attachment, with the dot (`'.pdf'`, `'.mp4'`).
  ///
  /// Empty when there is no file name. The name is a display label the uploader
  /// chose, never a path, so nothing here is ever used to open a local file.
  String get attachmentExtension {
    final name = (attachmentName ?? '').trim();
    final dot = name.lastIndexOf('.');
    if (dot < 0 || dot == name.length - 1) return '';
    return name.substring(dot).toLowerCase();
  }

  /// True when the attachment is a video the in-app player can stream.
  ///
  /// The backend stores MP4/MOV/MKV and serves them with the matching content
  /// type; this only decides which screen opens.
  bool get isVideo => const <String>{
    '.mp4',
    '.mov',
    '.mkv',
    '.m4v',
    '.webm',
  }.contains(attachmentExtension);

  /// True when the attachment is a PDF (the only other kind the backend stores).
  bool get isPdf => attachmentExtension == '.pdf';

  /// True when there is something to open: an attachment the app can play or
  /// render. A name it does not recognise is treated as a PDF, because that is
  /// what every assignment the app could open before a video existed was.
  bool get isPlayable => hasAttachment && (isVideo || isPdf);
}
