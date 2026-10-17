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

  const AssignmentsPage({
    super.key,
    required this.student,
    this.client,
    this.loadPdf,
    this.savePdf,
    this.surfaceFactory,
    this.embedded = false,
  });

  @override
  State<AssignmentsPage> createState() => _AssignmentsPageState();
}

class _AssignmentsPageState extends State<AssignmentsPage> {
  bool _isLoading = true;
  String? _errorMessage;
  List<Assignment> _assignments = const [];

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

  Future<void> _fetchAssignments({bool forceRefresh = false}) async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

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
        final response = await (widget.client?.get(uri, headers: headers) ??
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
          setState(() {
            _errorMessage =
                'Could not load assignments (${response.statusCode})';
            _isLoading = false;
          });
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
      if (!mounted) return;
      setState(() {
        _errorMessage =
            'Could not connect to CampusSync server. Please check your internet connection and try again.';
        _isLoading = false;
      });
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
              child: CircularProgressIndicator(
                color: GlassColors.primaryBlue,
              ),
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
                style: const TextStyle(
                  color: GlassColors.secondaryText,
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
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
      children: [
        const Text(
          'All Assignments',
          style: TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.bold,
            color: GlassColors.heading,
          ),
        ),
        const SizedBox(height: 6),
        const Text(
          'Everything posted for your division and batch.',
          style: TextStyle(fontSize: 13, color: GlassColors.secondaryText),
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
            child: const Icon(
              Icons.assignment_outlined,
              size: 26,
              color: GlassColors.secondaryText,
            ),
          ),
          const SizedBox(width: 16),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'No assignments yet',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: GlassColors.heading,
                  ),
                ),
                SizedBox(height: 4),
                Text(
                  'When a teacher posts an assignment for your division or '
                  'batch, it will appear here.',
                  style: TextStyle(
                    fontSize: 13,
                    color: GlassColors.secondaryText,
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
