/// The in-app reader for an assignment PDF.
///
/// Opening this screen only *fetches* the PDF into memory through the existing
/// authenticated endpoint; it never writes to the device. The Download button is
/// the one and only path that saves a copy, and it does so in the phone's normal
/// Downloads location (or through the system Save dialog, whichever the device
/// supports).
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
import 'utils/pdf_surface.dart';

class AssignmentPdfViewerPage extends StatefulWidget {
  const AssignmentPdfViewerPage({
    super.key,
    required this.assignment,
    required this.token,
    this.client,
    this.load,
    this.savePdf,
    this.surfaceFactory,
  });

  final Assignment assignment;

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
  late final PdfSurface _surface;

  Uint8List? _bytes;
  AssignmentPdfResult? _failure;
  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _surface = (widget.surfaceFactory ?? createPdfrxSurface)();
    _surface.handle.addListener(_onSurfaceChanged);
    _loadPdf();
  }

  @override
  void dispose() {
    _surface.handle.removeListener(_onSurfaceChanged);
    _surface.handle.dispose();
    super.dispose();
  }

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

    final loader =
        widget.load ??
        AssignmentPdfService(client: widget.client, token: widget.token).load;

    final AssignmentPdfResult result;
    try {
      result = await loader(widget.assignment.id);
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

  Future<void> _signOut() async {
    await AuthService().clearAuthData();
    if (!mounted) return;
    _showSnack('Your session has expired. Please sign in again.');
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (context) => const RoleSelectionPage()),
      (route) => false,
    );
  }

  /// The explicit Download: the only thing in this screen that writes a file.
  Future<void> _download() async {
    final bytes = _bytes;
    if (bytes == null || _saving) return;

    setState(() => _saving = true);

    final fileName = buildAssignmentPdfFileName(
      title: widget.assignment.title,
      subject: widget.assignment.subject,
      assignmentId: widget.assignment.id,
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: const GlassAppBar(title: Text('Assignment')),
      body: GlassBackground(
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, kToolbarHeight + 12, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildDetails(),
                const SizedBox(height: 12),
                Expanded(child: _buildBody()),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Title, subject, deadline and instructions stay visible while reading.
  Widget _buildDetails() {
    final assignment = widget.assignment;
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
            Text(
              assignment.description!.trim(),
              style: TextStyle(
                fontSize: 12.5,
                color: GlassColors.secondaryTextOf(context),
              ),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: GlassContainer(
              padding: EdgeInsets.zero,
              borderRadius: 14,
              opacity: 0.45,
              borderOpacity: 0.35,
              child: _surface.build(
                context,
                bytes,
                // Never the token or any account detail: just a stable,
                // non-identifying source name.
                'assignment-${widget.assignment.id}.pdf',
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        _buildControls(),
        const SizedBox(height: 12),
        _buildDownloadButton(),
      ],
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
