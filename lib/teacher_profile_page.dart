import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'utils/glass_container.dart';
import 'utils/teacher_api.dart';
import 'utils/theme_provider.dart';

/// Profile tab of the Teacher Panel / Admin Panel.
///
/// It holds the account details and the logout action. Logout is deliberately
/// here rather than on Home: it uses the existing teacher session (the owner
/// calls `POST /teacher/logout` and clears the teacher-prefixed credentials),
/// so signing out can never affect a student session.
class TeacherProfileView extends StatelessWidget {
  const TeacherProfileView({
    super.key,
    required this.name,
    required this.email,
    required this.isAdmin,
    required this.onLogout,
    this.shortCode,
    this.canReviewRegistrations = false,
    this.isLoggingOut = false,
  });

  final String name;
  final String email;
  final bool isAdmin;
  final String? shortCode;
  final bool canReviewRegistrations;
  final Future<void> Function() onLogout;
  final bool isLoggingOut;

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
              GlassContainer(
                width: double.infinity,
                padding: const EdgeInsets.all(20),
                borderRadius: 20,
                blurStrength: 20,
                opacity: 0.8,
                borderOpacity: 0.5,
                child: Row(
                  children: [
                    CircleAvatar(
                      radius: 28,
                      backgroundColor: GlassColors.primaryBlue.withValues(
                        alpha: 0.2,
                      ),
                      child: Icon(
                        isAdmin
                            ? Icons.admin_panel_settings_rounded
                            : Icons.person_rounded,
                        size: 28,
                        color: GlassColors.primaryBlue,
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            name,
                            style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                              color: GlassColors.headingOf(context),
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            email,
                            style: TextStyle(
                              fontSize: 14,
                              color: GlassColors.secondaryTextOf(context),
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              Text(
                'Account',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: GlassColors.headingOf(context),
                ),
              ),
              const SizedBox(height: 12),
              GlassCard(
                margin: EdgeInsets.zero,
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    _buildRow(
                      context,
                      'Role',
                      isAdmin ? 'Administrator' : 'Teacher',
                    ),
                    _buildRow(
                      context,
                      'Faculty code',
                      // Only shown when an administrator has linked one.
                      (shortCode == null || shortCode!.isEmpty)
                          ? 'Not linked'
                          : shortCode!,
                    ),
                    _buildRow(
                      context,
                      'Registration approvals',
                      isAdmin
                          ? 'Allowed (administrator)'
                          : canReviewRegistrations
                          ? 'Allowed'
                          : 'Not permitted',
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              _buildDarkModeCard(context),
              const SizedBox(height: 24),
              GlassButton(
                onPressed: isLoggingOut ? null : onLogout,
                height: 52,
                borderRadius: 14,
                color: GlassColors.error,
                isLoading: isLoggingOut,
                disabled: isLoggingOut,
                child: const Text(
                  'LOG OUT',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                isAdmin
                    ? 'Logging out ends only this admin session and returns to '
                          'the admin login. Student and teacher sessions on this '
                          'device are untouched.'
                    : 'Logging out ends only this teacher session and returns to '
                          'the teacher login. A student session on this device '
                          'is untouched.',
                style: TextStyle(
                  fontSize: 13,
                  color: GlassColors.secondaryTextOf(context),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// The in-app theme switch, shared with the student Profile tab.
  ///
  /// Both switches drive the same [ThemeProvider], so the choice is one app
  /// setting, not per-role state: turning it on as a teacher and signing in as
  /// a student keeps dark mode on.
  Widget _buildDarkModeCard(BuildContext context) {
    final isDark = context.watch<ThemeProvider>().isDarkMode;

    return GlassCard(
      margin: EdgeInsets.zero,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          Icon(
            isDark ? Icons.dark_mode_rounded : Icons.dark_mode_outlined,
            size: 24,
            color: GlassColors.primaryBlue,
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Dark Mode',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: GlassColors.headingOf(context),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  isDark
                      ? 'On - solid dark surfaces'
                      : 'Off - light glass theme',
                  style: TextStyle(
                    fontSize: 12,
                    color: GlassColors.secondaryTextOf(context),
                  ),
                ),
              ],
            ),
          ),
          Switch(
            value: isDark,
            onChanged: (value) =>
                context.read<ThemeProvider>().setDarkMode(value),
          ),
        ],
      ),
    );
  }

  Widget _buildRow(BuildContext context, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 150,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 14,
                color: GlassColors.secondaryTextOf(context),
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: GlassColors.headingOf(context),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
