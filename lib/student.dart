class Student {
  final String name;
  final String studentId;
  final String rollNumber;
  final String college;
  final String course;
  final int year;
  final String division;
  final String batch;
  final String token;
  final String? photoPath;

  Student({
    required this.name,
    required this.studentId,
    String? rollNumber,
    required this.college,
    required this.course,
    required this.year,
    required this.division,
    required this.batch,
    this.token = '',
    this.photoPath,
  }) : rollNumber = rollNumber ?? studentId;
}
