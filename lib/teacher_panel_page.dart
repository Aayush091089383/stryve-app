import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'claim_free_period_page.dart';
import 'config/environment.dart';
import 'services/teacher_auth_service.dart';
import 'teacher_approvals_page.dart';
import 'teacher_assignments_page.dart';
import 'teacher_attendance_page.dart';
import 'teacher_login_page.dart';
import 'teacher_management_page.dart';
import 'teacher_models.dart';
import 'teacher_profile_page.dart';
import 'utils/animated_count_badge.dart';
import 'utils/glass_container.dart';
import 'utils/teacher_api.dart';

export 'teacher_models.dart';

/// Teacher Panel / Admin Panel shell.
///
/// Two separate dashboards that only share backend infrastructure:
///
/// * Teacher Panel - exactly three bottom tabs: **Home, Assignments, Profile**.
///   Student Registration Approvals is a separate section reached from Home
///   (and only when the backend says this account may review registrations).
/// * Admin Panel - three tabs: **Home, Approvals, Profile**, with the admin
///   overview and navigation to teacher management. The Admin Logout button
///   lives on the Profile tab, never on Home.
///
/// Every authorization decision is the backend's: this page only reflects what
/// `/teacher/me` and the feature endpoints return.
class TeacherPanelPage extends StatefulWidget {
  const TeacherPanelPage({super.key, this.authService, this.client});

  /// Optional injected services, used by tests.
  ///
  /// Production leaves both null: the page then uses the real
  /// [TeacherAuthService] (secure storage) and a short-lived `http.Client`.
  final TeacherAuthService? authService;
  final http.Client? client;

  @override
  State<TeacherPanelPage> createState() => _TeacherPanelPageState();
}

class _TeacherPanelPageState extends State<TeacherPanelPage> {
  late final TeacherAuthService _authService =
      widget.authService ?? TeacherAuthService();

  /// Only set when this page created the client itself, so [dispose] closes
  /// what it owns and never closes a client injected by a caller/test.
  http.Client? _ownedClient;

  http.Client get _client => widget.client ?? (_ownedClient ??= http.Client());

  TeacherData? _teacher;

  /// Effective approval permission, as reported by `GET /teacher/me`.
  bool _canReviewRegistrations = false;

  /// Faculty short code linked to this account (null when not linked).
  String? _shortCode;

  List<TeachingAssignment> _assignments = const [];
  List<FreePeriodClaim> _claims = const [];

  /// Admin overview counts (null until loaded, or when not an admin).
  int? _pendingRegistrationCount;
  int? _teacherAccountCount;

  bool _isLoading = true;
  bool _isRefreshing = false;
  bool _isLoggingOut = false;
  String? _loadError;
  int _tabIndex = 0;

  bool get _isAdmin => _teacher?.role == 'admin';

  static const List<String> _teacherTabTitles = [
    'Home',
    'Assignments',
    'Profile',
  ];
  static const List<String> _adminTabTitles = ['Home', 'Approvals', 'Profile'];

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

  // -------------------------------------------------------------------------
  // Loading
  // -------------------------------------------------------------------------

  Future<void> _load({bool isRefresh = false}) async {
    if (isRefresh) {
      setState(() => _isRefreshing = true);
    } else {
      setState(() {
        _isLoading = true;
        _loadError = null;
      });
    }

    try {
      final teacher = await _authService.getTeacher();
      if (!mounted) return;

      if (teacher == null) {
        // Nothing usable is stored locally (missing or locally expired): the
        // teacher has to sign in again.
        _goToTeacherLogin();
        return;
      }

      setState(() => _teacher = teacher);

      final token = await _authService.getToken();
      if (!mounted) return;
      if (token == null) {
        _goToTeacherLogin();
        return;
      }

      final me = await _client
          .get(
            Uri.parse('${Environment.backendUrl}/teacher/me'),
            headers: teacherHeaders(token),
          )
          .timeout(kTeacherRequestTimeout);

      if (!mounted) return;

      if (me.statusCode == 401) {
        await _handleSessionExpired();
        return;
      }

      if (me.statusCode == 200) {
        final body = jsonDecode(me.body) as Map<String, dynamic>;
        final code = (body['short_code'] as String?)?.trim();
        setState(() {
          _canReviewRegistrations =
              body['can_review_registrations'] as bool? ?? false;
          _shortCode = (code == null || code.isEmpty) ? null : code;
        });
      }

      await _loadAssignments(token);
      await _loadClaims(token);
      if (_isAdmin) {
        await _loadAdminOverview(token);
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

  Future<void> _loadAssignments(String token) async {
    try {
      final response = await _client
          .get(
            Uri.parse('${Environment.backendUrl}/teacher/assignments'),
            headers: teacherHeaders(token),
          )
          .timeout(kTeacherRequestTimeout);

      if (!mounted) return;

      if (response.statusCode == 200) {
        setState(() {
          _assignments = teacherJsonList(
            response.body,
          ).map(TeachingAssignment.fromJson).toList();
        });
      } else if (response.statusCode == 401) {
        await _handleSessionExpired();
      }
    } catch (_) {
      // The Home tab shows its own message; a missing assignment list must not
      // blank out the whole panel.
    }
  }

  Future<void> _loadClaims(String token) async {
    try {
      final response = await _client
          .get(
            Uri.parse('${Environment.backendUrl}/teacher/free-periods/claims'),
            headers: teacherHeaders(token),
          )
          .timeout(kTeacherRequestTimeout);

      if (!mounted) return;

      if (response.statusCode == 200) {
        setState(() {
          _claims = teacherJsonList(
            response.body,
          ).map(FreePeriodClaim.fromJson).toList();
        });
      } else if (response.statusCode == 401) {
        await _handleSessionExpired();
      }
    } catch (_) {
      // Non-fatal: the Claim Free Period screen reports its own errors.
    }
  }

  Future<void> _loadAdminOverview(String token) async {
    try {
      final pending = await _client
          .get(
            Uri.parse('${Environment.backendUrl}/teacher/registrations/pending'),
            headers: teacherHeaders(token),
          )
          .timeout(kTeacherRequestTimeout);
      final accounts = await _client
          .get(
            Uri.parse('${Environment.backendUrl}/teacher/list'),
            headers: teacherHeaders(token),
          )
          .timeout(kTeacherRequestTimeout);

      if (!mounted) return;

      if (pending.statusCode == 401 || accounts.statusCode == 401) {
        await _handleSessionExpired();
        return;
      }

      setState(() {
        _pendingRegistrationCount = pending.statusCode == 200
            ? teacherJsonList(pending.body).length
            : null;
        _teacherAccountCount = accounts.statusCode == 200
            ? teacherJsonList(accounts.body).length
            : null;
      });
    } catch (_) {
      // Counts are informational only.
    }
  }

  // -------------------------------------------------------------------------
  // Session + navigation
  // -------------------------------------------------------------------------

  /// A 401 means the stored teacher token is no longer accepted: drop only the
  /// teacher credentials (never the student's) and send them to teacher login.
  Future<void> _handleSessionExpired() async {
    await _authService.clearAuthData();
    if (!mounted) return;
    _showSnackBar('Your session expired. Please sign in again.');
    _goToTeacherLogin();
  }

  void _goToTeacherLogin() {
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (_) => const TeacherLoginPage()),
    );
  }

  /// Logout: invalidate the session on the backend (best effort) and clear only
  /// the teacher-prefixed credentials, then return to the teacher/admin login.
  Future<void> _logout() async {
    if (_isLoggingOut) return;
    setState(() => _isLoggingOut = true);

    try {
      final token = await _authService.getToken();
      if (token != null) {
        await _client
            .post(
              Uri.parse('${Environment.backendUrl}/teacher/logout'),
              headers: teacherHeaders(token),
            )
            .timeout(kTeacherRequestTimeout);
      }
    } catch (_) {
      // Signing out locally must work even when the backend is unreachable.
    }

    await _authService.clearAuthData();
    if (!mounted) return;
    setState(() => _isLoggingOut = false);
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (_) => const TeacherLoginPage()),
    );
  }

  void _showSnackBar(String message, {Color? color}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: color),
    );
  }

  void _openApprovals() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => TeacherApprovalsPage(
          authService: _authService,
          client: widget.client,
          onSessionExpired: _handleSessionExpired,
        ),
      ),
    );
  }

  void _openAttendance() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => TeacherAttendancePage(
          authService: _authService,
          client: widget.client,
        ),
      ),
    );
  }

  void _openClaimFreePeriod() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ClaimFreePeriodPage(
          authService: _authService,
          client: widget.client,
        ),
      ),
    );
  }

  void _openTeacherManagement() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => TeacherManagementPage(
          authService: _authService,
          client: widget.client,
          onSessionExpired: _handleSessionExpired,
        ),
      ),
    );
  }

  // -------------------------------------------------------------------------
  // Build
  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(
        body: Center(
          child: CircularProgressIndicator(
            valueColor: AlwaysStoppedAnimation<Color>(GlassColors.primaryBlue),
          ),
        ),
      );
    }

    final isAdmin = _isAdmin;
    final tabTitles = isAdmin ? _adminTabTitles : _teacherTabTitles;

    final pages = <Widget>[
      isAdmin ? _buildAdminHome() : _buildTeacherHome(),
      isAdmin
          ? TeacherApprovalsView(
              authService: _authService,
              client: _client,
              onSessionExpired: _handleSessionExpired,
            )
          : TeacherAssignmentsView(
              authService: _authService,
              client: _client,
              onSessionExpired: _handleSessionExpired,
            ),
      TeacherProfileView(
        name: _teacher?.name ?? (isAdmin ? 'Administrator' : 'Teacher'),
        email: _teacher?.email ?? '',
        isAdmin: isAdmin,
        shortCode: _shortCode,
        canReviewRegistrations: _canReviewRegistrations,
        isLoggingOut: _isLoggingOut,
        onLogout: _logout,
      ),
    ];

    return Scaffold(
      extendBody: true,
      extendBodyBehindAppBar: true,
      appBar: GlassAppBar(
        title: Text(
          isAdmin
              ? 'Admin Panel · ${tabTitles[_tabIndex]}'
              : 'Teacher Panel · ${tabTitles[_tabIndex]}',
        ),
        automaticallyImplyLeading: false,
        actions: [
          IconButton(
            icon: _isRefreshing
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation<Color>(
                        GlassColors.primaryBlue,
                      ),
                    ),
                  )
                : const Icon(Icons.refresh_rounded),
            onPressed: _isRefreshing
                ? null
                : () => _load(isRefresh: true),
            tooltip: 'Refresh',
          ),
        ],
      ),
      body: GlassBackground(
        child: SafeArea(
          child: IndexedStack(index: _tabIndex, children: pages),
        ),
      ),
      bottomNavigationBar: _GlassBottomNav(
        selectedIndex: _tabIndex,
        onDestinationSelected: (index) => setState(() => _tabIndex = index),
        destinations: [
          const NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home_rounded),
            label: 'Home',
          ),
          isAdmin
              ? NavigationDestination(
                  // Pending registrations are the only real, already-fetched
                  // count in the app (GET /teacher/registrations/pending).
                  // `null` means "could not fetch", which must never be drawn
                  // as a badge, so it is passed as 0.
                  icon: AnimatedCountBadge(
                    count: _pendingRegistrationCount ?? 0,
                    child: const Icon(Icons.assignment_ind_outlined),
                  ),
                  selectedIcon: AnimatedCountBadge(
                    count: _pendingRegistrationCount ?? 0,
                    child: const Icon(Icons.assignment_ind_rounded),
                  ),
                  label: 'Approvals',
                )
              : const NavigationDestination(
                  icon: Icon(Icons.upload_file_outlined),
                  selectedIcon: Icon(Icons.upload_file_rounded),
                  label: 'Assignments',
                ),
          const NavigationDestination(
            icon: Icon(Icons.person_outline),
            selectedIcon: Icon(Icons.person_rounded),
            label: 'Profile',
          ),
        ],
      ),
    );
  }

  // -------------------------------------------------------------------------
  // Teacher Home
  // -------------------------------------------------------------------------

  Widget _buildTeacherHome() {
    final now = DateTime.now();
    final todayName = _dayName(now);
    final today = _assignments
        .where(
          (assignment) =>
              assignment.day.isEmpty ||
              assignment.day.toLowerCase() == todayName.toLowerCase(),
        )
        .toList();

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 110),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: kTeacherMaxContentWidth),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildIdentityCard(
                roleBadge: 'TEACHER',
                subtitle: _shortCode == null
                    ? 'Faculty code not linked yet'
                    : 'Faculty code $_shortCode',
              ),
              if (_loadError != null) ...[
                const SizedBox(height: 16),
                _buildInlineError(_loadError!),
              ],
              const SizedBox(height: 24),
              const _SectionTitle("Today's Classes"),
              const SizedBox(height: 12),
              if (today.isEmpty)
                _buildInfoCard(
                  icon: Icons.event_available_rounded,
                  title: 'No classes assigned for $todayName',
                  body: _assignments.isEmpty
                      ? 'CampusSync has no verified teaching assignments for '
                            'your account yet. Ask an administrator to link '
                            'your faculty code from the official Division D '
                            'timetable.'
                      : 'Your verified assignments have no period scheduled '
                            'today.',
                )
              else
                ...today.map(
                  (assignment) => Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: GlassCard(
                      margin: EdgeInsets.zero,
                      padding: const EdgeInsets.all(14),
                      child: Row(
                        children: [
                          GlassContainer(
                            width: 44,
                            height: 44,
                            borderRadius: 12,
                            padding: EdgeInsets.zero,
                            blurStrength: 12,
                            opacity: 0.7,
                            borderOpacity: 0.4,
                            child: const Icon(
                              Icons.school_rounded,
                              size: 22,
                              color: GlassColors.primaryBlue,
                            ),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  assignment.subject,
                                  style: const TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                    color: GlassColors.heading,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  '${assignment.slotLabel} • '
                                  '${assignment.batchLabel}',
                                  style: const TextStyle(
                                    fontSize: 13,
                                    color: GlassColors.secondaryText,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              const SizedBox(height: 24),
              const _SectionTitle('Teaching'),
              const SizedBox(height: 12),
              _buildActionCard(
                icon: Icons.fact_check_outlined,
                title: 'Lecture Attendance',
                subtitle:
                    'Mark present/absent for a lecture you are assigned to '
                    'teach.',
                onTap: _openAttendance,
              ),
              const SizedBox(height: 12),
              _buildActionCard(
                icon: Icons.event_busy_rounded,
                title: 'Claim Free Period',
                subtitle: _claims.isEmpty
                    ? 'Claim a period in which your class group is free.'
                    : '${_claims.length} period(s) already claimed.',
                onTap: _openClaimFreePeriod,
              ),
              if (_claims.isNotEmpty) ...[
                const SizedBox(height: 12),
                GlassCard(
                  margin: EdgeInsets.zero,
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Your claimed periods',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: GlassColors.heading,
                        ),
                      ),
                      const SizedBox(height: 8),
                      ..._claims.take(4).map(
                        (claim) => Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: Text(
                            '${claim.claimDate} • ${claim.time} • '
                            '${claim.batchLabel}',
                            style: const TextStyle(
                              fontSize: 13,
                              color: GlassColors.secondaryText,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 24),
              const _SectionTitle('Student Registration Approvals'),
              const SizedBox(height: 12),
              if (_canReviewRegistrations)
                _buildActionCard(
                  icon: Icons.how_to_reg_rounded,
                  title: 'Review Pending Registrations',
                  subtitle:
                      'A separate section - it is not part of the bottom '
                      'navigation.',
                  onTap: _openApprovals,
                )
              else
                _buildInfoCard(
                  icon: Icons.lock_outline_rounded,
                  title: 'Approval access not granted',
                  body:
                      'Reviewing student registrations is a permission an '
                      'administrator grants explicitly. Your account does not '
                      'have it, so the backend refuses those requests.',
                ),
              const SizedBox(height: 24),
              const _SectionTitle('My Assignments'),
              const SizedBox(height: 12),
              if (_assignments.isEmpty)
                _buildInfoCard(
                  icon: Icons.assignment_ind_outlined,
                  title: 'No verified teaching assignments',
                  body:
                      'Assignments are taken from the official Division D '
                      'timetable or added by an administrator. Nothing is '
                      'inferred from your name.',
                )
              else
                ..._assignments.map(
                  (assignment) => Padding(
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
                                  assignment.subject,
                                  style: const TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                    color: GlassColors.heading,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  '${assignment.dayLabel} • '
                                  '${assignment.slotLabel} • '
                                  '${assignment.batchLabel}',
                                  style: const TextStyle(
                                    fontSize: 12,
                                    color: GlassColors.secondaryText,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Text(
                            assignment.source == 'timetable'
                                ? 'timetable'
                                : 'admin',
                            style: const TextStyle(
                              fontSize: 11,
                              color: GlassColors.disabled,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  // -------------------------------------------------------------------------
  // Admin Home
  // -------------------------------------------------------------------------

  Widget _buildAdminHome() {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 110),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: kTeacherMaxContentWidth),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildIdentityCard(
                roleBadge: 'ADMIN',
                subtitle: 'Administrator dashboard',
              ),
              if (_loadError != null) ...[
                const SizedBox(height: 16),
                _buildInlineError(_loadError!),
              ],
              const SizedBox(height: 24),
              const _SectionTitle('Overview'),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: _buildStatCard(
                      'Pending registrations',
                      _pendingRegistrationCount,
                      Icons.hourglass_bottom_rounded,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _buildStatCard(
                      'Teacher accounts',
                      _teacherAccountCount,
                      Icons.people_alt_outlined,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              const _SectionTitle('Administration'),
              const SizedBox(height: 12),
              _buildActionCard(
                icon: Icons.how_to_reg_rounded,
                title: 'Student Registration Approvals',
                subtitle: 'Approve or reject pending student registrations.',
                onTap: () => setState(() => _tabIndex = 1),
              ),
              const SizedBox(height: 12),
              _buildActionCard(
                icon: Icons.manage_accounts_rounded,
                title: 'Teacher Management',
                subtitle:
                    'Create teacher accounts, link official faculty codes and '
                    'grant the registration-approval permission.',
                onTap: _openTeacherManagement,
              ),
              const SizedBox(height: 24),
              _buildInfoCard(
                icon: Icons.gavel_rounded,
                title: 'Scoped permissions',
                body:
                    'Only administrators can create accounts or change '
                    'permissions. Teachers never gain those rights, and no '
                    'password, hash or token is ever listed in the app.',
              ),
            ],
          ),
        ),
      ),
    );
  }

  // -------------------------------------------------------------------------
  // Shared pieces
  // -------------------------------------------------------------------------

  Widget _buildIdentityCard({
    required String roleBadge,
    required String subtitle,
  }) {
    final isAdmin = roleBadge == 'ADMIN';

    return GlassContainer(
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
            backgroundColor: GlassColors.primaryBlue.withValues(alpha: 0.2),
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
                  _teacher?.name ?? (isAdmin ? 'Administrator' : 'Teacher'),
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: GlassColors.heading,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                Text(
                  _teacher?.email ?? '',
                  style: const TextStyle(
                    fontSize: 14,
                    color: GlassColors.secondaryText,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 6),
                Text(
                  subtitle,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: GlassColors.primaryBlue,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color:
                  (isAdmin ? GlassColors.warning : GlassColors.primaryBlue)
                      .withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color:
                    (isAdmin ? GlassColors.warning : GlassColors.primaryBlue)
                        .withValues(alpha: 0.4),
              ),
            ),
            child: Text(
              roleBadge,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: isAdmin
                    ? GlassColors.warning
                    : GlassColors.primaryBlue,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActionCard({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return GlassContainer(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      borderRadius: 16,
      blurStrength: 15,
      opacity: 0.7,
      borderOpacity: 0.4,
      onTap: onTap,
      child: Row(
        children: [
          GlassContainer(
            width: 46,
            height: 46,
            borderRadius: 12,
            padding: EdgeInsets.zero,
            blurStrength: 12,
            opacity: 0.7,
            borderOpacity: 0.4,
            child: Icon(icon, size: 22, color: GlassColors.primaryBlue),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: GlassColors.heading,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: const TextStyle(
                    fontSize: 12,
                    color: GlassColors.secondaryText,
                  ),
                ),
              ],
            ),
          ),
          const Icon(
            Icons.chevron_right_rounded,
            color: GlassColors.secondaryText,
          ),
        ],
      ),
    );
  }

  Widget _buildInfoCard({
    required IconData icon,
    required String title,
    required String body,
  }) {
    return GlassContainer(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      borderRadius: 16,
      blurStrength: 15,
      opacity: 0.6,
      borderOpacity: 0.3,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 22, color: GlassColors.secondaryText),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: GlassColors.heading,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  body,
                  style: const TextStyle(
                    fontSize: 12,
                    color: GlassColors.secondaryText,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInlineError(String message) {
    return GlassContainer(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      borderRadius: 16,
      blurStrength: 15,
      opacity: 0.7,
      borderOpacity: 0.4,
      child: Row(
        children: [
          const Icon(
            Icons.cloud_off_rounded,
            size: 22,
            color: GlassColors.warning,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: GlassColors.heading,
              ),
            ),
          ),
          TextButton(
            onPressed: _isRefreshing ? null : () => _load(isRefresh: true),
            child: const Text('Retry'),
          ),
        ],
      ),
    );
  }

  Widget _buildStatCard(String label, int? value, IconData icon) {
    return GlassContainer(
      padding: const EdgeInsets.all(16),
      borderRadius: 16,
      blurStrength: 15,
      opacity: 0.75,
      borderOpacity: 0.4,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: GlassColors.primaryBlue),
          const SizedBox(height: 10),
          Text(
            value == null ? '—' : '$value',
            style: const TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.bold,
              color: GlassColors.heading,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: const TextStyle(
              fontSize: 12,
              color: GlassColors.secondaryText,
            ),
          ),
        ],
      ),
    );
  }

  static String _dayName(DateTime date) {
    const names = [
      'Monday',
      'Tuesday',
      'Wednesday',
      'Thursday',
      'Friday',
      'Saturday',
      'Sunday',
    ];
    return names[date.weekday - 1];
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    return Text(
      title,
      style: const TextStyle(
        fontSize: 18,
        fontWeight: FontWeight.bold,
        color: GlassColors.heading,
      ),
    );
  }
}

class _GlassBottomNav extends StatelessWidget {
  const _GlassBottomNav({
    required this.selectedIndex,
    required this.onDestinationSelected,
    required this.destinations,
  });

  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;
  final List<NavigationDestination> destinations;

  @override
  Widget build(BuildContext context) {
    return GlassContainer(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      borderRadius: 24,
      blurStrength: 25,
      opacity: 0.8,
      borderOpacity: 0.5,
      // No outline around the white navigation container. A transparent 1px
      // border keeps the exact same inner geometry as before.
      borderColor: Colors.transparent,
      child: NavigationBar(
        selectedIndex: selectedIndex,
        onDestinationSelected: onDestinationSelected,
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        height: 60,
        labelBehavior: NavigationDestinationLabelBehavior.onlyShowSelected,
        indicatorColor: GlassColors.primaryBlue.withValues(alpha: 0.2),
        indicatorShape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
        ),
        destinations: destinations,
      ),
    );
  }
}
