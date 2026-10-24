import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'config/environment.dart';
import 'services/teacher_auth_service.dart';
import 'teacher_login_page.dart';
import 'teacher_models.dart';
import 'utils/glass_container.dart';
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

enum _AttendanceStage { setup, marking, review }

class _ClassStudent {
  const _ClassStudent({
    this.id,
    required this.name,
    required this.rollNumber,
    required this.batch,
    this.isRegistered = true,
  });

  /// The account id, or null while this student is only on the class roster.
  final int? id;
  final String name;
  final String rollNumber;
  final String batch;
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
      isRegistered: (json['is_registered'] as bool?) ?? json['id'] is int,
    );
  }
}

/// Swipe-based lecture attendance.
///
/// The subject list comes from the teacher's VERIFIED assignments
/// (`GET /teacher/assignments`), and the backend refuses any save for a class or
/// subject the caller is not assigned to teach, so this screen can never mark
/// attendance beyond what the teacher actually teaches. Swiping right marks a
/// student present, swiping left absent; nothing is written until the review
/// screen is confirmed.
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
          _assignments = assignments;
          _subject = assignments.isEmpty
              ? null
              : (_subject ?? assignments.first.subject);
          _batch = _batchForSubject(_subject);
          _slot = _slotForSubject(_subject) ?? _slot;
          _isLoading = false;
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

    if (mounted) setState(() => _isLoading = false);
  }

  /// The batch of the teacher's assignment for a subject ('' when it covers the
  /// whole division).
  String _batchForSubject(String? subject) {
    if (subject == null) return '';
    final match = _assignments.where((a) => a.subject == subject);
    if (match.isEmpty) return '';
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

  List<String> get _batchChoices {
    return <String>{
      '',
      for (final assignment in _assignments)
        if (assignment.subject == _subject) assignment.batch,
    }.toList();
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

    try {
      final response = await _client
          .get(
            Uri.parse(
              '${Environment.backendUrl}/teacher/attendance'
              '?subject=${Uri.encodeQueryComponent(subject)}'
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
              'subject': subject,
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
              else if (_assignments.isEmpty)
                _buildNoAssignmentsCard()
              else ...[
                if (_stage == _AttendanceStage.setup) _buildSelector(),
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
    final batches = _batchChoices;

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
            key: ValueKey<String>('attendance-subject-$_subject'),
            initialValue: _subject,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Subject'),
            items: _assignments
                .map((a) => a.subject)
                .toSet()
                .map(
                  (subject) => DropdownMenuItem<String>(
                    value: subject,
                    child: Text(subject, overflow: TextOverflow.ellipsis),
                  ),
                )
                .toList(),
            onChanged: (value) {
              if (value == null) return;
              setState(() {
                _subject = value;
                _batch = _batchForSubject(value);
                _slot = _slotForSubject(value) ?? _slot;
              });
            },
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<int>(
                  key: ValueKey<int>(_year),
                  initialValue: _year,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Year'),
                  items: const [1, 2, 3, 4, 5]
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
                  key: ValueKey<String>('attendance-period-$_periodLabel'),
                  initialValue: _periodLabel,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Period'),
                  items: kTimetableSlots
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
                    final match = kTimetableSlots.firstWhere(
                      (slot) => '${slot[0]}-${slot[1]}' == value,
                      orElse: () => kTimetableSlots.first,
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
            resizeDuration: const Duration(milliseconds: 180),
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
                  Text(
                    student.batch.isEmpty ? 'Whole division' : student.batch,
                    style: TextStyle(
                      fontSize: 12,
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
