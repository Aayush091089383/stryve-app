import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'config/environment.dart';
import 'services/teacher_auth_service.dart';
import 'teacher_login_page.dart';
import 'teacher_models.dart';
import 'utils/glass_container.dart';
import 'utils/official_subjects.dart';
import 'utils/subject_aliases.dart';
import 'utils/teacher_api.dart';

/// The periods of the official Division D timetable, used only to offer choices.
/// The backend re-validates every slot, so a stale list here cannot widen what
/// is accepted.
const List<List<String>> kTimetableSlots = [
  ['10:15', '11:15'],
  ['11:15', '12:15'],
  ['13:00', '14:00'],
  ['14:00', '15:00'],
  ['15:15', '16:15'],
  ['16:15', '17:15'],
];

/// Every class group an attendance sheet may cover: the whole division, or one
/// of the three practical batches.
const List<String> kAttendanceBatches = ['', 'D-1', 'D-2', 'D-3'];

/// Stryve's college runs a four-year BE programme, so year five does not exist.
const List<int> kAttendanceYears = [1, 2, 3, 4];

/// "15:15" -> "3:15 PM".
///
/// The timetable is stored as a 24-hour grid because the backend validates
/// exactly those strings; a teacher reads a clock face, so only the labels are
/// converted. An unparseable value is returned unchanged rather than guessed at.
String formatClock12h(String hhmm) {
  final parts = hhmm.split(':');
  if (parts.length != 2) return hhmm;
  final hour24 = int.tryParse(parts[0]);
  final minute = int.tryParse(parts[1]);
  if (hour24 == null || minute == null) return hhmm;
  final suffix = hour24 < 12 ? 'AM' : 'PM';
  final hour12 = hour24 % 12 == 0 ? 12 : hour24 % 12;
  return '$hour12:${minute.toString().padLeft(2, '0')} $suffix';
}

/// ["13:00", "14:00"] -> "1:00 PM - 2:00 PM".
String formatPeriod12h(List<String> slot) {
  if (slot.length != 2) return slot.join('-');
  return '${formatClock12h(slot[0])} - ${formatClock12h(slot[1])}';
}

/// "13:00-14:00" (the stored wire format) -> "1:00 PM - 2:00 PM".
String formatStoredPeriod12h(String period) {
  final parts = period.split('-');
  if (parts.length != 2) return period;
  return '${formatClock12h(parts[0].trim())} - ${formatClock12h(parts[1].trim())}';
}

const List<String> _monthNames = [
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

/// "2026-10-24" -> "24 Oct 2026". Anything unparseable is left alone.
String formatSessionDate(String isoDate) {
  final parts = isoDate.split('-');
  if (parts.length != 3) return isoDate;
  final year = int.tryParse(parts[0]);
  final month = int.tryParse(parts[1]);
  final day = int.tryParse(parts[2]);
  if (year == null || month == null || day == null) return isoDate;
  if (month < 1 || month > 12 || day < 1 || day > 31) return isoDate;
  return '$day ${_monthNames[month - 1]} $year';
}

enum _AttendanceStage { setup, marking, review }

class _ClassStudent {
  const _ClassStudent({
    this.id,
    required this.name,
    required this.rollNumber,
    required this.batch,
    this.branch = '',
    this.isRegistered = true,
  });

  /// The account id, or null while this student is only on the class roster.
  final int? id;
  final String name;
  final String rollNumber;
  final String batch;

  /// The branch on the student's account ('AI&DS'); empty for a roster entry
  /// whose student has not registered yet, because the branch is only known
  /// once an account exists.
  final String branch;
  final bool isRegistered;

  /// The stable identity of a row: attendance is keyed on the roll number,
  /// because that is the only thing that exists before a student registers.
  String get key => rollNumber;

  factory _ClassStudent.fromJson(Map<String, dynamic> json) {
    return _ClassStudent(
      id: json['id'] as int?,
      name: (json['name'] as String?)?.trim() ?? '',
      rollNumber: (json['roll_number'] as String?)?.trim() ?? '',
      batch: (json['batch'] as String?)?.trim() ?? '',
      branch: (json['branch'] as String?)?.trim() ?? '',
      isRegistered: (json['is_registered'] as bool?) ?? json['id'] is int,
    );
  }
}

/// One saved lecture from `GET /teacher/attendance/history`.
class _PastSession {
  const _PastSession({
    required this.classDate,
    required this.period,
    required this.subject,
    required this.division,
    required this.batch,
    required this.total,
    required this.present,
    required this.absent,
    required this.canDelete,
  });

  final String classDate;
  final String period;
  final String subject;
  final String division;
  final String batch;
  final int total;
  final int present;
  final int absent;

  /// Decided by the backend, never by this screen: admins may delete any
  /// session, a teacher only one they marked while its lecture window is open.
  /// The clock is the college's, so a client cannot judge it.
  final bool canDelete;

  /// Identifies the session on screen (the request itself is built from the
  /// fields, not from this string).
  String get key => '$subject|$classDate|$period|$batch';

  /// A copy with the tallies of an expanded session after a flip, so the list
  /// header never disagrees with the student rows below it.
  _PastSession copyWith({int? present, int? absent}) {
    return _PastSession(
      classDate: classDate,
      period: period,
      subject: subject,
      division: division,
      batch: batch,
      total: (present ?? this.present) + (absent ?? this.absent),
      present: present ?? this.present,
      absent: absent ?? this.absent,
      canDelete: canDelete,
    );
  }

  factory _PastSession.fromJson(Map<String, dynamic> json) {
    return _PastSession(
      classDate: (json['class_date'] as String?)?.trim() ?? '',
      period: (json['period'] as String?)?.trim() ?? '',
      subject: (json['subject'] as String?)?.trim() ?? '',
      division: (json['division'] as String?)?.trim() ?? '',
      batch: (json['batch'] as String?)?.trim() ?? '',
      total: (json['total'] as num?)?.toInt() ?? 0,
      present: (json['present'] as num?)?.toInt() ?? 0,
      absent: (json['absent'] as num?)?.toInt() ?? 0,
      canDelete: json['can_delete'] == true,
    );
  }
}

/// One student's row inside an expanded saved session.
class _SessionStudent {
  const _SessionStudent({
    required this.recordId,
    required this.rollNumber,
    required this.name,
    required this.status,
    this.updatedAt,
  });

  final int recordId;
  final String rollNumber;
  final String name;
  final String status;
  final String? updatedAt;

  _SessionStudent withStatus(String value) => _SessionStudent(
    recordId: recordId,
    rollNumber: rollNumber,
    name: name,
    status: value,
    updatedAt: updatedAt,
  );

  factory _SessionStudent.fromJson(Map<String, dynamic> json) {
    return _SessionStudent(
      recordId: (json['record_id'] as num?)?.toInt() ?? 0,
      rollNumber: (json['roll_number'] as String?)?.trim() ?? '',
      name: (json['name'] as String?)?.trim() ?? '',
      status: json['status'] == 'absent' ? 'absent' : 'present',
      updatedAt: json['updated_at'] as String?,
    );
  }
}

/// `GET /teacher/attendance/session`: the two lists and what this caller may do.
///
/// `canEdit` is the server's 24-hour correction window (or an admin); the screen
/// never computes it, because the window is judged away from this device.
class _SessionDetail {
  _SessionDetail({
    required this.canEdit,
    required this.present,
    required this.absent,
  });

  final bool canEdit;
  final List<_SessionStudent> present;
  final List<_SessionStudent> absent;

  factory _SessionDetail.fromJson(Map<String, dynamic> json) {
    final info = json['session'];
    final session = info is Map<String, dynamic>
        ? info
        : const <String, dynamic>{};

    List<_SessionStudent> parse(Object? value) => value is List
        ? value
              .whereType<Map<String, dynamic>>()
              .map(_SessionStudent.fromJson)
              .toList()
        : <_SessionStudent>[];

    return _SessionDetail(
      canEdit: session['can_edit'] == true,
      present: parse(json['present']),
      absent: parse(json['absent']),
    );
  }
}

/// Numeric roll numbers first (1, 2, 10), then any non-numeric label.
int _compareRolls(String a, String b) {
  final left = int.tryParse(a);
  final right = int.tryParse(b);
  if (left != null && right != null) return left.compareTo(right);
  if (left != null) return -1;
  if (right != null) return 1;
  return a.compareTo(b);
}

/// Swipe-based lecture attendance.
///
/// A teacher's subject list comes from their VERIFIED assignments
/// (`GET /teacher/assignments`), and the backend refuses any save for a class or
/// subject the caller is not assigned to teach, so this screen can never mark
/// attendance beyond what the teacher actually teaches. An admin has no
/// assignments but may mark any class, so their pickers offer the official
/// subjects, batches, years and periods - the backend still validates the save.
/// Swiping right marks a student present, swiping left absent; nothing is
/// written until the review screen is confirmed.
class TeacherAttendancePage extends StatefulWidget {
  const TeacherAttendancePage({
    super.key,
    this.authService,
    this.client,
    this.embedded = false,
    this.bottomInset = 0,
  });

  final TeacherAuthService? authService;
  final http.Client? client;

  /// When true the page renders without its own Scaffold/app bar, for use as a
  /// tab inside the Teacher Panel.
  final bool embedded;

  /// Room the floating nav bar needs under the content (embedded mode only).
  final double bottomInset;

  @override
  State<TeacherAttendancePage> createState() => _TeacherAttendancePageState();
}

class _TeacherAttendancePageState extends State<TeacherAttendancePage> {
  late final TeacherAuthService _authService =
      widget.authService ?? TeacherAuthService();
  http.Client? _ownedClient;
  http.Client get _client => widget.client ?? (_ownedClient ??= http.Client());

  List<TeachingAssignment> _assignments = const [];
  List<_ClassStudent> _students = const [];

  String? _subject;
  String _batch = '';
  int _year = 1;

  /// Whether the signed-in account is an admin.
  ///
  /// An admin has no teaching assignments of their own, but may mark any class
  /// (the backend already allows that), so the pickers fall back to the full
  /// official lists instead of an empty assignment list.
  bool _isAdmin = false;
  String _division = 'D';
  DateTime _date = DateTime.now();
  List<String> _slot = kTimetableSlots.first;

  _AttendanceStage _stage = _AttendanceStage.setup;

  /// Roll numbers still waiting to be swiped, in roll order.
  final List<String> _queue = [];

  /// Roll number -> 'present' | 'absent'. A student in here is marked.
  final Map<String, String> _marks = {};

  bool _isLoading = true;
  bool _isLoadingRoster = false;
  bool _isSaving = false;
  String? _loadError;
  int? _savedSessionCount;

  /// Saved lectures already on the server, newest first.
  List<_PastSession> _pastSessions = const [];
  bool _isLoadingHistory = false;
  bool _historyLoaded = false;
  String? _historyError;

  /// The session whose delete request is in flight, so only its own button
  /// shows a spinner and a repeated tap cannot send a second request.
  String? _deletingSessionKey;

  /// Expanded sessions, the detail each one loaded, and the in-flight/error
  /// state per session. A session is fetched only when it is first opened.
  final Set<String> _expandedSessions = {};
  final Map<String, _SessionDetail> _sessionDetails = {};
  final Set<String> _loadingSessionDetails = {};
  final Map<String, String> _sessionDetailErrors = {};

  /// The record whose flip is in flight, so one tap cannot send two flips.
  String? _flippingRecordId;

  @override
  void initState() {
    super.initState();
    _loadAssignments();
  }

  @override
  void dispose() {
    _ownedClient?.close();
    super.dispose();
  }

  Future<void> _sessionLost() async {
    await _authService.clearAuthData();
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const TeacherLoginPage()),
      (route) => false,
    );
  }

  void _showSnackBar(String message, {Color? color}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message), backgroundColor: color));
  }

  String get _dateIso =>
      '${_date.year.toString().padLeft(4, '0')}-'
      '${_date.month.toString().padLeft(2, '0')}-'
      '${_date.day.toString().padLeft(2, '0')}';

  /// The wire format the backend validates ("13:00-14:00").
  String get _periodLabel => '${_slot[0]}-${_slot[1]}';

  /// The same period as a teacher reads it ("1:00 PM - 2:00 PM").
  String get _periodDisplay => formatPeriod12h(_slot);

  int get _unmarkedCount => _students.length - _marks.length;

  int get _presentCount => _marks.values.where((m) => m == 'present').length;

  int get _absentCount => _marks.values.where((m) => m == 'absent').length;

  Future<void> _loadAssignments() async {
    setState(() {
      _isLoading = true;
      _loadError = null;
    });

    try {
      final token = await _authService.getToken();
      if (!mounted) return;
      if (token == null) {
        await _sessionLost();
        return;
      }

      // The role was stored at login, so no extra round trip is needed to
      // decide which lists to offer.
      final account = await _authService.getTeacher();
      final isAdmin = account?.isAdmin ?? false;

      final response = await _client
          .get(
            Uri.parse('${Environment.backendUrl}/teacher/assignments'),
            headers: teacherHeaders(token),
          )
          .timeout(kTeacherRequestTimeout);

      if (!mounted) return;

      if (response.statusCode == 200) {
        final assignments = teacherJsonList(response.body)
            .map(TeachingAssignment.fromJson)
            .toList();
        setState(() {
          _isAdmin = isAdmin;
          _assignments = assignments;
          final subjects = _subjectChoices;
          _subject = subjects.isEmpty
              ? null
              : (subjects.contains(_subject) ? _subject : subjects.first);
          _batch = _batchForSubject(_subject);
          _slot = _slotForSubject(_subject) ?? _slot;
          _isLoading = false;
        });
        await _loadHistory();
        return;
      } else if (response.statusCode == 401) {
        await _sessionLost();
        return;
      } else {
        setState(() => _loadError = teacherMessageFromBody(response));
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadError = kTeacherUnreachableMessage);
    }

    if (mounted) setState(() => _isLoading = false);
  }

  /// The batch of the teacher's assignment for a subject ('' when it covers the
  /// whole division).
  String _batchForSubject(String? subject) {
    if (subject == null) return '';
    final match = _assignments.where((a) => a.subject == subject);
    if (match.isEmpty) return '';
    // Prefer a whole-division sheet when the subject is taught to the whole
    // division: it lists the entire class, and a single-batch sheet can be
    // empty when no student of that batch has registered yet.
    if (match.any((a) => a.batch.isEmpty)) return '';
    return match.first.batch;
  }

  /// The printed period of the teacher's assignment for a subject, so the
  /// default sheet is one the backend will actually accept.
  List<String>? _slotForSubject(String? subject) {
    if (subject == null) return null;
    for (final assignment in _assignments) {
      if (assignment.subject != subject) continue;
      if (assignment.startTime.isEmpty || assignment.endTime.isEmpty) continue;
      for (final slot in kTimetableSlots) {
        if (slot[0] == assignment.startTime && slot[1] == assignment.endTime) {
          return slot;
        }
      }
    }
    return null;
  }

  /// The subjects the picker offers.
  ///
  /// A teacher only sees the subjects they hold a verified assignment for. An
  /// admin has no assignments of their own, so the seven official subjects are
  /// offered instead; the backend validates whatever is saved either way.
  List<String> get _subjectChoices => _isAdmin
      ? kOfficialSubjects
      : <String>{for (final assignment in _assignments) assignment.subject}
            .toList();

  /// The class groups the picker offers for the selected subject.
  ///
  /// An admin may mark any group. A teacher sees the batches their own
  /// assignment covers, plus the whole division.
  List<String> get _batchChoices {
    if (_isAdmin) return kAttendanceBatches;
    return <String>{
      '',
      for (final assignment in _assignments)
        if (assignment.subject == _subject) assignment.batch,
    }.toList();
  }

  /// The periods the picker offers for the selected subject.
  ///
  /// A teacher sees only the slots their own assignment prints for that
  /// subject, so the picker cannot suggest a period the backend would refuse.
  /// When nothing pins the subject down - an admin has no assignments - the
  /// official slot grid is offered instead; the server still validates the
  /// period, so this can only ever offer choices, not widen what is accepted.
  List<List<String>> get _periodChoices {
    final subject = _subject;
    if (subject == null) return kTimetableSlots;

    final assigned = <String>{
      for (final assignment in _assignments)
        if (assignment.subject == subject &&
            assignment.startTime.isNotEmpty &&
            assignment.endTime.isNotEmpty)
          '${assignment.startTime}-${assignment.endTime}',
    };
    if (assigned.isEmpty) return kTimetableSlots;

    // Keep the sheet's order, then append any verified slot that is not one of
    // the printed periods (a practical block such as 13:00-15:00).
    final ordered = <List<String>>[];
    for (final slot in kTimetableSlots) {
      if (assigned.contains('${slot[0]}-${slot[1]}')) ordered.add(slot);
    }
    for (final raw in assigned) {
      if (ordered.any((slot) => '${slot[0]}-${slot[1]}' == raw)) continue;
      final parts = raw.split('-');
      if (parts.length == 2) ordered.add([parts[0], parts[1]]);
    }
    return ordered.isEmpty ? kTimetableSlots : ordered;
  }

  /// Applies a new subject and keeps the batch and period valid for it.
  void _selectSubject(String subject) {
    setState(() {
      _subject = subject;
      if (!_isAdmin) _batch = _batchForSubject(subject);
      final assignedSlot = _slotForSubject(subject);
      if (assignedSlot != null) _slot = assignedSlot;
      final periods = _periodChoices;
      if (!periods.any((slot) => slot[0] == _slot[0] && slot[1] == _slot[1])) {
        _slot = periods.first;
      }
    });
  }

  /// Loads the class roster and starts the swipe stage.
  ///
  /// Attendance already saved for this lecture is read back and pre-marked, so
  /// correcting a session starts from what is stored instead of forcing the
  /// teacher to re-swipe everyone. A failed read-back still lets marking start.
  Future<void> _loadStudents() async {
    final subject = _subject;
    if (subject == null || _isLoadingRoster) return;

    setState(() {
      _isLoadingRoster = true;
      _loadError = null;
      _savedSessionCount = null;
    });

    try {
      final token = await _authService.getToken();
      if (!mounted) return;
      if (token == null) {
        await _sessionLost();
        return;
      }

      final response = await _client
          .get(
            Uri.parse(
              '${Environment.backendUrl}/teacher/attendance/students'
              '?year=$_year'
              '&division=${Uri.encodeQueryComponent(_division)}'
              '&batch=${Uri.encodeQueryComponent(_batch)}',
            ),
            headers: teacherHeaders(token),
          )
          .timeout(kTeacherRequestTimeout);

      if (!mounted) return;

      if (response.statusCode == 200) {
        final students = teacherJsonList(response.body)
            .map(_ClassStudent.fromJson)
            .toList();

        final saved = await _fetchSavedSession(token);

        if (!mounted) return;
        setState(() {
          _students = students;
          _queue
            ..clear()
            ..addAll(
              students
                  .map((student) => student.key)
                  .where((key) => !saved.containsKey(key)),
            );
          _marks
            ..clear()
            ..addAll({
              for (final entry in saved.entries)
                if (students.any((student) => student.key == entry.key))
                  entry.key: entry.value,
            });
          _savedSessionCount = saved.isEmpty ? null : saved.length;
          _isLoadingRoster = false;
          _stage = _queue.isEmpty && students.isNotEmpty
              ? _AttendanceStage.review
              : _AttendanceStage.marking;
        });
        return;
      } else if (response.statusCode == 401) {
        await _sessionLost();
        return;
      } else {
        setState(() => _loadError = teacherMessageFromBody(response));
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadError = kTeacherUnreachableMessage);
    }

    if (mounted) setState(() => _isLoadingRoster = false);
  }

  /// What the server already holds for this lecture, as roll number -> status.
  /// Any failure is an empty map: marking must still be possible.
  Future<Map<String, String>> _fetchSavedSession(String token) async {
    final subject = _subject;
    if (subject == null) return const {};
    // Query the same label the save uses: an admin picks the official name,
    // but the lecture is stored under the sheet code.
    final storedSubject = attendanceSubjectFor(subject);

    try {
      final response = await _client
          .get(
            Uri.parse(
              '${Environment.backendUrl}/teacher/attendance'
              '?subject=${Uri.encodeQueryComponent(storedSubject)}'
              '&division=${Uri.encodeQueryComponent(_division)}'
              '&batch=${Uri.encodeQueryComponent(_batch)}'
              '&session_date=$_dateIso'
              '&slot_start=${_slot[0]}&slot_end=${_slot[1]}',
            ),
            headers: teacherHeaders(token),
          )
          .timeout(kTeacherRequestTimeout);

      if (!mounted || response.statusCode != 200) return const {};

      // Keyed by roll number: a lecture taken from the roster has no account
      // id, so an id-keyed map would silently lose those marks.
      final saved = <String, String>{};
      for (final row in teacherJsonList(response.body)) {
        final roll = row['roll_number'];
        final status = row['status'];
        if (roll is String && status is String) saved[roll] = status;
      }
      return saved;
    } catch (_) {
      return const {};
    }
  }

  void _mark(_ClassStudent student, String status) {
    if (_marks.containsKey(student.key)) return;
    setState(() {
      _marks[student.key] = status;
      _queue.remove(student.key);
      if (_queue.isEmpty) _stage = _AttendanceStage.review;
    });
  }

  void _flip(String rollNumber) {
    setState(() {
      _marks[rollNumber] = _marks[rollNumber] == 'present'
          ? 'absent'
          : 'present';
    });
  }

  void _markAllRemainingPresent() {
    if (_queue.isEmpty) return;
    setState(() {
      for (final key in _queue) {
        _marks[key] = 'present';
      }
      _queue.clear();
      _stage = _AttendanceStage.review;
    });
  }

  void _resetToSetup() {
    setState(() {
      _stage = _AttendanceStage.setup;
      _students = const [];
      _marks.clear();
      _queue.clear();
      _savedSessionCount = null;
    });
  }

  Future<void> _submit() async {
    final subject = _subject;
    if (subject == null || _students.isEmpty || _isSaving) return;
    if (_unmarkedCount > 0) return;

    // The picker shows the official name for an admin; the record is stored
    // under the sheet code so it joins the teacher's marks of the same class.
    final storedSubject = attendanceSubjectFor(subject);

    final token = await _authService.getToken();
    if (!mounted) return;
    if (token == null) {
      await _sessionLost();
      return;
    }

    setState(() => _isSaving = true);

    try {
      final response = await _client
          .post(
            Uri.parse('${Environment.backendUrl}/teacher/attendance/submit'),
            headers: teacherHeaders(token),
            body: jsonEncode({
              'class_date': _dateIso,
              'period': _periodLabel,
              'subject': storedSubject,
              'division': _division,
              'batch': _batch,
              'records': _students
                  .map(
                    (student) => {
                      'roll_number': student.rollNumber,
                      if (student.id != null) 'student_id': student.id,
                      'status': _marks[student.key] ?? 'present',
                    },
                  )
                  .toList(),
            }),
          )
          .timeout(kTeacherRequestTimeout);

      if (!mounted) return;

      if (response.statusCode == 200) {
        final body = jsonDecode(response.body) as Map<String, dynamic>;
        final present = body['present'] ?? _presentCount;
        final absent = body['absent'] ?? _absentCount;
        _showSnackBar(
          'Attendance saved · $present present, $absent absent',
          color: GlassColors.success,
        );
        _resetToSetup();
        // The lecture just saved belongs in the Past sessions list at once.
        await _loadHistory();
      } else if (response.statusCode == 401) {
        await _sessionLost();
      } else {
        _showSnackBar(teacherMessageFromBody(response));
      }
    } catch (_) {
      if (!mounted) return;
      _showSnackBar(kTeacherUnreachableMessage);
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  // -------------------------------------------------------------------------
  // Past sessions (history + soft delete)
  // -------------------------------------------------------------------------

  /// Loads the lectures already saved on the server.
  ///
  /// A failure is reported inside the section and never shown as "no sessions":
  /// a teacher who cannot reach the server must not conclude that attendance
  /// disappeared.
  Future<void> _loadHistory() async {
    if (_isLoadingHistory) return;

    setState(() {
      _isLoadingHistory = true;
      _historyError = null;
    });

    try {
      final token = await _authService.getToken();
      if (!mounted) return;
      if (token == null) {
        await _sessionLost();
        return;
      }

      final response = await _client
          .get(
            Uri.parse(
              '${Environment.backendUrl}/teacher/attendance/history?limit=50',
            ),
            headers: teacherHeaders(token),
          )
          .timeout(kTeacherRequestTimeout);

      if (!mounted) return;

      if (response.statusCode == 200) {
        final sessions = teacherJsonList(response.body)
            .map(_PastSession.fromJson)
            .toList();
        final keys = sessions.map((session) => session.key).toSet();
        setState(() {
          _pastSessions = sessions;
          _historyError = null;
          // Drop any expansion whose session is gone (deleted, or pushed out
          // of the 50-session window) so it cannot show stale rows.
          _expandedSessions.retainAll(keys);
          _sessionDetails.removeWhere((key, _) => !keys.contains(key));
          _sessionDetailErrors.removeWhere((key, _) => !keys.contains(key));
        });
        return;
      } else if (response.statusCode == 401) {
        await _sessionLost();
        return;
      } else {
        setState(() => _historyError = teacherMessageFromBody(response));
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => _historyError = kTeacherUnreachableMessage);
    } finally {
      if (mounted) {
        setState(() {
          _isLoadingHistory = false;
          _historyLoaded = true;
        });
      }
    }
  }

  /// Opens or closes one saved session, fetching its students the first time.
  void _toggleSession(_PastSession session) {
    final expanding = !_expandedSessions.contains(session.key);
    setState(() {
      if (expanding) {
        _expandedSessions.add(session.key);
      } else {
        _expandedSessions.remove(session.key);
      }
    });

    if (expanding &&
        !_sessionDetails.containsKey(session.key) &&
        !_loadingSessionDetails.contains(session.key)) {
      _loadSessionDetail(session);
    }
  }

  /// Loads the present/absent lists of one saved session.
  Future<void> _loadSessionDetail(_PastSession session) async {
    if (_loadingSessionDetails.contains(session.key)) return;

    setState(() {
      _loadingSessionDetails.add(session.key);
      _sessionDetailErrors.remove(session.key);
    });

    try {
      final token = await _authService.getToken();
      if (!mounted) return;
      if (token == null) {
        await _sessionLost();
        return;
      }

      final uri =
          Uri.parse('${Environment.backendUrl}/teacher/attendance/session')
              .replace(
                queryParameters: {
                  'class_date': session.classDate,
                  'period': session.period,
                  'subject': session.subject,
                  'division': session.division,
                  'batch': session.batch,
                },
              );

      final response = await _client
          .get(uri, headers: teacherHeaders(token))
          .timeout(kTeacherRequestTimeout);

      if (!mounted) return;

      if (response.statusCode == 200) {
        final decoded = jsonDecode(response.body);
        if (decoded is Map<String, dynamic>) {
          final detail = _SessionDetail.fromJson(decoded);
          detail.present.sort(
            (a, b) => _compareRolls(a.rollNumber, b.rollNumber),
          );
          detail.absent.sort(
            (a, b) => _compareRolls(a.rollNumber, b.rollNumber),
          );
          setState(() => _sessionDetails[session.key] = detail);
        }
      } else if (response.statusCode == 401) {
        await _sessionLost();
      } else {
        setState(
          () => _sessionDetailErrors[session.key] = teacherMessageFromBody(
            response,
          ),
        );
      }
    } catch (_) {
      if (!mounted) return;
      setState(
        () => _sessionDetailErrors[session.key] = kTeacherUnreachableMessage,
      );
    } finally {
      if (mounted) setState(() => _loadingSessionDetails.remove(session.key));
    }
  }

  /// Flips one student between present and absent, inside the server's window.
  Future<void> _flipRecord(
    _PastSession session,
    _SessionStudent student,
  ) async {
    if (_flippingRecordId != null) return;

    final detail = _sessionDetails[session.key];
    if (detail == null || !detail.canEdit) return;

    final next = student.status == 'present' ? 'absent' : 'present';

    final token = await _authService.getToken();
    if (!mounted) return;
    if (token == null) {
      await _sessionLost();
      return;
    }

    setState(() => _flippingRecordId = '${student.recordId}');

    try {
      final response = await _client
          .patch(
            Uri.parse(
              '${Environment.backendUrl}/teacher/attendance/record/'
              '${student.recordId}',
            ),
            headers: teacherHeaders(token),
            body: jsonEncode({'status': next}),
          )
          .timeout(kTeacherRequestTimeout);

      if (!mounted) return;

      if (response.statusCode == 200) {
        var updated = student.withStatus(next);
        try {
          final decoded = jsonDecode(response.body);
          if (decoded is Map<String, dynamic>) {
            updated = _SessionStudent.fromJson(decoded);
          }
        } catch (_) {
          // Non-JSON success body: the requested status is what was applied.
        }

        setState(() {
          detail.present.removeWhere((row) => row.recordId == student.recordId);
          detail.absent.removeWhere((row) => row.recordId == student.recordId);
          final target = next == 'present' ? detail.present : detail.absent;
          target.add(updated);
          detail.present.sort(
            (a, b) => _compareRolls(a.rollNumber, b.rollNumber),
          );
          detail.absent.sort(
            (a, b) => _compareRolls(a.rollNumber, b.rollNumber),
          );
          _replaceSessionCounts(
            session,
            present: detail.present.length,
            absent: detail.absent.length,
          );
        });

        _showSnackBar(
          '${updated.name.isEmpty ? 'Roll ${updated.rollNumber}' : updated.name} '
          'marked $next',
          color: GlassColors.success,
        );
      } else if (response.statusCode == 401) {
        await _sessionLost();
      } else {
        _showSnackBar(teacherMessageFromBody(response));
        if (response.statusCode == 403) {
          // The 24-hour window may have closed since the session was opened.
          await _loadSessionDetail(session);
        }
      }
    } catch (_) {
      if (!mounted) return;
      _showSnackBar(kTeacherUnreachableMessage);
    } finally {
      if (mounted) setState(() => _flippingRecordId = null);
    }
  }

  /// Keeps the list header's tallies in step with the expanded rows.
  void _replaceSessionCounts(
    _PastSession session, {
    required int present,
    required int absent,
  }) {
    final index = _pastSessions.indexWhere((item) => item.key == session.key);
    if (index == -1) return;
    final updated = List<_PastSession>.of(_pastSessions);
    updated[index] = _pastSessions[index].copyWith(
      present: present,
      absent: absent,
    );
    _pastSessions = updated;
  }

  /// Soft-deletes one saved lecture after an explicit confirmation.
  Future<void> _deleteSession(_PastSession session) async {
    if (_deletingSessionKey != null) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete attendance session?'),
        content: Text(
          'This will delete ${session.total} attendance '
          '${session.total == 1 ? 'record' : 'records'} for '
          '${session.subject} on ${formatSessionDate(session.classDate)} '
          '(${formatStoredPeriod12h(session.period)})'
          '${session.batch.isEmpty ? '' : ' · ${session.batch}'}. '
          'Students will no longer see these records. This cannot be undone, '
          'though the deletion is retained for administrators.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('attendance_delete_confirm'),
            style: FilledButton.styleFrom(backgroundColor: GlassColors.error),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    final token = await _authService.getToken();
    if (!mounted) return;
    if (token == null) {
      await _sessionLost();
      return;
    }

    setState(() => _deletingSessionKey = session.key);

    try {
      final response = await _client
          .delete(
            Uri.parse('${Environment.backendUrl}/teacher/attendance/session'),
            headers: teacherHeaders(token),
            body: jsonEncode({
              'class_date': session.classDate,
              'period': session.period,
              'subject': session.subject,
              'division': session.division,
              'batch': session.batch,
            }),
          )
          .timeout(kTeacherRequestTimeout);

      if (!mounted) return;

      if (response.statusCode == 200) {
        var count = session.total;
        try {
          final body = jsonDecode(response.body);
          if (body is Map && body['deleted_count'] is num) {
            count = (body['deleted_count'] as num).toInt();
          }
        } catch (_) {
          // Non-JSON success body: the session's own tally is the same number.
        }
        _showSnackBar(
          'Session deleted · $count ${count == 1 ? 'record' : 'records'}. '
          'It can be re-marked during the lecture window.',
          color: GlassColors.success,
        );
        await _loadHistory();
      } else if (response.statusCode == 401) {
        await _sessionLost();
      } else {
        _showSnackBar(teacherMessageFromBody(response));
      }
    } catch (_) {
      if (!mounted) return;
      _showSnackBar(kTeacherUnreachableMessage);
    } finally {
      if (mounted) setState(() => _deletingSessionKey = null);
    }
  }

  // -------------------------------------------------------------------------
  // Build
  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final body = SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
        24,
        24,
        24,
        widget.embedded ? widget.bottomInset + 24 : 40,
      ),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: kTeacherMaxContentWidth),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_isLoading)
                const Center(
                  child: Padding(
                    padding: EdgeInsets.symmetric(vertical: 32),
                    child: CircularProgressIndicator(
                      valueColor: AlwaysStoppedAnimation<Color>(
                        GlassColors.primaryBlue,
                      ),
                    ),
                  ),
                )
              else if (_loadError != null)
                _buildErrorCard()
              else if (_assignments.isEmpty && !_isAdmin)
                _buildNoAssignmentsCard()
              else ...[
                if (_stage == _AttendanceStage.setup) ...[
                  _buildSelector(),
                  const SizedBox(height: 20),
                  _buildPastSessions(),
                ],
                if (_stage == _AttendanceStage.marking) ...[
                  _buildLectureHeader(),
                  const SizedBox(height: 16),
                  _buildProgress(),
                  const SizedBox(height: 16),
                  _buildSwipeCard(),
                ],
                if (_stage == _AttendanceStage.review) ...[
                  _buildLectureHeader(),
                  const SizedBox(height: 16),
                  _buildReview(),
                ],
              ],
            ],
          ),
        ),
      ),
    );

    if (widget.embedded) return body;

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: const GlassAppBar(title: Text('Attendance')),
      body: GlassBackground(child: SafeArea(child: body)),
    );
  }

  Widget _buildErrorCard() {
    return GlassContainer(
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      borderRadius: 16,
      blurStrength: 15,
      opacity: 0.7,
      borderOpacity: 0.4,
      child: Column(
        children: [
          const Icon(
            Icons.cloud_off_rounded,
            size: 44,
            color: GlassColors.warning,
          ),
          const SizedBox(height: 12),
          Text(
            _loadError!,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: GlassColors.headingOf(context),
            ),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: 180,
            child: GlassOutlinedButton(
              onPressed: _loadAssignments,
              height: 44,
              borderRadius: 12,
              child: const Text('Retry'),
            ),
          ),
        ],
      ),
    );
  }

  /// Reporting the missing data instead of inventing an assignment list.
  Widget _buildNoAssignmentsCard() {
    return GlassContainer(
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      borderRadius: 16,
      blurStrength: 15,
      opacity: 0.7,
      borderOpacity: 0.4,
      child: Column(
        children: [
          const Icon(
            Icons.assignment_ind_outlined,
            size: 44,
            color: GlassColors.warning,
          ),
          const SizedBox(height: 12),
          Text(
            'No verified teaching assignments',
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w600,
              color: GlassColors.headingOf(context),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Stryve only records attendance for classes you are assigned '
            'to teach. Ask an administrator to link your faculty code from the '
            'official Division D timetable (or add your assignments) and try '
            'again.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13,
              color: GlassColors.secondaryTextOf(context),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSelector() {
    final subjects = _subjectChoices;
    final batches = _batchChoices;
    final periods = _periodChoices;
    final subjectValue = subjects.contains(_subject)
        ? _subject
        : (subjects.isEmpty ? null : subjects.first);
    final periodValue =
        periods.any((slot) => '${slot[0]}-${slot[1]}' == _periodLabel)
        ? _periodLabel
        : '${periods.first[0]}-${periods.first[1]}';

    return GlassContainer(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      borderRadius: 18,
      blurStrength: 15,
      opacity: 0.75,
      borderOpacity: 0.4,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Lecture',
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.bold,
              color: GlassColors.headingOf(context),
            ),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            key: ValueKey<String>('attendance-subject-$subjectValue'),
            initialValue: subjectValue,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Subject'),
            items: subjects
                .map(
                  (subject) => DropdownMenuItem<String>(
                    value: subject,
                    child: Text(subject, overflow: TextOverflow.ellipsis),
                  ),
                )
                .toList(),
            onChanged: (value) {
              if (value == null) return;
              _selectSubject(value);
            },
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<int>(
                  key: ValueKey<int>(_year),
                  initialValue: kAttendanceYears.contains(_year)
                      ? _year
                      : kAttendanceYears.first,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Year'),
                  items: kAttendanceYears
                      .map(
                        (year) => DropdownMenuItem<int>(
                          value: year,
                          child: Text('Year $year'),
                        ),
                      )
                      .toList(),
                  onChanged: (value) => setState(() => _year = value ?? _year),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: DropdownButtonFormField<String>(
                  key: ValueKey<String>(_division),
                  initialValue: _division,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Division'),
                  items: const ['D']
                      .map(
                        (division) => DropdownMenuItem<String>(
                          value: division,
                          child: Text('Division $division'),
                        ),
                      )
                      .toList(),
                  onChanged: (value) =>
                      setState(() => _division = value ?? _division),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<String>(
                  key: ValueKey<String>('attendance-batch-$_batch'),
                  initialValue: batches.contains(_batch) ? _batch : '',
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Batch'),
                  items: batches
                      .map(
                        (batch) => DropdownMenuItem<String>(
                          value: batch,
                          child: Text(
                            batch.isEmpty ? 'Whole division' : batch,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      )
                      .toList(),
                  onChanged: (value) => setState(() => _batch = value ?? ''),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: DropdownButtonFormField<String>(
                  key: ValueKey<String>('attendance-period-$periodValue'),
                  initialValue: periodValue,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Period'),
                  items: periods
                      .map(
                        (slot) => DropdownMenuItem<String>(
                          value: '${slot[0]}-${slot[1]}',
                          child: Text(
                            formatPeriod12h(slot),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      )
                      .toList(),
                  onChanged: (value) {
                    final match = periods.firstWhere(
                      (slot) => '${slot[0]}-${slot[1]}' == value,
                      orElse: () => periods.first,
                    );
                    setState(() => _slot = match);
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          GlassOutlinedButton(
            onPressed: () async {
              final picked = await showDatePicker(
                context: context,
                initialDate: _date,
                firstDate: DateTime.now().subtract(const Duration(days: 120)),
                lastDate: DateTime.now().add(const Duration(days: 120)),
              );
              if (picked == null || !mounted) return;
              setState(() => _date = picked);
            },
            height: 50,
            borderRadius: 12,
            child: Text('Date $_dateIso', style: const TextStyle(fontSize: 13)),
          ),
          const SizedBox(height: 14),
          GlassButton(
            key: const Key('attendance_load_students'),
            onPressed: _isLoadingRoster ? null : _loadStudents,
            height: 52,
            borderRadius: 14,
            isLoading: _isLoadingRoster,
            disabled: _isLoadingRoster,
            child: const Text(
              'LOAD STUDENTS',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }

  /// Saved lectures, with a Delete action only where the server allows it.
  Widget _buildPastSessions() {
    final hasError = _historyError != null;

    return GlassContainer(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      borderRadius: 18,
      blurStrength: 15,
      opacity: 0.75,
      borderOpacity: 0.4,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Past sessions',
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.bold,
                    color: GlassColors.headingOf(context),
                  ),
                ),
              ),
              IconButton(
                key: const Key('attendance_history_refresh'),
                tooltip: 'Refresh past sessions',
                onPressed: _isLoadingHistory ? null : _loadHistory,
                icon: const Icon(Icons.refresh_rounded, size: 20),
              ),
            ],
          ),
          Text(
            'A session can be deleted by the teacher who marked it while its '
            'lecture window is open; an administrator can delete any session.',
            style: TextStyle(
              fontSize: 11,
              color: GlassColors.disabledOf(context),
            ),
          ),
          const SizedBox(height: 12),
          if (_isLoadingHistory && !_historyLoaded)
            const Center(
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2.4),
                ),
              ),
            )
          else if (hasError && _pastSessions.isEmpty)
            Column(
              children: [
                Text(
                  _historyError!,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 13,
                    color: GlassColors.headingOf(context),
                  ),
                ),
                const SizedBox(height: 8),
                TextButton(onPressed: _loadHistory, child: const Text('Retry')),
              ],
            )
          else if (_pastSessions.isEmpty)
            Text(
              'No saved sessions yet. Lectures you submit will be listed here.',
              style: TextStyle(
                fontSize: 13,
                color: GlassColors.secondaryTextOf(context),
              ),
            )
          else ...[
            if (hasError)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  'Could not refresh the list: $_historyError',
                  style: TextStyle(fontSize: 12, color: GlassColors.error),
                ),
              ),
            for (final session in _pastSessions) _buildPastSessionCard(session),
          ],
        ],
      ),
    );
  }

  Widget _buildPastSessionCard(_PastSession session) {
    final isDeleting = _deletingSessionKey == session.key;
    final isExpanded = _expandedSessions.contains(session.key);
    final group = session.batch.isEmpty ? 'Whole division' : session.batch;

    return GlassCard(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Material(
            color: Colors.transparent,
            child: InkWell(
              key: Key('attendance_session_toggle_${session.key}'),
              onTap: () => _toggleSession(session),
              borderRadius: BorderRadius.circular(10),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          session.subject,
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: GlassColors.headingOf(context),
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${formatSessionDate(session.classDate)} · '
                          '${formatStoredPeriod12h(session.period)} · $group',
                          style: TextStyle(
                            fontSize: 12,
                            color: GlassColors.secondaryTextOf(context),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '${session.present} present · '
                          '${session.absent} absent · ${session.total} total',
                          style: TextStyle(
                            fontSize: 12,
                            color: GlassColors.disabledOf(context),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (session.canDelete)
                    TextButton(
                      key: Key('attendance_delete_${session.key}'),
                      onPressed: isDeleting
                          ? null
                          : () => _deleteSession(session),
                      style: TextButton.styleFrom(
                        foregroundColor: GlassColors.error,
                      ),
                      child: isDeleting
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('Delete'),
                    ),
                  Icon(
                    isExpanded
                        ? Icons.expand_less_rounded
                        : Icons.expand_more_rounded,
                    size: 20,
                    color: GlassColors.secondaryTextOf(context),
                  ),
                ],
              ),
            ),
          ),
          if (isExpanded) ...[
            const SizedBox(height: 8),
            _buildSessionDetail(session),
          ],
        ],
      ),
    );
  }

  /// The present/absent lists of one expanded session.
  Widget _buildSessionDetail(_PastSession session) {
    final detail = _sessionDetails[session.key];
    final error = _sessionDetailErrors[session.key];

    if (detail == null) {
      if (error != null) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              error,
              style: const TextStyle(fontSize: 12, color: GlassColors.error),
            ),
            TextButton(
              key: Key('attendance_session_retry_${session.key}'),
              onPressed: () => _loadSessionDetail(session),
              child: const Text('Retry'),
            ),
          ],
        );
      }
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 10),
        child: Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2.2),
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildAttendanceGroup(
          session,
          detail,
          label: 'Present',
          rows: detail.present,
        ),
        const SizedBox(height: 10),
        _buildAttendanceGroup(
          session,
          detail,
          label: 'Absent',
          rows: detail.absent,
        ),
        if (!detail.canEdit) ...[
          const SizedBox(height: 8),
          Text(
            'Marks can be corrected for 24 hours after the lecture was saved. '
            'An administrator can still change them.',
            style: TextStyle(
              fontSize: 11,
              color: GlassColors.disabledOf(context),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildAttendanceGroup(
    _PastSession session,
    _SessionDetail detail, {
    required String label,
    required List<_SessionStudent> rows,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '$label (${rows.length})',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: GlassColors.headingOf(context),
          ),
        ),
        if (rows.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              label == 'Present'
                  ? 'Nobody is marked present.'
                  : 'Nobody is marked absent.',
              style: TextStyle(
                fontSize: 12,
                color: GlassColors.secondaryTextOf(context),
              ),
            ),
          )
        else
          for (final student in rows)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '${student.rollNumber} · ${student.name}',
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        color: GlassColors.headingOf(context),
                      ),
                    ),
                  ),
                  if (detail.canEdit)
                    TextButton(
                      key: Key('attendance_flip_${student.recordId}'),
                      onPressed: _flippingRecordId == null
                          ? () => _flipRecord(session, student)
                          : null,
                      style: TextButton.styleFrom(
                        foregroundColor: student.status == 'present'
                            ? GlassColors.error
                            : GlassColors.success,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        minimumSize: const Size(0, 32),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      child: _flippingRecordId == '${student.recordId}'
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Text(
                              student.status == 'present'
                                  ? 'Mark absent'
                                  : 'Mark present',
                              style: const TextStyle(fontSize: 12),
                            ),
                    ),
                ],
              ),
            ),
      ],
    );
  }

  /// The lecture the sheet belongs to, so the teacher can see what they are
  /// marking before they submit it.
  Widget _buildLectureHeader() {
    return GlassCard(
      margin: EdgeInsets.zero,
      padding: const EdgeInsets.all(14),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _subject ?? 'Lecture',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: GlassColors.headingOf(context),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '$_dateIso · $_periodDisplay · '
                  '${_batch.isEmpty ? 'Whole division' : _batch}',
                  style: TextStyle(
                    fontSize: 12,
                    color: GlassColors.secondaryTextOf(context),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Attendance can be saved during this period only, with 15 '
                  'minutes of grace either side (IST).',
                  style: TextStyle(
                    fontSize: 11,
                    color: GlassColors.disabledOf(context),
                  ),
                ),
              ],
            ),
          ),
          if (_stage == _AttendanceStage.marking)
            TextButton(onPressed: _resetToSetup, child: const Text('Change')),
        ],
      ),
    );
  }

  Widget _buildProgress() {
    final total = _students.length;
    final marked = _marks.length;
    final fraction = total == 0 ? 0.0 : marked / total;

    return GlassContainer(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      borderRadius: 16,
      blurStrength: 15,
      opacity: 0.7,
      borderOpacity: 0.4,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '$marked / $total marked',
                  key: const Key('attendance_progress'),
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: GlassColors.headingOf(context),
                  ),
                ),
              ),
              Text(
                'Swipe → present · ← absent',
                style: TextStyle(
                  fontSize: 11,
                  color: GlassColors.secondaryTextOf(context),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: fraction,
              minHeight: 8,
              backgroundColor: GlassColors.borderOf(context),
              valueColor: const AlwaysStoppedAnimation<Color>(
                GlassColors.primaryBlue,
              ),
            ),
          ),
          if (_savedSessionCount != null) ...[
            const SizedBox(height: 10),
            Text(
              '$_savedSessionCount student(s) were already marked for this '
              'lecture and are kept as saved.',
              style: const TextStyle(fontSize: 12, color: GlassColors.warning),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildSwipeCard() {
    if (_students.isEmpty) return _buildEmptyRoster();
    if (_queue.isEmpty) return _buildEmptyRoster();

    final student = _students.firstWhere((s) => s.key == _queue.first);
    final next = _queue.length > 1
        ? _students.firstWhere((s) => s.key == _queue[1])
        : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: 240,
          child: Dismissible(
            key: Key('attendance_card_${student.key}'),
            direction: DismissDirection.horizontal,
            // Snappier than Flutter's defaults (200ms fly-off, 300ms collapse,
            // 0.4 threshold): marking a class should keep up with the thumb.
            movementDuration: const Duration(milliseconds: 120),
            resizeDuration: const Duration(milliseconds: 120),
            dismissThresholds: const {
              DismissDirection.startToEnd: 0.25,
              DismissDirection.endToStart: 0.25,
            },
            background: _swipeBackground(
              alignment: Alignment.centerLeft,
              color: GlassColors.success,
              icon: Icons.check_rounded,
              label: 'PRESENT',
            ),
            secondaryBackground: _swipeBackground(
              alignment: Alignment.centerRight,
              color: GlassColors.error,
              icon: Icons.close_rounded,
              label: 'ABSENT',
            ),
            onDismissed: (direction) => _mark(
              student,
              direction == DismissDirection.startToEnd ? 'present' : 'absent',
            ),
            child: GlassContainer(
              width: double.infinity,
              borderRadius: 24,
              opacity: 0.85,
              borderOpacity: 0.6,
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    student.rollNumber.isEmpty ? '—' : student.rollNumber,
                    style: TextStyle(
                      fontSize: 56,
                      fontWeight: FontWeight.bold,
                      height: 1,
                      color: GlassColors.headingOf(context),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    student.name,
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                      color: GlassColors.headingOf(context),
                    ),
                  ),
                  const SizedBox(height: 6),
                  // Branch first: it is what tells two classmates apart on the
                  // official list. A roster entry has no account yet, so it has
                  // no branch and falls back to its batch.
                  Text(
                    student.branch.isNotEmpty
                        ? student.branch
                        : (student.batch.isEmpty
                              ? 'Whole division'
                              : student.batch),
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: GlassColors.secondaryTextOf(context),
                    ),
                  ),
                  if (next != null) ...[
                    const SizedBox(height: 16),
                    Text(
                      'Next: ${next.rollNumber}',
                      style: TextStyle(
                        fontSize: 12,
                        color: GlassColors.disabledOf(context),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 14),
        Row(
          children: [
            Expanded(
              child: GlassButton(
                key: const Key('attendance_mark_absent'),
                onPressed: () => _mark(student, 'absent'),
                height: 46,
                borderRadius: 12,
                color: GlassColors.error,
                child: const Text(
                  'ABSENT',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: GlassButton(
                key: const Key('attendance_mark_present'),
                onPressed: () => _mark(student, 'present'),
                height: 46,
                borderRadius: 12,
                color: GlassColors.success,
                child: const Text(
                  'PRESENT',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: GlassOutlinedButton(
                onPressed: _queue.isEmpty ? null : _markAllRemainingPresent,
                height: 46,
                borderRadius: 12,
                child: const Text(
                  'Mark all remaining present',
                  style: TextStyle(fontSize: 12),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: GlassOutlinedButton(
                key: const Key('attendance_review'),
                onPressed: () =>
                    setState(() => _stage = _AttendanceStage.review),
                height: 46,
                borderRadius: 12,
                child: const Text('Review', style: TextStyle(fontSize: 12)),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _swipeBackground({
    required Alignment alignment,
    required Color color,
    required IconData icon,
    required String label,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(24),
      ),
      alignment: alignment,
      padding: const EdgeInsets.symmetric(horizontal: 28),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (alignment == Alignment.centerRight) ...[
            Text(
              label,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 15,
              ),
            ),
            const SizedBox(width: 8),
          ],
          Icon(icon, color: Colors.white, size: 34),
          if (alignment == Alignment.centerLeft) ...[
            const SizedBox(width: 8),
            Text(
              label,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 15,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildReview() {
    final absent = _students
        .where((student) => _marks[student.key] == 'absent')
        .toList();
    final unmarked = _students
        .where((student) => !_marks.containsKey(student.key))
        .toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: _summaryTile(
                'Total',
                _students.length,
                GlassColors.primaryBlue,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _summaryTile(
                'Present',
                _presentCount,
                GlassColors.success,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _summaryTile('Absent', _absentCount, GlassColors.error),
            ),
          ],
        ),
        const SizedBox(height: 16),
        if (unmarked.isNotEmpty) ...[
          GlassCard(
            margin: EdgeInsets.zero,
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                const Icon(
                  Icons.help_outline_rounded,
                  color: GlassColors.warning,
                  size: 22,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '${unmarked.length} student(s) still unmarked. Mark them '
                    'present, or go back and swipe.',
                    style: TextStyle(
                      fontSize: 12,
                      color: GlassColors.headingOf(context),
                    ),
                  ),
                ),
                TextButton(
                  onPressed: _markAllRemainingPresent,
                  child: const Text('Mark present'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
        ],
        Text(
          'Absent students',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.bold,
            color: GlassColors.headingOf(context),
          ),
        ),
        const SizedBox(height: 10),
        if (absent.isEmpty)
          GlassCard(
            margin: EdgeInsets.zero,
            padding: const EdgeInsets.all(14),
            child: Text(
              'Nobody is marked absent.',
              style: TextStyle(
                fontSize: 13,
                color: GlassColors.secondaryTextOf(context),
              ),
            ),
          )
        else
          ...absent.map(
            (student) => Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: GlassCard(
                margin: EdgeInsets.zero,
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            student.name,
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: GlassColors.headingOf(context),
                            ),
                          ),
                          Text(
                            'Roll ${student.rollNumber}',
                            style: TextStyle(
                              fontSize: 12,
                              color: GlassColors.secondaryTextOf(context),
                            ),
                          ),
                        ],
                      ),
                    ),
                    SizedBox(
                      width: 140,
                      child: GlassOutlinedButton(
                        onPressed: () => _flip(student.key),
                        height: 36,
                        borderRadius: 10,
                        child: const Text(
                          'Flip to present',
                          style: TextStyle(fontSize: 11),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        const SizedBox(height: 12),
        Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            title: Text(
              'All students (${_students.length})',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: GlassColors.headingOf(context),
              ),
            ),
            childrenPadding: const EdgeInsets.only(bottom: 4),
            children: _students
                .map(
                  (student) => Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            '${student.rollNumber} · ${student.name}',
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 13,
                              color: GlassColors.headingOf(context),
                            ),
                          ),
                        ),
                        TextButton(
                          onPressed: () => _flip(student.key),
                          child: Text(
                            _marks[student.key] == 'present'
                                ? 'Present'
                                : _marks[student.key] == 'absent'
                                ? 'Absent'
                                : 'Unmarked',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: _marks[student.key] == 'present'
                                  ? GlassColors.success
                                  : _marks[student.key] == 'absent'
                                  ? GlassColors.error
                                  : GlassColors.warning,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                )
                .toList(),
          ),
        ),
        const SizedBox(height: 16),
        GlassButton(
          key: const Key('attendance_submit'),
          onPressed: _isSaving || _unmarkedCount > 0 ? null : _submit,
          height: 52,
          borderRadius: 14,
          isLoading: _isSaving,
          disabled: _isSaving || _unmarkedCount > 0,
          child: Text(
            _unmarkedCount > 0
                ? 'MARK $_unmarkedCount REMAINING TO SUBMIT'
                : 'CONFIRM & SUBMIT',
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
        ),
        const SizedBox(height: 10),
        Center(
          child: TextButton(
            onPressed: _isSaving
                ? null
                : () => setState(() => _stage = _AttendanceStage.marking),
            child: const Text('Back to swiping'),
          ),
        ),
      ],
    );
  }

  Widget _summaryTile(String label, int value, Color color) {
    return GlassContainer(
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 10),
      borderRadius: 14,
      blurStrength: 12,
      opacity: 0.7,
      borderOpacity: 0.4,
      child: Column(
        children: [
          Text(
            '$value',
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              color: GlassColors.secondaryTextOf(context),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyRoster() {
    return GlassContainer(
      width: double.infinity,
      padding: const EdgeInsets.all(28),
      borderRadius: 16,
      blurStrength: 15,
      opacity: 0.6,
      borderOpacity: 0.3,
      child: Column(
        children: [
          Icon(
            Icons.groups_outlined,
            size: 44,
            color: GlassColors.disabledOf(context),
          ),
          const SizedBox(height: 12),
          Text(
            'No students in this class group',
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w600,
              color: GlassColors.headingOf(context),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Only approved students of this year, division and batch are '
            'listed.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13,
              color: GlassColors.secondaryTextOf(context),
            ),
          ),
        ],
      ),
    );
  }
}
