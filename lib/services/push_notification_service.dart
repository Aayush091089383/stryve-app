import 'dart:async';
import 'dart:convert';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;

import '../config/environment.dart';
import 'notification_service.dart';

/// The tray alert shown for a data-only message while the app is closed.
///
/// Must be a top-level function and is registered in `main()` (or in the
/// service below) with `FirebaseMessaging.onBackgroundMessage`: Android runs it
/// in a separate isolate, so it cannot touch anything the UI created.
///
/// When the server sends a `notification` payload - which is what Stryve does -
/// Android has already drawn the alert by the time this runs, so the handler
/// only makes sure Firebase is initialised and stays silent. It is still
/// registered because a data-only message would otherwise never reach the tray.
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  try {
    await Firebase.initializeApp();
  } catch (_) {
    // Nothing to show without Firebase; never crash the background isolate.
  }

  if (message.notification != null) return;

  final title = (message.data['title'] as String?)?.trim();
  final body = (message.data['body'] as String?)?.trim();
  if (title == null && body == null) return;

  try {
    await LocalSystemNotifications().show(
      title?.isNotEmpty == true ? title! : 'New assignment',
      body ?? '',
    );
  } catch (_) {
    // A tray alert is a convenience; a failure here changes nothing.
  }
}

/// Registers this phone for push and shows the alert while the app is open.
///
/// Push is a delivery channel on top of the in-app feed, never a replacement
/// for it: the notifications row the backend writes is what the bell counts.
/// Everything here is best effort, so a missing Firebase project, a denied
/// permission or an unreachable backend leaves the app exactly as it was.
class PushNotificationService {
  PushNotificationService({
    SystemNotifications? systemNotifications,
    this.client,
  }) : _notifications = systemNotifications ?? LocalSystemNotifications();

  final SystemNotifications _notifications;

  /// Optional injected HTTP client, for tests only (null in the app).
  final http.Client? client;

  bool _started = false;
  StreamSubscription<RemoteMessage>? _foregroundMessages;
  StreamSubscription<String>? _tokenRefreshes;

  /// Keyed to the same channel the in-app alert uses, so Android's own
  /// per-category settings silence both together.
  static const String channelId = 'stryve_assignments';

  /// Starts push for the signed-in student.
  ///
  /// Safe to call more than once and safe to call on a platform without FCM:
  /// the first call wins, and every failure is swallowed.
  Future<void> start({required String authToken, VoidCallback? onMessage}) async {
    if (_started) return;
    _started = true;

    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    if (authToken.trim().isEmpty) return;

    try {
      await Firebase.initializeApp();

      final messaging = FirebaseMessaging.instance;

      // Android 13+ asks here; older releases answer "authorized" without a
      // prompt. A denial still leaves the in-app feed working.
      await messaging.requestPermission(alert: true, badge: true, sound: true);

      // Create the channel now, not on the first in-app alert: an FCM
      // notification that names a channel which does not exist yet is
      // downgraded to a low-importance default one.
      await _ensureChannel();

      final token = await messaging.getToken();
      if (token != null && token.isNotEmpty) {
        await _register(authToken, token);
      }

      _tokenRefreshes = messaging.onTokenRefresh.listen((refreshed) {
        unawaited(_register(authToken, refreshed));
      });

      _foregroundMessages = FirebaseMessaging.onMessage.listen((message) {
        // Android only draws a pushed notification itself when the app is in
        // the background, so a message that arrives while the student is
        // looking at the app is shown here through the same presenter the
        // in-app alert uses.
        final title = _titleOf(message);
        final body = _bodyOf(message);
        if (title == null && body == null) return;
        unawaited(_notifications.show(title ?? 'New assignment', body ?? ''));
        onMessage?.call();
      });
    } catch (_) {
      // No Firebase project, no Play Services, no permission, no network:
      // the app keeps working and the in-app bell still updates.
    }
  }

  /// Stops listening. Does not unregister the token: the row is re-pointed to
  /// the next student who signs in on this phone, which is what stops an old
  /// student's alerts from ringing a handed-over device.
  Future<void> dispose() async {
    await _foregroundMessages?.cancel();
    await _tokenRefreshes?.cancel();
    _foregroundMessages = null;
    _tokenRefreshes = null;
  }

  Future<void> _register(String authToken, String deviceToken) async {
    final httpClient = client ?? http.Client();
    final shouldCloseClient = client == null;

    try {
      await httpClient.post(
        Uri.parse('${Environment.backendUrl}/notifications/device-token'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $authToken',
        },
        body: jsonEncode({'token': deviceToken}),
      );
    } catch (_) {
      // The student can still read the feed; the next launch retries.
    } finally {
      if (shouldCloseClient) {
        httpClient.close();
      }
    }
  }

  Future<void> _ensureChannel() async {
    final plugin = FlutterLocalNotificationsPlugin();
    await plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      ),
    );
    await plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.createNotificationChannel(LocalSystemNotifications.channel);
  }

  static String? _titleOf(RemoteMessage message) {
    final fromNotification = message.notification?.title?.trim();
    if (fromNotification != null && fromNotification.isNotEmpty) {
      return fromNotification;
    }
    final fromData = (message.data['title'] as String?)?.trim();
    return fromData != null && fromData.isNotEmpty ? fromData : null;
  }

  static String? _bodyOf(RemoteMessage message) {
    final fromNotification = message.notification?.body?.trim();
    if (fromNotification != null && fromNotification.isNotEmpty) {
      return fromNotification;
    }
    final fromData = (message.data['body'] as String?)?.trim();
    return fromData != null && fromData.isNotEmpty ? fromData : null;
  }
}
