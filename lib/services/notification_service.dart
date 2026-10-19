import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Anything that can raise a system-tray alert.
///
/// A one-method interface so the Home screen can be tested without the native
/// notifications plugin, and so a platform without a tray implementation simply
/// does nothing. A tray alert is always best-effort: it must never break the
/// screen that asked for it.
abstract class SystemNotifications {
  Future<void> show(String title, String body);
}

/// The Android implementation, backed by `flutter_local_notifications`.
///
/// Initialisation is lazy and happens on the first alert, so the app's start-up
/// does not touch a platform channel. Every failure (no plugin registered, an
/// unsupported platform, a denied permission) leaves the in-app badge and the
/// Notifications screen working exactly as before.
class LocalSystemNotifications implements SystemNotifications {
  LocalSystemNotifications({FlutterLocalNotificationsPlugin? plugin})
    : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  final FlutterLocalNotificationsPlugin _plugin;

  /// One channel for every assignment alert, so Android's own settings can
  /// silence the category without silencing the app.
  static const AndroidNotificationChannel channel = AndroidNotificationChannel(
    'stryve_assignments',
    'Assignment alerts',
    description: 'Tells you when a teacher uploads a new assignment',
    importance: Importance.high,
  );

  static const AndroidNotificationDetails _details = AndroidNotificationDetails(
    'stryve_assignments',
    'Assignment alerts',
    channelDescription: 'Tells you when a teacher uploads a new assignment',
    importance: Importance.high,
    priority: Priority.high,
  );

  /// A tray id for each alert. Android replaces an alert with the same id, so
  /// using the clock keeps two uploads in one session from collapsing into one.
  int _nextId = 0;

  bool _initialized = false;
  bool _unavailable = false;

  Future<void> _ensureInitialized() async {
    if (_initialized || _unavailable) return;

    try {
      const settings = InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      );
      await _plugin.initialize(settings: settings);

      final android = _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      await android?.createNotificationChannel(channel);
      // Android 13+ asks the user at runtime; on older releases this is a
      // no-op that answers true.
      await android?.requestNotificationsPermission();

      _initialized = true;
    } catch (_) {
      // Deliberately swallowed: the tray alert is a convenience, and an
      // unavailable plugin must not surface as an error on Home.
      _unavailable = true;
    }
  }

  @override
  Future<void> show(String title, String body) async {
    // The plugin has no tray implementation on the Windows/Linux desktop build
    // or in widget tests; skipping early keeps those paths silent and cheap.
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;

    await _ensureInitialized();
    if (!_initialized) return;

    try {
      await _plugin.show(
        id: _nextId++,
        title: title,
        body: body,
        notificationDetails: const NotificationDetails(android: _details),
      );
    } catch (_) {
      // Same reason as above: a failed alert never changes app behaviour.
    }
  }
}
