import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'assignments_page.dart';
import 'config/environment.dart';
import 'faculty_finder_page.dart';
import 'lab_finder_page.dart';
import 'role_selection_page.dart';
import 'services/api_cache.dart';
import 'services/auth_service.dart';
import 'student.dart';
import 'timetable.dart';
import 'profile.dart';
import 'utils/glass_container.dart';
import 'utils/motion.dart';

class HomePage extends StatefulWidget {
  final Student student;

  /// Optional injected HTTP client, for tests only (same convention as the
  /// teacher panel and the finder screens). Null in the app.
  final http.Client? client;

  /// The floating glass navigation bar's footprint: the distance from the
  /// bottom of the screen to the top edge of the bar.
  ///
  /// Derived from [_GlassBottomNav]'s own geometry - 16 bottom margin + 8
  /// bottom padding + 60 bar height + 8 top padding. A tab body that scrolls
  /// uses this so its last card clears the bar instead of sitting behind it,
  /// where taps belong to the bar.
  static const double kGlassNavInset = 92;

  const HomePage({super.key, required this.student, this.client});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int selectedIndex = 0;

  /// A slot stays null until its tab is first shown.
  ///
  /// Building all three tabs up front (the previous behaviour) meant the
  /// Assignments tab fired `GET /assignments` while the user was still on
  /// Home, competing with the timetable request and delaying the first
  /// screen. Once created, a tab is kept alive by the IndexedStack exactly as
  /// before, so switching back never refetches or resets scroll position.
  final List<Widget?> _pages = List<Widget?>.filled(3, null);

  static const List<String> _tabTitles = ['CampusSync', 'Assignments', 'Profile'];

  @override
  void initState() {
    super.initState();
    _pages[0] = _buildPage(0);
  }

  Widget _buildPage(int index) {
    switch (index) {
      case 1:
        // Forward the injected client too, so the Assignments tab uses the
        // same test seam as this page's other network calls. `embedded` keeps
        // this page's Scaffold, app bar and background as the only chrome.
        return AssignmentsPage(
          student: widget.student,
          client: widget.client,
          embedded: true,
          bottomInset: HomePage.kGlassNavInset,
        );
      case 2:
        return ProfilePage(student: widget.student);
      default:
        return _HomeTab(student: widget.student, client: widget.client);
    }
  }

  /// Switches tab, creating its page on first visit. Used by the bottom
  /// navigation.
  void _select(int index) {
    if (index == selectedIndex && _pages[index] != null) return;
    setState(() {
      selectedIndex = index;
      _pages[index] ??= _buildPage(index);
    });
  }

  Widget _slot(int index) {
    if (index != selectedIndex && _pages[index] == null) {
      // Not visited yet: never mount it, so no request is made for it.
      return const SizedBox.shrink();
    }
    return _pages[index] ??= _buildPage(index);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBody: true,
      extendBodyBehindAppBar: true,
      appBar: GlassAppBar(
        title: AnimatedSwitcher(
          duration: motionDuration(context, const Duration(milliseconds: 160)),
          switchInCurve: Curves.easeOut,
          switchOutCurve: Curves.easeIn,
          child: Text(
            _tabTitles[selectedIndex],
            key: ValueKey<int>(selectedIndex),
          ),
        ),
        automaticallyImplyLeading: false,
        actions: [
          IconButton(
            icon: const Icon(Icons.notifications_outlined),
            onPressed: () {},
          ),
        ],
      ),
      body: GlassBackground(
        child: IndexedStack(
          index: selectedIndex,
          children: [for (var i = 0; i < 3; i++) _slot(i)],
        ),
      ),

      // Bottom navigation
      bottomNavigationBar: _GlassBottomNav(
        selectedIndex: selectedIndex,
        onDestinationSelected: _select,
      ),
    );
  }
}

class _GlassBottomNav extends StatelessWidget {
  const _GlassBottomNav({
    required this.selectedIndex,
    required this.onDestinationSelected,
  });

  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;

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
      // Flat surface: no drop shadow (read as an outline).
      shadowColor: Colors.transparent,
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
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home_rounded),
            label: 'Home',
          ),
          NavigationDestination(
            key: Key('nav_assignments'),
            icon: Icon(Icons.assignment_outlined),
            selectedIcon: Icon(Icons.assignment_rounded),
            label: 'Assignments',
          ),
          NavigationDestination(
            icon: Icon(Icons.person_outline),
            selectedIcon: Icon(Icons.person_rounded),
            label: 'Profile',
          ),
        ],
      ),
    );
  }
}

class _HomeTab extends StatefulWidget {
  const _HomeTab({required this.student, this.client});

  final Student student;

  /// Optional injected HTTP client, for tests only.
  final http.Client? client;

  @override
  State<_HomeTab> createState() => _HomeTabState();
}

class _HomeTabState extends State<_HomeTab> {
  bool _isLoadingSchedule = true;
  String? _scheduleError;
  List<TimetableEntry> _today = const [];
  http.Client? _ownedClient;
  http.Client get _client => widget.client ?? (_ownedClient ??= http.Client());

  @override
  void dispose() {
    _ownedClient?.close();
    super.dispose();
  }

  static const List<String> _dayNames = [
    'Monday',
    'Tuesday',
    'Wednesday',
    'Thursday',
    'Friday',
    'Saturday',
    'Sunday',
  ];

  @override
  void initState() {
    super.initState();
    _fetchToday();
  }

  Future<void> _fetchToday() async {
    setState(() {
      _isLoadingSchedule = true;
      _scheduleError = null;
    });

    try {
      final cacheKey = 'timetable_${widget.student.token}';
      final cached = ApiCache.get(cacheKey);

      final String responseBody;
      if (cached != null) {
        responseBody = cached;
      } else {
        final response = await _client.get(
          Uri.parse('${Environment.backendUrl}/timetable'),
          headers: {'Authorization': 'Bearer ${widget.student.token}'},
        );

        if (!mounted) return;

        if (response.statusCode == 401) {
          await AuthService().clearAuthData();
          if (!mounted) return;
          Navigator.of(context).pushAndRemoveUntil(
            MaterialPageRoute(builder: (_) => const RoleSelectionPage()),
            (route) => false,
          );
          return;
        }

        if (response.statusCode != 200) {
          setState(() {
            _scheduleError =
                'Could not load your timetable (${response.statusCode})';
            _isLoadingSchedule = false;
          });
          return;
        }

        responseBody = response.body;
        ApiCache.set(cacheKey, responseBody);
      }

      final todayName = _dayNames[DateTime.now().weekday - 1];
      final entries = (jsonDecode(responseBody) as List<dynamic>)
          .map((entry) => TimetableEntry.fromJson(entry as Map<String, dynamic>))
          // Breaks and the sheet's free periods ("RELM") are not classes, so
          // today's schedule only ever lists real lectures and practicals.
          .where(
            (entry) =>
                entry.day == todayName &&
                !entry.isBreak &&
                !entry.isFreePeriod,
          )
          .toList()
        ..sort((a, b) => a.startTime.compareTo(b.startTime));

      setState(() {
        _today = entries;
        _isLoadingSchedule = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _scheduleError = 'Could not connect to CampusSync server.';
        _isLoadingSchedule = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final hour = DateTime.now().hour;
    final greeting = hour >= 5 && hour < 12
        ? 'Good morning'
        : hour >= 12 && hour < 17
        ? 'Good afternoon'
        : 'Good evening';

    // One shared backdrop blur for the glass surfaces that sit side by side on
    // this screen (the schedule rows, the quick-access cards, the update card)
    // instead of one blur per card. Glass nested *inside* a card keeps its own
    // blur, so nothing about the look changes - see [GlassContainer].
    return BackdropGroup(
      child: _buildHomeContent(context, greeting),
    );
  }

  Widget _buildHomeContent(BuildContext context, String greeting) {
    final student = widget.student;

    return SingleChildScrollView(
      // 100 of breathing room plus the floating nav's footprint, so the
      // "Latest Update" card can scroll fully clear of the bar.
      padding: EdgeInsets.fromLTRB(20, 16, 20, 100 + HomePage.kGlassNavInset),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Welcome
          Text(
            greeting,
            style: const TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.bold,
              color: GlassColors.heading,
              letterSpacing: -0.5,
            ),
          ),

          const SizedBox(height: 6),

          // The student's official name, exactly as stored: no token is
          // assumed to be the given name (some registry rows are not in
          // given/father/family order). The name is the flexible part, so it
          // is the name that ellipsizes; course and division stay visible.
          Row(
            children: [
              Flexible(
                child: Text(
                  student.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w500,
                    color: GlassColors.secondaryText,
                  ),
                ),
              ),
              Text(
                ' \u2022 ${student.course} \u2022 ${student.division}',
                maxLines: 1,
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w500,
                  color: GlassColors.secondaryText,
                ),
              ),
            ],
          ),

          const SizedBox(height: 28),

          // Today's Schedule - the student's own Division D timetable, filtered
          // by the batch stored on their account (the server decides).
          const Text(
            "Today's Schedule",
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: GlassColors.heading,
            ),
          ),

          const SizedBox(height: 14),

          AnimatedSwitcher(
            duration: motionDuration(context, kMotionStandard),
            switchInCurve: Curves.easeOut,
            switchOutCurve: Curves.easeIn,
            child: _isLoadingSchedule
                ? const GlassCard(
                    key: ValueKey('schedule-loading'),
                    padding: EdgeInsets.all(16),
                    margin: EdgeInsets.zero,
                    borderRadius: 16,
                    child: Center(
                      child: Padding(
                        padding: EdgeInsets.symmetric(vertical: 12),
                        child: CircularProgressIndicator(
                          color: GlassColors.primaryBlue,
                        ),
                      ),
                    ),
                  )
                : _scheduleError != null
                ? GlassCard(
                    key: ValueKey('schedule-error-${_scheduleError ?? ''}'),
                    padding: const EdgeInsets.all(16),
                    margin: EdgeInsets.zero,
                    borderRadius: 16,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _scheduleError!,
                          style: const TextStyle(
                            fontSize: 14,
                            color: GlassColors.secondaryText,
                          ),
                        ),
                        const SizedBox(height: 10),
                        SizedBox(
                          width: 140,
                          child: GlassOutlinedButton(
                            onPressed: _fetchToday,
                            height: 40,
                            borderRadius: 12,
                            child: const Text(
                              'Try Again',
                              style: TextStyle(fontSize: 13),
                            ),
                          ),
                        ),
                      ],
                    ),
                  )
                : _today.isEmpty
                ? GlassCard(
                    key: const ValueKey('schedule-empty'),
                    padding: const EdgeInsets.all(16),
              margin: EdgeInsets.zero,
                    borderRadius: 16,
                    child: Row(
                      children: [
                        GlassContainer(
                          width: 52,
                          height: 52,
                          borderRadius: 14,
                          padding: EdgeInsets.zero,
                          blurStrength: 15,
                          opacity: 0.7,
                          borderOpacity: 0.4,
                          child: const Icon(
                            Icons.event_available_rounded,
                            size: 26,
                            color: GlassColors.primaryBlue,
                          ),
                        ),
                        const SizedBox(width: 16),
                        const Expanded(
                          child: Text(
                            'No classes scheduled for your batch today.',
                            style: TextStyle(
                              fontSize: 14,
                              color: GlassColors.secondaryText,
                            ),
                          ),
                        ),
                      ],
                    ),
                  )
                : Column(
                    key: const ValueKey('schedule-list'),
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: _today.map(
                        (entry) => Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: GlassCard(
                            padding: const EdgeInsets.all(16),
                            margin: EdgeInsets.zero,
                            borderRadius: 16,
                            child: Row(
                              children: [
                                GlassContainer(
                                  width: 52,
                                  height: 52,
                                  borderRadius: 14,
                                  padding: EdgeInsets.zero,
                                  blurStrength: 15,
                                  opacity: 0.7,
                                  borderOpacity: 0.4,
                                  child: Icon(
                                    entry.entryType == 'practical'
                                        ? Icons.science_rounded
                                        : Icons.menu_book_rounded,
                                    size: 26,
                                    color: GlassColors.primaryBlue,
                                  ),
                                ),
                                const SizedBox(width: 16),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        entry.subject,
                                        style: const TextStyle(
                                          fontSize: 18,
                                          fontWeight: FontWeight.bold,
                                          color: GlassColors.heading,
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        '${entry.time}'
                                        '${entry.faculty != null && entry.faculty!.isNotEmpty ? ' \u2022 ${entry.faculty}' : ''}',
                                        style: const TextStyle(
                                          fontSize: 14,
                                          color: GlassColors.secondaryText,
                                        ),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        entry.entryType == 'practical'
                                            ? 'Practical \u2022 ${entry.batch}'
                                            : 'Lecture \u2022 whole division',
                                        style: const TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.w600,
                                          color: GlassColors.primaryBlue,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                    ).toList(),
                ),
          ),

          const SizedBox(height: 28),

          // Quick Access
          const Text(
            'Quick Access',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: GlassColors.heading,
            ),
          ),

          const SizedBox(height: 14),

          // Simple non-scrollable grid replacement. Five cards, two per row,
          // with the fifth (Announcements) full width in the last row. Tasks
          // is not here: the Assignments tab is the way in.
          Row(
            children: [
              Expanded(
                child: _glassQuickCard(
                  icon: Icons.calendar_month_rounded,
                  title: 'Timetable',
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => TimetablePage(student: student),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _glassQuickCard(
                  icon: Icons.bar_chart_rounded,
                  title: 'Attendance',
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _glassQuickCard(
                  icon: Icons.person_search_rounded,
                  title: 'Faculty Finder',
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => FacultyFinderPage(student: student),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _glassQuickCard(
                  icon: Icons.science_rounded,
                  title: 'Labs',
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => LabFinderPage(student: student),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _glassQuickCard(
                  icon: Icons.campaign_rounded,
                  title: 'Announcements',
                ),
              ),
            ],
          ),

          const SizedBox(height: 28),

          // Latest Update
          const Text(
            'Latest Update',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: GlassColors.heading,
            ),
          ),

          const SizedBox(height: 14),

          GlassCard(
            padding: const EdgeInsets.all(16),
            margin: EdgeInsets.zero,
            borderRadius: 16,
            child: Row(
              children: [
                GlassContainer(
                  width: 44,
                  height: 44,
                  borderRadius: 12,
                  padding: EdgeInsets.zero,
                  blurStrength: 15,
                  opacity: 0.7,
                  borderOpacity: 0.4,
                  child: const Icon(
                    Icons.check_circle_outline_rounded,
                    size: 22,
                    color: GlassColors.success,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'No Schedule Changes',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                          color: GlassColors.heading,
                        ),
                      ),
                      const SizedBox(height: 2),
                      const Text(
                        'There are no free-period changes for your batch.',
                        style: TextStyle(
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
        ],
      ),
    );
  }

  Widget _glassQuickCard({
    Key? key,
    required IconData icon,
    required String title,
    VoidCallback? onTap,
  }) {
    return GlassContainer(
      key: key,
      padding: const EdgeInsets.all(18),
      margin: EdgeInsets.zero,
      borderRadius: 16,
      blurStrength: 15,
      opacity: 0.6,
      borderOpacity: 0.4,
      onTap: onTap,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          GlassContainer(
            width: 50,
            height: 50,
            borderRadius: 14,
            padding: EdgeInsets.zero,
            blurStrength: 15,
            opacity: 0.7,
            borderOpacity: 0.4,
            child: Icon(icon, size: 26, color: GlassColors.primaryBlue),
          ),
          const SizedBox(height: 10),
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontWeight: FontWeight.w600,
              fontSize: 14,
              color: GlassColors.heading,
            ),
          ),
        ],
      ),
    );
  }
}
