import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'config/environment.dart';
import 'services/teacher_auth_service.dart';
import 'teacher_login_page.dart';
import 'utils/glass_container.dart';
import 'utils/teacher_api.dart';

/// Post an announcement to the student feed.
///
/// Any active teacher or admin account may post; the backend decides, and the
/// author is always the authenticated account (never anything typed here).
/// `year`/`division` are optional restrictions - leaving both on \"Every\"
/// posts to every student, which is how a college-wide notice is sent.
class TeacherAnnouncementsPage extends StatefulWidget {
  const TeacherAnnouncementsPage({super.key, this.authService, this.client});

  final TeacherAuthService? authService;
  final http.Client? client;

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

  bool _posting = false;
  String? _error;

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
      final response = await _client
          .post(
            Uri.parse('${Environment.backendUrl}/teacher/announcements'),
            headers: {
              'Authorization': 'Bearer $token',
              'Content-Type': 'application/json',
            },
            body: jsonEncode({
              'title': _titleController.text.trim(),
              'message': _messageController.text.trim(),
              // Omitted rather than sent as null: an absent restriction is what
              // makes the post readable by everyone.
              if (_year != null) 'year': _year,
              if (_division != null) 'division': _division,
            }),
          )
          .timeout(const Duration(seconds: 20));

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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: const GlassAppBar(title: Text('Post Announcement')),
      body: GlassBackground(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 40),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: Form(
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
                        'It appears in every student\'s feed that matches the '
                        'audience below.',
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
                                DropdownMenuItem<int?>(value: 1, child: Text('Year 1')),
                                DropdownMenuItem<int?>(value: 2, child: Text('Year 2')),
                                DropdownMenuItem<int?>(value: 3, child: Text('Year 3')),
                                DropdownMenuItem<int?>(value: 4, child: Text('Year 4')),
                                DropdownMenuItem<int?>(value: 5, child: Text('Year 5')),
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
                                  : (value) => setState(() => _division = value),
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
            ),
          ),
        ),
      ),
    );
  }
}
