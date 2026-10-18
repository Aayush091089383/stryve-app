import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import 'config/environment.dart';
import 'create_teacher_dialog.dart';
import 'services/teacher_auth_service.dart';
import 'teacher_models.dart';
import 'utils/glass_container.dart';
import 'utils/teacher_api.dart';

/// Admin-only teacher account management:
/// create accounts, see who exists, and configure each account's approval
/// permission and official faculty code.
///
/// Every request here needs an admin token (`GET /teacher/list`,
/// `POST /teacher/create`, `PATCH /teacher/{id}/permissions`,
/// `PATCH /teacher/{id}/status`), so a teacher who somehow reaches this screen
/// still gets a 403 from the server.
///
/// The password an admin provisioned is returned by the admin-only list so it
/// can be handed to the teacher; it stays masked until the eye is tapped and is
/// copied on demand. Nothing is persisted on the device - the value lives only
/// in the last response.
class TeacherManagementPage extends StatefulWidget {
  const TeacherManagementPage({
    super.key,
    this.authService,
    this.client,
    this.onSessionExpired,
  });

  final TeacherAuthService? authService;
  final http.Client? client;
  final Future<void> Function()? onSessionExpired;

  @override
  State<TeacherManagementPage> createState() => _TeacherManagementPageState();
}

class _TeacherManagementPageState extends State<TeacherManagementPage> {
  late final TeacherAuthService _authService =
      widget.authService ?? TeacherAuthService();
  http.Client? _ownedClient;
  http.Client get _client => widget.client ?? (_ownedClient ??= http.Client());

  List<TeacherAccount> _teachers = const [];
  bool _isLoading = true;
  bool _isRefreshing = false;
  String? _loadError;
  bool _isCreateDialogOpen = false;
  int? _savingTeacherId;
  final Map<int, TextEditingController> _shortCodeControllers = {};

  /// Accounts whose stored password is currently revealed on screen.
  final Set<int> _revealedPasswords = {};

  @override
  void initState() {
    super.initState();
    _fetchTeachers();
  }

  @override
  void dispose() {
    _ownedClient?.close();
    for (final controller in _shortCodeControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _fetchTeachers({bool isRefresh = false}) async {
    if (isRefresh) {
      setState(() => _isRefreshing = true);
    } else {
      setState(() {
        _isLoading = true;
        _loadError = null;
      });
    }

    try {
      final token = await _authService.getToken();
      if (!mounted) return;

      if (token == null) {
        await _sessionLost();
        return;
      }

      final response = await _client
          .get(
            Uri.parse('${Environment.backendUrl}/teacher/list'),
            headers: teacherHeaders(token),
          )
          .timeout(kTeacherRequestTimeout);

      if (!mounted) return;

      if (response.statusCode == 200) {
        setState(() {
          _teachers = teacherJsonList(
            response.body,
          ).map(TeacherAccount.fromJson).toList();
          _loadError = null;
        });
      } else if (response.statusCode == 401) {
        await _sessionLost();
      } else if (response.statusCode == 403) {
        setState(
          () => _loadError = teacherMessageFromBody(response),
        );
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
    await _authService.clearAuthData();
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  void _showSnackBar(String message, {Color? color}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: color),
    );
  }

  Future<void> _openCreateTeacherDialog() async {
    if (_isCreateDialogOpen) return;
    setState(() => _isCreateDialogOpen = true);

    try {
      final outcome = await showCreateTeacherDialog(
        context,
        client: _client,
        authService: _authService,
      );
      if (!mounted || outcome == null) return;

      if (outcome == TeacherCreateOutcome.created) {
        _showSnackBar(
          'Teacher account created successfully',
          color: GlassColors.success,
        );
        await _fetchTeachers(isRefresh: true);
      } else if (outcome == TeacherCreateOutcome.sessionExpired) {
        await _sessionLost();
      }
    } finally {
      if (mounted) setState(() => _isCreateDialogOpen = false);
    }
  }

  /// Save the configurable permission and/or the official faculty code.
  Future<void> _saveTeacher(
    TeacherAccount account, {
    bool? canApprove,
  }) async {
    if (_savingTeacherId != null) return;

    final token = await _authService.getToken();
    if (!mounted) return;
    if (token == null) {
      await _sessionLost();
      return;
    }

    final controller = _shortCodeControllers[account.id];
    final rawCode = controller?.text.trim().toUpperCase() ?? '';
    final codeChanged = rawCode != (account.shortCode ?? '');

    final payload = <String, dynamic>{};
    if (canApprove != null) payload['can_approve_registrations'] = canApprove;
    if (codeChanged) payload['short_code'] = rawCode;

    if (payload.isEmpty) {
      _showSnackBar('Nothing to save.');
      return;
    }

    setState(() => _savingTeacherId = account.id);

    try {
      final response = await _client
          .patch(
            Uri.parse(
              '${Environment.backendUrl}/teacher/${account.id}/permissions',
            ),
            headers: teacherHeaders(token),
            body: jsonEncode(payload),
          )
          .timeout(kTeacherRequestTimeout);

      if (!mounted) return;

      if (response.statusCode == 200) {
        _showSnackBar('Saved', color: GlassColors.success);
        await _fetchTeachers(isRefresh: true);
      } else if (response.statusCode == 401) {
        await _sessionLost();
      } else {
        _showSnackBar(teacherMessageFromBody(response));
      }
    } catch (_) {
      if (!mounted) return;
      _showSnackBar(kTeacherUnreachableMessage);
    } finally {
      if (mounted) setState(() => _savingTeacherId = null);
    }
  }

  /// Activate or deactivate an account. The server refuses to deactivate the
  /// caller's own account, so the last admin cannot lock themselves out.
  Future<void> _setActive(TeacherAccount account, bool isActive) async {
    if (_savingTeacherId != null) return;

    final token = await _authService.getToken();
    if (!mounted) return;
    if (token == null) {
      await _sessionLost();
      return;
    }

    setState(() => _savingTeacherId = account.id);

    try {
      final response = await _client
          .patch(
            Uri.parse('${Environment.backendUrl}/teacher/${account.id}/status'),
            headers: teacherHeaders(token),
            body: jsonEncode({'is_active': isActive}),
          )
          .timeout(kTeacherRequestTimeout);

      if (!mounted) return;

      if (response.statusCode == 200) {
        _showSnackBar(
          isActive ? 'Account activated' : 'Account deactivated',
          color: GlassColors.success,
        );
        await _fetchTeachers(isRefresh: true);
      } else if (response.statusCode == 401) {
        await _sessionLost();
      } else {
        _showSnackBar(teacherMessageFromBody(response));
      }
    } catch (_) {
      if (!mounted) return;
      _showSnackBar(kTeacherUnreachableMessage);
    } finally {
      if (mounted) setState(() => _savingTeacherId = null);
    }
  }

  Future<void> _copy(String label, String value) async {
    if (value.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: value));
    _showSnackBar('$label copied');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: GlassAppBar(
        title: const Text('Teacher Accounts'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            onPressed: _isRefreshing
                ? null
                : () => _fetchTeachers(isRefresh: true),
            tooltip: 'Refresh',
          ),
        ],
      ),
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
                    Row(
                      children: [
                        const Expanded(
                          child: Text(
                            'Teacher Management (Admin Only)',
                            style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                              color: GlassColors.heading,
                            ),
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: GlassColors.surface,
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(color: GlassColors.border),
                          ),
                          child: Text(
                            // Never report "0 accounts" when the list failed to
                            // load - that would read as "there are none".
                            _loadError == null
                                ? '${_teachers.length} accounts'
                                : 'not loaded',
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: GlassColors.primaryBlue,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    GlassButton(
                      onPressed: _isCreateDialogOpen
                          ? null
                          : _openCreateTeacherDialog,
                      height: 48,
                      borderRadius: 14,
                      disabled: _isCreateDialogOpen,
                      child: const Text(
                        'CREATE TEACHER ACCOUNT',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
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
                    else if (_teachers.isEmpty)
                      _buildEmptyState()
                    else
                      ..._teachers.map(_buildTeacherCard),
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
              onPressed: () => _fetchTeachers(isRefresh: true),
              height: 44,
              borderRadius: 12,
              child: const Text('Retry'),
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
      child: const Column(
        children: [
          Icon(Icons.people_outline_rounded, size: 48, color: GlassColors.disabled),
          SizedBox(height: 16),
          Text(
            'No Teacher Accounts',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: GlassColors.heading,
            ),
          ),
          SizedBox(height: 8),
          Text(
            'Accounts you create will appear here.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: GlassColors.secondaryText),
          ),
        ],
      ),
    );
  }

  Widget _buildTeacherCard(TeacherAccount account) {
    final controller = _shortCodeControllers.putIfAbsent(
      account.id,
      () => TextEditingController(text: account.shortCode ?? ''),
    );
    final isSaving = _savingTeacherId == account.id;

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: GlassContainer(
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
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        account.name,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: GlassColors.heading,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              account.email,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 13,
                                color: GlassColors.secondaryText,
                              ),
                            ),
                          ),
                          IconButton(
                            tooltip: 'Copy email',
                            icon: const Icon(Icons.copy_rounded, size: 15),
                            visualDensity: VisualDensity.compact,
                            constraints: const BoxConstraints(),
                            padding: const EdgeInsets.all(4),
                            onPressed: () => _copy('Email', account.email),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                _badge(
                  account.isAdmin ? 'ADMIN' : 'TEACHER',
                  account.isAdmin
                      ? GlassColors.warning
                      : GlassColors.primaryBlue,
                ),
                const SizedBox(width: 8),
                _badge(
                  account.isActive ? 'Active' : 'Inactive',
                  account.isActive ? GlassColors.success : GlassColors.error,
                ),
              ],
            ),
            const SizedBox(height: 4),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: account.isActive,
              onChanged: isSaving
                  ? null
                  : (value) => _setActive(account, value),
              title: const Text(
                'Account active',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: GlassColors.heading,
                ),
              ),
              subtitle: Text(
                account.isActive
                    ? 'Can sign in to the teacher panel.'
                    : 'Cannot sign in until switched back on.',
                style: const TextStyle(
                  fontSize: 12,
                  color: GlassColors.secondaryText,
                ),
              ),
            ),
            _buildPasswordRow(account),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: controller,
                    textCapitalization: TextCapitalization.characters,
                    decoration: const InputDecoration(
                      labelText: 'Official faculty code (e.g. SMG)',
                      hintText: 'From the Division D timetable',
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                GlassOutlinedButton(
                  onPressed: isSaving ? null : () => _saveTeacher(account),
                  width: 96,
                  height: 46,
                  borderRadius: 12,
                  child: isSaving
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Save', style: TextStyle(fontSize: 14)),
                ),
              ],
            ),
            const SizedBox(height: 4),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: account.canReviewRegistrations,
              onChanged: isSaving
                  ? null
                  : (value) => _saveTeacher(account, canApprove: value),
              title: const Text(
                'May review student registrations',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: GlassColors.heading,
                ),
              ),
              subtitle: Text(
                account.isAdmin
                    ? 'Administrators always may.'
                    : 'Granted explicitly to this teacher.',
                style: const TextStyle(
                  fontSize: 12,
                  color: GlassColors.secondaryText,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// The provisioned password: masked by default, revealed only on request,
  /// copyable without revealing it.
  Widget _buildPasswordRow(TeacherAccount account) {
    final password = account.plainPassword;
    final revealed = password != null && _revealedPasswords.contains(account.id);

    return Row(
      children: [
        const Icon(
          Icons.key_rounded,
          size: 16,
          color: GlassColors.secondaryText,
        ),
        const SizedBox(width: 6),
        Expanded(
          child: password == null
              ? const Text(
                  'No stored password for this account',
                  style: TextStyle(
                    fontSize: 13,
                    fontStyle: FontStyle.italic,
                    color: GlassColors.secondaryText,
                  ),
                )
              : Text(
                  revealed
                      ? 'Password: $password'
                      : 'Password: \u2022\u2022\u2022\u2022\u2022\u2022\u2022\u2022',
                  key: ValueKey('password-${account.id}-$revealed'),
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    letterSpacing: revealed ? 0.4 : 2,
                    color: GlassColors.heading,
                  ),
                ),
        ),
        if (password != null) ...[
          IconButton(
            tooltip: revealed ? 'Hide password' : 'Show password',
            icon: Icon(
              revealed
                  ? Icons.visibility_off_outlined
                  : Icons.visibility_outlined,
              size: 19,
            ),
            visualDensity: VisualDensity.compact,
            onPressed: () => setState(() {
              if (revealed) {
                _revealedPasswords.remove(account.id);
              } else {
                _revealedPasswords.add(account.id);
              }
            }),
          ),
          IconButton(
            tooltip: 'Copy password',
            icon: const Icon(Icons.copy_rounded, size: 17),
            visualDensity: VisualDensity.compact,
            onPressed: () => _copy('Password', password),
          ),
        ],
      ],
    );
  }

  Widget _badge(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }
}
