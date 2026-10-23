import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'announcement.dart';
import 'assignment.dart';
import 'assignment_pdf_viewer_page.dart';
import 'config/environment.dart';
import 'role_selection_page.dart';
import 'services/auth_service.dart';
import 'student.dart';
import 'utils/glass_container.dart';
import 'utils/linkified_text.dart';
import 'utils/motion.dart';
import 'utils/official_subjects.dart';
import 'video_player_page.dart';

/// The student's announcements feed: everything a teacher or admin posted for
/// this student's class group, newest first.
///
/// The backend decides what this student may read (`GET /announcements` is
/// scoped by the authenticated token), so this screen never sends a year or a
/// division and never filters on the client. Reading is the only action here:
/// an announcement is never edited, and withdrawing one is a teacher/admin
/// action on their own panel, not something this screen can do.
class AnnouncementsPage extends StatefulWidget {
  const AnnouncementsPage({super.key, required this.student, this.client});

  final Student student;

  /// Injection seam for tests; production leaves it null and the page uses the
  /// real authenticated endpoint.
  final http.Client? client;

  @override
  State<AnnouncementsPage> createState() => _AnnouncementsPageState();
}

class _AnnouncementsPageState extends State<AnnouncementsPage> {
  bool _isLoading = true;
  String? _errorMessage;
  List<Announcement> _announcements = const [];

  /// "all", "common", or one of [kOfficialSubjects]. Filtering is client-side:
  /// the backend already scoped the feed to this student's class group, and the
  /// subject only chooses which slice of that same feed to show.
  String _subjectFilter = 'all';

  http.Client? _ownedClient;
  http.Client get _client => widget.client ?? (_ownedClient ??= http.Client());

  @override
  void initState() {
    super.initState();
    _fetchAnnouncements();
  }

  @override
  void dispose() {
    _ownedClient?.close();
    super.dispose();
  }

  /// Load the feed again.
  ///
  /// [showFullLoading] is false for the pull gesture: the current list stays on
  /// screen while the request runs, so the RefreshIndicator owns the progress
  /// and a refresh visibly replaces the cards. A first load and "Try Again"
  /// still use the full-page spinner.
  Future<void> _fetchAnnouncements({bool showFullLoading = true}) async {
    setState(() {
      if (showFullLoading || _announcements.isEmpty) {
        _isLoading = true;
      }
      _errorMessage = null;
    });

    try {
      final response = await _client.get(
        Uri.parse('${Environment.backendUrl}/announcements'),
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
          _errorMessage =
              'Could not load announcements (${response.statusCode})';
          _isLoading = false;
        });
        return;
      }

      final decoded = jsonDecode(response.body);
      final loaded = decoded is List
          ? decoded
                .whereType<Map<String, dynamic>>()
                .map(Announcement.fromJson)
                .toList()
          : <Announcement>[];

      setState(() {
        _announcements = loaded;
        _isLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _errorMessage =
            'Could not connect to Stryve server. Please check your internet '
            'connection and try again.';
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: const GlassAppBar(title: Text('Announcements')),
      body: GlassBackground(
        child: AnimatedSwitcher(
          duration: motionDuration(context, kMotionStandard),
          switchInCurve: Curves.easeOut,
          switchOutCurve: Curves.easeIn,
          child: _content(context),
        ),
      ),
    );
  }

  Widget _content(BuildContext context) {
    if (_isLoading) {
      return const Center(
        key: ValueKey('announcements-loading'),
        child: CircularProgressIndicator(color: GlassColors.primaryBlue),
      );
    }

    if (_errorMessage != null) {
      return KeyedSubtree(
        key: const ValueKey('announcements-error'),
        child: _buildError(),
      );
    }

    // An error is never rendered as an empty feed: the two states are separate
    // branches, and only a successful, empty response reaches this one.
    if (_announcements.isEmpty) {
      return KeyedSubtree(
        key: const ValueKey('announcements-empty'),
        child: _buildEmpty(),
      );
    }

    return _buildFeed(context);
  }

  /// The subject label for a chip value. [subjectLabel] on an announcement
  /// already answers this for a post; this is for the chip row itself.
  static String _filterLabel(String value) {
    if (value == 'all') return 'All';
    if (value == 'common') return 'Common';
    return value;
  }

  /// The posts that match the selected chip. "Common" is the absence of a
  /// subject, which is also how every pre-subject post was stored.
  List<Announcement> get _visibleAnnouncements {
    if (_subjectFilter == 'all') return _announcements;
    if (_subjectFilter == 'common') {
      return _announcements
          .where((item) => (item.subject ?? '').trim().isEmpty)
          .toList();
    }
    return _announcements
        .where((item) => item.subject == _subjectFilter)
        .toList();
  }

  Widget _buildFilterChip(
    BuildContext context,
    String value,
    String label,
  ) {
    final selected = _subjectFilter == value;
    final textColor = selected
        ? Colors.white
        : GlassColors.secondaryTextOf(context);

    return Semantics(
      key: ValueKey('announcement-filter-$value'),
      button: true,
      selected: selected,
      label: label,
      child: GlassContainer(
        margin: EdgeInsets.zero,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        borderRadius: 999,
        blurStrength: 8,
        opacity: selected ? 0.9 : 0.55,
        borderOpacity: selected ? 1 : 0.4,
        borderColor: selected ? GlassColors.primaryBlue : null,
        gradient: selected
            ? const LinearGradient(
                colors: [GlassColors.primaryBlue, GlassColors.primaryBlue],
              )
            : null,
        onTap: () {
          if (_subjectFilter == value) return;
          setState(() => _subjectFilter = value);
        },
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
            color: textColor,
          ),
        ),
      ),
    );
  }

  Widget _buildFilterChips(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Row(
        children: [
          for (final value in <String>[
            'all',
            'common',
            ...kOfficialSubjects,
          ]) ...[
            _buildFilterChip(context, value, _filterLabel(value)),
            const SizedBox(width: 8),
          ],
        ],
      ),
    );
  }

  Widget _buildFilteredEmpty(BuildContext context) {
    return GlassCard(
      padding: const EdgeInsets.all(24),
      margin: EdgeInsets.zero,
      borderRadius: 16,
      child: Column(
        children: [
          Icon(
            Icons.filter_alt_off_outlined,
            size: 30,
            color: GlassColors.secondaryTextOf(context),
          ),
          const SizedBox(height: 10),
          Text(
            'No ${_filterLabel(_subjectFilter)} announcements yet',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: GlassColors.headingOf(context),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Switch to All to see every notice.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13,
              color: GlassColors.secondaryTextOf(context),
            ),
          ),
          const SizedBox(height: 14),
          GlassOutlinedButton(
            onPressed: () => setState(() => _subjectFilter = 'all'),
            width: 150,
            height: 42,
            borderRadius: 12,
            child: const Text(
              'SHOW ALL',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFeed(BuildContext context) {
    final visible = _visibleAnnouncements;
    final countLabel = visible.length == 1
        ? '1 announcement'
        : '${visible.length} announcements';

    return KeyedSubtree(
      key: const ValueKey('announcements-feed'),
      child: RefreshIndicator(
        color: GlassColors.primaryBlue,
        onRefresh: () => _fetchAnnouncements(showFullLoading: false),
        child: ListView(
          // RefreshIndicator only sees an overscroll when the list itself is
          // scrollable. A feed of one short notice fits the screen, and without
          // this the pull gesture silently did nothing - leaving the old
          // subject on screen after a data change.
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.only(top: 16, bottom: 32),
          children: [
            _buildFilterChips(context),
            const SizedBox(height: 14),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Text(
                _subjectFilter == 'all'
                    ? countLabel
                    : '$countLabel · ${_filterLabel(_subjectFilter)}',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: GlassColors.secondaryTextOf(context),
                ),
              ),
            ),
            const SizedBox(height: 12),
            if (visible.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: _buildFilteredEmpty(context),
              )
            else
              for (final announcement in visible)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                  child: _AnnouncementCard(
                    announcement: announcement,
                    token: widget.student.token,
                  ),
                ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmpty() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
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
                Icons.campaign_outlined,
                size: 32,
                color: GlassColors.primaryBlue,
              ),
            ),
            const SizedBox(height: 20),
            Text(
              'No announcements yet',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w600,
                color: GlassColors.headingOf(context),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Notices your teachers post for your class will appear here.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                color: GlassColors.secondaryTextOf(context),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildError() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: GlassCard(
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
                _errorMessage!,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: GlassColors.secondaryTextOf(context),
                  fontSize: 15,
                ),
              ),
              const SizedBox(height: 24),
              GlassButton(
                onPressed: _fetchAnnouncements,
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
}

/// One announcement, rendered as a glass card.
class _AnnouncementCard extends StatelessWidget {
  const _AnnouncementCard({required this.announcement, required this.token});

  final Announcement announcement;

  /// The student's bearer token, used only by the attachment readers - the
  /// backend still decides whether this student may read the file.
  final String token;

  /// A stand-in [Assignment] so the existing PDF reader and video player can
  /// open an announcement file without a parallel viewer. Its id is the
  /// announcement's, and [sourceUrl] on the pages is what actually names the
  /// file route.
  Assignment _asAssignment(AssignmentAttachment file) {
    return Assignment(
      id: announcement.id,
      subject: 'Announcement',
      title: announcement.title,
      description: announcement.message,
      dueDate: announcement.postedLabel,
      hasAttachment: true,
      attachmentName: file.name,
      attachments: [file],
    );
  }

  void _openAttachment(
    BuildContext context,
    AssignmentAttachment file,
  ) {
    final assignment = _asAssignment(file);
    final url = '${Environment.backendUrl}${announcement.filePath(file)}';
    final Widget page = file.isVideo
        ? VideoPlayerPage(
            assignment: assignment,
            token: token,
            sourceUrl: url,
          )
        : AssignmentPdfViewerPage(
            assignment: assignment,
            token: token,
            sourceUrl: url,
            heading: 'Announcement',
          );

    Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
  }

  @override
  Widget build(BuildContext context) {
    final audience = announcement.audienceLabel;

    return GlassCard(
      padding: const EdgeInsets.all(16),
      margin: EdgeInsets.zero,
      borderRadius: 16,
      blurStrength: 8,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              GlassContainer(
                width: 40,
                height: 40,
                borderRadius: 12,
                padding: EdgeInsets.zero,
                blurStrength: 12,
                opacity: 0.7,
                borderOpacity: 0.4,
                child: const Icon(
                  Icons.campaign_rounded,
                  size: 20,
                  color: GlassColors.primaryBlue,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      announcement.title,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: GlassColors.headingOf(context),
                      ),
                    ),
                    const SizedBox(height: 3),
                    Wrap(
                      spacing: 8,
                      runSpacing: 2,
                      children: [
                        // Filing the notice under a subject is what the chips
                        // above filter on, so it is shown on every card - a
                        // pre-subject post reads as "Common", which is true.
                        Text(
                          announcement.subjectLabel,
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: GlassColors.primaryBlue,
                          ),
                        ),
                        if (audience != null)
                          Text(
                            audience,
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: GlassColors.primaryBlue,
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          // A notice often carries a link (a form, a reading, a schedule), and
          // reading it out character by character is useless on a phone.
          LinkifiedText(
            announcement.message,
            style: TextStyle(
              fontSize: 14,
              height: 1.45,
              color: GlassColors.secondaryTextOf(context),
            ),
            linkStyle: const TextStyle(fontWeight: FontWeight.w600),
          ),
          if (announcement.hasAttachments) ...[
            const SizedBox(height: 12),
            for (final file in announcement.attachments)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _AnnouncementAttachmentRow(
                  file: file,
                  onOpen: () => _openAttachment(context, file),
                ),
              ),
          ],
          const SizedBox(height: 14),
          Row(
            children: [
              Icon(
                Icons.person_outline_rounded,
                size: 15,
                color: GlassColors.secondaryTextOf(context),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  announcement.authorName,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: GlassColors.secondaryTextOf(context),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                announcement.postedLabel,
                style: TextStyle(
                  fontSize: 12,
                  color: GlassColors.secondaryTextOf(context),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// One attached file inside an announcement card: icon, name, size and the
/// button that opens it in the matching reader.
class _AnnouncementAttachmentRow extends StatelessWidget {
  const _AnnouncementAttachmentRow({required this.file, required this.onOpen});

  final AssignmentAttachment file;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final isVideo = file.isVideo;

    return GlassContainer(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      margin: EdgeInsets.zero,
      borderRadius: 12,
      blurStrength: 8,
      opacity: 0.6,
      borderOpacity: 0.35,
      child: Row(
        children: [
          Icon(
            isVideo
                ? Icons.play_circle_outline_rounded
                : Icons.picture_as_pdf_outlined,
            size: 22,
            color: GlassColors.primaryBlue,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  file.name.isEmpty ? 'Attached file' : file.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: GlassColors.headingOf(context),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  formatAttachmentSize(file.fileSize),
                  style: TextStyle(
                    fontSize: 11,
                    color: GlassColors.secondaryTextOf(context),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 108,
            child: GlassOutlinedButton(
              onPressed: onOpen,
              height: 36,
              borderRadius: 10,
              borderColor: GlassColors.primaryBlue,
              textColor: GlassColors.primaryBlue,
              child: Text(
                isVideo ? 'PLAY VIDEO' : 'READ PDF',
                style: const TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.4,
                  color: GlassColors.primaryBlue,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// "824 KB", "8.1 MB", or "0 B" for the legacy rows that carried no size.
String formatAttachmentSize(int bytes) {
  if (bytes >= 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  if (bytes >= 1024) return '${(bytes / 1024).round()} KB';
  return '$bytes B';
}
