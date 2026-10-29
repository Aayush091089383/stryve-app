import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import 'announcements_page.dart';
import 'assignments_page.dart';
import 'config/environment.dart';
import 'faculty_finder_page.dart';
import 'lab_finder_page.dart';
import 'notifications_page.dart';
import 'role_selection_page.dart';
import 'schedule_change.dart';
import 'services/api_cache.dart';
import 'services/auth_service.dart';
import 'services/notification_service.dart';
import 'services/push_notification_service.dart';
import 'student.dart';
import 'student_attendance_page.dart';
import 'student_notification.dart';
import 'timetable.dart';
import 'profile.dart';
import 'utils/glass_container.dart';
import 'utils/motion.dart';
import 'utils/subject_aliases.dart';
import 'utils/sliding_nav_bar.dart';

class HomePage extends StatefulWidget {
  final Student student;

  /// Optional injected HTTP client, for tests only (same convention as the
  /// teacher panel and the finder screens). Null in the app.
  final http.Client? client;

  /// Optional injection seam for the system-tray alert, for tests only. Null in
  /// the app, where [LocalSystemNotifications] is used.
  final SystemNotifications? systemNotifications;

  /// Optional injection seam for Firebase push, for tests only. Null in the
  /// app, where a real [PushNotificationService] registers this phone.
  final PushNotificationService? pushNotifications;

  /// The glass bar's own footprint: 16 floating margin + 8 bottom padding +
  /// 60 bar height + 8 top padding.
  ///
  /// This is only the bar itself. The bar is wrapped in a bottom [SafeArea], so
  /// the system gesture inset is added *below* it - [navInsetOf] is what a
  /// scrolling tab must clear.
  static const double kGlassNavBarHeight = 92;

  /// How far above the bottom of the screen the bar's top edge sits.
  ///
  /// The bar's own height plus the system gesture inset its [SafeArea]
  /// consumes.
  ///
  /// Must be read from a context ABOVE the `Scaffold` - i.e. a `HomePage`
  /// element, never one of the tab bodies. A `Scaffold` with a
  /// `bottomNavigationBar` strips the bottom inset from its body's
  /// `MediaQuery` (`padding` *and* `viewPadding`), so inside a tab everything
  /// reports zero; that is why the value is computed here and passed down to
  /// the tabs instead of being looked up in their own `build`.
  ///
  /// It is a method rather than a constant because the inset differs by device
  /// and by navigation mode (24dp for the gesture pill, ~48dp for the
  /// three-button bar) and can change while the app runs.
  static double navInsetOf(BuildContext context) =>
      kGlassNavBarHeight + MediaQuery.paddingOf(context).bottom;

  const HomePage({
    super.key,
    required this.student,
    this.client,
    this.systemNotifications,
    this.pushNotifications,
  });

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int selectedIndex = 0;

  /// When the system back request last asked to leave. A second request within
  /// two seconds exits; see [_handleBackPress].
  DateTime? _lastBackPress;

  /// Cached [HomePage.navInsetOf] value, refreshed in [didChangeDependencies].
  ///
  /// The Assignments tab bakes the inset into its list padding when it is
  /// built, so the value has to be known outside a build pass (a tab is also
  /// created from the navigation callback).
  double _navInset = HomePage.kGlassNavBarHeight;

  /// A slot stays null until its tab is first shown.
  ///
  /// Building every tab up front (the previous behaviour) meant the
  /// Assignments tab fired `GET /assignments` while the user was still on
  /// Home, competing with the timetable request and delaying the first
  /// screen. Once created, a tab is kept alive by the IndexedStack exactly as
  /// before, so switching back never refetches or resets scroll position.
  final List<Widget?> _pages = List<Widget?>.filled(4, null);

  /// The student's notification feed, used for the bell badge. Empty until the
  /// first fetch answers (or when the backend is unreachable, in which case the
  /// badge simply stays hidden - the screen reports its own error).
  List<StudentNotification> _notifications = const [];

  http.Client? _ownedNotificationClient;
  http.Client get _notificationClient =>
      widget.client ?? (_ownedNotificationClient ??= http.Client());

  SystemNotifications? _systemNotifications;
  SystemNotifications get _notificationsPresenter => _systemNotifications ??=
      widget.systemNotifications ?? LocalSystemNotifications();

  PushNotificationService? _pushNotifications;
  PushNotificationService get _pushService => _pushNotifications ??=
      widget.pushNotifications ??
      PushNotificationService(systemNotifications: _notificationsPresenter);

  /// Highest notification id already announced in the system tray. Starts at 0
  /// per app launch, so the newest unread assignment is announced once and a
  /// rebuild or a second fetch never repeats it.
  int _lastAlertedId = 0;

  /// True while the Notifications route is open, so a double tap cannot push it
  /// twice.
  bool _openingNotifications = false;

  static const List<String> _tabTitles = [
    'Stryve',
    'Assignments',
    'Attendance',
    'Profile',
  ];

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();

    final inset = HomePage.navInsetOf(context);
    if (inset == _navInset) return;
    _navInset = inset;

    // Already-built tabs carry the old inset (page 0 is built in initState,
    // before this runs). Recreate the widgets - their State, data and scroll
    // position are kept, only the padding changes - so a tab opened across a
    // navigation-mode change still clears the bar.
    for (final index in const [0, 1, 2]) {
      if (_pages[index] != null) {
        _pages[index] = _buildPage(index);
      }
    }
  }

  @override
  void initState() {
    super.initState();
    _pages[0] = _buildPage(0);
    _fetchNotifications();

    // Register this phone for push on top of the in-app feed. Best effort:
    // a missing Firebase project, denied permission or unreachable backend
    // leaves the bell exactly as it was.
    unawaited(
      _pushService.start(
        authToken: widget.student.token,
        // A push that lands while the app is open means the feed changed;
        // refresh the badge, but do not raise a second tray alert for a row
        // the push just announced.
        onMessage: () => unawaited(_fetchNotifications(alert: false)),
      ),
    );
  }

  @override
  void dispose() {
    _pushNotifications?.dispose();
    _ownedNotificationClient?.close();
    super.dispose();
  }

  /// Loads the feed and, when asked, raises a tray alert for the newest unread
  /// row that has not been announced yet.
  ///
  /// Failures are silent on purpose: the bell is an enhancement, and the
  /// timetable request already owns the app's "backend unreachable" state.
  Future<void> _fetchNotifications({bool alert = true}) async {
    try {
      final response = await _notificationClient.get(
        Uri.parse('${Environment.backendUrl}/notifications'),
        headers: {'Authorization': 'Bearer ${widget.student.token}'},
      );

      if (!mounted || response.statusCode != 200) return;

      final List<dynamic> raw = jsonDecode(response.body);
      final loaded = raw
          .map((n) => StudentNotification.fromJson(n as Map<String, dynamic>))
          .toList();

      if (!mounted) return;
      setState(() => _notifications = loaded);

      final unread = loaded.where((n) => !n.isRead).toList();
      if (!alert || unread.isEmpty) return;

      final newest = unread.reduce((a, b) => a.id >= b.id ? a : b);
      if (newest.id <= _lastAlertedId) return;

      _lastAlertedId = newest.id;
      unawaited(_notificationsPresenter.show(newest.title, newest.message));
    } catch (_) {
      // Leave the previous badge in place; nothing here may break Home.
    }
  }

  Future<void> _openNotifications() async {
    if (_openingNotifications) return;
    _openingNotifications = true;
    try {
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) =>
              NotificationsPage(student: widget.student, client: widget.client),
        ),
      );
    } finally {
      _openingNotifications = false;
    }

    // The screen may have marked rows read; refresh the badge but do not raise
    // a second tray alert for something the student just looked at.
    await _fetchNotifications(alert: false);
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
          bottomInset: _navInset,
        );
      case 2:
        return StudentAttendancePage(
          student: widget.student,
          client: widget.client,
          embedded: true,
          bottomInset: _navInset,
        );
      case 3:
        return ProfilePage(student: widget.student);
      default:
        return _HomeTab(
          student: widget.student,
          client: widget.client,
          bottomInset: _navInset,
          onOpenAttendance: () => _select(2),
          onRefreshNotifications: () => _fetchNotifications(alert: false),
        );
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

  /// Standard Android two-step exit: the first back asks for confirmation, a
  /// second one within two seconds leaves the app.
  ///
  /// Home is the root route after login, so without this a stray back would
  /// close the app outright; the snackbar is the only confirmation.
  void _handleBackPress() {
    final now = DateTime.now();
    final last = _lastBackPress;
    if (last != null && now.difference(last) <= const Duration(seconds: 2)) {
      SystemNavigator.pop();
      return;
    }

    _lastBackPress = now;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(
          content: Text('Press back again to exit'),
          duration: Duration(seconds: 2),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _handleBackPress();
      },
      child: _buildShell(context),
    );
  }

  Widget _buildShell(BuildContext context) {
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
            key: const Key('home_bell'),
            tooltip: 'Notifications',
            icon: _NotificationBell(
              unreadCount: unreadNotificationCount(_notifications),
            ),
            onPressed: _openNotifications,
          ),
        ],
      ),
      body: GlassBackground(
        child: IndexedStack(
          index: selectedIndex,
          children: [for (var i = 0; i < _pages.length; i++) _slot(i)],
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

/// The bell icon with its unread count.
///
/// A zero count hides the badge entirely, and three digits are capped at "99+"
/// so the label never widens the app-bar action.
class _NotificationBell extends StatelessWidget {
  const _NotificationBell({required this.unreadCount});

  final int unreadCount;

  @override
  Widget build(BuildContext context) {
    return Badge(
      key: const Key('home_bell_badge'),
      isLabelVisible: unreadCount > 0,
      backgroundColor: GlassColors.error,
      textColor: Colors.white,
      label: Text(unreadCount > 99 ? '99+' : '$unreadCount'),
      child: const Icon(Icons.notifications_outlined),
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
    // The Scaffold has `extendBody: true`, so `bottomNavigationBar` is laid out
    // flush with the physical bottom edge - behind the Android gesture pill or
    // the three-button bar. A 16px margin is measured from that edge, not from
    // the system inset, so the bar's bottom edge sat on top of the gesture
    // area. SafeArea pushes it clear by exactly the inset the system reports
    // (and only at the bottom: the app bar keeps its own layout).
    return SafeArea(
      top: false,
      bottom: true,
      child: GlassContainer(
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        borderRadius: 24,
        blurStrength: 25,
        // The one surface that pays for the extra save layer: its edge floats
        // over scrolling content and the seam there reads as a border. The
        // cards keep the cheaper exact clip.
        useSaveLayer: true,
        opacity: 0.8,
        borderOpacity: 0.5,
        // No outline around the white navigation container. A transparent 1px
        // border keeps the exact same inner geometry as before.
        borderColor: Colors.transparent,
        // Flat surface: no drop shadow (read as an outline).
        shadowColor: Colors.transparent,
        // One pill slides between the three equal slots instead of each tab
        // flashing its own indicator on. Height stays 60, so the bar's own
        // body is still the 92px of [HomePage.kGlassNavBarHeight]; SafeArea
        // adds the gesture inset above it.
        child: SlidingNavBar(
          selectedIndex: selectedIndex,
          onDestinationSelected: onDestinationSelected,
          height: 60,
          destinations: const [
            SlidingNavDestination(
              icon: Icon(Icons.home_outlined),
              selectedIcon: Icon(Icons.home_rounded),
              label: 'Home',
            ),
            SlidingNavDestination(
              key: Key('nav_assignments'),
              icon: Icon(Icons.assignment_outlined),
              selectedIcon: Icon(Icons.assignment_rounded),
              label: 'Assignments',
            ),
            SlidingNavDestination(
              key: Key('nav_attendance'),
              icon: Icon(Icons.fact_check_outlined),
              selectedIcon: Icon(Icons.fact_check_rounded),
              label: 'Attendance',
            ),
            SlidingNavDestination(
              icon: Icon(Icons.person_outline),
              selectedIcon: Icon(Icons.person_rounded),
              label: 'Profile',
            ),
          ],
        ),
      ),
    );
  }
}

class _HomeTab extends StatefulWidget {
  const _HomeTab({
    required this.student,
    this.client,
    this.bottomInset = 0,
    this.onOpenAttendance,
    this.onRefreshNotifications,
  });

  final Student student;

  /// Switches HomePage to the Attendance tab; the quick card used to be a dead
  /// tile before that tab existed.
  final VoidCallback? onOpenAttendance;

  /// Pull-to-refresh also refreshes the bell badge, which lives on the parent
  /// page. Null when the tab is built without one.
  final Future<void> Function()? onRefreshNotifications;

  /// Optional injected HTTP client, for tests only.
  final http.Client? client;

  /// Room the floating nav bar (plus the system inset it is lifted by) needs
  /// under the content. Passed in because the body's `MediaQuery` has the
  /// bottom inset removed - see [HomePage.navInsetOf].
  final double bottomInset;

  @override
  State<_HomeTab> createState() => _HomeTabState();
}

class _HomeTabState extends State<_HomeTab> {
  bool _isLoadingSchedule = true;
  String? _scheduleError;

  /// Today's claimed free periods for this student's class group.
  List<ScheduleChange> _scheduleChanges = const [];
  bool _isLoadingChanges = true;
  String? _changesError;
  List<TimetableEntry> _today = const [];
  http.Client? _ownedClient;
  http.Client get _client => widget.client ?? (_ownedClient ??= http.Client());

  /// The day the current [_today] list was fetched for. Used to notice the
  /// clock crossing midnight while the app stays open.
  String? _scheduleDay;

  /// Rebuilds the "Next Up" queue once a minute so a lecture that has just
  /// ended disappears without the student touching the screen.
  Timer? _refreshTimer;

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _ownedClient?.close();
    super.dispose();
  }

  /// True when the end of a printed "HH:mm - HH:mm" pair is at or before
  /// [now]. An unparseable value is never treated as ended.
  static bool _hasEnded(String time, DateTime now) {
    final parts = time.split('-');
    if (parts.length != 2) return false;
    final end = _minutesOfDay(parts[1].trim());
    if (end == null) return false;
    return end <= now.hour * 60 + now.minute;
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
    _fetchScheduleChanges();
    _refreshTimer = Timer.periodic(
      const Duration(minutes: 1),
      (_) => _onMinuteTick(),
    );
  }

  void _onMinuteTick() {
    if (!mounted) return;

    // Stay on the right day: a device left on Home overnight would otherwise
    // keep yesterday's rows and call them "caught up".
    final todayName = _dayNames[DateTime.now().weekday - 1];
    if (_scheduleDay != null && _scheduleDay != todayName) {
      _fetchToday();
      // Claims are day-scoped too: a phone left open overnight must not keep
      // yesterday's changes on screen.
      _fetchScheduleChanges();
      return;
    }

    // A claim whose period has passed must stop advertising itself even when
    // the app has been open since the morning. The backend drops it on the
    // next request; this only nudges the stale copy.
    if (_scheduleChanges.any((change) => _hasEnded(change.time, DateTime.now()))) {
      _fetchScheduleChanges();
    }

    setState(() {});
  }

  /// Minutes since midnight for a timetable time, or null when it is not a
  /// plain clock time. The API prints the official sheet's 24-hour `HH:mm`;
  /// the 12-hour form is accepted too so a malformed/older value still works.
  static int? _minutesOfDay(String value) {
    final match = RegExp(
      r'^(\d{1,2}):(\d{2})\s*(AM|PM)?$',
      caseSensitive: false,
    ).firstMatch(value.trim());
    if (match == null) return null;

    var hour = int.parse(match.group(1)!);
    final minute = int.parse(match.group(2)!);
    final meridiem = match.group(3)?.toUpperCase();
    if (minute > 59) return null;

    if (meridiem == null) {
      if (hour > 23) return null;
    } else {
      if (hour < 1 || hour > 12) return null;
      if (meridiem == 'AM') {
        if (hour == 12) hour = 0;
      } else if (hour != 12) {
        hour += 12;
      }
    }

    return hour * 60 + minute;
  }

  /// The next two lectures that have not ended yet, earliest first.
  ///
  /// A lecture disappears at its own end time, not when the following one
  /// starts, so the one in progress stays at the top of the queue until it is
  /// over. Sorting here (rather than trusting the fetch order) keeps the queue
  /// chronological even if the API ever returns the rows in another order.
  List<TimetableEntry> _upNext(DateTime now) {
    final nowMinutes = now.hour * 60 + now.minute;

    final upcoming =
        _today.where((entry) {
          final end = _minutesOfDay(entry.endTime);
          // An unparseable end time stays visible: silently hiding a class is a
          // worse failure than showing one stale row.
          return end == null || end > nowMinutes;
        }).toList()..sort((a, b) {
          final aStart = _minutesOfDay(a.startTime);
          final bStart = _minutesOfDay(b.startTime);
          if (aStart != null && bStart != null) return aStart.compareTo(bStart);
          return a.startTime.compareTo(b.startTime);
        });

    return upcoming.take(2).toList();
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
      final entries =
          (jsonDecode(responseBody) as List<dynamic>)
              .map(
                (entry) =>
                    TimetableEntry.fromJson(entry as Map<String, dynamic>),
              )
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
        _scheduleDay = todayName;
        _isLoadingSchedule = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _scheduleError = 'Could not connect to Stryve server.';
        _isLoadingSchedule = false;
      });
    }
  }

  /// Loads today's claimed free periods for this student's class group.
  ///
  /// The backend scopes the list to the student's own division and batch, so
  /// this screen never filters or widens it. A failed refresh keeps the last
  /// good list on screen; only a first load can render the error card, so a
  /// dropped connection never pretends the changes disappeared.
  Future<void> _fetchScheduleChanges() async {
    setState(() {
      _isLoadingChanges = true;
      _changesError = null;
    });

    try {
      final response = await _client.get(
        Uri.parse('${Environment.backendUrl}/student/schedule-changes'),
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
          _changesError =
              'Could not load schedule updates (${response.statusCode}).';
          _isLoadingChanges = false;
        });
        return;
      }

      final decoded = jsonDecode(response.body);
      final raw = decoded is Map<String, dynamic> ? decoded['changes'] : null;
      final changes = raw is List
          ? raw
                .whereType<Map<String, dynamic>>()
                .map(ScheduleChange.fromJson)
                .toList()
          : <ScheduleChange>[];

      setState(() {
        _scheduleChanges = changes;
        _changesError = null;
        _isLoadingChanges = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _changesError = 'Could not connect to Stryve server.';
        _isLoadingChanges = false;
      });
    }
  }

  /// Pull-to-refresh: the timetable, the claimed periods and the bell badge.
  Future<void> _refreshHome() async {
    await Future.wait([
      _fetchToday(),
      _fetchScheduleChanges(),
      if (widget.onRefreshNotifications != null)
        widget.onRefreshNotifications!(),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final hour = DateTime.now().hour;
    final greeting = hour >= 5 && hour < 12
        ? 'morning'
        : hour >= 12 && hour < 17
        ? 'afternoon'
        : 'evening';

    // One shared backdrop blur for the glass surfaces that sit side by side on
    // this screen (the schedule rows, the quick-access cards, the update card)
    // instead of one blur per card. Glass nested *inside* a card keeps its own
    // blur, so nothing about the look changes - see [GlassContainer].
    return BackdropGroup(child: _buildHomeContent(context, greeting));
  }

  /// "AAYUSH" -> "Ayush". The registry stores names upper case.
  String _titleCase(String value) {
    if (value.isEmpty) return value;
    return value[0].toUpperCase() + value.substring(1).toLowerCase();
  }

  Widget _buildHomeContent(BuildContext context, String greeting) {
    final student = widget.student;

    // `extendBodyBehindAppBar` draws the body *under* the translucent app bar,
    // so the header has to start below it. With only the old 16px of top
    // padding the welcome line was painted behind the bar and read as an empty
    // gap above "Today's Schedule".
    //
    // Scaffold already reports the app bar's footprint in `padding.top` for a
    // body that scrolls behind it, so only the small gap is ours to add -
    // adding `kToolbarHeight` on top of it pushed the greeting ~84dp lower
    // than the bar.
    final topInset = MediaQuery.paddingOf(context).top + 8;
    final firstName = _titleCase(
      student.name.trim().split(RegExp(r'\s+')).first,
    );

    // Recomputed on every build, including the once-a-minute timer rebuild.
    final nextUp = _upNext(DateTime.now());

    return RefreshIndicator(
      onRefresh: _refreshHome,
      child: SingleChildScrollView(
        // Always scrollable, so the gesture works even when the page is short.
        physics: const AlwaysScrollableScrollPhysics(),
        // 100 of breathing room plus the floating nav's footprint, so the
        // "Latest Update" card can scroll fully clear of the bar.
        padding: EdgeInsets.fromLTRB(
          20,
          topInset,
          20,
          100 + widget.bottomInset,
        ),
        child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Welcome. The greeting is the only identity line on Home: only the
          // first token of the stored name is shown, so a registry row stored
          // family-name-first (`SHINDE AJAY ANGATRAO`) greets with the surname.
          // The full details live on the Profile tab.
          Text(
            'Good $greeting $firstName',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.bold,
              color: GlassColors.headingOf(context),
              letterSpacing: -0.5,
            ),
          ),

          // The "AAYUSH SHANTARAM TITAME \u2022 AI&DS \u2022 D" line used to sit
          // here. It duplicated the greeting and cluttered the header, so it
          // was removed on request; the greeting carries the name and the full
          // details remain on the Profile tab.
          const SizedBox(height: 28),

          // Next Up - the next two lectures of the student's own Division D
          // timetable (batch filtering is decided server-side). The whole day
          // no longer lives here: see [_upNext] for the rolling window.
          Text(
            "Today's Schedule",
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: GlassColors.headingOf(context),
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
                    // Tuned from 15 to 8 for perf; measure before reverting.
                    blurStrength: 8,
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
                    blurStrength: 8,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _scheduleError!,
                          style: TextStyle(
                            fontSize: 14,
                            color: GlassColors.secondaryTextOf(context),
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
                : nextUp.isEmpty
                ? GlassCard(
                    key: const ValueKey('schedule-empty'),
                    padding: const EdgeInsets.all(16),
                    margin: EdgeInsets.zero,
                    borderRadius: 16,
                    blurStrength: 8,
                    // Deliberately text only - no icon, no second line.
                    child: Text(
                      "You're all caught up for today!",
                      style: TextStyle(
                        fontSize: 14,
                        color: GlassColors.secondaryTextOf(context),
                      ),
                    ),
                  )
                : Column(
                    key: const ValueKey('schedule-list'),
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: nextUp
                        .map(
                          (entry) => Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            child: GlassCard(
                              padding: const EdgeInsets.all(16),
                              margin: EdgeInsets.zero,
                              borderRadius: 16,
                              blurStrength: 8,
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
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          entry.subject,
                                          style: TextStyle(
                                            fontSize: 18,
                                            fontWeight: FontWeight.bold,
                                            color: GlassColors.headingOf(
                                              context,
                                            ),
                                          ),
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          '${entry.time}'
                                          '${entry.faculty != null && entry.faculty!.isNotEmpty ? ' \u2022 ${entry.faculty}' : ''}',
                                          style: TextStyle(
                                            fontSize: 14,
                                            color: GlassColors.secondaryTextOf(
                                              context,
                                            ),
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
                        )
                        .toList(),
                  ),
          ),

          const SizedBox(height: 28),

          // Quick Access
          Text(
            'Quick Access',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: GlassColors.headingOf(context),
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
                  key: const Key('home_attendance_card'),
                  icon: Icons.bar_chart_rounded,
                  title: 'Attendance',
                  onTap: widget.onOpenAttendance,
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
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => AnnouncementsPage(
                          student: student,
                          client: widget.client,
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),

          const SizedBox(height: 28),

          // Latest Update
          Text(
            'Latest Update',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: GlassColors.headingOf(context),
            ),
          ),

          const SizedBox(height: 14),

          _buildLatestUpdate(),
        ],
        ),
      ),
    );
  }

  /// The "Latest Update" card: today's claimed free periods, or the honest
  /// empty/error states. It never reports an unreachable server as "no
  /// changes".
  Widget _buildLatestUpdate() {
    // A refresh keeps the last good list; only a first load shows a spinner.
    if (_isLoadingChanges && _scheduleChanges.isEmpty) {
      return const GlassCard(
        padding: EdgeInsets.all(16),
        margin: EdgeInsets.zero,
        borderRadius: 16,
        blurStrength: 8,
        child: Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }

    if (_changesError != null && _scheduleChanges.isEmpty) {
      return GlassCard(
        padding: const EdgeInsets.all(16),
        margin: EdgeInsets.zero,
        borderRadius: 16,
        blurStrength: 8,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Could not load schedule updates.',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 16,
                color: GlassColors.headingOf(context),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              _changesError!,
              style: TextStyle(
                fontSize: 12,
                color: GlassColors.secondaryTextOf(context),
              ),
            ),
            TextButton(
              key: const Key('home_schedule_changes_retry'),
              onPressed: _fetchScheduleChanges,
              child: const Text('Retry'),
            ),
          ],
        ),
      );
    }

    if (_scheduleChanges.isEmpty) {
      return GlassCard(
        padding: const EdgeInsets.all(16),
        margin: EdgeInsets.zero,
        borderRadius: 16,
        blurStrength: 8,
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
                  Text(
                    'No Schedule Changes',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                      color: GlassColors.headingOf(context),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'There are no free-period changes for your batch.',
                    style: TextStyle(
                      fontSize: 13,
                      color: GlassColors.secondaryTextOf(context),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    return GlassCard(
      key: const Key('home_schedule_changes'),
      padding: const EdgeInsets.all(16),
      margin: EdgeInsets.zero,
      borderRadius: 16,
      blurStrength: 8,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${_scheduleChanges.length} Schedule '
            'Change${_scheduleChanges.length == 1 ? '' : 's'}',
            style: TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 16,
              color: GlassColors.headingOf(context),
            ),
          ),
          const SizedBox(height: 8),
          for (final change in _scheduleChanges)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(
                    Icons.event_available_rounded,
                    size: 16,
                    color: GlassColors.primaryBlue,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // The cancelled class is the point of the card, so
                        // it is the bold line; the slot and claimant sit
                        // underneath as supporting detail.
                        Text(
                          change.hasCancelledSubject
                              ? '${subjectLabelFor(change.cancelledSubject!)} '
                                    'is cancelled'
                              : 'Free period',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 15,
                            color: GlassColors.headingOf(context),
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${change.time} · Claimed by '
                          '${change.claimedByLabel}',
                          style: TextStyle(
                            fontSize: 12,
                            color: GlassColors.secondaryTextOf(context),
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
      // Tuned from 15 to 8 for perf; measure before reverting.
      blurStrength: 8,
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
            style: TextStyle(
              fontWeight: FontWeight.w600,
              fontSize: 14,
              color: GlassColors.headingOf(context),
            ),
          ),
        ],
      ),
    );
  }
}
