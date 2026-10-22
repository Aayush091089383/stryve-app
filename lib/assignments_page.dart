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
import 'utils/linkified_text.dart';
import 'utils/motion.dart';
import 'utils/pdf_surface.dart';
import 'utils/video_surface.dart';
import 'video_player_page.dart';

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
  final VideoSurfaceFactory? videoSurfaceFactory;

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
    this.videoSurfaceFactory,
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

  /// Subjects the student has opened.
  ///
  /// Empty means every folder starts closed, which is the point of grouping:
  /// seven open folders is the flat list with extra headers. Opening is a
  /// reading preference for this visit only, so it is not stored anywhere.
  final Set<String> _expandedSubjects = <String>{};

  @override
  void initState() {
    super.initState();
    _fetchAssignments();
  }

  Future<void> _openAssignment(
    Assignment assignment, {
    AssignmentAttachment? file,
    List<Assignment>? siblings,
  }) async {
    if (_openingViewer) return;
    _openingViewer = true;
    try {
      // The rows of the same subject, so the reader's Previous/Next walks the
      // folder that was opened rather than jumping to a different subject.
      // The viewer skips the rows without a PDF and finds the tapped one by id.
      final group = siblings ?? _assignments;
      // The tapped file decides the screen (and the endpoint); with no explicit
      // file the assignment's primary one is opened, exactly as before.
      final target = file ?? assignment.primaryFile;
      final attachmentId = target == null || target.isLegacy ? null : target.id;
      final isVideo = target?.isVideo ?? assignment.isVideo;

      await Navigator.of(context).push(
        MaterialPageRoute(
          // The file decides the screen: a video streams in the player, a PDF
          // renders in the reader. Both go through the same authorized
          // endpoint, so the backend still decides who may open what.
          builder: (context) => isVideo
              ? VideoPlayerPage(
                  assignment: assignment,
                  assignments: group,
                  initialIndex: group.indexWhere(
                    (row) => row.id == assignment.id,
                  ),
                  attachmentId: attachmentId,
                  token: widget.student.token,
                  surfaceFactory: widget.videoSurfaceFactory,
                )
              : AssignmentPdfViewerPage(
                  assignment: assignment,
                  assignments: group,
                  initialIndex: group.indexWhere(
                    (row) => row.id == assignment.id,
                  ),
                  attachmentId: attachmentId,
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

  /// The fetched rows grouped by subject, alphabetically by subject name.
  ///
  /// Several uploads for one subject stay inside that subject's section
  /// instead of becoming several look-alike top-level cards. Within a section
  /// the soonest deadline comes first and same-day uploads fall back to the
  /// oldest id, so a subject reads in the order its work was set: the first
  /// assignment at the top, the latest upload at the bottom.
  List<_SubjectSectionData> _groupedAssignments() {
    final bySubject = <String, List<Assignment>>{};
    for (final assignment in _assignments) {
      // A blank subject is still one group, never a key that disappears.
      final subject = assignment.subject.trim().isEmpty
          ? 'General'
          : assignment.subject.trim();
      bySubject.putIfAbsent(subject, () => <Assignment>[]).add(assignment);
    }

    final subjects = bySubject.keys.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

    return subjects.map((subject) {
      final rows = bySubject[subject]!
        ..sort((a, b) {
          final byDue = a.dueDate.compareTo(b.dueDate);
          return byDue != 0 ? byDue : a.id.compareTo(b.id);
        });
      return _SubjectSectionData(subject: subject, rows: rows);
    }).toList();
  }

  void _toggleSubject(String subject) {
    setState(() {
      if (!_expandedSubjects.remove(subject)) {
        _expandedSubjects.add(subject);
      }
    });
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

    final groups = _groupedAssignments();

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
            _assignments.isEmpty
                ? 'Everything posted for your division and batch.'
                : 'Everything posted for your division and batch, grouped '
                      'by subject. Tap a subject to open it.',
            style: TextStyle(
              fontSize: 13,
              color: GlassColors.secondaryTextOf(context),
            ),
          ),
          const SizedBox(height: 16),
          if (_assignments.isEmpty)
            _buildEmptyState()
          else
            ...groups.map(
              (group) => _SubjectSection(
                key: ValueKey('subject-${group.subject}'),
                data: group,
                expanded: _expandedSubjects.contains(group.subject),
                onToggle: () => _toggleSubject(group.subject),
                onOpen: (assignment, file) => _openAssignment(
                  assignment,
                  file: file,
                  siblings: group.rows,
                ),
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

/// The description the backend seeds on a subject's "nothing uploaded" row.
/// Such a row is a placeholder, not coursework: it carries no file, its title
/// is just the subject name and its due date is the end of the academic year.
const String _kPlaceholderDescription = 'No assignment posted yet.';

bool _isPlaceholder(Assignment assignment, String subject) {
  if (assignment.hasAttachment) return false;
  final title = assignment.title.trim().toLowerCase();
  final description = assignment.description?.trim() ?? '';
  return title == subject.trim().toLowerCase() ||
      description == _kPlaceholderDescription;
}

/// One subject's rows, before any widget is built.
///
/// The backend keeps assignments flat (one row per upload, `subject` is just a
/// text column); the folder the student sees is created here, on the client.
class _SubjectSectionData {
  const _SubjectSectionData({required this.subject, required this.rows});

  final String subject;

  /// Sorted by [AssignmentsPage]: soonest deadline first, then newest id.
  final List<Assignment> rows;

  /// Rows a student can actually open. Only these count as "files": a
  /// placeholder row is not coursework, so it must never be counted as one.
  List<Assignment> get files =>
      rows.where((row) => row.hasAttachment).toList();

  /// Rows without a file - the seeded placeholders, and any older text-only
  /// assignment a teacher posted before uploads existed.
  List<Assignment> get filelessRows =>
      rows.where((row) => !row.hasAttachment).toList();

  /// What the folder shows when opened.
  ///
  /// A single placeholder under a folder that already holds real PDFs is pure
  /// noise ("No assignment posted yet" next to two files), so it is dropped as
  /// soon as the folder has anything real in it. A folder with nothing real
  /// still explains itself instead of looking broken.
  List<Assignment> get visibleRows =>
      files.isNotEmpty ? files : filelessRows;

  /// "2 files · due 21 Oct 2026", "No files yet" - the header has to say
  /// something useful while the folder is closed.
  String get summary {
    if (files.isEmpty) return 'No files yet';
    final count = files.length == 1 ? '1 file' : '${files.length} files';
    return '$count · due ${formatAssignmentDueDate(files.first.dueDate)}';
  }
}

/// One subject, foldable. The accordion itself is not [ExpansionTile]: that
/// widget brings its own Material chrome (dividers, list-tile padding, a
/// full-width ink background) that would sit on top of the glass treatment,
/// and it cannot collapse *animatedly* without `maintainState` quirks. This is
/// the same interaction - tap the header, the children slide open or shut.
class _SubjectSection extends StatelessWidget {
  const _SubjectSection({
    super.key,
    required this.data,
    required this.expanded,
    required this.onToggle,
    required this.onOpen,
  });

  final _SubjectSectionData data;
  final bool expanded;
  final VoidCallback onToggle;
  final void Function(Assignment assignment, AssignmentAttachment? file) onOpen;

  @override
  Widget build(BuildContext context) {
    final secondary = GlassColors.secondaryTextOf(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GlassCard(
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          onTap: onToggle,
          child: Row(
            children: [
              GlassContainer(
                width: 44,
                height: 44,
                borderRadius: 12,
                padding: EdgeInsets.zero,
                blurStrength: 15,
                opacity: 0.7,
                borderOpacity: 0.4,
                child: Icon(
                  expanded
                      ? Icons.folder_open_rounded
                      : Icons.folder_rounded,
                  size: 22,
                  color: GlassColors.primaryBlue,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      data.subject,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                        color: GlassColors.headingOf(context),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      data.summary,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: secondary),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              AnimatedRotation(
                turns: expanded ? 0.5 : 0,
                duration: motionDuration(context, kMotionStandard),
                curve: Curves.easeOut,
                child: Icon(
                  Icons.expand_more_rounded,
                  size: 24,
                  color: secondary,
                ),
              ),
            ],
          ),
        ),
        AnimatedSize(
          duration: motionDuration(context, kMotionStandard),
          curve: Curves.easeOut,
          alignment: Alignment.topCenter,
          // Collapsed renders nothing at all, so a folded folder never leaves
          // its cards in the tree (nor in a screen reader's order).
          child: expanded
              ? Column(
                  children: [
                    for (final assignment in data.visibleRows)
                      Padding(
                        padding: const EdgeInsets.only(left: 10),
                        child: _isPlaceholder(assignment, data.subject)
                            ? const _NoAssignmentRow()
                            : _AssignmentFileRow(
                                assignment: assignment,
                                onOpenFile: (file) =>
                                    onOpen(assignment, file),
                              ),
                      ),
                  ],
                )
              : const SizedBox(width: double.infinity),
        ),
      ],
    );
  }
}

/// One PDF inside a subject folder.
///
/// Deliberately lighter than [AssignmentCard]: the subject is already the
/// header this row sits under, so repeating it would be noise, and a nested
/// row must not compete with the folder that owns it.
class _AssignmentFileRow extends StatelessWidget {
  const _AssignmentFileRow({
    required this.assignment,
    required this.onOpenFile,
  });

  final Assignment assignment;
  final void Function(AssignmentAttachment file) onOpenFile;

  @override
  Widget build(BuildContext context) {
    final secondary = GlassColors.secondaryTextOf(context);
    final description = assignment.description?.trim() ?? '';
    final files = assignment.files;
    final hasFile = files.isNotEmpty;
    // Tapping the card is only unambiguous when there is nothing to choose
    // between; with several files the student taps the one they want.
    final onlyFile = files.length == 1 ? files.first : null;

    return GlassCard(
      // A flat tint: this sits on the page's already-blurred background and a
      // filter per row would cost a full blur pass for nothing visible.
      useBlur: false,
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      borderRadius: 14,
      onTap: onlyFile == null ? null : () => onOpenFile(onlyFile),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              GlassContainer(
                width: 40,
                height: 40,
                borderRadius: 10,
                padding: EdgeInsets.zero,
                blurStrength: 12,
                opacity: 0.65,
                borderOpacity: 0.35,
                child: Icon(
                  !hasFile
                      ? Icons.assignment_outlined
                      : files.length > 1
                      ? Icons.attach_file_rounded
                      : onlyFile!.isVideo
                      ? Icons.play_circle_fill_rounded
                      : Icons.picture_as_pdf_rounded,
                  size: 20,
                  color: hasFile ? GlassColors.primaryBlue : secondary,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      assignment.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: GlassColors.headingOf(context),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Wrap(
                      spacing: 10,
                      runSpacing: 6,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.calendar_today_rounded,
                              size: 12,
                              color: secondary,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              'Due: ${formatAssignmentDueDate(assignment.dueDate)}',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w500,
                                color: secondary,
                              ),
                            ),
                          ],
                        ),
                        if (assignment.batch != null)
                          GlassContainer(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 2,
                            ),
                            borderRadius: 7,
                            blurStrength: 10,
                            opacity: 0.6,
                            borderOpacity: 0.3,
                            child: Text(
                              assignment.batch!,
                              style: const TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: GlassColors.primaryBlue,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              if (onlyFile != null) ...[
                const SizedBox(width: 8),
                Icon(Icons.chevron_right_rounded, size: 20, color: secondary),
              ],
            ],
          ),
          if (description.isNotEmpty) ...[
            const SizedBox(height: 8),
            // A link a teacher typed in the instructions is meant to be
            // tapped, not read out.
            LinkifiedText(
              description,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, height: 1.35, color: secondary),
              linkStyle: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ],
          if (hasFile) ...[
            const SizedBox(height: 10),
            if (onlyFile != null)
              _AttachmentLine(
                file: onlyFile,
                onOpen: () => onOpenFile(onlyFile),
              )
            else
              // Several files: one line each, so every attachment can be
              // opened on its own instead of guessing which one a single
              // "READ PDF" button meant.
              Column(
                children: [
                  for (final file in files)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: _AttachmentLine(
                        file: file,
                        onOpen: () => onOpenFile(file),
                      ),
                    ),
                ],
              ),
          ],
        ],
      ),
    );
  }
}

/// One file inside an assignment row: its name, and the one action it
/// supports (read a PDF, play a video).
class _AttachmentLine extends StatelessWidget {
  const _AttachmentLine({required this.file, required this.onOpen});

  final AssignmentAttachment file;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final secondary = GlassColors.secondaryTextOf(context);
    final name = file.name.trim().isEmpty ? 'Attached file' : file.name.trim();

    return Row(
      children: [
        Icon(
          file.isVideo
              ? Icons.play_circle_outline_rounded
              : Icons.picture_as_pdf_outlined,
          size: 16,
          color: GlassColors.primaryBlue,
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, color: secondary),
          ),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 118,
          child: GlassButton(
            onPressed: onOpen,
            color: GlassColors.primaryBlue,
            height: 34,
            borderRadius: 9,
            child: Text(
              file.isVideo ? 'PLAY VIDEO' : 'READ PDF',
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// The "nothing here yet" row of a folder with no files.
///
/// Deliberately not an [_AssignmentFileRow]: the placeholder carries the
/// subject's name as its title and the academic year's end as its due date, so
/// rendering it as a card would repeat the folder's own name and invent a
/// deadline. One muted line says the same thing without either.
class _NoAssignmentRow extends StatelessWidget {
  const _NoAssignmentRow();

  @override
  Widget build(BuildContext context) {
    final secondary = GlassColors.secondaryTextOf(context);

    return GlassCard(
      useBlur: false,
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      borderRadius: 14,
      child: Row(
        children: [
          Icon(Icons.info_outline_rounded, size: 18, color: secondary),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'No assignment posted yet.',
              style: TextStyle(
                fontSize: 12.5,
                height: 1.3,
                color: secondary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
