/// The seven subjects of Division D's first-year timetable, in the wording the
/// official sheet uses.
///
/// Assignments and announcements both file content under exactly these labels
/// (the backend validates against the same list), so the app keeps one copy:
/// the upload form and the announcement subject picker/chips all read this.
const List<String> kOfficialSubjects = <String>[
  'Engineering Mathematics-I',
  'Engineering Physics',
  'Basic Electrical Engineering',
  'Engineering Graphics',
  'Fundamentals of Programming Languages',
  'Design Thinking & Idea Lab',
  'Professional Communication Skills',
];
