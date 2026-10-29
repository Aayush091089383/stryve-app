import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:github_release_apk_updater/github_release_apk_updater.dart';
import 'package:stryve/update_dialog.dart';

/// Stands in for the package's downloader: no Dio, no filesystem.
class _FakeDownloader extends ApkDownloaderService {
  _FakeDownloader({this.result = '/tmp/Stryve.apk'});

  String? result;
  int calls = 0;

  @override
  Future<String?> downloadAPK(
    String url,
    String? tokenGithub,
    Function(int received, int total)? onProgress,
  ) async {
    calls++;
    onProgress?.call(50, 100);
    onProgress?.call(100, 100);
    return result;
  }
}

/// Records the path handed to the Android installer.
class _FakeUpdater extends GithubReleaseApkUpdater {
  String? installedPath;

  @override
  Future<void> installApk(String filePath) async {
    installedPath = filePath;
  }
}

GithubAPKRelease _release() => GithubAPKRelease(
  version: '1.2.0',
  apkUrl: 'https://example.invalid/Stryve.apk',
  releaseNote: 'Fixes the attendance sheet.',
);

Future<void> _openDialog(
  WidgetTester tester, {
  required UpdateDialog dialog,
  required void Function() onClosed,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            await showDialog<void>(
              context: context,
              barrierDismissible: false,
              builder: (_) => dialog,
            );
            onClosed();
          },
          child: const Text('open'),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('prompt names both versions and the release notes', (
    tester,
  ) async {
    var closed = false;
    await _openDialog(
      tester,
      dialog: UpdateDialog(
        release: _release(),
        currentVersion: '1.0.0',
        updater: _FakeUpdater(),
        downloader: _FakeDownloader(),
      ),
      onClosed: () => closed = true,
    );

    expect(find.text('Update available'), findsOneWidget);
    expect(find.textContaining('Stryve 1.2.0'), findsOneWidget);
    expect(find.textContaining('1.0.0'), findsOneWidget);
    expect(find.text('Fixes the attendance sheet.'), findsOneWidget);

    await tester.tap(find.text('Later'));
    await tester.pumpAndSettle();
    expect(closed, isTrue);
  });

  testWidgets('Update downloads the APK and hands it to the installer', (
    tester,
  ) async {
    final downloader = _FakeDownloader();
    final updater = _FakeUpdater();
    var closed = false;

    await _openDialog(
      tester,
      dialog: UpdateDialog(
        release: _release(),
        currentVersion: '1.0.0',
        updater: updater,
        downloader: downloader,
      ),
      onClosed: () => closed = true,
    );

    await tester.tap(find.byKey(const Key('update_download')));
    await tester.pumpAndSettle();

    expect(downloader.calls, 1);
    expect(updater.installedPath, '/tmp/Stryve.apk');
    expect(closed, isTrue);
    expect(find.text('Update available'), findsNothing);
  });

  testWidgets('a failed download stays open and offers a retry', (tester) async {
    final downloader = _FakeDownloader(result: null);
    final updater = _FakeUpdater();
    var closed = false;

    await _openDialog(
      tester,
      dialog: UpdateDialog(
        release: _release(),
        currentVersion: '1.0.0',
        updater: updater,
        downloader: downloader,
      ),
      onClosed: () => closed = true,
    );

    await tester.tap(find.byKey(const Key('update_download')));
    await tester.pumpAndSettle();

    expect(closed, isFalse);
    expect(updater.installedPath, isNull);
    expect(find.textContaining('could not be downloaded'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);

    // A retry that succeeds closes the dialog and installs.
    downloader.result = '/tmp/Stryve.apk';
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();

    expect(downloader.calls, 2);
    expect(updater.installedPath, '/tmp/Stryve.apk');
    expect(closed, isTrue);
  });
}
