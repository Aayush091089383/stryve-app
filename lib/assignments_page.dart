import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'assignment.dart';
import 'assignment_pdf_viewer_page.dart';
import 'config/environment.dart';
import 'role_selection_page.dart';
import 'services/api_cache.dart';
import 'services/assignment_pdf_service.dart';
import 'services/auth_service.dart';
import 'student.dart';
import 'utils/assignment_card.dart';
import 'utils/glass_container.dart';
import 'utils/motion.dart';
import 'utils/pdf_surface.dart';

/// The student's Assignments screen: every assignment the existing
/// `GET /assignments` endpoint returns for their class group.
///
/// This is deliberately NOT a second Tasks screen. The Tasks tab keeps its own
/// "Pending Tasks" list (plus its static Completed placeholder); this screen is
/// the full catalogue, which is also why it can show the assignment
/// `description` the Tasks card does not use.
///
/// Scope is whatever the backend allows: year + division + (own batch and
/// division-wide). Nothing is widened on the client - the server is the only
/// thing that decides which assignments a student may see.
class AssignmentsPage extends StatefulWidget {
  final Student student;

  /// Injection seams for tests; production leaves them null and uses the real
  /// authenticated endpoint, the pdfrx surface and the device saver.
  final http.Client? client;
  final AssignmentPdfLoad? loadPdf;
  final AssignmentPdfSave? savePdf;
  final PdfSurfaceFactory? surfaceFactory;

  /// When true this page renders only its content, for use as a tab body.
  ///
  /// The host (``HomePage``) already provides the ``Scaffold``, the glass app
  /// bar and the ``GlassBackground``, so drawing them here as well would stack
  /// two app bars and two backgrounds. The pushed route leaves this false and
  /// is unchanged.
  final bool embedded;

  /// Extra bottom padding for the embedded (tab) mode.
  ///
  /// The pushed route fills the whole screen, so 0 is correct there. As a tab
  /// body this list sits under HomePage's floating glass navigation bar, and it
  /// must leave room for it - otherwise the last card ends up behind the bar,
  /// where taps belong to the bar instead of the card.
  final double bottomInset;

  const AssignmentsPage({
    super.key,
    required this.student,
    this.client,
    this.loadPdf,
    this.savePdf,
    this.surfaceFactory,
    this.embedded = false,
    this.bottomInset = 0,
  });

  @override
  State<AssignmentsPage> createState() => _AssignmentsPageState();
}

class _AssignmentsPageState extends State<AssignmentsPage> {
  bool _isLoading = true;
  String? _errorMessage;
  List<Assignment> _assignments = const [];

  /// True while a pull-to-refresh (or the header's refresh button) is in
  /// flight, so a second gesture or tap cannot start a parallel request.
  bool _isRefreshing = false;

  /// True while the viewer route is being pushed, so a second tap cannot open
  /// the same document twice.
  bool _openingViewer = false;

  @override
  void initState() {
    super.initState();
    _fetchAssignments();
  }

  Future<void> _openAssignment(Assignment assignment) async {
    if (_openingViewer) return;
    _openingViewer = true;
    try {
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (context) => AssignmentPdfViewerPage(
            assignment: assignment,
            // The whole list, so the reader's Previous/Next can walk it
            // without popping back to this screen. The viewer skips the rows
            // without a PDF and finds the tapped one by id.
            assignments: _assignments,
            initialIndex: _assignments.indexWhere(
              (row) => row.id == assignment.id,
            ),
            token: widget.student.token,
            client: widget.client,
            load: widget.loadPdf,
            savePdf: widget.savePdf,
            surfaceFactory: widget.surfaceFactory,
          ),
        ),
      );
    } finally {
      _openingViewer = false;
    }
  }

  Future<void> _fetchAssignments({
    bool forceRefresh = false,
    bool showLoading = true,
  }) async {
    // A refresh keeps the list on screen: flipping `_isLoading` would replace
    // the content with the full-screen spinner mid-gesture, which reads as a
    // reload rather than a refresh.
    if (showLoading) {
      setState(() {
        _isLoading = true;
        _errorMessage = null;
      });
    }

    try {
      // The same key the Tasks tab uses: whichever screen opens first fetches,
      // the other renders the cached body instead of asking again.
      final cacheKey = 'assignments_${widget.student.token}';
      final cached = forceRefresh ? null : ApiCache.get(cacheKey);

      final String responseBody;
      if (cached != null) {
        responseBody = cached;
      } else {
        final uri = Uri.parse('${Environment.backendUrl}/assignments');
        final headers = {'Authorization': 'Bearer ${widget.student.token}'};
        final response =
            await (widget.client?.get(uri, headers: headers) ??
                http.get(uri, headers: headers));

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
          _handleFetchFailure(
            'Could not load assignments (${response.statusCode})',
            showLoading: showLoading,
          );
          return;
        }

        responseBody = response.body;
        ApiCache.set(cacheKey, responseBody);
      }

      final List<dynamic> raw = jsonDecode(responseBody);
      final loaded = raw.map((a) => Assignment.fromJson(a)).toList()
        ..sort((a, b) => a.dueDate.compareTo(b.dueDate));

      if (!mounted) return;
      setState(() {
        _assignments = loaded;
        _isLoading = false;
      });
    } catch (_) {
      _handleFetchFailure(
        'Could not connect to Stryve server. Please check your internet connection and try again.',
        showLoading: showLoading,
      );
    }
  }

  /// Reports a failed fetch without throwing away a list the student is already
  /// reading.
  ///
  /// A first load (or a pull on an empty list) shows the error state with its
  /// Try Again button; a failed *refresh* of existing content keeps the
  /// assignments on screen and only says so in a snackbar. An error is never
  /// rendered as an empty list.
  void _handleFetchFailure(String message, {required bool showLoading}) {
    if (!mounted) return;
    if (!showLoading && _assignments.isNotEmpty) {
      _showSnackBar('Could not refresh assignments. Pull down to try again.');
      return;
    }
    setState(() {
      _errorMessage = message;
      _isLoading = false;
    });
  }

  void _showSnackBar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  /// Pull-to-refresh and the header button both come through here.
  ///
  /// `forceRefresh` matters: without it the fetch would answer from
  /// [ApiCache] and the student would pull, see the indicator spin, and still
  /// get yesterday's list - which is exactly the bug this screen had.
  Future<void> _refresh() async {
    if (_isRefreshing) return;
    setState(() => _isRefreshing = true);
    try {
      await _fetchAssignments(forceRefresh: true, showLoading: false);
    } finally {
      if (mounted) setState(() => _isRefreshing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.embedded) {
      return _content(context);
    }
    return Scaffold(
      appBar: const GlassAppBar(title: Text('Assignments')),
      body: GlassBackground(child: _content(context)),
    );
  }

  /// The loading/error/list switcher, without any page chrome.
  ///
  /// Shared by both modes so the two can never drift apart.
  Widget _content(BuildContext context) {
    return AnimatedSwitcher(
      duration: motionDuration(context, kMotionStandard),
      switchInCurve: Curves.easeOut,
      switchOutCurve: Curves.easeIn,
      child: _isLoading
          ? const Center(
              key: ValueKey('assignments-loading'),
              child: CircularProgressIndicator(color: GlassColors.primaryBlue),
            )
          : _errorMessage != null
          ? KeyedSubtree(
              key: const ValueKey('assignments-error'),
              child: _buildError(),
            )
          : KeyedSubtree(
              key: const ValueKey('assignments-content'),
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
                onPressed: () => _fetchAssignments(forceRefresh: true),
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
    // The embedded tab body scrolls *behind* HomePage's glass app bar
    // (`extendBodyBehindAppBar`), and the Scaffold reports the bar's footprint
    // in the inherited top padding. The fixed 16 this used to add put the
    // "All Assignments" title under the bar, where the glass hid it. In the
    // pushed (non-embedded) mode the page has its own Scaffold and only needs
    // the plain gap.
    final topInset = widget.embedded
        ? MediaQuery.paddingOf(context).top + 8
        : 16.0;

    return RefreshIndicator(
      // Pull down to fetch again - through the network, never the cache.
      onRefresh: _refresh,
      color: GlassColors.primaryBlue,
      backgroundColor: GlassColors.surface,
      child: ListView(
        // Always scrollable: a short list, and the empty state, would otherwise
        // have nothing to drag and the pull gesture would be unavailable
        // exactly when the student most needs it.
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsets.fromLTRB(
          20,
          topInset,
          20,
          24 + widget.bottomInset,
        ),
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'All Assignments',
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    color: GlassColors.headingOf(context),
                  ),
                ),
              ),
              // A visible fallback for anyone who does not think to pull: same
              // action, same handler, disabled while a refresh is running.
              IconButton(
                onPressed: _isRefreshing ? null : _refresh,
                tooltip: 'Refresh',
                visualDensity: VisualDensity.compact,
                icon: Icon(
                  Icons.refresh_rounded,
                  size: 22,
                  color: _isRefreshing
                      ? GlassColors.disabled
                      : GlassColors.primaryBlue,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'Everything posted for your division and batch.',
            style: TextStyle(
              fontSize: 13,
              color: GlassColors.secondaryTextOf(context),
            ),
          ),
          const SizedBox(height: 16),
          if (_assignments.isEmpty)
            _buildEmptyState()
          else
            ..._assignments.map(
              (assignment) => AssignmentCard(
                title: assignment.title,
                subject: assignment.subject,
                dueDate: formatAssignmentDueDate(assignment.dueDate),
                batch: assignment.batch,
                description: assignment.description,
                hasAttachment: assignment.hasAttachment,
                attachmentName: assignment.attachmentName,
                onOpen: () => _openAssignment(assignment),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return GlassCard(
      padding: const EdgeInsets.all(24),
      margin: EdgeInsets.zero,
      child: Row(
        children: [
          GlassContainer(
            width: 52,
            height: 52,
            borderRadius: 14,
            padding: EdgeInsets.zero,
            blurStrength: 15,
            opacity: 0.6,
            borderOpacity: 0.3,
            child: Icon(
              Icons.assignment_outlined,
              size: 26,
              color: GlassColors.secondaryTextOf(context),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'No assignments yet',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: GlassColors.headingOf(context),
                  ),
                ),
                SizedBox(height: 4),
                Text(
                  'When a teacher posts an assignment for your division or '
                  'batch, it will appear here.',
                  style: TextStyle(
                    fontSize: 13,
                    color: GlassColors.secondaryTextOf(context),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
