import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'role_selection_page.dart';
import 'student.dart';
import 'config/environment.dart';
import 'services/auth_service.dart';
import 'services/api_cache.dart';
import 'utils/glass_container.dart';
import 'utils/motion.dart';

/// The civil (12-hour) form of a clock time.
///
/// `"10:15" -> "10:15 AM"`, `"14:00" -> "2:00 PM"`, `"12:15" -> "12:15 PM"`,
/// `"00:30" -> "12:30 AM"`. The official sheet prints 24-hour times and that is
/// what the API stores, so the conversion belongs to the display layer - and
/// anything that is not a plain `HH:mm` string comes back untouched, so a
/// malformed value can never blank out a row.
String formatClock(String value) {
  final match = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(value.trim());
  if (match == null) return value;

  final hour = int.parse(match.group(1)!);
  if (hour > 23) return value;
  final minute = match.group(2)!;
  final suffix = hour < 12 ? 'AM' : 'PM';
  final hour12 = hour % 12 == 0 ? 12 : hour % 12;
  return '$hour12:$minute $suffix';
}

class TimetableEntry {
  final String day;
  final String startTime;
  final String endTime;
  final String subject;
  final String? faculty;
  final String? room;
  final String? batch;
  final bool isBreak;

  /// One of the sheet's free periods ("RELM"): free for every class group, so a
  /// student has nothing to attend. Such an entry is never rendered here, as a
  /// lecture or otherwise - it belongs to the teacher's Claim Free Period screen.
  final bool isFreePeriod;

  /// "lecture" (no batch: the whole division), "practical" (batch-specific),
  /// "free_period" (RELM) or "break". Decided by the backend from the same
  /// columns it filters on, so the label and the filtering cannot disagree.
  final String entryType;

  /// The label the sheet prints for a free period. Used only to keep such a row
  /// out of the schedule even if an older backend still returns it as a lecture.
  static const String freePeriodSubject = 'RELM';

  const TimetableEntry({
    required this.day,
    required this.startTime,
    required this.endTime,
    required this.subject,
    this.faculty,
    this.room,
    this.batch,
    this.isBreak = false,
    this.isFreePeriod = false,
    this.entryType = '',
  });

  factory TimetableEntry.fromJson(Map<String, dynamic> json) {
    final rawBatch = json['batch'] as String?;
    final rawType = (json['entry_type'] as String?)?.trim();

    return TimetableEntry(
      day: json['day'],
      startTime: json['start_time'],
      endTime: json['end_time'],
      subject: json['subject'],
      faculty: json['faculty'],
      room: json['room'],
      batch: rawBatch,
      isBreak: json['is_break'] ?? false,
      isFreePeriod:
          (json['is_free_period'] as bool? ?? false) ||
          (rawType == 'free_period') ||
          (json['subject'] as String?)?.trim().toUpperCase() ==
              freePeriodSubject,
      // Falls back to the batch rule if an older backend omits the field - but
      // a free period is never called a lecture, whatever the backend sends.
      entryType: (rawType == null || rawType.isEmpty)
          ? ((json['is_free_period'] as bool? ?? false) ||
                    (json['subject'] as String?)?.trim().toUpperCase() ==
                        freePeriodSubject
                ? 'free_period'
                : ((rawBatch == null || rawBatch.isEmpty)
                      ? 'lecture'
                      : 'practical'))
          : rawType,
    );
  }

  bool get isPractical => entryType == 'practical';

  String get typeLabel =>
      isFreePeriod ? 'Free period' : (isPractical ? 'Practical' : 'Lecture');

  /// Shown in 12-hour form; the sorting keys stay the raw 24-hour columns.
  String get time => '${formatClock(startTime)} - ${formatClock(endTime)}';
}

class TimetablePage extends StatefulWidget {
  final Student student;

  /// Optional injected HTTP client, for tests only. Null in the app, where a
  /// real client is created (same convention as TeacherPanelPage/the finders).
  final http.Client? client;

  const TimetablePage({super.key, required this.student, this.client});

  @override
  State<TimetablePage> createState() => _TimetablePageState();
}

class _TimetablePageState extends State<TimetablePage> {
  late int selectedDay = DateTime.now().weekday == DateTime.sunday
      ? 0
      : DateTime.now().weekday - 1;

  final List<String> days = [
    'Monday',
    'Tuesday',
    'Wednesday',
    'Thursday',
    'Friday',
    'Saturday',
  ];

  bool isLoading = true;
  String? errorMessage;
  Map<String, List<TimetableEntry>> timetable = {};
  http.Client? _ownedClient;
  http.Client get _client => widget.client ?? (_ownedClient ??= http.Client());

  @override
  void dispose() {
    _ownedClient?.close();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    fetchTimetable();
  }

  Future<void> fetchTimetable({bool forceRefresh = false}) async {
    setState(() {
      isLoading = true;
      errorMessage = null;
    });

    try {
      final cacheKey = 'timetable_${widget.student.token}';
      final cached = forceRefresh ? null : ApiCache.get(cacheKey);

      final String responseBody;
      if (cached != null) {
        responseBody = cached;
      } else {
        final response = await _client.get(
          Uri.parse('${Environment.backendUrl}/timetable'),
          headers: {'Authorization': 'Bearer ${widget.student.token}'},
        );

        if (response.statusCode == 401) {
          final authService = AuthService();
          await authService.clearAuthData();

          if (!mounted) return;

          Navigator.of(context).pushAndRemoveUntil(
            MaterialPageRoute(builder: (context) => const RoleSelectionPage()),
            (route) => false,
          );

          return;
        }

        if (response.statusCode != 200) {
          setState(() {
            errorMessage = 'Could not load timetable (${response.statusCode})';
            isLoading = false;
          });

          return;
        }

        responseBody = response.body;
        ApiCache.set(cacheKey, responseBody);
      }

      final List<dynamic> rawEntries = jsonDecode(responseBody);

      // A free period ("RELM") is not part of a student's schedule: the
      // backend already leaves it out, and it is filtered again here so an
      // older backend can never make it show up as a lecture.
      final entries = rawEntries
          .map((e) => TimetableEntry.fromJson(e))
          .where((entry) => !entry.isFreePeriod)
          .toList();

      final Map<String, List<TimetableEntry>> grouped = {
        for (final day in days) day: <TimetableEntry>[],
      };

      for (final entry in entries) {
        grouped[entry.day]?.add(entry);
      }

      for (final day in days) {
        grouped[day]?.sort((a, b) => a.startTime.compareTo(b.startTime));
      }

      setState(() {
        timetable = grouped;
        isLoading = false;
      });
    } catch (e) {
      setState(() {
        errorMessage = 'Could not connect to Stryve server. Please check your internet connection and try again.';
        isLoading = false;
      });
    }
  }

  List<TimetableEntry> get entriesForSelectedDay {
    final day = days[selectedDay];
    return timetable[day] ?? [];
  }

  String getYearText() {
    switch (widget.student.year) {
      case 1:
        return '1st Year';
      case 2:
        return '2nd Year';
      case 3:
        return '3rd Year';
      default:
        return '${widget.student.year}th Year';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: GlassAppBar(
        title: const Text('Timetable'),
        automaticallyImplyLeading: false,
        // Timetable is pushed from Home's Quick Access card, so the header gets
        // its way back. maybePop is a no-op when there is nothing beneath
        // (a widget test may mount this page as the root).
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          color: GlassColors.headingOf(context),
          tooltip: 'Back',
          onPressed: () => Navigator.maybePop(context),
        ),
      ),
      body: GlassBackground(
        // One shared backdrop blur for the glass surfaces that sit side by side
        // on this screen (the day pills, the student card, the entries) instead
        // of one backdrop per surface. Same mechanism Home's tab already uses;
        // a surface nested *inside* a card still blurs its own backdrop, so the
        // look of the chips on top of a card is unchanged.
        child: BackdropGroup(
          child: AnimatedSwitcher(
            duration: motionDuration(context, kMotionStandard),
            switchInCurve: Curves.easeOut,
            switchOutCurve: Curves.easeIn,
            child: isLoading
                ? const Center(
                    key: ValueKey('timetable-loading'),
                    child: CircularProgressIndicator(
                      color: GlassColors.primaryBlue,
                    ),
                  )
                : errorMessage != null
                ? KeyedSubtree(
                    key: const ValueKey('timetable-error'),
                    child: _buildError(context),
                  )
                : KeyedSubtree(
                    key: const ValueKey('timetable-content'),
                    child: _buildTimetable(context),
                  ),
          ),
        ),
      ),
    );
  }

  Widget _buildError(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: GlassCard(
          // Tuned from 15 to 8 for perf; measure before reverting.
          blurStrength: 8,
          padding: const EdgeInsets.all(32),
          margin: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              GlassContainer(
                width: 64,
                height: 64,
                borderRadius: 32,
                padding: EdgeInsets.zero,
                blurStrength: 15,
                opacity: 0.7,
                borderOpacity: 0.4,
                child: const Icon(
                  Icons.wifi_off_rounded,
                  size: 32,
                  color: GlassColors.error,
                ),
              ),
              const SizedBox(height: 20),
              Text(
                errorMessage!,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: GlassColors.secondaryTextOf(context),
                  fontSize: 15,
                ),
              ),
              const SizedBox(height: 24),
              GlassButton(
                onPressed: fetchTimetable,
                height: 48,
                borderRadius: 14,
                width: 160,
                child: const Text('Try Again', style: TextStyle(fontSize: 15)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTimetable(BuildContext context) {
    final entries = entriesForSelectedDay;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 100, 16, 100),
      children: [
        // DAY SELECTOR
        SizedBox(
          height: 50,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 4),
            itemCount: days.length,
            itemBuilder: (context, index) {
              final selected = selectedDay == index;

              // The pill's own look is tweened between its two existing
              // states; nothing moves or resizes, and the tween only re-runs
              // when this chip's `selected` actually flips (implicit
              // animations keep their own state, so parent rebuilds do not
              // restart it).
              return Padding(
                padding: const EdgeInsets.only(right: 8),
                child: TweenAnimationBuilder<double>(
                  tween: Tween<double>(end: selected ? 1 : 0),
                  duration: motionDuration(
                    context,
                    const Duration(milliseconds: 180),
                  ),
                  curve: Curves.easeOutCubic,
                  builder: (context, t, _) {
                    return GlassContainer(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      margin: EdgeInsets.zero,
                      borderRadius: 14,
                      // Tuned from 15 to 8 for perf; measure before reverting.
                      blurStrength: 8,
                      opacity: 0.5 + 0.3 * t,
                      borderOpacity: 0.3 + 0.3 * t,
                      onTap: () => onDaySelected(index),
                      child: Text(
                        days[index],
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.lerp(
                            FontWeight.w500,
                            FontWeight.w600,
                            t,
                          ),
                          color: Color.lerp(
                            GlassColors.secondaryTextOf(context),
                            GlassColors.headingOf(context),
                            t,
                          ),
                        ),
                      ),
                    );
                  },
                ),
              );
            },
          ),
        ),

        const SizedBox(height: 16),

        // STUDENT INFORMATION
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: GlassCard(
            // Tuned from 15 to 8 for perf; measure before reverting.
            blurStrength: 8,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            margin: EdgeInsets.zero,
            child: Row(
              children: [
                const Icon(
                  Icons.person_rounded,
                  size: 18,
                  color: GlassColors.primaryBlue,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '${widget.student.name} \u2022 '
                    '${widget.student.course} \u2022 '
                    '${getYearText()} \u2022 '
                    '${widget.student.division}-${widget.student.batch}',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: GlassColors.headingOf(context),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),

        const SizedBox(height: 12),

        // LEGEND
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Row(
            children: [
              _legendItem(Icons.science_rounded, 'Practical (your batch)'),
              const SizedBox(width: 16),
              _legendItem(Icons.groups_rounded, 'Lecture (whole division)'),
            ],
          ),
        ),

        const SizedBox(height: 12),

        // TIMETABLE LIST
        entries.isEmpty
            ? _buildEmptyState()
            : ListView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(4, 0, 4, 20),
                itemCount: entries.length,
                itemBuilder: (context, index) {
                  return _buildEntryCard(entries[index]);
                },
              ),
      ],
    );
  }

  void onDaySelected(int index) {
    setState(() {
      selectedDay = index;
    });
  }

  Widget _legendItem(IconData icon, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 12, color: GlassColors.secondaryTextOf(context)),
        const SizedBox(width: 4),
        Text(
          label,
          style: TextStyle(
            fontSize: 12,
            color: GlassColors.secondaryTextOf(context),
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: GlassCard(
          // Tuned from 15 to 8 for perf; measure before reverting.
          blurStrength: 8,
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              GlassContainer(
                width: 80,
                height: 80,
                borderRadius: 40,
                padding: EdgeInsets.zero,
                blurStrength: 15,
                opacity: 0.6,
                borderOpacity: 0.3,
                child: Icon(
                  Icons.calendar_month_rounded,
                  size: 36,
                  color: GlassColors.secondaryTextOf(context),
                ),
              ),
              const SizedBox(height: 20),
              Text(
                'No classes scheduled',
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w500,
                  color: GlassColors.headingOf(context),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Your timetable for this day will appear here.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14,
                  color: GlassColors.secondaryTextOf(context),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildEntryCard(TimetableEntry entry) {
    if (entry.isBreak) {
      return GlassCard(
        // Tuned from 15 to 8 for perf; measure before reverting.
        blurStrength: 8,
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
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
                Icons.free_breakfast_rounded,
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
                    entry.subject,
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                      color: GlassColors.headingOf(context),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    entry.time,
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
      // Tuned from 15 to 8 for perf; measure before reverting.
      blurStrength: 8,
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        children: [
          GlassContainer(
            width: 48,
            height: 48,
            borderRadius: 12,
            padding: EdgeInsets.zero,
            blurStrength: 15,
            opacity: 0.7,
            borderOpacity: 0.4,
            child: const Icon(
              Icons.school_rounded,
              size: 24,
              color: GlassColors.primaryBlue,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        entry.subject,
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.bold,
                          color: GlassColors.headingOf(context),
                        ),
                      ),
                    ),
                    // Clear Lecture / Practical label (requirement: entries
                    // without a batch are common lectures, entries naming a
                    // batch are that batch's practical).
                    GlassContainer(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      borderRadius: 8,
                      blurStrength: 10,
                      opacity: 0.6,
                      borderOpacity: 0.3,
                      child: Text(
                        entry.typeLabel,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: entry.isPractical
                              ? GlassColors.warning
                              : GlassColors.primaryBlue,
                        ),
                      ),
                    ),
                    if (entry.batch != null) ...[
                      const SizedBox(width: 6),
                      GlassContainer(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 4,
                        ),
                        borderRadius: 8,
                        blurStrength: 10,
                        opacity: 0.6,
                        borderOpacity: 0.3,
                        child: Text(
                          entry.batch!,
                          style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: GlassColors.primaryBlue,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  '${entry.time}'
                  '${entry.faculty != null && entry.faculty!.isNotEmpty ? ' \u2022 ${entry.faculty}' : ''}'
                  '${entry.room != null ? ' \u2022 Room ${entry.room}' : ''}',
                  style: TextStyle(
                    fontSize: 13,
                    color: GlassColors.secondaryTextOf(context),
                    decoration: TextDecoration.none,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
