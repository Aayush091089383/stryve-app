import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'config/environment.dart';
import 'role_selection_page.dart';
import 'services/auth_service.dart';
import 'student.dart';
import 'student_notification.dart';
import 'utils/glass_container.dart';
import 'utils/motion.dart';

/// The student's notification feed: one row per in-app message the backend
/// created for them (today, one per uploaded assignment).
///
/// The backend scopes every request to the authenticated token, so this screen
/// never sends a student id and never filters on the client. Reading is the only
/// mutation: an unread row is marked read by tapping it, or all at once with
/// "Mark all as read". The bell badge on Home is refreshed when this route pops.
class NotificationsPage extends StatefulWidget {
  final Student student;

  /// Injection seam for tests; production leaves it null and the page uses the
  /// real authenticated endpoint.
  final http.Client? client;

  const NotificationsPage({super.key, required this.student, this.client});

  @override
  State<NotificationsPage> createState() => _NotificationsPageState();
}

class _NotificationsPageState extends State<NotificationsPage> {
  bool _isLoading = true;
  bool _markingAll = false;
  String? _errorMessage;
  List<StudentNotification> _notifications = const [];

  http.Client? _ownedClient;
  http.Client get _client => widget.client ?? (_ownedClient ??= http.Client());

  /// Unread ids with a request in flight, so a second tap cannot send a second
  /// PUT for the same row.
  final Set<int> _marking = <int>{};

  @override
  void initState() {
    super.initState();
    _fetchNotifications();
  }

  @override
  void dispose() {
    _ownedClient?.close();
    super.dispose();
  }

  Future<void> _fetchNotifications() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final response = await _client.get(
        Uri.parse('${Environment.backendUrl}/notifications'),
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
              'Could not load notifications (${response.statusCode})';
          _isLoading = false;
        });
        return;
      }

      final List<dynamic> raw = jsonDecode(response.body);
      final loaded = raw
          .map((n) => StudentNotification.fromJson(n as Map<String, dynamic>))
          .toList();

      setState(() {
        _notifications = loaded;
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

  void _showNotice(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _markRead(StudentNotification notification) async {
    if (notification.isRead || _marking.contains(notification.id)) return;

    final previous = notification;
    setState(() {
      _marking.add(notification.id);
      _notifications = [
        for (final n in _notifications)
          if (n.id == notification.id) n.copyWith(isRead: true) else n,
      ];
    });

    try {
      final response = await _client.put(
        Uri.parse(
          '${Environment.backendUrl}/notifications/${notification.id}/read',
        ),
        headers: {'Authorization': 'Bearer ${widget.student.token}'},
      );
      if (!mounted) return;
      if (response.statusCode != 200) {
        // Put the row back the way it was: the server still thinks it unread.
        setState(() {
          _notifications = [
            for (final n in _notifications)
              if (n.id == previous.id) previous else n,
          ];
        });
        _showNotice('Could not mark that notification as read.');
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _notifications = [
          for (final n in _notifications)
            if (n.id == previous.id) previous else n,
        ];
      });
      _showNotice('Could not reach Stryve server.');
    } finally {
      if (mounted) setState(() => _marking.remove(notification.id));
    }
  }

  Future<void> _markAllRead() async {
    if (_markingAll || unreadNotificationCount(_notifications) == 0) return;

    setState(() => _markingAll = true);

    try {
      final response = await _client.put(
        Uri.parse('${Environment.backendUrl}/notifications/read-all'),
        headers: {'Authorization': 'Bearer ${widget.student.token}'},
      );
      if (!mounted) return;

      if (response.statusCode == 200) {
        setState(() {
          _notifications = [for (final n in _notifications) n.copyWith(isRead: true)];
        });
      } else {
        _showNotice('Could not mark all notifications as read.');
      }
    } catch (_) {
      if (!mounted) return;
      _showNotice('Could not reach Stryve server.');
    } finally {
      if (mounted) setState(() => _markingAll = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: const GlassAppBar(title: Text('Notifications')),
      body: GlassBackground(child: _content(context)),
    );
  }

  Widget _content(BuildContext context) {
    return AnimatedSwitcher(
      duration: motionDuration(context, kMotionStandard),
      switchInCurve: Curves.easeOut,
      switchOutCurve: Curves.easeIn,
      child: _isLoading
          ? const Center(
              key: ValueKey('notifications-loading'),
              child: CircularProgressIndicator(color: GlassColors.primaryBlue),
            )
          : _errorMessage != null
          ? KeyedSubtree(
              key: const ValueKey('notifications-error'),
              child: _buildError(),
            )
          : KeyedSubtree(
              key: const ValueKey('notifications-content'),
              child: _buildList(),
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
                onPressed: _fetchNotifications,
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

  Widget _buildList() {
    // Plain text, no card: an empty feed says one line and nothing else.
    if (_notifications.isEmpty) {
      return const Center(
        child: Text(
          'No message yet',
          style: TextStyle(fontSize: 16, color: Colors.grey),
        ),
      );
    }

    final unreadCount = unreadNotificationCount(_notifications);

    return RefreshIndicator(
      color: GlassColors.primaryBlue,
      onRefresh: _fetchNotifications,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  unreadCount == 0
                      ? 'All caught up'
                      : '$unreadCount unread',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: GlassColors.secondaryTextOf(context),
                  ),
                ),
              ),
              if (unreadCount > 0)
                GlassButton(
                  key: const Key('mark_all_read'),
                  // The label stays put while the request is in flight; only the
                  // tap target is disabled, so the button never turns into an
                  // unexplained spinner.
                  onPressed: _markingAll ? null : _markAllRead,
                  disabled: _markingAll,
                  color: GlassColors.primaryBlue,
                  width: 150,
                  height: 40,
                  borderRadius: 12,
                  child: const Text(
                    'Mark all as read',
                    style: TextStyle(fontSize: 13),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 14),
          ..._notifications.map(_buildNotificationCard),
        ],
      ),
    );
  }

  Widget _buildNotificationCard(StudentNotification notification) {
    final unread = !notification.isRead;

    return GlassCard(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      // Tapping an unread row is the second way to mark it read; a read row has
      // nothing left to do, so it stays inert.
      onTap: unread ? () => _markRead(notification) : null,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: GlassContainer(
              width: 36,
              height: 36,
              borderRadius: 12,
              padding: EdgeInsets.zero,
              blurStrength: 12,
              opacity: 0.7,
              borderOpacity: 0.3,
              child: Icon(
                unread
                    ? Icons.notifications_active_rounded
                    : Icons.notifications_none_rounded,
                size: 20,
                color: unread
                    ? GlassColors.primaryBlue
                    : GlassColors.secondaryTextOf(context),
              ),
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
                        notification.title,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: unread
                              ? FontWeight.bold
                              : FontWeight.w600,
                          color: GlassColors.headingOf(context),
                        ),
                      ),
                    ),
                    if (unread)
                      Container(
                        width: 9,
                        height: 9,
                        decoration: const BoxDecoration(
                          color: GlassColors.primaryBlue,
                          shape: BoxShape.circle,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  notification.message,
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.35,
                    color: unread
                        ? GlassColors.headingOf(context)
                        : GlassColors.secondaryTextOf(context),
                  ),
                ),
                if (notification.createdAt != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    _formatTimestamp(notification.createdAt!),
                    style: TextStyle(
                      fontSize: 11,
                      color: GlassColors.disabledOf(context),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// "19 Oct 2026, 10:42" - the backend stores UTC, the student reads local time.
  static String _formatTimestamp(DateTime timestamp) {
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    final local = timestamp.toLocal();
    final hour = local.hour.toString().padLeft(2, '0');
    final minute = local.minute.toString().padLeft(2, '0');
    return '${local.day} ${months[local.month - 1]} ${local.year}, '
        '$hour:$minute';
  }
}
