import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'config/environment.dart';
import 'role_selection_page.dart';
import 'services/auth_service.dart';
import 'student.dart';
import 'utils/glass_container.dart';
import 'utils/teacher_api.dart';

/// One room / laboratory record, exactly as the backend has it.
class LabRecord {
  const LabRecord({
    required this.id,
    required this.name,
    this.code,
    this.room,
    this.building,
    this.floor,
    this.subject,
    this.kind = 'classroom',
    this.isVerified = false,
  });

  final int id;
  final String name;
  final String? code;
  final String? room;
  final String? building;
  final String? floor;
  final String? subject;
  final String kind;
  final bool isVerified;

  factory LabRecord.fromJson(Map<String, dynamic> json) {
    return LabRecord(
      id: json['id'] as int,
      name: (json['name'] as String?)?.trim() ?? '',
      code: (json['code'] as String?)?.trim(),
      room: (json['room'] as String?)?.trim(),
      building: (json['building'] as String?)?.trim(),
      floor: (json['floor'] as String?)?.trim(),
      subject: (json['subject'] as String?)?.trim(),
      kind: (json['kind'] as String?)?.trim() ?? 'classroom',
      isVerified: json['is_verified'] as bool? ?? false,
    );
  }
}

/// Lab Finder: search the recorded rooms and laboratories.
///
/// The official Division D sheet names only classroom M308 (Block-11), so that
/// is all that can be shown. Any laboratory without a recorded room number
/// simply does not appear - the screen never invents a location.
class LabFinderPage extends StatefulWidget {
  const LabFinderPage({super.key, required this.student, this.client});

  final Student student;
  final http.Client? client;

  @override
  State<LabFinderPage> createState() => _LabFinderPageState();
}

class _LabFinderPageState extends State<LabFinderPage> {
  final TextEditingController _searchController = TextEditingController();
  http.Client? _ownedClient;
  http.Client get _client => widget.client ?? (_ownedClient ??= http.Client());

  List<LabRecord> _rooms = const [];
  bool _isLoading = true;
  String? _errorMessage;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _fetchRooms();
  }

  @override
  void dispose() {
    _ownedClient?.close();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _fetchRooms({String? query}) async {
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
              '${Environment.backendUrl}/labs'
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
      final rooms = decoded is List
          ? decoded
                .whereType<Map<String, dynamic>>()
                .map(LabRecord.fromJson)
                .toList()
          : <LabRecord>[];

      setState(() {
        _rooms = rooms;
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
      appBar: const GlassAppBar(title: Text('Lab Finder')),
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
                    onSubmitted: (value) => _fetchRooms(query: value),
                    onChanged: (value) {
                      if (value.trim().isEmpty && _query.isNotEmpty) {
                        _fetchRooms(query: '');
                      }
                    },
                    decoration: InputDecoration(
                      border: InputBorder.none,
                      hintText: 'Search by laboratory or room code',
                      prefixIcon: Icon(
                        Icons.search_rounded,
                        color: GlassColors.secondaryTextOf(context),
                      ),
                      suffixIcon: _query.isEmpty
                          ? null
                          : IconButton(
                              icon: const Icon(Icons.close_rounded),
                              onPressed: () {
                                _searchController.clear();
                                _fetchRooms(query: '');
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
                  style: TextStyle(
                    fontSize: 14,
                    color: GlassColors.secondaryTextOf(context),
                  ),
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: 160,
                  child: GlassButton(
                    onPressed: _fetchRooms,
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

    if (_rooms.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: GlassCard(
            margin: EdgeInsets.zero,
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.science_outlined,
                  size: 44,
                  color: GlassColors.disabledOf(context),
                ),
                const SizedBox(height: 14),
                Text(
                  _query.trim().isEmpty
                      ? 'No laboratory locations recorded yet'
                      : 'No room matches "$_query"',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: GlassColors.headingOf(context),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Room numbers, blocks and floors come from the department. '
                  'Until they are provided, Stryve shows nothing rather '
                  'than a guessed location.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 13,
                    color: GlassColors.secondaryTextOf(context),
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
      itemCount: _rooms.length,
      itemBuilder: (context, index) => _buildCard(_rooms[index]),
    );
  }

  Widget _buildCard(LabRecord room) {
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
                GlassContainer(
                  width: 44,
                  height: 44,
                  borderRadius: 12,
                  padding: EdgeInsets.zero,
                  blurStrength: 12,
                  opacity: 0.7,
                  borderOpacity: 0.4,
                  child: Icon(
                    room.kind == 'laboratory'
                        ? Icons.science_rounded
                        : Icons.meeting_room_rounded,
                    size: 22,
                    color: GlassColors.primaryBlue,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        room.name,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: GlassColors.headingOf(context),
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        room.kind == 'laboratory' ? 'Laboratory' : 'Classroom',
                        style: TextStyle(
                          fontSize: 12,
                          color: GlassColors.secondaryTextOf(context),
                        ),
                      ),
                    ],
                  ),
                ),
                if (room.isVerified)
                  const Icon(
                    Icons.verified_rounded,
                    size: 18,
                    color: GlassColors.success,
                  ),
              ],
            ),
            const SizedBox(height: 12),
            _buildRow('Room', room.room ?? room.code),
            _buildRow('Building', room.building),
            _buildRow('Floor', room.floor),
            _buildRow('Subject', room.subject),
          ],
        ),
      ),
    );
  }

  Widget _buildRow(String label, String? value) {
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
              style: TextStyle(
                fontSize: 12,
                color: GlassColors.secondaryTextOf(context),
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
                    ? GlassColors.disabledOf(context)
                    : GlassColors.headingOf(context),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
