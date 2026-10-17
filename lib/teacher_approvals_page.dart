import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'config/environment.dart';
import 'services/teacher_auth_service.dart';
import 'teacher_models.dart';
import 'teacher_login_page.dart';
import 'utils/glass_container.dart';
import 'utils/teacher_api.dart';

/// Student Registration Approvals - a SEPARATE section, deliberately not a
/// fourth bottom tab of the Teacher Panel.
///
/// Whether the caller may use it is decided by the backend
/// (`GET /teacher/registrations/*` requires an admin, or a teacher whose
/// configurable approval permission has been granted). This screen only
/// reflects what the server answers, and never marks a registration processed
/// on its own.
class TeacherApprovalsView extends StatefulWidget {
  const TeacherApprovalsView({
    super.key,
    required this.authService,
    required this.client,
    this.onSessionExpired,
  });

  final TeacherAuthService authService;
  final http.Client client;

  /// Called when the backend rejects the stored session (401/403 on
  /// `/teacher/me`). The owner decides where to send the user.
  final Future<void> Function()? onSessionExpired;

  @override
  State<TeacherApprovalsView> createState() => _TeacherApprovalsViewState();
}

class _TeacherApprovalsViewState extends State<TeacherApprovalsView> {
  List<PendingStudent> _pendingStudents = const [];
  bool _isLoading = true;
  bool _isRefreshing = false;
  int? _processingStudentId;
  String? _processingAction;
  String? _loadError;
  TextEditingController? _rejectReasonController;

  @override
  void initState() {
    super.initState();
    _fetchPendingRegistrations();
  }

  @override
  void dispose() {
    _rejectReasonController?.dispose();
    super.dispose();
  }

  Future<void> _fetchPendingRegistrations({bool isRefresh = false}) async {
    if (isRefresh) {
      setState(() => _isRefreshing = true);
    } else {
      setState(() {
        _isLoading = true;
        _loadError = null;
      });
    }

    try {
      final token = await widget.authService.getToken();
      if (!mounted) return;

      if (token == null) {
        await _sessionLost();
        return;
      }

      final response = await widget.client
          .get(
            Uri.parse(
              '${Environment.backendUrl}/teacher/registrations/pending',
            ),
            headers: teacherHeaders(token),
          )
          .timeout(kTeacherRequestTimeout);

      if (!mounted) return;

      if (response.statusCode == 200) {
        setState(() {
          _pendingStudents = teacherJsonList(
            response.body,
          ).map(PendingStudent.fromJson).toList();
          _loadError = null;
        });
      } else if (response.statusCode == 401) {
        await _sessionLost();
      } else if (response.statusCode == 403) {
        // The account is signed in but not permitted. Say so plainly instead
        // of rendering the "nothing pending" empty state.
        setState(() {
          _loadError = teacherMessageFromBody(response);
        });
      } else {
        setState(() => _loadError = teacherMessageFromBody(response));
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadError = kTeacherUnreachableMessage);
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _isRefreshing = false;
        });
      }
    }
  }

  Future<void> _sessionLost() async {
    if (widget.onSessionExpired != null) {
      await widget.onSessionExpired!();
      return;
    }
    await widget.authService.clearAuthData();
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const TeacherLoginPage()),
      (route) => false,
    );
  }

  void _showSnackBar(String message, {Color? color, SnackBarAction? action}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: color,
        action: action,
        duration: Duration(seconds: action == null ? 4 : 8),
      ),
    );
  }

  Future<void> _approveStudent(
    PendingStudent student, {
    bool skipConfirmation = false,
  }) async {
    if (_processingStudentId != null) return;

    if (!skipConfirmation) {
      final confirmed = await _showConfirmDialog(
        title: 'Approve Registration',
        message:
            'Approve registration for ${student.name} (Roll: ${student.rollNumber ?? 'unknown'})?',
        confirmText: 'Approve',
      );
      if (!confirmed || !mounted) return;
    }

    await _runAction(
      student: student,
      action: 'approve',
      send: (token) => widget.client.post(
        Uri.parse(
          '${Environment.backendUrl}/teacher/registrations/${student.id}/approve',
        ),
        headers: teacherHeaders(token),
        body: jsonEncode(<String, dynamic>{}),
      ),
      successMessage: '${student.name} approved successfully',
      successColor: GlassColors.success,
      permissionMessage: 'You are not permitted to approve registrations.',
      onRetry: () => _approveStudent(student, skipConfirmation: true),
    );
  }

  Future<void> _rejectStudent(
    PendingStudent student, {
    bool skipConfirmation = false,
  }) async {
    if (_processingStudentId != null) return;

    String? reason;
    if (!skipConfirmation) {
      final rawReason = await _showRejectDialog(student.name);
      if (rawReason == null || !mounted) return;
      final trimmed = rawReason.trim();
      reason = trimmed.isEmpty ? null : trimmed;
    }

    await _runAction(
      student: student,
      action: 'reject',
      send: (token) => widget.client.post(
        Uri.parse(
          '${Environment.backendUrl}/teacher/registrations/${student.id}/reject',
        ),
        headers: teacherHeaders(token),
        body: jsonEncode(<String, dynamic>{'reason': reason}),
      ),
      successMessage: '${student.name} rejected',
      successColor: GlassColors.warning,
      permissionMessage: 'You are not permitted to reject registrations.',
      onRetry: () => _rejectStudent(student, skipConfirmation: true),
    );
  }

  /// Sends one approve/reject request and reacts to the backend's answer.
  ///
  /// The list is only ever refreshed from the server *after* it confirms the
  /// action, so a student is never shown as processed on an optimistic guess.
  Future<void> _runAction({
    required PendingStudent student,
    required String action,
    required Future<http.Response> Function(String token) send,
    required String successMessage,
    required Color successColor,
    required String permissionMessage,
    VoidCallback? onRetry,
  }) async {
    final token = await widget.authService.getToken();
    if (!mounted) return;

    if (token == null) {
      await _sessionLost();
      return;
    }

    setState(() {
      _processingStudentId = student.id;
      _processingAction = action;
    });

    try {
      final response = await send(token).timeout(kTeacherRequestTimeout);
      if (!mounted) return;

      if (response.statusCode == 200) {
        _showSnackBar(successMessage, color: successColor);
        await _fetchPendingRegistrations();
      } else if (response.statusCode == 401) {
        await _sessionLost();
      } else if (response.statusCode == 403) {
        _showSnackBar(permissionMessage);
      } else if (response.statusCode == 400 || response.statusCode == 404) {
        _showSnackBar(teacherMessageFromBody(response));
        await _fetchPendingRegistrations();
      } else {
        _showSnackBar(teacherMessageFromBody(response));
      }
    } catch (_) {
      if (!mounted) return;
      _showSnackBar(
        kTeacherUnreachableMessage,
        action: onRetry == null
            ? null
            : SnackBarAction(label: 'RETRY', onPressed: onRetry),
      );
    } finally {
      if (mounted) {
        setState(() {
          _processingStudentId = null;
          _processingAction = null;
        });
      }
    }
  }

  Future<bool> _showConfirmDialog({
    required String title,
    required String message,
    required String confirmText,
  }) async {
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            title: Text(title),
            content: Text(message),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, true),
                style: TextButton.styleFrom(
                  foregroundColor: GlassColors.primaryBlue,
                ),
                child: Text(confirmText),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<String?> _showRejectDialog(String studentName) async {
    final controller = _rejectReasonController ??= TextEditingController();
    controller.clear();

    return await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text('Reject $studentName'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Optional rejection reason:'),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              maxLines: 3,
              decoration: const InputDecoration(
                hintText: 'Enter reason (optional)...',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, controller.text),
            style: TextButton.styleFrom(foregroundColor: GlassColors.error),
            child: const Text('Reject'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 40),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: kTeacherMaxContentWidth),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildSectionHeader(),
              const SizedBox(height: 16),
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
              else if (_pendingStudents.isEmpty)
                _buildEmptyState()
              else
                ListView.separated(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: _pendingStudents.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 12),
                  itemBuilder: (context, index) =>
                      _buildStudentCard(_pendingStudents[index]),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSectionHeader() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        const Flexible(
          child: Text(
            'Pending Student Registrations',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: GlassColors.heading,
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(width: 12),
        GlassOutlinedButton(
          onPressed: _isRefreshing
              ? null
              : () => _fetchPendingRegistrations(isRefresh: true),
          width: 96,
          height: 38,
          borderRadius: 12,
          child: _isRefreshing
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Refresh', style: TextStyle(fontSize: 13)),
        ),
        const SizedBox(width: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: GlassColors.surface,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: GlassColors.border),
          ),
          child: Text(
            '${_pendingStudents.length} pending',
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: GlassColors.primaryBlue,
            ),
          ),
        ),
      ],
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
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: GlassColors.heading,
            ),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: 180,
            child: GlassOutlinedButton(
              onPressed: _isRefreshing
                  ? null
                  : () => _fetchPendingRegistrations(isRefresh: true),
              height: 44,
              borderRadius: 12,
              borderColor: _isRefreshing
                  ? GlassColors.disabled
                  : GlassColors.primaryBlue,
              textColor: _isRefreshing
                  ? GlassColors.disabled
                  : GlassColors.primaryBlue,
              child: _isRefreshing
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Retry'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return GlassContainer(
      width: double.infinity,
      padding: const EdgeInsets.all(32),
      borderRadius: 16,
      blurStrength: 15,
      opacity: 0.6,
      borderOpacity: 0.3,
      child: Column(
        children: [
          Icon(
            Icons.assignment_turned_in_rounded,
            size: 48,
            color: GlassColors.secondaryText.withValues(alpha: 0.5),
          ),
          const SizedBox(height: 16),
          const Text(
            'No Pending Registrations',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: GlassColors.heading,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'All student registrations have been processed.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 14, color: GlassColors.secondaryText),
          ),
        ],
      ),
    );
  }

  Widget _buildStudentCard(PendingStudent student) {
    final isProcessing = _processingStudentId == student.id;
    final isApproving = isProcessing && _processingAction == 'approve';
    final isRejecting = isProcessing && _processingAction == 'reject';
    final details = student.visibleDetails;

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
          Text(
            student.name,
            style: const TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 18,
              color: GlassColors.heading,
            ),
          ),
          const SizedBox(height: 10),
          ...details.entries.map(
            (entry) => Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 96,
                    child: Text(
                      entry.key,
                      style: const TextStyle(
                        fontSize: 13,
                        color: GlassColors.secondaryText,
                      ),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      entry.value,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: GlassColors.heading,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: GlassButton(
                  onPressed: isProcessing
                      ? null
                      : () => _approveStudent(student),
                  height: 46,
                  borderRadius: 12,
                  color: GlassColors.success,
                  isLoading: isApproving,
                  disabled: isProcessing,
                  child: const Text(
                    'APPROVE',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: GlassButton(
                  onPressed: isProcessing ? null : () => _rejectStudent(student),
                  height: 46,
                  borderRadius: 12,
                  color: GlassColors.error,
                  isLoading: isRejecting,
                  disabled: isProcessing,
                  child: const Text(
                    'REJECT',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Full-screen wrapper for the approvals section.
///
/// Used when the section is opened from the Teacher Panel home (a teacher's
/// bottom navigation stays Home / Assignments / Profile - approvals is never a
/// fourth tab).
class TeacherApprovalsPage extends StatelessWidget {
  const TeacherApprovalsPage({
    super.key,
    this.authService,
    this.client,
    this.onSessionExpired,
  });

  final TeacherAuthService? authService;
  final http.Client? client;
  final Future<void> Function()? onSessionExpired;

  @override
  Widget build(BuildContext context) {
    final ownedClient = client == null ? http.Client() : null;
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: const GlassAppBar(
        title: Text('Student Registration Approvals'),
      ),
      body: GlassBackground(
        child: SafeArea(
          child: TeacherApprovalsView(
            authService: authService ?? TeacherAuthService(),
            client: client ?? ownedClient!,
            onSessionExpired: onSessionExpired,
          ),
        ),
      ),
    );
  }
}
