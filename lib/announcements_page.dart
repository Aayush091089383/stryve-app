import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'announcement.dart';
import 'config/environment.dart';
import 'role_selection_page.dart';
import 'services/auth_service.dart';
import 'student.dart';
import 'utils/glass_container.dart';
import 'utils/linkified_text.dart';
import 'utils/motion.dart';

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

  Future<void> _fetchAnnouncements() async {
    setState(() {
      _isLoading = true;
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

  Widget _buildFeed(BuildContext context) {
    return KeyedSubtree(
      key: const ValueKey('announcements-feed'),
      child: RefreshIndicator(
        color: GlassColors.primaryBlue,
        onRefresh: _fetchAnnouncements,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
          children: [
            Text(
              _announcements.length == 1
                  ? '1 announcement'
                  : '${_announcements.length} announcements',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: GlassColors.secondaryTextOf(context),
              ),
            ),
            const SizedBox(height: 12),
            for (final announcement in _announcements)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: _AnnouncementCard(announcement: announcement),
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
  const _AnnouncementCard({required this.announcement});

  final Announcement announcement;

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
                    if (audience != null) ...[
                      const SizedBox(height: 3),
                      Text(
                        audience,
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: GlassColors.primaryBlue,
                        ),
                      ),
                    ],
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
