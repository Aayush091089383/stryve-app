import 'package:flutter/material.dart';
import 'package:github_release_apk_updater/github_release_apk_updater.dart';

/// Prompts for one available release, downloads its APK in place and hands it
/// to the Android installer.
///
/// The downloader and the installer are injectable so widget tests can drive
/// the whole flow without touching the network or a platform channel.
class UpdateDialog extends StatefulWidget {
  const UpdateDialog({
    super.key,
    required this.release,
    required this.currentVersion,
    this.updater,
    this.downloader,
  });

  final GithubAPKRelease release;

  /// The installed version, shown so the prompt is unambiguous.
  final String currentVersion;

  final GithubReleaseApkUpdater? updater;
  final ApkDownloaderService? downloader;

  @override
  State<UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<UpdateDialog> {
  late final GithubReleaseApkUpdater _updater =
      widget.updater ?? GithubReleaseApkUpdater();
  late final ApkDownloaderService _downloader =
      widget.downloader ?? ApkDownloaderService();

  bool _downloading = false;
  bool _installing = false;
  double? _progress;
  String? _error;

  Future<void> _startUpdate() async {
    setState(() {
      _downloading = true;
      _installing = false;
      _progress = 0;
      _error = null;
    });

    String? path;
    try {
      path = await _downloader.downloadAPK(
        widget.release.apkUrl,
        null,
        (received, total) {
          if (!mounted) return;
          setState(() => _progress = total > 0 ? received / total : null);
        },
      );
    } catch (_) {
      path = null;
    }

    if (!mounted) return;

    if (path == null) {
      setState(() {
        _downloading = false;
        _progress = null;
        _error =
            'The update could not be downloaded. Check your connection and try again.';
      });
      return;
    }

    setState(() => _installing = true);

    try {
      await _updater.installApk(path);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _downloading = false;
        _installing = false;
        _progress = null;
        _error =
            'Android could not open the installer. Allow Stryve to install unknown apps, then try again.';
      });
      return;
    }

    if (!mounted) return;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final busy = _downloading || _installing;
    final progressLabel = _installing
        ? 'Opening the installer…'
        : _progress == null
        ? 'Downloading…'
        : '${(_progress! * 100).round()}%';

    return PopScope(
      // A download in flight should not be dismissed by the back gesture; the
      // install is launched from this dialog when it finishes.
      canPop: !busy,
      child: AlertDialog(
        title: const Text('Update available'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Stryve ${widget.release.version} is available. '
                'You are on ${widget.currentVersion}.',
              ),
              if (widget.release.releaseNote.trim().isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(
                  widget.release.releaseNote.trim(),
                  maxLines: 6,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall,
                ),
              ],
              if (busy) ...[
                const SizedBox(height: 16),
                LinearProgressIndicator(value: _installing ? null : _progress),
                const SizedBox(height: 8),
                Text(progressLabel, style: theme.textTheme.bodySmall),
              ],
              if (_error != null) ...[
                const SizedBox(height: 16),
                Text(
                  _error!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ],
              if (!busy) ...[
                const SizedBox(height: 12),
                Text(
                  'The APK downloads inside the app, then Android asks you to '
                  'install it.',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ],
          ),
        ),
        actions: [
          if (!busy)
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(_error == null ? 'Later' : 'Close'),
            ),
          if (!busy)
            FilledButton(
              key: const Key('update_download'),
              onPressed: _startUpdate,
              child: Text(_error == null ? 'Update' : 'Try again'),
            ),
        ],
      ),
    );
  }
}
