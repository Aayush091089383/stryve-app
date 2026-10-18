import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'config/environment.dart';
import 'services/teacher_auth_service.dart';
import 'utils/glass_container.dart';

/// How long the create request may take before it counts as unreachable.
const Duration _kRequestTimeout = Duration(seconds: 15);

/// Minimum length the app enforces for a new teacher password.
const int kMinTeacherPasswordLength = 8;

/// Outcome of the Admin-only "Create Teacher Account" dialog.
enum TeacherCreateOutcome {
  /// The backend confirmed the account was created.
  created,

  /// The stored admin token was rejected (401). The caller must clear the
  /// teacher session and send the admin back to teacher login.
  sessionExpired,
}

/// Shows the Admin-only "Create Teacher Account" dialog.
///
/// This is UI + validation only. Whether the caller is actually allowed to
/// create accounts is decided by the backend (`POST /teacher/create` requires
/// an admin token); the dialog never assumes the role from local state.
///
/// Returns null when the admin cancelled.
Future<TeacherCreateOutcome?> showCreateTeacherDialog(
  BuildContext context, {
  required http.Client client,
  required TeacherAuthService authService,
}) {
  return showDialog<TeacherCreateOutcome>(
    context: context,
    // The form holds the only copy of a freshly typed password; an accidental
    // tap outside must not discard it. Cancel stays available.
    barrierDismissible: false,
    builder: (context) =>
        _CreateTeacherDialog(client: client, authService: authService),
  );
}

class _CreateTeacherDialog extends StatefulWidget {
  const _CreateTeacherDialog({required this.client, required this.authService});

  final http.Client client;
  final TeacherAuthService authService;

  @override
  State<_CreateTeacherDialog> createState() => _CreateTeacherDialogState();
}

class _CreateTeacherDialogState extends State<_CreateTeacherDialog> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();

  /// Role sent to the backend. The endpoint accepts only 'teacher' or 'admin'.
  String _role = 'teacher';

  bool _obscurePassword = true;
  bool _isSubmitting = false;
  String? _errorMessage;

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  // -------------------------------------------------------------------------
  // Validation
  // -------------------------------------------------------------------------

  String? _validateName(String? value) {
    final name = value?.trim() ?? '';
    if (name.isEmpty) return "Enter the teacher's name.";
    if (name.length < 2) return 'Name is too short.';
    return null;
  }

  /// Any well-formed address, matching the intent of the backend's `EmailStr`.
  ///
  /// Deliberately not the Gmail-only student validator: staff mailboxes are not
  /// necessarily Gmail, and the backend accepts any valid email.
  String? _validateEmail(String? value) {
    final email = value?.trim() ?? '';
    if (email.isEmpty) return 'Enter an email address.';
    if (!RegExp(r'^[^@\s]+@[^@\s]+\.[A-Za-z]{2,}$').hasMatch(email)) {
      return 'Enter a valid email address.';
    }
    return null;
  }

  String? _validatePassword(String? value) {
    final password = value ?? '';
    if (password.isEmpty) return 'Enter a password.';
    if (password.length < kMinTeacherPasswordLength) {
      return 'Use at least $kMinTeacherPasswordLength characters.';
    }
    if (!RegExp(r'[A-Za-z]').hasMatch(password) ||
        !RegExp(r'[0-9]').hasMatch(password)) {
      return 'Include at least one letter and one number.';
    }
    return null;
  }

  // -------------------------------------------------------------------------
  // Submit
  // -------------------------------------------------------------------------

  Future<void> _submit() async {
    if (_isSubmitting) return;

    setState(() => _errorMessage = null);

    if (!(_formKey.currentState?.validate() ?? false)) return;

    final name = _nameController.text.trim();
    final email = _emailController.text.trim();
    final password = _passwordController.text;
    final role = _role;

    // Confirmation before anything is sent. The password is never echoed here.
    final confirmed = await _confirm(name: name, email: email, role: role);
    if (!confirmed || !mounted) return;

    setState(() => _isSubmitting = true);

    try {
      final token = await widget.authService.getToken();
      if (!mounted) return;

      if (token == null) {
        Navigator.pop(context, TeacherCreateOutcome.sessionExpired);
        return;
      }

      final response = await widget.client
          .post(
            Uri.parse('${Environment.backendUrl}/teacher/create'),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $token',
            },
            body: jsonEncode({
              'name': name,
              'email': email,
              'password': password,
              'role': role,
            }),
          )
          .timeout(_kRequestTimeout);

      if (!mounted) return;

      if (response.statusCode == 200 || response.statusCode == 201) {
        Navigator.pop(context, TeacherCreateOutcome.created);
      } else if (response.statusCode == 401) {
        // Invalid/expired admin token: the caller clears the teacher session.
        Navigator.pop(context, TeacherCreateOutcome.sessionExpired);
      } else if (response.statusCode == 403) {
        setState(
          () => _errorMessage =
              'Your account is not permitted to create teacher accounts.',
        );
      } else if (response.statusCode == 409) {
        // Duplicate email (or a concurrent create): keep the form so the admin
        // can correct the address.
        setState(
          () => _errorMessage =
              _plainMessage(response) ?? 'That email is already registered.',
        );
      } else if (response.statusCode == 400 || response.statusCode == 422) {
        setState(() => _errorMessage = _validationMessage(response));
      } else {
        setState(
          () => _errorMessage =
              _plainMessage(response) ??
              'The account could not be created (HTTP ${response.statusCode}). Please try again.',
        );
      }
    } catch (_) {
      if (!mounted) return;
      setState(
        () => _errorMessage =
            'Could not reach the Stryve server. Check your connection and try again.',
      );
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  Future<bool> _confirm({
    required String name,
    required String email,
    required String role,
  }) async {
    final roleLabel = role == 'admin' ? 'an admin' : 'a teacher';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Create Teacher Account?'),
        content: Text('Create $roleLabel account for $name ($email)?'),
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
            child: const Text('Create'),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }

  /// A plain `detail`/`message` string from a FastAPI error body.
  String? _plainMessage(http.Response response) {
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map) {
        final detail = decoded['detail'];
        if (detail is String && detail.trim().isNotEmpty) return detail.trim();
        final message = decoded['message'];
        if (message is String && message.trim().isNotEmpty) {
          return message.trim();
        }
      }
    } catch (_) {
      // Non-JSON body (proxy/tunnel HTML): fall through.
    }
    return null;
  }

  /// FastAPI validation errors arrive as `{"detail": [{"msg": ...}, ...]}`.
  String _validationMessage(http.Response response) {
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map) {
        final detail = decoded['detail'];
        if (detail is String && detail.trim().isNotEmpty) return detail.trim();
        if (detail is List) {
          final messages = <String>[];
          for (final item in detail) {
            if (item is Map && item['msg'] is String) {
              messages.add(
                (item['msg'] as String).replaceFirst('Value error, ', ''),
              );
            }
          }
          if (messages.isNotEmpty) return messages.join('\n');
        }
      }
    } catch (_) {
      // Non-JSON body: fall through.
    }
    return 'Please check the details and try again.';
  }

  // -------------------------------------------------------------------------
  // Build
  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      backgroundColor: GlassColors.surface,
      title: const Text(
        'Create Teacher Account',
        style: TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.bold,
          color: GlassColors.heading,
        ),
      ),
      content: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _field(
                controller: _nameController,
                label: 'Full name',
                icon: Icons.person_rounded,
                validator: _validateName,
                textCapitalization: TextCapitalization.words,
                enabled: !_isSubmitting,
              ),
              const SizedBox(height: 16),
              _field(
                controller: _emailController,
                label: 'Email',
                icon: Icons.email_rounded,
                validator: _validateEmail,
                keyboardType: TextInputType.emailAddress,
                enabled: !_isSubmitting,
              ),
              const SizedBox(height: 16),
              _field(
                controller: _passwordController,
                label: 'Password',
                icon: Icons.lock_rounded,
                validator: _validatePassword,
                enabled: !_isSubmitting,
                obscureText: _obscurePassword,
                suffixIcon: IconButton(
                  icon: Icon(
                    _obscurePassword
                        ? Icons.visibility_rounded
                        : Icons.visibility_off_rounded,
                    color: GlassColors.secondaryText,
                  ),
                  tooltip: _obscurePassword ? 'Show password' : 'Hide password',
                  onPressed: _isSubmitting
                      ? null
                      : () => setState(
                          () => _obscurePassword = !_obscurePassword,
                        ),
                ),
              ),
              const SizedBox(height: 6),
              const Text(
                'Provide at least $kMinTeacherPasswordLength characters, '
                'including a letter and a number. Share it with the teacher '
                'securely - it cannot be viewed later.',
                style: TextStyle(
                  fontSize: 12,
                  color: GlassColors.secondaryText,
                ),
              ),
              const SizedBox(height: 20),
              const Text(
                'Role',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: GlassColors.heading,
                ),
              ),
              const SizedBox(height: 8),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment<String>(
                    value: 'teacher',
                    label: Text('Teacher'),
                  ),
                  ButtonSegment<String>(value: 'admin', label: Text('Admin')),
                ],
                selected: {_role},
                showSelectedIcon: false,
                onSelectionChanged: _isSubmitting
                    ? null
                    : (selection) => setState(() => _role = selection.first),
              ),
              if (_errorMessage != null) ...[
                const SizedBox(height: 16),
                _errorBanner(_errorMessage!),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isSubmitting ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        SizedBox(
          width: 170,
          child: GlassButton(
            onPressed: _isSubmitting ? null : _submit,
            height: 44,
            borderRadius: 12,
            color: GlassColors.primaryBlue,
            disabled: _isSubmitting,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (_isSubmitting) ...[
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
                // Flexible so a large text scale ellipsizes instead of
                // overflowing the fixed-width action button.
                Flexible(
                  child: Text(
                    _isSubmitting ? 'CREATING...' : 'CREATE ACCOUNT',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _field({
    required TextEditingController controller,
    required String label,
    required IconData icon,
    required String? Function(String?) validator,
    bool enabled = true,
    bool obscureText = false,
    Widget? suffixIcon,
    TextInputType? keyboardType,
    TextCapitalization textCapitalization = TextCapitalization.none,
  }) {
    return TextFormField(
      controller: controller,
      enabled: enabled,
      obscureText: obscureText,
      keyboardType: keyboardType,
      textCapitalization: textCapitalization,
      validator: validator,
      style: const TextStyle(color: GlassColors.heading, fontSize: 15),
      decoration: InputDecoration(
        labelText: label,
        prefixIcon: Icon(icon, color: GlassColors.secondaryText),
        suffixIcon: suffixIcon,
        border: const OutlineInputBorder(),
        focusedBorder: const OutlineInputBorder(
          borderSide: BorderSide(color: GlassColors.primaryBlue, width: 2),
        ),
        labelStyle: const TextStyle(color: GlassColors.secondaryText),
      ),
    );
  }

  Widget _errorBanner(String message) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: GlassColors.error.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: GlassColors.error.withValues(alpha: 0.4)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.error_outline_rounded,
            size: 20,
            color: GlassColors.error,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(fontSize: 13, color: GlassColors.error),
            ),
          ),
        ],
      ),
    );
  }
}
