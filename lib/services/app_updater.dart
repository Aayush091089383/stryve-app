import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:github_release_apk_updater/github_release_apk_updater.dart';

import '../update_dialog.dart';

/// Checks the public GitHub Releases feed for a newer Stryve build.
///
/// Android only: the update is an APK installed through the system installer,
/// which means nothing on the Windows build. Every failure - offline, GitHub
/// rate limit, a release with no APK attached - is swallowed. An update check
/// must never get in the way of opening the app.
class AppUpdater {
  AppUpdater._();

  static const String owner = 'Aayush091089383';
  static const String repository = 'stryve-app';

  /// `releases/latest` is fetched unauthenticated (60 requests/hour per IP),
  /// so one check per app run; a tab that rebuilds does not ask again.
  static bool _scheduled = false;

  static bool get isSupported => !kIsWeb && Platform.isAndroid;

  /// Runs the check once, a couple of seconds after the first frame.
  ///
  /// Takes the root navigator's key rather than a page's context: the startup
  /// page is replaced as soon as the session check finishes, and a dialog
  /// pushed on its context would disappear with it.
  static void scheduleStartupCheck(
    GlobalKey<NavigatorState> navigatorKey, {
    Duration delay = const Duration(seconds: 2),
  }) {
    if (!isSupported || _scheduled) return;
    _scheduled = true;

    Future<void>.delayed(delay, () async {
      final context = navigatorKey.currentContext;
      if (context == null || !context.mounted) return;
      await checkForUpdate(context);
    });
  }

  /// Shows the update prompt when the latest release is newer than this install.
  static Future<void> checkForUpdate(BuildContext context) async {
    if (!isSupported) return;

    try {
      final updater = GithubReleaseApkUpdater();
      final currentVersion = await updater.getCurrentAppVersion();
      final abis = await updater.getSupportedAbis();
      final release = await GithubApiService().getLatestGithubAPKRelease(
        ownerGithub: owner,
        repositoryGithub: repository,
        // Any APK attached to the release; the asset name does not matter.
        apkKeyName: '',
        supportedAbis: abis,
      );

      if (release == null) return;
      if (!VersionComparator().isNewerVersion(release.version, currentVersion)) {
        return;
      }
      if (!context.mounted) return;

      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => UpdateDialog(
          release: release,
          currentVersion: currentVersion,
        ),
      );
    } catch (_) {
      // No network, rate limited, malformed tag, release without an APK:
      // stay silent and let the app start normally.
    }
  }
}
