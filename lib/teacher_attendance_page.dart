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

class _ClassStudent {
  const _ClassStudent({
    required this.id,
    required this.name,
    required this.rollNumber,
    required this.batch,
  });

  final int id;
  final String name;
  final String rollNumber;
  final String batch;

  factory _ClassStudent.fromJson(Map<String, dynamic> json) {
    return _ClassStudent(
      id: json['id'] as int,
      name: (json['name'] as String?)?.trim() ?? '',
      rollNumber: (json['roll_number'] as String?)?.trim() ?? '',
      batch: (json['batch'] as String?)?.trim() ?? '',
    );
  }
}

/// Lecture-wise attendance.
///
/// The subject list comes from the teacher's VERIFIED assignments
/// (`GET /teacher/assignments`), and the backend refuses any save for a class or
/// subject the caller is not assigned to teach, so this screen can never mark
/// attendance beyond what the teacher actually teaches.
class TeacherAttendancePage extends StatefulWidget {
  const TeacherAttendancePage({super.key, this.authService, this.client});

  final TeacherAuthService? authService;
  final http.Client? client;

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
  DateTime _date = DateTime.now();
  List<String> _slot = kTimetableSlots.first;

  /// studentId -> 'present' | 'absent'
  final Map<int, String> _marks = {};

  bool _isLoading = true;
  bool _isSaving = false;
  String? _loadError;
  bool _sessionLoaded = false;

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
          _isLoading = false;
        });
        if (_subject != null) {
          await _loadClass();
        }
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

  Future<void> _loadClass() async {
    final subject = _subject;
    if (subject == null) return;

    setState(() {
      _isLoading = true;
      _loadError = null;
      _sessionLoaded = false;
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
              '${Environment.backendUrl}/teacher/classes'
              '?division=D&batch=${Uri.encodeQueryComponent(_batch)}',
            ),
            headers: teacherHeaders(token),
          )
          .timeout(kTeacherRequestTimeout);

      if (!mounted) return;

      if (response.statusCode == 200) {
        final students = teacherJsonList(response.body)
            .map(_ClassStudent.fromJson)
            .toList();
        setState(() {
          _students = students;
          _marks
            ..clear()
            ..addEntries(students.map((s) => MapEntry(s.id, 'present')));
          _isLoading = false;
        });
        await _loadExistingSession();
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

  /// Read back what was already saved for this lecture, so a correction starts
  /// from the stored state instead of a blank sheet.
  Future<void> _loadExistingSession() async {
    final subject = _subject;
    if (subject == null || _students.isEmpty) return;

    try {
      final token = await _authService.getToken();
      if (!mounted) return;
      if (token == null) return;

      final response = await _client
          .get(
            Uri.parse(
              '${Environment.backendUrl}/teacher/attendance'
              '?subject=${Uri.encodeQueryComponent(subject)}'
              '&division=D&batch=${Uri.encodeQueryComponent(_batch)}'
              '&session_date=$_dateIso'
              '&slot_start=${_slot[0]}&slot_end=${_slot[1]}',
            ),
            headers: teacherHeaders(token),
          )
          .timeout(kTeacherRequestTimeout);

      if (!mounted || response.statusCode != 200) return;

      final saved = teacherJsonList(response.body);
      if (saved.isEmpty) return;

      setState(() {
        for (final row in saved) {
          final id = row['student_id'];
          final status = row['status'];
          if (id is int && status is String) _marks[id] = status;
        }
        _sessionLoaded = true;
      });
    } catch (_) {
      // A failed read-back must not block marking the lecture.
    }
  }

  Future<void> _save() async {
    final subject = _subject;
    if (subject == null || _students.isEmpty || _isSaving) return;

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
            Uri.parse('${Environment.backendUrl}/teacher/attendance'),
            headers: teacherHeaders(token),
            body: jsonEncode({
              'subject': subject,
              'division': 'D',
              'batch': _batch,
              'session_date': _dateIso,
              'slot_start': _slot[0],
              'slot_end': _slot[1],
              'records': _students
                  .map(
                    (student) => {
                      'student_id': student.id,
                      'status': _marks[student.id] ?? 'present',
                    },
                  )
                  .toList(),
            }),
          )
          .timeout(kTeacherRequestTimeout);

      if (!mounted) return;

      if (response.statusCode == 200) {
        final body = jsonDecode(response.body) as Map<String, dynamic>;
        final created = body['created'];
        final corrected = body['corrected'];
        _showSnackBar(
          'Attendance saved ($created new, $corrected corrected)',
          color: GlassColors.success,
        );
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: const GlassAppBar(title: Text('Attendance')),
      body: GlassBackground(
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 24, 24, 40),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: kTeacherMaxContentWidth,
                ),
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
                      _buildLectureSelector(),
                      const SizedBox(height: 20),
                      _buildStudentList(),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
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
          Icon(
            Icons.assignment_ind_outlined,
            size: 44,
            color: GlassColors.warning,
          ),
          SizedBox(height: 12),
          Text(
            'No verified teaching assignments',
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w600,
              color: GlassColors.headingOf(context),
            ),
          ),
          SizedBox(height: 8),
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

  Widget _buildLectureSelector() {
    final batches = <String>{
      '',
      for (final assignment in _assignments)
        if (assignment.subject == _subject) assignment.batch,
    }.toList();

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
            initialValue: _subject,
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
              });
              _loadClass();
            },
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<String>(
                  initialValue: batches.contains(_batch) ? _batch : '',
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
                  onChanged: (value) {
                    setState(() => _batch = value ?? '');
                    _loadClass();
                  },
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: DropdownButtonFormField<String>(
                  initialValue: '${_slot[0]}-${_slot[1]}',
                  decoration: const InputDecoration(labelText: 'Period'),
                  items: kTimetableSlots
                      .map(
                        (slot) => DropdownMenuItem<String>(
                          value: '${slot[0]}-${slot[1]}',
                          child: Text('${slot[0]} - ${slot[1]}'),
                        ),
                      )
                      .toList(),
                  onChanged: (value) {
                    final match = kTimetableSlots.firstWhere(
                      (slot) => '${slot[0]}-${slot[1]}' == value,
                      orElse: () => kTimetableSlots.first,
                    );
                    setState(() => _slot = match);
                    _loadExistingSession();
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: GlassOutlinedButton(
                  onPressed: () async {
                    final picked = await showDatePicker(
                      context: context,
                      initialDate: _date,
                      firstDate: DateTime.now().subtract(
                        const Duration(days: 120),
                      ),
                      lastDate: DateTime.now().add(const Duration(days: 120)),
                    );
                    if (picked == null || !mounted) return;
                    setState(() => _date = picked);
                    await _loadExistingSession();
                  },
                  height: 50,
                  borderRadius: 12,
                  child: Text(
                    'Date $_dateIso',
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
              ),
            ],
          ),
          if (_sessionLoaded) ...[
            const SizedBox(height: 12),
            const Text(
              'This lecture already has saved attendance - changing a value '
              'corrects the existing record.',
              style: TextStyle(fontSize: 12, color: GlassColors.warning),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildStudentList() {
    if (_students.isEmpty) {
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
            SizedBox(height: 12),
            Text(
              'No students in this class group',
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w600,
                color: GlassColors.headingOf(context),
              ),
            ),
            SizedBox(height: 8),
            Text(
              'Only approved students of this division and batch are listed.',
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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Students',
          style: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.bold,
            color: GlassColors.headingOf(context),
          ),
        ),
        const SizedBox(height: 12),
        ..._students.map((student) {
          final mark = _marks[student.id] ?? 'present';
          return Padding(
            padding: const EdgeInsets.only(bottom: 10),
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
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: GlassColors.headingOf(context),
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Roll ${student.rollNumber}'
                          '${student.batch.isEmpty ? '' : ' • ${student.batch}'}',
                          style: TextStyle(
                            fontSize: 12,
                            color: GlassColors.secondaryTextOf(context),
                          ),
                        ),
                      ],
                    ),
                  ),
                  _markButton(student.id, 'present', mark, 'PRESENT'),
                  const SizedBox(width: 8),
                  _markButton(student.id, 'absent', mark, 'ABSENT'),
                ],
              ),
            ),
          );
        }),
        const SizedBox(height: 12),
        GlassButton(
          onPressed: _isSaving ? null : _save,
          height: 52,
          borderRadius: 14,
          isLoading: _isSaving,
          disabled: _isSaving,
          child: const Text(
            'SAVE ATTENDANCE',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          ),
        ),
      ],
    );
  }

  Widget _markButton(
    int studentId,
    String value,
    String current,
    String label,
  ) {
    final selected = current == value;
    final color = value == 'present' ? GlassColors.success : GlassColors.error;

    return GlassButton(
      onPressed: _isSaving
          ? null
          : () => setState(() => _marks[studentId] = value),
      width: 92,
      height: 38,
      borderRadius: 10,
      color: selected ? color : GlassColors.disabledOf(context),
      disabled: _isSaving,
      child: Text(
        label,
        style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
      ),
    );
  }
}
