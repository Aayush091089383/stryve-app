import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';

import 'config/environment.dart';
import 'services/teacher_auth_service.dart';
import 'teacher_models.dart';
import 'utils/glass_container.dart';
import 'utils/teacher_api.dart';

/// A PDF the teacher picked from the device.
class PickedAssignmentFile {
  const PickedAssignmentFile({required this.name, required this.bytes});

  final String name;
  final List<int> bytes;

  int get sizeBytes => bytes.length;
}

/// How a PDF is chosen. Injectable so widget tests can supply bytes without an
/// OS file dialog; production uses the platform file chooser.
typedef AssignmentFilePicker = Future<PickedAssignmentFile?> Function();

/// The seven subjects of Division D's first-year timetable, in the wording the
/// official sheet uses. The backend replaces a subject's text-only row with the
/// upload, so the label a teacher picks is the label stored on the assignment.
const List<String> kAssignmentSubjects = <String>[
  'Engineering Mathematics-I',
  'Engineering Physics',
  'Basic Electrical Engineering',
  'Engineering Graphics',
  'Fundamentals of Programming Languages',
  'Design Thinking & Idea Lab',
  'Professional Communication Skills',
];

Future<PickedAssignmentFile?> defaultPickPdf() async {
  const typeGroup = XTypeGroup(
    label: 'PDF',
    extensions: <String>['pdf'],
    mimeTypes: <String>['application/pdf'],
  );
  final file = await openFile(acceptedTypeGroups: <XTypeGroup>[typeGroup]);
  if (file == null) return null;
  final bytes = await file.readAsBytes();
  return PickedAssignmentFile(name: file.name, bytes: bytes);
}

/// Assignments tab: upload a PDF assignment and manage the ones you uploaded.
///
/// The backend decides what may be uploaded (`POST
/// /teacher/assignments/upload` validates the file type, the size, the metadata
/// and the caller) and what a student may later download.
class TeacherAssignmentsView extends StatefulWidget {
  const TeacherAssignmentsView({
    super.key,
    required this.authService,
    required this.client,
    this.pickFile,
    this.onSessionExpired,
  });

  final TeacherAuthService authService;
  final http.Client client;
  final AssignmentFilePicker? pickFile;
  final Future<void> Function()? onSessionExpired;

  @override
  State<TeacherAssignmentsView> createState() => _TeacherAssignmentsViewState();
}

class _TeacherAssignmentsViewState extends State<TeacherAssignmentsView> {
  List<AssignmentRecord> _assignments = const [];
  bool _isLoading = true;
  bool _isRefreshing = false;
  bool _isUploading = false;
  String? _loadError;
  int? _deletingId;

  @override
  void initState() {
    super.initState();
    _fetchMine();
  }

  Future<void> _fetchMine({bool isRefresh = false}) async {
    if (isRefresh) {
      setState(() => _isRefreshing = true);
    } else {
      setState(() {
        _isLoading = true;
        _loadError = null;
      });
    }

    try {
      final token = await widget.authService.getToken();
      if (!mounted) return;
      if (token == null) {
        await _sessionLost();
        return;
      }

      final response = await widget.client
          .get(
            Uri.parse('${Environment.backendUrl}/teacher/assignments/mine'),
            headers: teacherHeaders(token),
          )
          .timeout(kTeacherRequestTimeout);

      if (!mounted) return;

      if (response.statusCode == 200) {
        setState(() {
          _assignments = teacherJsonList(response.body)
              .map(AssignmentRecord.fromJson)
              .toList();
          _loadError = null;
        });
      } else if (response.statusCode == 401) {
        await _sessionLost();
      } else {
        setState(() => _loadError = teacherMessageFromBody(response));
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadError = kTeacherUnreachableMessage);
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _isRefreshing = false;
        });
      }
    }
  }

  Future<void> _sessionLost() async {
    if (widget.onSessionExpired != null) {
      await widget.onSessionExpired!();
      return;
    }
    await widget.authService.clearAuthData();
  }

  void _showSnackBar(String message, {Color? color}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message), backgroundColor: color));
  }

  Future<void> _startUpload() async {
    final picker = widget.pickFile ?? defaultPickPdf;

    final payload = await showModalBottomSheet<_UploadPayload>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _AssignmentUploadSheet(pickFile: picker),
    );

    if (payload == null || !mounted) return;
    await _upload(payload);
  }

  Future<void> _upload(_UploadPayload payload) async {
    if (_isUploading) return;

    final token = await widget.authService.getToken();
    if (!mounted) return;
    if (token == null) {
      await _sessionLost();
      return;
    }

    setState(() => _isUploading = true);

    try {
      final request = http.MultipartRequest(
        'POST',
        Uri.parse('${Environment.backendUrl}/teacher/assignments/upload'),
      );
      request.headers['Authorization'] = 'Bearer $token';
      request.fields['title'] = payload.title;
      request.fields['subject'] = payload.subject;
      request.fields['description'] = payload.instructions;
      request.fields['due_date'] = payload.dueDate;
      request.fields['year'] = '${payload.year}';
      request.fields['division'] = payload.division;
      request.fields['batch'] = payload.batch;
      request.files.add(
        http.MultipartFile.fromBytes(
          'file',
          payload.file.bytes,
          filename: payload.file.name,
          contentType: MediaType('application/pdf', 'pdf'),
        ),
      );

      // Sent through the view's client (not request.send()) so widget tests can
      // inspect the multipart body without a live backend.
      final streamed = await widget.client
          .send(request)
          .timeout(const Duration(seconds: 60));
      final response = await http.Response.fromStream(streamed);

      if (!mounted) return;

      if (response.statusCode == 201) {
        _showSnackBar(
          'Assignment uploaded successfully',
          color: GlassColors.success,
        );
        await _fetchMine(isRefresh: true);
      } else if (response.statusCode == 401) {
        await _sessionLost();
      } else {
        _showSnackBar(teacherMessageFromBody(response));
      }
    } catch (_) {
      if (!mounted) return;
      _showSnackBar(kTeacherUnreachableMessage);
    } finally {
      if (mounted) setState(() => _isUploading = false);
    }
  }

  Future<void> _delete(AssignmentRecord assignment) async {
    if (_deletingId != null) return;

    final confirmed =
        await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            title: const Text('Remove assignment'),
            content: Text(
              'Remove "${assignment.title}" and its uploaded file? Students '
              'will no longer see it.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, true),
                style: TextButton.styleFrom(foregroundColor: GlassColors.error),
                child: const Text('Remove'),
              ),
            ],
          ),
        ) ??
        false;

    if (!confirmed || !mounted) return;

    final token = await widget.authService.getToken();
    if (!mounted) return;
    if (token == null) {
      await _sessionLost();
      return;
    }

    setState(() => _deletingId = assignment.id);

    try {
      final response = await widget.client
          .delete(
            Uri.parse(
              '${Environment.backendUrl}/teacher/assignments/${assignment.id}',
            ),
            headers: teacherHeaders(token),
          )
          .timeout(kTeacherRequestTimeout);

      if (!mounted) return;

      if (response.statusCode == 200) {
        _showSnackBar('Assignment removed', color: GlassColors.success);
        await _fetchMine(isRefresh: true);
      } else if (response.statusCode == 401) {
        await _sessionLost();
      } else {
        _showSnackBar(teacherMessageFromBody(response));
      }
    } catch (_) {
      if (!mounted) return;
      _showSnackBar(kTeacherUnreachableMessage);
    } finally {
      if (mounted) setState(() => _deletingId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 40),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: kTeacherMaxContentWidth),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'My Assignments',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: GlassColors.headingOf(context),
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 40,
                    height: 40,
                    child: IconButton(
                      icon: _isRefreshing
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.refresh_rounded),
                      onPressed: _isRefreshing
                          ? null
                          : () => _fetchMine(isRefresh: true),
                      tooltip: 'Refresh',
                    ),
                  ),
                  const SizedBox(width: 4),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: GlassColors.surfaceOf(context),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: GlassColors.borderOf(context)),
                    ),
                    child: Text(
                      '${_assignments.length} uploaded',
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: GlassColors.primaryBlue,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              GlassButton(
                onPressed: _isUploading ? null : _startUpload,
                height: 52,
                borderRadius: 14,
                isLoading: _isUploading,
                disabled: _isUploading,
                child: Text(
                  _isUploading ? 'UPLOADING...' : 'UPLOAD PDF ASSIGNMENT',
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(height: 20),
              if (_isLoading)
                const Center(
                  child: Padding(
                    padding: EdgeInsets.symmetric(vertical: 32),
                    child: CircularProgressIndicator(
                      valueColor: AlwaysStoppedAnimation<Color>(
                        GlassColors.primaryBlue,
                      ),
                    ),
                  ),
                )
              else if (_loadError != null)
                _buildErrorCard()
              else if (_assignments.isEmpty)
                _buildEmptyState()
              else
                ..._assignments.map(_buildCard),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildErrorCard() {
    return GlassContainer(
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      borderRadius: 16,
      blurStrength: 15,
      opacity: 0.7,
      borderOpacity: 0.4,
      child: Column(
        children: [
          const Icon(
            Icons.cloud_off_rounded,
            size: 44,
            color: GlassColors.warning,
          ),
          const SizedBox(height: 12),
          Text(
            _loadError!,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: GlassColors.headingOf(context),
            ),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: 180,
            child: GlassOutlinedButton(
              onPressed: () => _fetchMine(isRefresh: true),
              height: 44,
              borderRadius: 12,
              child: const Text('Retry'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return GlassContainer(
      width: double.infinity,
      padding: const EdgeInsets.all(32),
      borderRadius: 16,
      blurStrength: 15,
      opacity: 0.6,
      borderOpacity: 0.3,
      child: Column(
        children: [
          Icon(
            Icons.upload_file_rounded,
            size: 48,
            color: GlassColors.disabledOf(context),
          ),
          SizedBox(height: 16),
          Text(
            'No assignments uploaded yet',
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w600,
              color: GlassColors.headingOf(context),
            ),
          ),
          SizedBox(height: 8),
          Text(
            'Upload a PDF to share it with your class. Students only see the '
            'assignments for their own course, division and batch.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13,
              color: GlassColors.secondaryTextOf(context),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCard(AssignmentRecord assignment) {
    final isDeleting = _deletingId == assignment.id;

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: GlassContainer(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        borderRadius: 16,
        blurStrength: 15,
        opacity: 0.7,
        borderOpacity: 0.4,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    assignment.title,
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.bold,
                      color: GlassColors.headingOf(context),
                    ),
                  ),
                ),
                if (assignment.hasAttachment)
                  const Icon(
                    Icons.picture_as_pdf_rounded,
                    size: 20,
                    color: GlassColors.primaryBlue,
                  ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              '${assignment.subject} • Year ${assignment.year} • '
              'Division ${assignment.division} • ${assignment.batchLabel}',
              style: TextStyle(
                fontSize: 13,
                color: GlassColors.secondaryTextOf(context),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Due ${assignment.dueDate}'
              '${assignment.originalName != null ? ' • ${assignment.originalName}' : ''}',
              style: TextStyle(
                fontSize: 13,
                color: GlassColors.secondaryTextOf(context),
              ),
            ),
            if (assignment.description != null &&
                assignment.description!.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                assignment.description!,
                style: TextStyle(
                  fontSize: 13,
                  color: GlassColors.headingOf(context),
                ),
              ),
            ],
            const SizedBox(height: 12),
            SizedBox(
              width: 140,
              child: GlassOutlinedButton(
                onPressed: isDeleting ? null : () => _delete(assignment),
                height: 40,
                borderRadius: 12,
                borderColor: isDeleting
                    ? GlassColors.disabledOf(context)
                    : GlassColors.error,
                textColor: isDeleting
                    ? GlassColors.disabledOf(context)
                    : GlassColors.error,
                child: isDeleting
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Remove', style: TextStyle(fontSize: 13)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _UploadPayload {
  const _UploadPayload({
    required this.title,
    required this.subject,
    required this.instructions,
    required this.dueDate,
    required this.year,
    required this.division,
    required this.batch,
    required this.file,
  });

  final String title;
  final String subject;
  final String instructions;
  final String dueDate;
  final int year;
  final String division;
  final String batch;
  final PickedAssignmentFile file;
}

/// The upload form. Returns the filled-in payload, or null when cancelled.
class _AssignmentUploadSheet extends StatefulWidget {
  const _AssignmentUploadSheet({required this.pickFile});

  final AssignmentFilePicker pickFile;

  @override
  State<_AssignmentUploadSheet> createState() => _AssignmentUploadSheetState();
}

class _AssignmentUploadSheetState extends State<_AssignmentUploadSheet> {
  final _titleController = TextEditingController();
  final _instructionsController = TextEditingController();

  static const List<String> _batches = ['', 'D-1', 'D-2', 'D-3'];
  static const List<int> _years = [1, 2, 3, 4];

  final String _division = 'D';
  String? _subject;
  String _batch = '';
  int _year = 1;
  DateTime _dueDate = DateTime.now().add(const Duration(days: 7));
  PickedAssignmentFile? _file;
  String? _error;

  @override
  void dispose() {
    _titleController.dispose();
    _instructionsController.dispose();
    super.dispose();
  }

  Future<void> _pickFile() async {
    try {
      final picked = await widget.pickFile();
      if (!mounted || picked == null) return;
      setState(() {
        _file = picked;
        _error = null;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = 'Could not read that file. Please try again.');
    }
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _dueDate,
      firstDate: DateTime.now().subtract(const Duration(days: 1)),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (picked == null || !mounted) return;
    setState(() => _dueDate = picked);
  }

  String get _dueDateIso =>
      '${_dueDate.year.toString().padLeft(4, '0')}-'
      '${_dueDate.month.toString().padLeft(2, '0')}-'
      '${_dueDate.day.toString().padLeft(2, '0')}';

  void _submit() {
    final title = _titleController.text.trim();
    final subject = _subject;

    if (title.isEmpty) {
      setState(() => _error = 'Please enter an assignment title.');
      return;
    }
    if (subject == null) {
      setState(() => _error = 'Please choose the subject.');
      return;
    }
    if (_file == null) {
      setState(() => _error = 'Please choose a PDF file to upload.');
      return;
    }

    Navigator.pop(
      context,
      _UploadPayload(
        title: title,
        subject: subject,
        instructions: _instructionsController.text.trim(),
        dueDate: _dueDateIso,
        year: _year,
        division: _division,
        batch: _batch,
        file: _file!,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 20,
        bottom: MediaQuery.of(context).viewInsets.bottom + 20,
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Upload Assignment',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: GlassColors.headingOf(context),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _titleController,
              decoration: const InputDecoration(labelText: 'Assignment title'),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: _subject,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Subject'),
              hint: const Text('Choose the subject'),
              items: kAssignmentSubjects
                  .map(
                    (subject) => DropdownMenuItem<String>(
                      value: subject,
                      child: Text(subject, overflow: TextOverflow.ellipsis),
                    ),
                  )
                  .toList(),
              onChanged: (value) => setState(() {
                _subject = value;
                _error = null;
              }),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _instructionsController,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: 'Instructions (optional)',
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<int>(
                    initialValue: _year,
                    decoration: const InputDecoration(labelText: 'Year'),
                    items: _years
                        .map(
                          (year) => DropdownMenuItem<int>(
                            value: year,
                            child: Text('Year $year'),
                          ),
                        )
                        .toList(),
                    onChanged: (value) =>
                        setState(() => _year = value ?? _year),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: _batch,
                    decoration: const InputDecoration(labelText: 'Batch'),
                    items: _batches
                        .map(
                          (batch) => DropdownMenuItem<String>(
                            value: batch,
                            child: Text(
                              batch.isEmpty ? 'Whole division' : batch,
                            ),
                          ),
                        )
                        .toList(),
                    onChanged: (value) => setState(() => _batch = value ?? ''),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: TextEditingController(text: _division),
                    readOnly: true,
                    decoration: const InputDecoration(labelText: 'Division'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: GlassOutlinedButton(
                    onPressed: _pickDate,
                    height: 56,
                    borderRadius: 14,
                    child: Text(
                      'Due $_dueDateIso',
                      style: const TextStyle(fontSize: 13),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            GlassOutlinedButton(
              onPressed: _pickFile,
              height: 52,
              borderRadius: 14,
              child: Text(
                _file == null
                    ? 'CHOOSE PDF FILE'
                    : '${_file!.name} (${(_file!.sizeBytes / 1024).toStringAsFixed(0)} KB)',
                style: const TextStyle(fontSize: 13),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: const TextStyle(fontSize: 13, color: GlassColors.error),
              ),
            ],
            const SizedBox(height: 16),
            GlassButton(
              onPressed: _submit,
              height: 50,
              borderRadius: 14,
              child: const Text(
                'UPLOAD',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
