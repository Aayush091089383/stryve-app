import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'attendance.dart';
import 'config/environment.dart';
import 'student.dart';
import 'utils/glass_container.dart';

/// The student's own attendance: one overall ring, one card per subject and
/// every lecture behind a card.
///
/// The backend answers from the authenticated session only (`GET
/// /student/attendance`), so this screen cannot ask for another student's
/// numbers, and an empty answer is shown as "nothing recorded yet" rather than
/// as 0% of an invented schedule.
class StudentAttendancePage extends StatefulWidget {
  const StudentAttendancePage({
    super.key,
    required this.student,
    this.client,
    this.embedded = false,
    this.bottomInset = 0,
  });

  final Student student;
  final http.Client? client;

  /// When true the page renders without its own Scaffold/app bar, for use as a
  /// tab inside HomePage.
  final bool embedded;

  /// Room the floating nav bar needs under the content (embedded mode only).
  final double bottomInset;

  @override
  State<StudentAttendancePage> createState() => _StudentAttendancePageState();
}

class _StudentAttendancePageState extends State<StudentAttendancePage> {
  http.Client? _ownedClient;
  http.Client get _client => widget.client ?? (_ownedClient ??= http.Client());

  StudentAttendance? _attendance;
  bool _isLoading = true;
  bool _isRefreshing = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _ownedClient?.close();
    super.dispose();
  }

  Future<void> _load({bool refresh = false}) async {
    final hadData = _attendance != null;

    if (refresh) {
      setState(() => _isRefreshing = true);
    } else {
      setState(() {
        _isLoading = true;
        _errorMessage = null;
      });
    }

    String? failure;

    try {
      final response = await _client
          .get(
            Uri.parse('${Environment.backendUrl}/student/attendance'),
            headers: {'Authorization': 'Bearer ${widget.student.token}'},
          )
          .timeout(const Duration(seconds: 15));

      if (!mounted) return;

      if (response.statusCode == 200) {
        final body = jsonDecode(response.body);
        setState(() {
          _attendance = body is Map<String, dynamic>
              ? StudentAttendance.fromJson(body)
              : const StudentAttendance(
                  overallPercentage: 0,
                  totalClasses: 0,
                  attended: 0,
                  subjects: [],
                );
          _errorMessage = null;
        });
      } else {
        failure = _readError(response);
      }
    } catch (_) {
      failure =
          'Could not reach the backend. Check your connection and try again.';
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _isRefreshing = false;
          // A failed refresh keeps the last good numbers on screen and reports
          // the failure once; clearing them would turn a connection blip into
          // "no attendance", which is a different, false claim.
          if (failure != null && !(refresh && hadData)) {
            _errorMessage = failure;
          }
        });
        if (failure != null && refresh && hadData) {
          ScaffoldMessenger.of(context)
            ..hideCurrentSnackBar()
            ..showSnackBar(SnackBar(content: Text(failure)));
        }
      }
    }
  }

  /// The backend answers errors as `{"detail": …}`; `message` is only present
  /// on success payloads, so it is the fallback, never the first choice.
  String _readError(http.Response response) {
    try {
      final body = jsonDecode(response.body);
      if (body is Map<String, dynamic>) {
        final detail = body['detail'];
        if (detail is String && detail.trim().isNotEmpty) return detail;
        final message = body['message'];
        if (message is String && message.trim().isNotEmpty) return message;
      }
    } catch (_) {
      // A proxy/tunnel HTML answer is not JSON; fall through to the status.
    }
    return 'Could not load attendance (${response.statusCode}).';
  }

  Color _percentageColor(double percentage) {
    if (percentage >= 75) return GlassColors.success;
    if (percentage >= 60) return GlassColors.warning;
    return GlassColors.error;
  }

  @override
  Widget build(BuildContext context) {
    final content = RefreshIndicator(
      onRefresh: () => _load(refresh: true),
      color: GlassColors.primaryBlue,
      child: ListView(
        key: const Key('attendance_list'),
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsets.fromLTRB(
          24,
          24,
          24,
          widget.embedded ? widget.bottomInset + 24 : 40,
        ),
        children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: _buildBody(),
            ),
          ),
        ],
      ),
    );

    if (widget.embedded) {
      return KeyedSubtree(
        key: const Key('student_attendance_tab'),
        child: content,
      );
    }

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: const GlassAppBar(title: Text('Attendance')),
      body: GlassBackground(child: SafeArea(child: content)),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 48),
        child: Center(
          child: CircularProgressIndicator(
            valueColor: AlwaysStoppedAnimation<Color>(GlassColors.primaryBlue),
          ),
        ),
      );
    }

    if (_errorMessage != null) {
      return _buildErrorCard();
    }

    final attendance = _attendance;
    if (attendance == null || !attendance.hasRecords) {
      return _buildEmptyCard();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildOverallCard(attendance),
        const SizedBox(height: 24),
        Row(
          children: [
            Expanded(
              child: Text(
                'By subject',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: GlassColors.headingOf(context),
                ),
              ),
            ),
            if (_isRefreshing)
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
          ],
        ),
        const SizedBox(height: 12),
        ...attendance.subjects.map(
          (subject) => Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: _buildSubjectCard(subject),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'Pull down to refresh. 75% is the minimum required attendance.',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 12,
            color: GlassColors.secondaryTextOf(context),
          ),
        ),
      ],
    );
  }

  Widget _buildOverallCard(StudentAttendance attendance) {
    final color = _percentageColor(attendance.overallPercentage);

    return GlassContainer(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      borderRadius: 20,
      blurStrength: 20,
      opacity: 0.8,
      borderOpacity: 0.5,
      child: Row(
        children: [
          SizedBox(
            width: 132,
            height: 132,
            child: Stack(
              alignment: Alignment.center,
              children: [
                SizedBox.expand(
                  child: CircularProgressIndicator(
                    value: (attendance.overallPercentage / 100).clamp(0.0, 1.0),
                    strokeWidth: 11,
                    backgroundColor: GlassColors.borderOf(context),
                    valueColor: AlwaysStoppedAnimation<Color>(color),
                  ),
                ),
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '${_formatPercent(attendance.overallPercentage)}%',
                      key: const Key('attendance_overall_percent'),
                      style: TextStyle(
                        fontSize: 30,
                        fontWeight: FontWeight.bold,
                        height: 1,
                        color: color,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'overall',
                      style: TextStyle(
                        fontSize: 11,
                        color: GlassColors.secondaryTextOf(context),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 20),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Attendance',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: GlassColors.headingOf(context),
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  '${attendance.attended} / ${attendance.totalClasses} '
                  'lectures attended',
                  style: TextStyle(
                    fontSize: 13,
                    color: GlassColors.secondaryTextOf(context),
                  ),
                ),
                const SizedBox(height: 14),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: color.withValues(alpha: 0.35)),
                  ),
                  child: Text(
                    attendance.overallPercentage >= 75
                        ? 'Above the 75% requirement'
                        : 'Below the 75% requirement',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: color,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSubjectCard(SubjectAttendance subject) {
    final color = _percentageColor(subject.percentage);

    return GlassCard(
      key: Key('attendance_subject_${subject.subject}'),
      margin: EdgeInsets.zero,
      padding: const EdgeInsets.all(16),
      onTap: () => _openSubject(subject),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.menu_book_rounded, size: 20, color: color),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  subject.subject,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: GlassColors.headingOf(context),
                  ),
                ),
              ),
              Text(
                '${_formatPercent(subject.percentage)}%',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: color,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: (subject.percentage / 100).clamp(0.0, 1.0),
              minHeight: 8,
              backgroundColor: GlassColors.borderOf(context),
              valueColor: AlwaysStoppedAnimation<Color>(color),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: Text(
                  '${subject.attended} / ${subject.totalClasses} lectures',
                  style: TextStyle(
                    fontSize: 12,
                    color: GlassColors.secondaryTextOf(context),
                  ),
                ),
              ),
              Icon(
                Icons.chevron_right_rounded,
                size: 20,
                color: GlassColors.disabledOf(context),
              ),
            ],
          ),
          if (subject.isBelowThreshold) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                const Icon(
                  Icons.warning_amber_rounded,
                  size: 16,
                  color: GlassColors.warning,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Attend ${subject.lecturesToReach75} more to reach 75%',
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: GlassColors.warning,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildEmptyCard() {
    return GlassContainer(
      width: double.infinity,
      padding: const EdgeInsets.all(28),
      borderRadius: 16,
      opacity: 0.65,
      borderOpacity: 0.35,
      child: Column(
        children: [
          Icon(
            Icons.fact_check_outlined,
            size: 48,
            color: GlassColors.disabledOf(context),
          ),
          const SizedBox(height: 14),
          Text(
            'No attendance recorded yet',
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w600,
              color: GlassColors.headingOf(context),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'No attendance recorded yet. Your teachers will mark attendance '
            'during class.',
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

  Widget _buildErrorCard() {
    return GlassContainer(
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      borderRadius: 16,
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
            _errorMessage!,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: GlassColors.headingOf(context),
            ),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: 180,
            child: GlassOutlinedButton(
              key: const Key('attendance_retry'),
              onPressed: _load,
              height: 44,
              borderRadius: 12,
              child: const Text('Retry'),
            ),
          ),
        ],
      ),
    );
  }

  void _openSubject(SubjectAttendance subject) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _SubjectDetailSheet(subject: subject),
    );
  }

  String _formatPercent(double value) {
    return value == value.roundToDouble()
        ? value.toStringAsFixed(0)
        : value.toStringAsFixed(1);
  }
}

/// Every lecture of one subject, newest first.
class _SubjectDetailSheet extends StatelessWidget {
  const _SubjectDetailSheet({required this.subject});

  final SubjectAttendance subject;

  @override
  Widget build(BuildContext context) {
    final color = subject.percentage >= 75
        ? GlassColors.success
        : subject.percentage >= 60
        ? GlassColors.warning
        : GlassColors.error;

    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 16,
      ),
      child: GlassContainer(
        width: double.infinity,
        borderRadius: 24,
        opacity: 0.95,
        borderOpacity: 0.5,
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.8,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 42,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 14),
                  decoration: BoxDecoration(
                    color: GlassColors.borderOf(context),
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ),
              Text(
                subject.subject,
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: GlassColors.headingOf(context),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '${_percent(subject.percentage)}% · '
                '${subject.attended}/${subject.totalClasses} lectures',
                style: TextStyle(fontSize: 13, color: color),
              ),
              const SizedBox(height: 16),
              Flexible(
                child: subject.lectures.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.symmetric(vertical: 28),
                        child: Text(
                          'No lectures recorded yet for this subject.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 13,
                            color: GlassColors.secondaryTextOf(context),
                          ),
                        ),
                      )
                    : ListView.separated(
                        shrinkWrap: true,
                        itemCount: subject.lectures.length,
                        separatorBuilder: (context, index) => Divider(
                          height: 1,
                          color: GlassColors.borderOf(context),
                        ),
                        itemBuilder: (context, index) {
                          final lecture = subject.lectures[index];
                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 11),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        formatAttendanceDate(lecture.date),
                                        style: TextStyle(
                                          fontSize: 14,
                                          fontWeight: FontWeight.w600,
                                          color: GlassColors.headingOf(context),
                                        ),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        lecture.period,
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: GlassColors.secondaryTextOf(
                                            context,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                Icon(
                                  lecture.isPresent
                                      ? Icons.check_circle_rounded
                                      : Icons.cancel_rounded,
                                  size: 22,
                                  color: lecture.isPresent
                                      ? GlassColors.success
                                      : GlassColors.error,
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  lecture.isPresent ? 'Present' : 'Absent',
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: lecture.isPresent
                                        ? GlassColors.success
                                        : GlassColors.error,
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _percent(double value) {
    return value == value.roundToDouble()
        ? value.toStringAsFixed(0)
        : value.toStringAsFixed(1);
  }
}
