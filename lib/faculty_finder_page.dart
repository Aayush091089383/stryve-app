import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'config/environment.dart';
import 'role_selection_page.dart';
import 'services/auth_service.dart';
import 'student.dart';
import 'utils/glass_container.dart';
import 'utils/teacher_api.dart';

/// A faculty row exactly as the backend has it.
///
/// Every field except the short code can be null: the official timetable only
/// prints initials, so the screen must be able to say "Not available" instead
/// of showing an invented name, e-mail or office.
class FacultyRecord {
  const FacultyRecord({
    required this.id,
    required this.shortCode,
    required this.displayName,
    this.fullName,
    this.department,
    this.email,
    this.office,
    this.phone,
    this.roleNote,
    this.isVerified = false,
    this.subjects = const [],
  });

  final int id;
  final String shortCode;
  final String displayName;
  final String? fullName;
  final String? department;
  final String? email;
  final String? office;
  final String? phone;
  final String? roleNote;
  final bool isVerified;
  final List<FacultySubject> subjects;

  factory FacultyRecord.fromJson(Map<String, dynamic> json) {
    final rawSubjects = json['subjects'];
    return FacultyRecord(
      id: json['id'] as int,
      shortCode: (json['short_code'] as String?)?.trim() ?? '',
      displayName: (json['display_name'] as String?)?.trim() ?? '',
      fullName: (json['full_name'] as String?)?.trim(),
      department: (json['department'] as String?)?.trim(),
      email: (json['email'] as String?)?.trim(),
      office: (json['office'] as String?)?.trim(),
      phone: (json['phone'] as String?)?.trim(),
      roleNote: (json['role_note'] as String?)?.trim(),
      isVerified: json['is_verified'] as bool? ?? false,
      subjects: rawSubjects is List
          ? rawSubjects
                .whereType<Map<String, dynamic>>()
                .map(FacultySubject.fromJson)
                .toList()
          : const [],
    );
  }
}

class FacultySubject {
  const FacultySubject({
    required this.name,
    required this.shortName,
    this.code,
    this.kind = 'theory',
  });

  final String name;
  final String shortName;
  final String? code;
  final String kind;

  factory FacultySubject.fromJson(Map<String, dynamic> json) {
    return FacultySubject(
      name: (json['name'] as String?)?.trim() ?? '',
      shortName: (json['short_name'] as String?)?.trim() ?? '',
      code: (json['code'] as String?)?.trim(),
      kind: (json['kind'] as String?)?.trim() ?? 'theory',
    );
  }
}

/// Faculty Finder: search the official faculty records by name, code or subject.
///
/// Nothing here is generated: records come from `GET /faculty`, and a field the
/// official document does not contain is shown as "Not available".
class FacultyFinderPage extends StatefulWidget {
  const FacultyFinderPage({super.key, required this.student, this.client});

  final Student student;
  final http.Client? client;

  @override
  State<FacultyFinderPage> createState() => _FacultyFinderPageState();
}

class _FacultyFinderPageState extends State<FacultyFinderPage> {
  final TextEditingController _searchController = TextEditingController();
  http.Client? _ownedClient;
  http.Client get _client => widget.client ?? (_ownedClient ??= http.Client());

  List<FacultyRecord> _faculty = const [];
  bool _isLoading = true;
  String? _errorMessage;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _fetchFaculty();
  }

  @override
  void dispose() {
    _ownedClient?.close();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _fetchFaculty({String? query}) async {
    final effectiveQuery = query ?? _query;
    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _query = effectiveQuery;
    });

    try {
      final response = await _client
          .get(
            Uri.parse(
              '${Environment.backendUrl}/faculty'
              '${effectiveQuery.trim().isEmpty ? '' : '?q=${Uri.encodeQueryComponent(effectiveQuery.trim())}'}',
            ),
            headers: {'Authorization': 'Bearer ${widget.student.token}'},
          )
          .timeout(kTeacherRequestTimeout);

      if (!mounted) return;

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
          _errorMessage = teacherMessageFromBody(response);
          _isLoading = false;
        });
        return;
      }

      final decoded = jsonDecode(response.body);
      final records = decoded is List
          ? decoded
                .whereType<Map<String, dynamic>>()
                .map(FacultyRecord.fromJson)
                .toList()
          : <FacultyRecord>[];

      setState(() {
        _faculty = records;
        _isLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _errorMessage = kTeacherUnreachableMessage;
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: const GlassAppBar(title: Text('Faculty Finder')),
      body: GlassBackground(
        child: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
                child: GlassCard(
                  margin: EdgeInsets.zero,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 4,
                  ),
                  child: TextField(
                    controller: _searchController,
                    textInputAction: TextInputAction.search,
                    onSubmitted: (value) => _fetchFaculty(query: value),
                    onChanged: (value) {
                      if (value.trim().isEmpty && _query.isNotEmpty) {
                        _fetchFaculty(query: '');
                      }
                    },
                    decoration: InputDecoration(
                      border: InputBorder.none,
                      hintText: 'Search by name, code or subject',
                      prefixIcon: const Icon(
                        Icons.search_rounded,
                        color: GlassColors.secondaryText,
                      ),
                      suffixIcon: _query.isEmpty
                          ? null
                          : IconButton(
                              icon: const Icon(Icons.close_rounded),
                              onPressed: () {
                                _searchController.clear();
                                _fetchFaculty(query: '');
                              },
                            ),
                    ),
                  ),
                ),
              ),
              Expanded(child: _buildBody()),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const Center(
        child: CircularProgressIndicator(color: GlassColors.primaryBlue),
      );
    }

    if (_errorMessage != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: GlassCard(
            margin: EdgeInsets.zero,
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.cloud_off_rounded,
                  size: 40,
                  color: GlassColors.warning,
                ),
                const SizedBox(height: 12),
                Text(
                  _errorMessage!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 14,
                    color: GlassColors.secondaryText,
                  ),
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: 160,
                  child: GlassButton(
                    onPressed: _fetchFaculty,
                    height: 44,
                    borderRadius: 12,
                    child: const Text('Try Again'),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    if (_faculty.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: GlassCard(
            margin: EdgeInsets.zero,
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.person_search_rounded,
                  size: 44,
                  color: GlassColors.disabled,
                ),
                const SizedBox(height: 14),
                Text(
                  _query.trim().isEmpty
                      ? 'No faculty records available yet'
                      : 'No faculty member matches "$_query"',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: GlassColors.heading,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Only official records are shown. If the directory is empty, '
                  'the faculty source data still has to be provided.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 13,
                    color: GlassColors.secondaryText,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 30),
      itemCount: _faculty.length,
      itemBuilder: (context, index) => _buildCard(_faculty[index]),
    );
  }

  Widget _buildCard(FacultyRecord record) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: GlassCard(
        margin: EdgeInsets.zero,
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 20,
                  backgroundColor: GlassColors.primaryBlue.withValues(
                    alpha: 0.15,
                  ),
                  child: Text(
                    record.shortCode.isEmpty ? '?' : record.shortCode[0],
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      color: GlassColors.primaryBlue,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        record.displayName,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: GlassColors.heading,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        record.roleNote ?? 'Faculty code ${record.shortCode}',
                        style: const TextStyle(
                          fontSize: 12,
                          color: GlassColors.secondaryText,
                        ),
                      ),
                    ],
                  ),
                ),
                if (record.isVerified)
                  const Icon(
                    Icons.verified_rounded,
                    size: 18,
                    color: GlassColors.success,
                  ),
              ],
            ),
            const SizedBox(height: 12),
            _buildRow('Full name', record.fullName),
            _buildRow('Department', record.department),
            _buildRow('Office', record.office),
            _buildRow('Email', record.email),
            _buildRow('Phone', record.phone),
            if (record.subjects.isNotEmpty) ...[
              const SizedBox(height: 8),
              const Text(
                'Subjects',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: GlassColors.heading,
                ),
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: record.subjects
                    .map(
                      (subject) => Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: GlassColors.primaryBlue.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: GlassColors.border.withValues(alpha: 0.6),
                          ),
                        ),
                        child: Text(
                          subject.code == null
                              ? subject.shortName
                              : '${subject.shortName} · ${subject.code}',
                          style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: GlassColors.heading,
                          ),
                        ),
                      ),
                    )
                    .toList(),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildRow(String label, String? value) {
    // "Not available" is shown instead of a fabricated value.
    final display = (value == null || value.isEmpty) ? 'Not available' : value;

    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 96,
            child: Text(
              label,
              style: const TextStyle(
                fontSize: 12,
                color: GlassColors.secondaryText,
              ),
            ),
          ),
          Expanded(
            child: Text(
              display,
              style: TextStyle(
                fontSize: 12,
                fontWeight: value == null || value.isEmpty
                    ? FontWeight.w400
                    : FontWeight.w600,
                color: value == null || value.isEmpty
                    ? GlassColors.disabled
                    : GlassColors.heading,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
