/// The in-app player for a video assignment.
///
/// Opening this screen only *streams* the file from the existing authorized
/// endpoint (`GET /assignments/{id}/file`) with the student's bearer token; it
/// writes nothing to the device. It is the video counterpart of
/// `AssignmentPdfViewerPage`: same details card, same Previous/Next behaviour,
/// same rule that the backend decides who may watch.
library;

import 'package:flutter/material.dart';

import 'assignment.dart';
import 'config/environment.dart';
import 'utils/glass_container.dart';
import 'utils/linkified_text.dart';
import 'utils/video_surface.dart';

class VideoPlayerPage extends StatefulWidget {
  const VideoPlayerPage({
    super.key,
    required this.assignment,
    required this.token,
    this.assignments = const [],
    this.initialIndex = 0,
    this.attachmentId,
    this.sourceUrl,
    this.baseUrl,
    this.surfaceFactory,
  });

  final Assignment assignment;

  /// One video of a multi-attachment assignment. Null streams the primary
  /// file through the legacy route.
  final int? attachmentId;

  /// A complete authorized URL, used by announcement attachments. Null streams
  /// through the assignment routes, exactly as before.
  final String? sourceUrl;

  /// The video assignments the list was showing, for Previous/Next. Empty (the
  /// default) means "just this one".
  final List<Assignment> assignments;

  /// Where [assignment] sat in [assignments]; a fallback only, the current
  /// video is matched by id first.
  final int initialIndex;

  final String token;

  /// The backend host. Injected by tests; production uses the configured one.
  final String? baseUrl;

  /// Injection seam so widget tests never start a native player.
  final VideoSurfaceFactory? surfaceFactory;

  @override
  State<VideoPlayerPage> createState() => _VideoPlayerPageState();
}

class _VideoPlayerPageState extends State<VideoPlayerPage> {
  /// The videos around the current one, in list order.
  late final List<Assignment> _playable;
  int _index = 0;

  /// The attachment opened from the list; cleared when Previous/Next moves to
  /// another assignment, whose primary video is then streamed.
  int? _attachmentId;

  Assignment get _current => _playable[_index];

  bool get _hasPrevious => _index > 0;
  bool get _hasNext => _index < _playable.length - 1;

  @override
  void initState() {
    super.initState();
    _playable = _playableFrom(widget.assignments, widget.assignment);
    _index = _indexOfCurrent();
    _attachmentId = widget.attachmentId;
  }

  /// The video rows around [current], always containing [current].
  ///
  /// Rows without a file, and PDFs, are skipped: Previous/Next only ever moves
  /// between things this screen can actually play.
  static List<Assignment> _playableFrom(
    List<Assignment> assignments,
    Assignment current,
  ) {
    final playable = <Assignment>[
      for (final assignment in assignments)
        if (assignment.isVideo) assignment,
    ];

    if (playable.isEmpty) return <Assignment>[current];
    if (playable.any((assignment) => assignment.id == current.id)) {
      return playable;
    }
    return <Assignment>[current, ...playable];
  }

  int _indexOfCurrent() {
    final byId = _playable.indexWhere(
      (assignment) => assignment.id == widget.assignment.id,
    );
    if (byId >= 0) return byId;
    return widget.initialIndex.clamp(0, _playable.length - 1);
  }

  /// The authorized file URL for one assignment.
  ///
  /// The same route the PDF reader uses, so a video is only readable by the
  /// students the backend says may see that assignment.
  String _urlFor(Assignment assignment, String host) {
    if (widget.sourceUrl != null) return widget.sourceUrl!;
    final attachmentId = _attachmentId;
    return attachmentId == null || attachmentId <= 0
        ? '$host/assignments/${assignment.id}/file'
        : '$host/assignments/${assignment.id}/files/$attachmentId';
  }

  void _step(int delta) {
    final target = _index + delta;
    if (target < 0 || target >= _playable.length) return;
    setState(() {
      _index = target;
      _attachmentId = null;
    });
  }

  Widget _meta(String text) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.circle, size: 5, color: GlassColors.primaryBlue),
        const SizedBox(width: 5),
        Text(
          text,
          style: TextStyle(
            fontSize: 12,
            color: GlassColors.secondaryTextOf(context),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final assignment = _current;
    // [baseUrl] only exists so a test can point at a fake host; production
    // always uses the same configured backend as every other screen.
    final host = widget.baseUrl ?? Environment.backendUrl;
    final factory = widget.surfaceFactory ?? createChewieSurface;

    // Landscape (and any very short window) has no room for a details card plus
    // a nav row: the video would be squeezed to a thumbnail. In that case the
    // player takes the height and the title moves into the app bar.
    final compact = MediaQuery.sizeOf(context).height < 500;

    return Scaffold(
      appBar: GlassAppBar(title: Text(compact ? assignment.title : 'Video')),
      body: GlassBackground(
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (!compact)
                  GlassCard(
                    margin: EdgeInsets.zero,
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          assignment.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: GlassColors.headingOf(context),
                          ),
                        ),
                        const SizedBox(height: 6),
                        Wrap(
                          spacing: 10,
                          runSpacing: 4,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            _meta(assignment.subject),
                            _meta('Due: ${assignment.dueDate}'),
                            if (assignment.batch != null)
                              _meta(assignment.batch!),
                          ],
                        ),
                        if ((assignment.description ?? '')
                            .trim()
                            .isNotEmpty) ...[
                          const SizedBox(height: 8),
                          LinkifiedText(
                            assignment.description!.trim(),
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12.5,
                              color: GlassColors.secondaryTextOf(context),
                            ),
                            linkStyle: const TextStyle(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                if (!compact) const SizedBox(height: 12),
                Expanded(
                  child: Center(
                    child: AspectRatio(
                      aspectRatio: 16 / 9,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(14),
                        child: GlassContainer(
                          padding: EdgeInsets.zero,
                          borderRadius: 14,
                          opacity: 0.9,
                          borderOpacity: 0.35,
                          // Rebuilt per video (and per retry) so the player can
                          // never keep streaming the previous file.
                          child: factory(
                            VideoSource(
                              url: _urlFor(assignment, host),
                              token: widget.token,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                if (!compact) const SizedBox(height: 12),
                if (!compact)
                  Row(
                    children: [
                      Expanded(
                        child: GlassOutlinedButton(
                          onPressed: _hasPrevious ? () => _step(-1) : null,
                          height: 44,
                          borderRadius: 12,
                          borderColor: _hasPrevious
                              ? GlassColors.primaryBlue
                              : GlassColors.disabledOf(context),
                          textColor: _hasPrevious
                              ? GlassColors.primaryBlue
                              : GlassColors.disabledOf(context),
                          child: Text(
                            'Previous',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              color: _hasPrevious
                                  ? GlassColors.primaryBlue
                                  : GlassColors.disabledOf(context),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: GlassOutlinedButton(
                          onPressed: _hasNext ? () => _step(1) : null,
                          height: 44,
                          borderRadius: 12,
                          borderColor: _hasNext
                              ? GlassColors.primaryBlue
                              : GlassColors.disabledOf(context),
                          textColor: _hasNext
                              ? GlassColors.primaryBlue
                              : GlassColors.disabledOf(context),
                          child: Text(
                            'Next',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              color: _hasNext
                                  ? GlassColors.primaryBlue
                                  : GlassColors.disabledOf(context),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
