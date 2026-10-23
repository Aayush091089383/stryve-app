import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';

import 'announcement.dart';
import 'config/environment.dart';
import 'services/teacher_auth_service.dart';
import 'teacher_assignments_page.dart'
    show
        AssignmentFilesPicker,
        PickedAssignmentFile,
        assignmentContentType,
        defaultPickAssignmentFiles,
        uploadFileName;
import 'teacher_login_page.dart';
import 'utils/glass_container.dart';
import 'utils/linkified_text.dart';
import 'utils/teacher_api.dart';

/// Post an announcement to the student feed, and withdraw one you posted.
///
/// Any active teacher or admin account may post; the backend decides, and the
/// author is always the authenticated account (never anything typed here).
/// `year`/`division` are optional restrictions - leaving both on "Every"
/// posts to every student, which is how a college-wide notice is sent.
///
/// The list below the form is the backend's answer to
/// `GET /teacher/announcements`: a teacher sees their own posts, an admin sees
/// every post. It is exactly the set the delete route accepts, so this screen
/// never offers a delete it would be refused.
class TeacherAnnouncementsPage extends StatefulWidget {
  const TeacherAnnouncementsPage({
    super.key,
    this.authService,
    this.client,
    this.pickFiles,
  });

  final TeacherAuthService? authService;
  final http.Client? client;

  /// Injectable file chooser (production uses the platform picker), so widget
  /// tests never open an OS dialog.
  final AssignmentFilesPicker? pickFiles;

  @override
  State<TeacherAnnouncementsPage> createState() =>
      _TeacherAnnouncementsPageState();
}

class _TeacherAnnouncementsPageState extends State<TeacherAnnouncementsPage> {
  final _formKey = GlobalKey<FormState>();
  final _titleController = TextEditingController();
  final _messageController = TextEditingController();

  late final TeacherAuthService _authService =
      widget.authService ?? TeacherAuthService();
  http.Client? _ownedClient;
  http.Client get _client => widget.client ?? (_ownedClient ??= http.Client());

  /// null = every year / every division.
  int? _year;
  String? _division;

  /// The files picked for the next post; empty keeps it text-only.
  List<PickedAssignmentFile> _files = const [];

  bool _posting = false;
  String? _error;

  /// The announcements this account may delete, newest first.
  List<Announcement> _announcements = const [];
  bool _loadingList = true;
  String? _listError;

  /// Ids with a delete in flight, so a repeated tap cannot send a second one.
  final Set<int> _deleting = <int>{};

  @override
  void initState() {
    super.initState();
    _loadAnnouncements();
  }

  @override
  void dispose() {
    _ownedClient?.close();
    _titleController.dispose();
    _messageController.dispose();
    super.dispose();
  }

  Future<void> _sessionLost() async {
    await _authService.clearAuthData();
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const TeacherLoginPage()),
      (route) => false,
    );
  }

  /// Load the announcements this account may manage.
  Future<void> _loadAnnouncements() async {
    setState(() {
      _loadingList = true;
      _listError = null;
    });

    final token = await _authService.getToken();
    if (!mounted) return;
    if (token == null) {
      await _sessionLost();
      return;
    }

    try {
      final response = await _client
          .get(
            Uri.parse('${Environment.backendUrl}/teacher/announcements'),
            headers: {'Authorization': 'Bearer $token'},
          )
          .timeout(const Duration(seconds: 20));

      if (!mounted) return;

      if (response.statusCode == 401) {
        await _sessionLost();
        return;
      }

      if (response.statusCode != 200) {
        setState(() {
          _listError = teacherMessageFromBody(response);
          _loadingList = false;
        });
        return;
      }

      final decoded = jsonDecode(response.body);
      final loaded = decoded is List
          ? decoded
                .whereType<Map<String, dynamic>>()
                .map(Announcement.fromJson)
                .toList()
          : <Announcement>[];

      setState(() {
        _announcements = loaded;
        _loadingList = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _listError =
            'Could not reach Stryve server. Check your connection and try '
            'again.';
        _loadingList = false;
      });
    }
  }

  /// Choose the PDFs/videos to post with the notice.
  ///
  /// The backend re-checks every file (magic bytes and size) and is the
  /// authority; these checks only keep an obviously wrong pick from spending a
  /// slow upload.
  Future<void> _pickFiles() async {
    try {
      final picked = await (widget.pickFiles ?? defaultPickAssignmentFiles)();
      if (!mounted || picked.isEmpty) return;

      const allowed = <String>{'.pdf', '.mp4', '.mov', '.mkv'};
      const maxBytes = 100 * 1024 * 1024;

      if (picked.length > 10) {
        setState(() => _error = 'At most 10 files can be attached.');
        return;
      }

      for (final file in picked) {
        final lower = file.name.toLowerCase();
        final dot = lower.lastIndexOf('.');
        final extension = dot < 0 ? '' : lower.substring(dot);
        if (!allowed.contains(extension)) {
          setState(
            () => _error = '"${file.name}" is not a PDF, MP4, MOV or MKV file.',
          );
          return;
        }
        if (file.sizeBytes > maxBytes) {
          setState(
            () => _error = '"${file.name}" is larger than 100 MB. Please '
                'choose a smaller file.',
          );
          return;
        }
      }

      setState(() {
        _files = picked;
        _error = null;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = 'Could not read that file. Please try again.');
    }
  }

  /// "CHOOSE PDFS OR VIDEOS (OPTIONAL)", "notes.pdf (820 KB)", "3 files".
  String get _filesLabel {
    if (_files.isEmpty) return 'CHOOSE PDFS OR VIDEOS (OPTIONAL)';
    if (_files.length == 1) {
      final file = _files.single;
      final kb = (file.sizeBytes / 1024).toStringAsFixed(0);
      return '${file.name} ($kb KB)';
    }
    return '${_files.length} FILES SELECTED';
  }

  Future<void> _post() async {
    if (_posting) return;
    if (!(_formKey.currentState?.validate() ?? false)) return;

    final token = await _authService.getToken();
    if (!mounted) return;
    if (token == null) {
      await _sessionLost();
      return;
    }

    setState(() {
      _posting = true;
      _error = null;
    });

    try {
      // Multipart, not JSON: the endpoint takes Form fields plus optional
      // files. Unset restrictions are omitted, which is what makes the post
      // readable by everyone.
      final request = http.MultipartRequest(
        'POST',
        Uri.parse('${Environment.backendUrl}/teacher/announcements'),
      );
      request.headers['Authorization'] = 'Bearer $token';
      request.fields['title'] = _titleController.text.trim();
      request.fields['message'] = _messageController.text.trim();
      if (_year != null) request.fields['year'] = '$_year';
      if (_division != null) request.fields['division'] = _division!;

      for (final picked in _files) {
        final name = uploadFileName(picked.name);
        request.files.add(
          http.MultipartFile.fromBytes(
            'files',
            picked.bytes,
            filename: name,
            contentType: MediaType.parse(assignmentContentType(name)),
          ),
        );
      }

      // Sent through the screen's client so widget tests can inspect the
      // multipart body without a live backend.
      final streamed = await _client.send(request).timeout(
        const Duration(seconds: 60),
      );
      final response = await http.Response.fromStream(streamed);

      if (!mounted) return;

      if (response.statusCode == 201) {
        // The panel shows the confirmation; the form closes so a second post
        // starts clean.
        Navigator.of(context).pop(true);
        return;
      }

      if (response.statusCode == 401) {
        await _sessionLost();
        return;
      }

      setState(() => _error = teacherMessageFromBody(response));
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error =
            'Could not reach Stryve server. Check your connection and try '
            'again.';
      });
    } finally {
      if (mounted) setState(() => _posting = false);
    }
  }

  /// Confirm, then ask the backend to withdraw [announcement].
  Future<void> _deleteAnnouncement(Announcement announcement) async {
    if (_deleting.contains(announcement.id)) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete this announcement?'),
        content: Text(
          '"${announcement.title}" will disappear from every student feed. '
          'This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: TextButton.styleFrom(foregroundColor: GlassColors.error),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    final token = await _authService.getToken();
    if (!mounted) return;
    if (token == null) {
      await _sessionLost();
      return;
    }

    setState(() {
      _deleting.add(announcement.id);
      _listError = null;
    });

    try {
      final response = await _client
          .delete(
            Uri.parse(
              '${Environment.backendUrl}/teacher/announcements/${announcement.id}',
            ),
            headers: {'Authorization': 'Bearer $token'},
          )
          .timeout(const Duration(seconds: 20));

      if (!mounted) return;

      if (response.statusCode == 401) {
        await _sessionLost();
        return;
      }

      if (response.statusCode == 200) {
        setState(() {
          _announcements = _announcements
              .where((row) => row.id != announcement.id)
              .toList();
        });
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(const SnackBar(content: Text('Announcement deleted')));
        return;
      }

      setState(() => _listError = teacherMessageFromBody(response));
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _listError =
            'Could not reach Stryve server. Check your connection and try '
            'again.';
      });
    } finally {
      if (mounted) {
        setState(() => _deleting.remove(announcement.id));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: const GlassAppBar(title: Text('Announcements')),
      body: GlassBackground(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 40),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Form(
                    key: _formKey,
                    child: GlassCard(
                      padding: const EdgeInsets.all(20),
                      margin: EdgeInsets.zero,
                      borderRadius: 20,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'New announcement',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              color: GlassColors.headingOf(context),
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'It appears in every student\'s feed that matches '
                            'the audience below.',
                            style: TextStyle(
                              fontSize: 13,
                              color: GlassColors.secondaryTextOf(context),
                            ),
                          ),
                          const SizedBox(height: 20),
                          TextFormField(
                            controller: _titleController,
                            textCapitalization: TextCapitalization.sentences,
                            textInputAction: TextInputAction.next,
                            maxLength: 200,
                            decoration: const InputDecoration(
                              labelText: 'Title',
                              hintText: 'e.g. Mid-term exam schedule',
                            ),
                            validator: (value) {
                              final text = (value ?? '').trim();
                              if (text.isEmpty) return 'Title is required';
                              if (text.length > 200) {
                                return 'Title must be at most 200 characters';
                              }
                              return null;
                            },
                          ),
                          const SizedBox(height: 4),
                          TextFormField(
                            controller: _messageController,
                            minLines: 5,
                            maxLines: 10,
                            textCapitalization: TextCapitalization.sentences,
                            decoration: const InputDecoration(
                              labelText: 'Message',
                              hintText: 'What students need to know',
                              alignLabelWithHint: true,
                            ),
                            validator: (value) {
                              final text = (value ?? '').trim();
                              if (text.isEmpty) return 'Message is required';
                              if (text.length > 5000) {
                                return 'Message must be at most 5000 characters';
                              }
                              return null;
                            },
                          ),
                          const SizedBox(height: 20),
                          Text(
                            'Audience',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: GlassColors.headingOf(context),
                            ),
                          ),
                          const SizedBox(height: 10),
                          Row(
                            children: [
                              Expanded(
                                child: DropdownButtonFormField<int?>(
                                  initialValue: _year,
                                  decoration: const InputDecoration(
                                    labelText: 'Year',
                                  ),
                                  items: const [
                                    DropdownMenuItem<int?>(
                                      value: null,
                                      child: Text('Every year'),
                                    ),
                                    DropdownMenuItem<int?>(
                                      value: 1,
                                      child: Text('Year 1'),
                                    ),
                                    DropdownMenuItem<int?>(
                                      value: 2,
                                      child: Text('Year 2'),
                                    ),
                                    DropdownMenuItem<int?>(
                                      value: 3,
                                      child: Text('Year 3'),
                                    ),
                                    DropdownMenuItem<int?>(
                                      value: 4,
                                      child: Text('Year 4'),
                                    ),
                                    DropdownMenuItem<int?>(
                                      value: 5,
                                      child: Text('Year 5'),
                                    ),
                                  ],
                                  onChanged: _posting
                                      ? null
                                      : (value) => setState(() => _year = value),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: DropdownButtonFormField<String?>(
                                  initialValue: _division,
                                  decoration: const InputDecoration(
                                    labelText: 'Division',
                                  ),
                                  items: const [
                                    DropdownMenuItem<String?>(
                                      value: null,
                                      child: Text('Every division'),
                                    ),
                                    DropdownMenuItem<String?>(
                                      value: 'D',
                                      child: Text('Division D'),
                                    ),
                                  ],
                                  onChanged: _posting
                                      ? null
                                      : (value) =>
                                            setState(() => _division = value),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Text(
                            _year == null && _division == null
                                ? 'Both on "Every" posts to every student.'
                                : 'Only students matching the audience above '
                                      'will see this.',
                            style: TextStyle(
                              fontSize: 12,
                              color: GlassColors.secondaryTextOf(context),
                            ),
                          ),
                          const SizedBox(height: 20),
                          Text(
                            'Attachments (optional)',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: GlassColors.headingOf(context),
                            ),
                          ),
                          const SizedBox(height: 10),
                          GlassOutlinedButton(
                            onPressed: _posting ? null : _pickFiles,
                            height: 46,
                            borderRadius: 12,
                            child: Text(
                              _filesLabel,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                color: GlassColors.primaryBlue,
                              ),
                            ),
                          ),
                          const SizedBox(height: 6),
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  'PDF or video · up to 10 files · 100 MB each',
                                  style: TextStyle(
                                    fontSize: 11.5,
                                    color: GlassColors.secondaryTextOf(context),
                                  ),
                                ),
                              ),
                              if (_files.isNotEmpty)
                                TextButton(
                                  onPressed: _posting
                                      ? null
                                      : () => setState(
                                          () => _files = const [],
                                        ),
                                  child: const Text(
                                    'Clear',
                                    style: TextStyle(fontSize: 12),
                                  ),
                                ),
                            ],
                          ),
                          if (_error != null) ...[
                            const SizedBox(height: 16),
                            Text(
                              _error!,
                              style: const TextStyle(
                                fontSize: 13,
                                color: GlassColors.error,
                              ),
                            ),
                          ],
                          const SizedBox(height: 24),
                          GlassButton(
                            onPressed: _posting ? null : _post,
                            disabled: _posting,
                            color: GlassColors.primaryBlue,
                            height: 52,
                            borderRadius: 14,
                            child: Text(
                              _posting ? 'Posting…' : 'Post',
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  _buildManageSection(context),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The posts this account may withdraw, with the delete affordance.
  ///
  /// Plain rows rather than one glass card per announcement: this list can be
  /// long, and every glass surface is a backdrop blur pass on the same screen
  /// as the compose form.
  Widget _buildManageSection(BuildContext context) {
    final secondary = GlassColors.secondaryTextOf(context);

    return GlassCard(
      padding: const EdgeInsets.all(20),
      margin: EdgeInsets.zero,
      borderRadius: 20,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Posted announcements',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: GlassColors.headingOf(context),
                  ),
                ),
              ),
              if (!_loadingList && _listError == null)
                Text(
                  _announcements.length == 1
                      ? '1 live'
                      : '${_announcements.length} live',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: secondary,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Deleting removes a notice from every student feed.',
            style: TextStyle(fontSize: 12, color: secondary),
          ),
          const SizedBox(height: 8),
          if (_loadingList)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Center(
                child: CircularProgressIndicator(
                  valueColor: AlwaysStoppedAnimation<Color>(
                    GlassColors.primaryBlue,
                  ),
                ),
              ),
            )
          else ...[
            // An error is shown *above* the list, never instead of it: a
            // refused delete must not make the announcements look gone.
            if (_listError != null) ...[
              const SizedBox(height: 8),
              Text(
                _listError!,
                style: const TextStyle(fontSize: 13, color: GlassColors.error),
              ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: GlassOutlinedButton(
                  onPressed: _loadAnnouncements,
                  width: 120,
                  height: 38,
                  borderRadius: 12,
                  child: const Text(
                    'Try again',
                    style: TextStyle(fontSize: 13),
                  ),
                ),
              ),
              if (_announcements.isNotEmpty) const SizedBox(height: 4),
            ],
            if (_announcements.isEmpty && _listError == null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Text(
                  'Nothing posted yet. Announcements you publish appear here.',
                  style: TextStyle(fontSize: 13, color: secondary),
                ),
              )
            else
              for (var i = 0; i < _announcements.length; i++) ...[
                if (i > 0)
                  Divider(
                    height: 24,
                    color: GlassColors.borderOf(context),
                  ),
                _buildManageRow(context, _announcements[i]),
              ],
          ],
        ],
      ),
    );
  }

  Widget _buildManageRow(BuildContext context, Announcement announcement) {
    final secondary = GlassColors.secondaryTextOf(context);
    final isDeleting = _deleting.contains(announcement.id);
    final audience = announcement.audienceLabel;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    announcement.title,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: GlassColors.headingOf(context),
                    ),
                  ),
                  if (audience != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      audience,
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: GlassColors.primaryBlue,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              onPressed: isDeleting
                  ? null
                  : () => _deleteAnnouncement(announcement),
              tooltip: 'Delete announcement',
              visualDensity: VisualDensity.compact,
              icon: isDeleting
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.delete_outline, size: 20),
              color: GlassColors.error,
            ),
          ],
        ),
        const SizedBox(height: 6),
        // A link a teacher typed in the notice is meant to be tapped, not
        // copied by hand.
        LinkifiedText(
          announcement.message,
          style: TextStyle(fontSize: 13, height: 1.4, color: secondary),
          linkStyle: const TextStyle(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        Text(
          '${announcement.authorName} · ${announcement.postedLabel}',
          style: TextStyle(fontSize: 11, color: secondary),
        ),
      ],
    );
  }
}
