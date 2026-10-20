/// The video playback surface used by the assignment player.
///
/// The screen talks to a [VideoSource], never to `video_player` or `chewie`
/// directly. The shipped factory ([createChewieSurface]) streams the assignment
/// through the existing authenticated endpoint, with the student's bearer
/// token, and gives Chewie's usual controls (play, pause, seek, full screen).
/// Tests inject their own factory, so the page is widget-testable without a
/// native player or a real stream.
library;

import 'package:chewie/chewie.dart';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import 'glass_container.dart';

/// What to play: the authorized endpoint, and the token that authorizes it.
class VideoSource {
  const VideoSource({required this.url, required this.token});

  final String url;
  final String token;
}

/// Builds the playing surface for [source]. Injectable for widget tests.
typedef VideoSurfaceFactory = Widget Function(VideoSource source);

/// The surface the app ships: Chewie on top of `video_player`.
Widget createChewieSurface(VideoSource source) => ChewieVideoSurface(source: source);

/// A Chewie player with a loading state, a failure state and a retry.
///
/// The stream is requested with the bearer token, because the file endpoint is
/// authorized like every other route: the backend decides whether this student
/// may watch this assignment, and a 401/403/404 surfaces as an error here
/// rather than an endlessly spinning box.
class ChewieVideoSurface extends StatefulWidget {
  const ChewieVideoSurface({super.key, required this.source});

  final VideoSource source;

  @override
  State<ChewieVideoSurface> createState() => _ChewieVideoSurfaceState();
}

class _ChewieVideoSurfaceState extends State<ChewieVideoSurface> {
  VideoPlayerController? _player;
  ChewieController? _chewie;
  bool _loading = true;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    _chewie?.dispose();
    _player?.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    setState(() {
      _loading = true;
      _failed = false;
    });

    final player = VideoPlayerController.networkUrl(
      Uri.parse(widget.source.url),
      httpHeaders: <String, String>{
        'Authorization': 'Bearer ${widget.source.token}',
      },
    );

    try {
      await player.initialize();
    } catch (_) {
      await player.dispose();
      if (!mounted) return;
      setState(() {
        _loading = false;
        _failed = true;
      });
      return;
    }

    if (!mounted) {
      await player.dispose();
      return;
    }

    final chewie = ChewieController(
      videoPlayerController: player,
      autoPlay: true,
      looping: false,
      allowFullScreen: true,
      allowMuting: true,
      aspectRatio: player.value.aspectRatio == 0
          ? 16 / 9
          : player.value.aspectRatio,
      errorBuilder: (context, message) => _errorBody(message),
    );

    setState(() {
      _player = player;
      _chewie = chewie;
      _loading = false;
    });
  }

  Widget _errorBody(String message) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Text(
          message.trim().isEmpty
              ? 'This video could not be played.'
              : 'This video could not be played.\n$message',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 13,
            color: GlassColors.secondaryTextOf(context),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(color: GlassColors.primaryBlue),
      );
    }

    if (_failed || _chewie == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.videocam_off_rounded,
                size: 34,
                color: GlassColors.secondaryTextOf(context),
              ),
              const SizedBox(height: 12),
              Text(
                'This video could not be loaded. Check your connection and try '
                'again.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  color: GlassColors.secondaryTextOf(context),
                ),
              ),
              const SizedBox(height: 16),
              GlassButton(
                onPressed: _start,
                color: GlassColors.primaryBlue,
                height: 40,
                borderRadius: 10,
                width: 130,
                child: const Text('Try again', style: TextStyle(fontSize: 13)),
              ),
            ],
          ),
        ),
      );
    }

    return Chewie(controller: _chewie!);
  }
}
