/// The in-app reader for an assignment PDF.
///
/// Opening this screen only *fetches* the PDF into memory through the existing
/// authenticated endpoint; it never writes to the device. The Download button is
/// the one and only path that saves a copy, and it does so in the phone's normal
/// Downloads location (or through the system Save dialog, whichever the device
/// supports).
///
/// The reader is built for actually reading a document on a phone:
///
/// * **Full screen** hides the app bar, the details card and every control, so
///   the page fills the whole display. It is entered from the expand button on
///   the page and left with the close button or the system back gesture.
/// * **Previous / Next** move between the assignments that have a PDF, without
///   going back to the list first. They follow the order of the list the viewer
///   was opened from and are disabled at either end.
/// * The controls sit in their own bottom [SafeArea], so the download button and
///   the page/next buttons never sit under the Android navigation bar.
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'assignment.dart';
import 'role_selection_page.dart';
import 'services/assignment_pdf_service.dart';
import 'services/auth_service.dart';
import 'utils/assignment_file_name.dart';
import 'utils/glass_container.dart';
import 'utils/linkified_text.dart';
import 'utils/pdf_surface.dart';

class AssignmentPdfViewerPage extends StatefulWidget {
  const AssignmentPdfViewerPage({
    super.key,
    required this.assignment,
    required this.token,
    this.assignments = const [],
    this.initialIndex = 0,
    this.attachmentId,
    this.sourceUrl,
    this.heading = 'Assignment',
    this.client,
    this.load,
    this.savePdf,
    this.surfaceFactory,
  });

  final Assignment assignment;

  /// One file of a multi-attachment assignment. Null opens the primary file
  /// through the legacy route; Previous/Next always moves between assignments
  /// and opens their primary files.
  final int? attachmentId;

  /// A complete authorized URL, used by announcement attachments. Null reads
  /// through the assignment routes, exactly as before.
  final String? sourceUrl;

  /// App-bar label. Announcement attachments pass "Announcement"; every
  /// assignment caller keeps the original wording.
  final String heading;

  /// Every assignment the list showed, in its display order.
  ///
  /// Used for Previous/Next. Empty (the default) means "just this document",
  /// which is what a caller that only has one assignment wants.
  final List<Assignment> assignments;

  /// Where [assignment] sat in [assignments]. Only a fallback - the document is
  /// matched by id first, so a list that changed shape cannot open the wrong
  /// file.
  final int initialIndex;

  /// The student's bearer token; the backend decides what it may read.
  final String token;

  /// Injection seams for tests (production leaves them null).
  final http.Client? client;
  final AssignmentPdfLoad? load;
  final AssignmentPdfSave? savePdf;
  final PdfSurfaceFactory? surfaceFactory;

  @override
  State<AssignmentPdfViewerPage> createState() =>
      _AssignmentPdfViewerPageState();
}

class _AssignmentPdfViewerPageState extends State<AssignmentPdfViewerPage> {
  late PdfSurface _surface;

  /// The assignments that actually have a PDF to show, in list order.
  ///
  /// A row without an attachment ("No assignment posted yet") is not readable,
  /// so Previous/Next skip it instead of opening a document that does not exist.
  late final List<Assignment> _readable;

  /// Index into [_readable] of the document on screen.
  int _index = 0;

  /// The attachment opened from the list, while it is still on screen. Null
  /// means "the assignment's primary file", which is also what Previous/Next
  /// falls back to.
  int? _attachmentId;

  Uint8List? _bytes;
  AssignmentPdfResult? _failure;
  bool _loading = true;
  bool _saving = false;
  bool _isFullScreen = false;

  /// The assignment on screen. Everything shown or saved reads from here, so
  /// stepping to the next document cannot leave the previous title or filename
  /// behind.
  Assignment get _current => _readable[_index];

  bool get _hasPrevious => _index > 0;
  bool get _hasNext => _index < _readable.length - 1;

  @override
  void initState() {
    super.initState();
    _readable = _readableFrom(widget.assignments, widget.assignment);
    _index = _indexOfCurrent();
    _attachmentId = widget.attachmentId;
    _surface = _createSurface();
    _surface.handle.addListener(_onSurfaceChanged);
    _loadPdf();
  }

  @override
  void dispose() {
    _surface.handle.removeListener(_onSurfaceChanged);
    _surface.handle.dispose();
    super.dispose();
  }

  /// The readable documents around [current], always containing [current].
  static List<Assignment> _readableFrom(
    List<Assignment> assignments,
    Assignment current,
  ) {
    final readable = [
      for (final assignment in assignments)
        if (assignment.hasAttachment) assignment,
    ];

    if (readable.isEmpty) return [current];
    if (readable.any((assignment) => assignment.id == current.id)) {
      return readable;
    }
    // A caller that opened a document outside the list it passed: keep it
    // readable and put the list after it.
    return [current, ...readable];
  }

  int _indexOfCurrent() {
    final byId = _readable.indexWhere(
      (assignment) => assignment.id == widget.assignment.id,
    );
    if (byId >= 0) return byId;
    return widget.initialIndex.clamp(0, _readable.length - 1);
  }

  PdfSurface _createSurface() =>
      (widget.surfaceFactory ?? createPdfrxSurface)();

  void _onSurfaceChanged() {
    if (mounted) setState(() {});
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  /// Loads the PDF into memory for viewing. Deliberately does not save anything.
  Future<void> _loadPdf() async {
    setState(() {
      _loading = true;
      _failure = null;
      _bytes = null;
    });

    final nativeService = AssignmentPdfService(
      client: widget.client,
      token: widget.token,
      attachmentId: _attachmentId,
      sourceUrl: widget.sourceUrl,
    );
    final loader = widget.load ?? nativeService.load;

    final AssignmentPdfResult result;
    try {
      // A caller that injected [load] gets the assignment id alone (its own
      // seam); production reads the exact attachment that was tapped.
      result = widget.load != null
          ? await loader(_current.id)
          : await nativeService.load(_current.id);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _failure = const AssignmentPdfResult.failed(
          AssignmentPdfFailure.network,
        );
      });
      return;
    }

    if (!mounted) return;

    if (result.ok) {
      setState(() {
        _bytes = result.bytes;
        _loading = false;
      });
      return;
    }

    setState(() {
      _failure = result;
      _loading = false;
    });

    // An expired session is handled exactly like every other screen: clear it
    // and return to role selection. The message is shown for the case where the
    // navigation cannot happen.
    if (result.isUnauthorized) await _signOut();
  }

  /// An expired session is handled exactly like every other screen: the
  /// credentials are cleared and the app returns to role selection.
  Future<void> _signOut() async {
    await AuthService().clearAuthData();
    if (!mounted) return;
    _showSnack('Your session has expired. Please sign in again.');
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (context) => const RoleSelectionPage()),
      (route) => false,
    );
  }

  /// Shows the document at [target] in [_readable].
  ///
  /// A rendered PDF is a separate native document, so the surface is rebuilt
  /// for the new file instead of being handed new bytes; the zoom/scroll state
  /// of the previous document is deliberately not carried over.
  Future<void> _step(int delta) async {
    final target = _index + delta;
    if (target < 0 || target >= _readable.length) return;
    if (_loading) return;

    final previous = _surface;
    previous.handle.removeListener(_onSurfaceChanged);
    previous.handle.dispose();

    setState(() {
      _index = target;
      _saving = false;
      // A different assignment means a different primary file.
      _attachmentId = null;
      _surface = _createSurface();
    });
    _surface.handle.addListener(_onSurfaceChanged);

    await _loadPdf();
  }

  /// The explicit Download: the only thing in this screen that writes a file.
  Future<void> _download() async {
    final bytes = _bytes;
    if (bytes == null || _saving) return;

    setState(() => _saving = true);

    final fileName = buildAssignmentPdfFileName(
      title: _current.title,
      subject: _current.subject,
      assignmentId: _current.id,
    );
    final save = widget.savePdf ?? saveAssignmentPdf;

    PdfSaveOutcome outcome;
    try {
      outcome = await save(bytes, fileName);
    } catch (_) {
      outcome = const PdfSaveOutcome.failed(
        'Could not save the PDF. Please try again.',
      );
    }

    if (!mounted) return;
    setState(() => _saving = false);

    if (outcome.cancelled) {
      _showSnack('Download cancelled - nothing was saved.');
    } else if (outcome.error != null) {
      _showSnack(outcome.error!);
    } else {
      _showSnack('Saved ${outcome.fileName} to ${outcome.location}');
    }
  }

  void _toggleFullScreen() {
    setState(() => _isFullScreen = !_isFullScreen);
  }

  @override
  Widget build(BuildContext context) {
    // Back leaves full screen first; a second back leaves the reader. Without
    // this, the system gesture would close the document while the student is
    // just trying to get the controls back.
    return PopScope(
      canPop: !_isFullScreen,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && _isFullScreen) {
          setState(() => _isFullScreen = false);
        }
      },
      child: Scaffold(
        extendBodyBehindAppBar: !_isFullScreen,
        appBar: _isFullScreen
            ? null
            : GlassAppBar(title: Text(widget.heading)),
        body: GlassBackground(
          child: SafeArea(
            // In full screen the document runs to the very top edge; the exit
            // button carries its own top SafeArea. The bottom inset belongs to
            // the controls bar (see [_buildBottomBar]), never to the page.
            top: !_isFullScreen,
            bottom: false,
            child: _isFullScreen ? _buildFullScreen() : _buildReadingLayout(),
          ),
        ),
      ),
    );
  }

  /// The normal layout: details on top, then the page with its controls.
  Widget _buildReadingLayout() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, kToolbarHeight + 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildDetails(),
          const SizedBox(height: 12),
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }

  /// The immersive layout: page only, plus a way back out.
  Widget _buildFullScreen() {
    return Stack(
      children: [
        Positioned.fill(child: _buildReader(inFullScreen: true)),
        Positioned(
          top: 8,
          right: 8,
          child: SafeArea(
            child: _overlayButton(
              icon: Icons.close_fullscreen_rounded,
              tooltip: 'Exit full screen',
              onPressed: _toggleFullScreen,
            ),
          ),
        ),
      ],
    );
  }

  /// Title, subject, deadline and instructions stay visible while reading.
  Widget _buildDetails() {
    final assignment = _current;
    return GlassCard(
      margin: EdgeInsets.zero,
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            assignment.title,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: GlassColors.headingOf(context),
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 10,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _meta(assignment.subject),
              _meta('Due: ${assignment.dueDate}'),
              if (assignment.batch != null) _meta(assignment.batch!),
            ],
          ),
          if ((assignment.description ?? '').trim().isNotEmpty) ...[
            const SizedBox(height: 8),
            LinkifiedText(
              assignment.description!.trim(),
              style: TextStyle(
                fontSize: 12.5,
                color: GlassColors.secondaryTextOf(context),
              ),
              linkStyle: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ],
        ],
      ),
    );
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

  Widget _buildBody() {
    // Controls (pages, Previous/Next, Download) only exist once there is a
    // document to act on: an error state offers Retry instead of a save button
    // that cannot work.
    final hasDocument =
        !_loading &&
        _failure == null &&
        _bytes != null &&
        !_surface.handle.hasFailed;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: _buildReader(inFullScreen: false)),
        if (hasDocument) ...[
          const SizedBox(height: 12),
          _buildBottomBar(),
        ],
      ],
    );
  }

  /// The page itself, in either layout.
  Widget _buildReader({required bool inFullScreen}) {
    if (_loading) {
      return _centeredCard(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: GlassColors.primaryBlue),
            SizedBox(height: 16),
            Text(
              'Preparing the PDF...',
              style: TextStyle(
                fontSize: 13,
                color: GlassColors.secondaryTextOf(context),
              ),
            ),
          ],
        ),
      );
    }

    if (_failure != null) {
      return _buildError(_failure!);
    }

    final bytes = _bytes;
    if (bytes == null) {
      // Not loading, no failure, no bytes: only reachable through a custom
      // loader, and answered the same way as an empty file.
      return _buildError(
        const AssignmentPdfResult.failed(AssignmentPdfFailure.empty),
      );
    }

    if (_surface.handle.hasFailed) {
      return _buildError(
        const AssignmentPdfResult.failed(
          AssignmentPdfFailure.server,
          detail: 'This PDF could not be opened. It may be damaged.',
        ),
      );
    }

    // pdfrx already renders inside a scrollable, pinch-zoomable, pannable view
    // (PDFium's own gesture handling). Wrapping it in an InteractiveViewer
    // would fight it for every gesture, so the page is handed to the user
    // as-is and only the surrounding chrome changes between layouts.
    final page = _surface.build(
      context,
      bytes,
      // Never the token or any account detail: just a stable, non-identifying
      // source name.
      'assignment-${_current.id}.pdf',
    );

    return Stack(
      children: [
        Positioned.fill(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(inFullScreen ? 0 : 14),
            child: GlassContainer(
              padding: EdgeInsets.zero,
              borderRadius: inFullScreen ? 0 : 14,
              opacity: 0.45,
              borderOpacity: inFullScreen ? 0 : 0.35,
              borderColor: inFullScreen ? Colors.transparent : null,
              child: page,
            ),
          ),
        ),
        if (!inFullScreen)
          Positioned(
            top: 8,
            right: 8,
            child: _overlayButton(
              icon: Icons.fullscreen_rounded,
              tooltip: 'Full screen',
              onPressed: _toggleFullScreen,
            ),
          ),
      ],
    );
  }

  /// A small glass circle for actions that float over the page.
  Widget _overlayButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback onPressed,
  }) {
    return GlassContainer(
      width: 40,
      height: 40,
      borderRadius: 20,
      padding: EdgeInsets.zero,
      margin: EdgeInsets.zero,
      opacity: 0.85,
      borderOpacity: 0.4,
      child: IconButton(
        tooltip: tooltip,
        onPressed: onPressed,
        icon: Icon(icon, size: 20, color: GlassColors.primaryBlue),
      ),
    );
  }

  /// Page controls, Previous/Next document and Download.
  ///
  /// This is the column that used to run into the Android navigation bar, so it
  /// owns the bottom [SafeArea]: the inset is applied once, here, and the page
  /// above simply takes the remaining height.
  Widget _buildBottomBar() {
    return SafeArea(
      top: false,
      minimum: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildControls(),
          const SizedBox(height: 10),
          _buildAssignmentNav(),
          const SizedBox(height: 12),
          _buildDownloadButton(),
        ],
      ),
    );
  }

  Widget _centeredCard({required Widget child}) {
    return Center(
      child: GlassCard(
        margin: EdgeInsets.zero,
        padding: const EdgeInsets.all(28),
        child: child,
      ),
    );
  }

  Widget _buildError(AssignmentPdfResult failure) {
    final IconData icon;
    switch (failure.failure) {
      case AssignmentPdfFailure.network:
        icon = Icons.wifi_off_rounded;
      case AssignmentPdfFailure.unauthorized:
      case AssignmentPdfFailure.forbidden:
        icon = Icons.lock_outline_rounded;
      case AssignmentPdfFailure.missing:
        icon = Icons.insert_drive_file_outlined;
      case AssignmentPdfFailure.empty:
      case AssignmentPdfFailure.server:
      case null:
        icon = Icons.error_outline_rounded;
    }

    return Center(
      child: GlassCard(
        margin: EdgeInsets.zero,
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            GlassContainer(
              width: 60,
              height: 60,
              borderRadius: 30,
              padding: EdgeInsets.zero,
              opacity: 0.7,
              borderOpacity: 0.4,
              child: Icon(icon, size: 28, color: GlassColors.error),
            ),
            const SizedBox(height: 18),
            Text(
              failure.message,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14.5,
                color: GlassColors.secondaryTextOf(context),
              ),
            ),
            const SizedBox(height: 20),
            GlassButton(
              onPressed: _loading ? null : _loadPdf,
              color: GlassColors.primaryBlue,
              height: 46,
              borderRadius: 12,
              width: 170,
              child: const Text('Retry', style: TextStyle(fontSize: 14)),
            ),
          ],
        ),
      ),
    );
  }

  /// Page navigation and zoom for the rendered PDF.
  Widget _buildControls() {
    final handle = _surface.handle;
    final ready = handle.isReady;
    final page = handle.currentPage;
    final pageCount = handle.pageCount;

    return GlassCard(
      margin: EdgeInsets.zero,
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      child: Row(
        children: [
          IconButton(
            tooltip: 'Previous page',
            onPressed: ready && page > 1
                ? () => handle.goToPage(page - 1)
                : null,
            icon: const Icon(Icons.chevron_left_rounded),
            color: GlassColors.primaryBlue,
            disabledColor: GlassColors.disabledOf(context),
          ),
          Expanded(
            child: Text(
              ready ? 'Page $page of $pageCount' : 'Loading pages...',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: GlassColors.secondaryTextOf(context),
              ),
            ),
          ),
          IconButton(
            tooltip: 'Next page',
            onPressed: ready && page < pageCount
                ? () => handle.goToPage(page + 1)
                : null,
            icon: const Icon(Icons.chevron_right_rounded),
            color: GlassColors.primaryBlue,
            disabledColor: GlassColors.disabledOf(context),
          ),
          Container(
            width: 1,
            height: 22,
            color: GlassColors.borderOf(context),
            margin: const EdgeInsets.symmetric(horizontal: 4),
          ),
          IconButton(
            tooltip: 'Zoom out',
            onPressed: ready ? handle.zoomOut : null,
            icon: const Icon(Icons.zoom_out_rounded),
            color: GlassColors.primaryBlue,
            disabledColor: GlassColors.disabledOf(context),
          ),
          IconButton(
            tooltip: 'Zoom in',
            onPressed: ready ? handle.zoomIn : null,
            icon: const Icon(Icons.zoom_in_rounded),
            color: GlassColors.primaryBlue,
            disabledColor: GlassColors.disabledOf(context),
          ),
        ],
      ),
    );
  }

  /// Previous / Next document, in the order the list showed them.
  Widget _buildAssignmentNav() {
    final enabled = !_loading;
    return Row(
      children: [
        Expanded(
          child: _navButton(
            label: 'Previous',
            icon: Icons.skip_previous_rounded,
            enabled: enabled && _hasPrevious,
            onPressed: () => _step(-1),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _navButton(
            label: 'Next',
            icon: Icons.skip_next_rounded,
            enabled: enabled && _hasNext,
            onPressed: () => _step(1),
          ),
        ),
      ],
    );
  }

  Widget _navButton({
    required String label,
    required IconData icon,
    required bool enabled,
    required VoidCallback onPressed,
  }) {
    // A grey label and border while disabled say "there is no next document"
    // without pretending to be tappable; the tap target is inert too.
    final color = enabled
        ? GlassColors.primaryBlue
        : GlassColors.disabledOf(context);
    return GlassOutlinedButton(
      onPressed: enabled ? onPressed : null,
      height: 44,
      borderRadius: 12,
      borderColor: color,
      textColor: color,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDownloadButton() {
    return GlassButton(
      // A solid colour (no gradient) and an honest label while saving; the
      // button is disabled so a repeated tap cannot stack two saves.
      onPressed: _saving ? null : _download,
      color: GlassColors.primaryBlue,
      disabled: _saving,
      height: 50,
      borderRadius: 14,
      child: Text(
        _saving ? 'DOWNLOADING...' : 'DOWNLOAD PDF',
        style: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.4,
        ),
      ),
    );
  }
}
