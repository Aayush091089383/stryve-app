import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'assignment.dart';
import 'assignment_pdf_viewer_page.dart';
import 'role_selection_page.dart';
import 'student.dart';
import 'config/environment.dart';
import 'services/assignment_pdf_service.dart';
import 'services/auth_service.dart';
import 'services/api_cache.dart';
import 'utils/assignment_card.dart';
import 'utils/glass_container.dart';
import 'utils/motion.dart';
import 'utils/pdf_surface.dart';

// Assignment has moved to assignment.dart (the viewer needs the same model);
// re-exported so existing importers of this file keep working.
export 'assignment.dart';

class TasksPage extends StatefulWidget {
  final Student student;

  /// Injection seams for tests; production leaves them null and the app uses
  /// the real authenticated endpoint, the pdfrx surface and the device saver.
  final http.Client? client;
  final AssignmentPdfLoad? loadPdf;
  final AssignmentPdfSave? savePdf;
  final PdfSurfaceFactory? surfaceFactory;

  const TasksPage({
    super.key,
    required this.student,
    this.client,
    this.loadPdf,
    this.savePdf,
    this.surfaceFactory,
  });

  @override
  State<TasksPage> createState() => _TasksPageState();
}

class _TasksPageState extends State<TasksPage> {
  bool isLoading = true;
  String? errorMessage;
  List<Assignment> assignments = [];

  /// True while the viewer route is being pushed, so a second tap on the same
  /// card cannot open it twice.
  bool _openingViewer = false;

  /// Opens the attached PDF in the in-app reader.
  ///
  /// Reading is not downloading: the viewer fetches the file through the
  /// authorized endpoint and holds it in memory. The student only ever gets a
  /// saved copy by tapping Download inside the viewer. The backend decides
  /// whether this student may see the file at all; a 403 is never worked around
  /// in the app.
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

  @override
  void initState() {
    super.initState();
    fetchAssignments();
  }

  Future<void> fetchAssignments({bool forceRefresh = false}) async {
    setState(() {
      isLoading = true;
      errorMessage = null;
    });

    try {
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
          final authService = AuthService();
          await authService.clearAuthData();

          if (!mounted) return;

          Navigator.of(context).pushAndRemoveUntil(
            MaterialPageRoute(builder: (context) => const RoleSelectionPage()),
            (route) => false,
          );

          return;
        }

        if (response.statusCode != 200) {
          setState(() {
            errorMessage =
                'Could not load assignments (${response.statusCode})';
            isLoading = false;
          });

          return;
        }

        responseBody = response.body;
        ApiCache.set(cacheKey, responseBody);
      }

      final List<dynamic> rawAssignments = jsonDecode(responseBody);

      final loaded = rawAssignments.map((a) => Assignment.fromJson(a)).toList();

      loaded.sort((a, b) => a.dueDate.compareTo(b.dueDate));

      setState(() {
        assignments = loaded;
        isLoading = false;
      });
    } catch (e) {
      setState(() {
        errorMessage = 'Could not connect to Stryve server. Please check your internet connection and try again.';
        isLoading = false;
      });
    }
  }

  String formatDueDate(String rawDate) => formatAssignmentDueDate(rawDate);

  @override
  Widget build(BuildContext context) {
    return _TasksContent(
      student: widget.student,
      isLoading: isLoading,
      errorMessage: errorMessage,
      assignments: assignments,
      onRefresh: fetchAssignments,
      formatDueDate: formatDueDate,
      onOpen: _openAssignment,
    );
  }
}

class _TasksContent extends StatelessWidget {
  final Student student;
  final bool isLoading;
  final String? errorMessage;
  final List<Assignment> assignments;
  final Future<void> Function({bool forceRefresh}) onRefresh;
  final String Function(String) formatDueDate;
  final Future<void> Function(Assignment) onOpen;

  const _TasksContent({
    required this.student,
    required this.isLoading,
    required this.errorMessage,
    required this.assignments,
    required this.onRefresh,
    required this.formatDueDate,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: motionDuration(context, kMotionStandard),
      switchInCurve: Curves.easeOut,
      switchOutCurve: Curves.easeIn,
      child: isLoading
          ? const Center(
              key: ValueKey('tasks-loading'),
              child: CircularProgressIndicator(color: GlassColors.primaryBlue),
            )
          : errorMessage != null
          ? KeyedSubtree(
              key: const ValueKey('tasks-error'),
              child: _buildError(context),
            )
          : KeyedSubtree(
              key: const ValueKey('tasks-content'),
              child: _buildTaskList(context),
            ),
    );
  }

  Widget _buildError(BuildContext context) {
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
                errorMessage!,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: GlassColors.secondaryTextOf(context),
                  fontSize: 15,
                ),
              ),
              const SizedBox(height: 24),
              GlassButton(
                onPressed: () => onRefresh(forceRefresh: true),
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

  Widget _buildTaskList(BuildContext context) {
    final media = MediaQuery.of(context);
    final double topPadding = media.padding.top + kToolbarHeight + 8;
    final double bottomPadding = media.padding.bottom + 76 + 8;

    final pendingWidgets = <Widget>[
      Text(
        'Pending Tasks',
        style: TextStyle(
          fontSize: 22,
          fontWeight: FontWeight.bold,
          color: GlassColors.headingOf(context),
        ),
      ),
      const SizedBox(height: 16),
    ];

    if (assignments.isEmpty) {
      pendingWidgets.add(
        _buildEmptyState(
          context: context,
          icon: Icons.assignment_turned_in_rounded,
          title: 'No pending tasks',
          subtitle:
              'New assignments will show up here as soon as they\'re posted.',
        ),
      );
    } else {
      pendingWidgets.addAll(
        assignments.map(
          (a) => AssignmentCard(
            subject: a.subject,
            title: a.title,
            dueDate: formatDueDate(a.dueDate),
            batch: a.batch,
            hasAttachment: a.hasAttachment,
            attachmentName: a.attachmentName,
            onOpen: () => onOpen(a),
          ),
        ),
      );
    }

    pendingWidgets.addAll([
      const SizedBox(height: 28),
      Text(
        'Completed',
        style: TextStyle(
          fontSize: 22,
          fontWeight: FontWeight.bold,
          color: GlassColors.headingOf(context),
        ),
      ),
      const SizedBox(height: 16),
      _buildEmptyState(
        context: context,
        icon: Icons.check_circle_outline_rounded,
        title: 'No completed tasks',
        subtitle: 'Completed assignments will appear here.',
      ),
    ]);

    return ListView(
      padding: EdgeInsets.fromLTRB(20, topPadding, 20, bottomPadding),
      children: pendingWidgets,
    );
  }

  Widget _buildEmptyState({
    required BuildContext context,
    required IconData icon,
    required String title,
    required String subtitle,
  }) {
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
              icon,
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
                  title,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: GlassColors.headingOf(context),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  subtitle,
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
