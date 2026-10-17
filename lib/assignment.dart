/// One assignment as the student's Tasks tab receives it from the backend.
class Assignment {
  final int id;
  final String subject;
  final String title;
  final String? description;
  final String dueDate;
  final String? batch;

  /// True when the teacher attached a PDF the student may open.
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
}
