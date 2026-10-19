import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'config/environment.dart';
import 'services/teacher_auth_service.dart';
import 'teacher_login_page.dart';
import 'teacher_models.dart';
import 'utils/glass_container.dart';
import 'utils/teacher_api.dart';

/// Claim Free Period.
///
/// Every slot shown here was computed by the backend from the official Division
/// D timetable AND the teacher's verified assignments: a period the teacher
/// teaches is never offered, a period in which any batch of the division has
/// class is never offered as "whole division", a period another teacher is
/// assigned to is not offered, and a period another teacher has already claimed
/// for that class group is reported as taken. The claim itself is re-validated
/// server-side.
///
/// The five periods the sheet prints as free periods ("RELM") appear here as
/// "Free period" and are offered, unclaimed, to any teacher whose account is
/// verified against the timetable. They are never shown to students.
class ClaimFreePeriodPage extends StatefulWidget {
  const ClaimFreePeriodPage({super.key, this.authService, this.client});

  final TeacherAuthService? authService;
  final http.Client? client;

  @override
  State<ClaimFreePeriodPage> createState() => _ClaimFreePeriodPageState();
}

class _ClaimFreePeriodPageState extends State<ClaimFreePeriodPage> {
  late final TeacherAuthService _authService =
      widget.authService ?? TeacherAuthService();
  http.Client? _ownedClient;
  http.Client get _client => widget.client ?? (_ownedClient ??= http.Client());

  DateTime _date = DateTime.now();
  FreePeriodAvailability? _availability;
  bool _isLoading = true;
  bool _isRefreshing = false;
  bool _showUnavailable = false;
  int? _claimingSlotIndex;
  int? _releasingId;
  String? _loadError;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _ownedClient?.close();
    super.dispose();
  }

  String get _dateIso =>
      '${_date.year.toString().padLeft(4, '0')}-'
      '${_date.month.toString().padLeft(2, '0')}-'
      '${_date.day.toString().padLeft(2, '0')}';

  Future<void> _sessionLost() async {
    await _authService.clearAuthData();
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const TeacherLoginPage()),
      (route) => false,
    );
  }

  void _showSnackBar(String message, {Color? color}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message), backgroundColor: color));
  }

  Future<void> _load({bool isRefresh = false}) async {
    if (isRefresh) {
      setState(() => _isRefreshing = true);
    } else {
      setState(() {
        _isLoading = true;
        _loadError = null;
      });
    }

    try {
      final token = await _authService.getToken();
      if (!mounted) return;
      if (token == null) {
        await _sessionLost();
        return;
      }

      final response = await _client
          .get(
            Uri.parse(
              '${Environment.backendUrl}/teacher/free-periods?date=$_dateIso',
            ),
            headers: teacherHeaders(token),
          )
          .timeout(kTeacherRequestTimeout);

      if (!mounted) return;

      if (response.statusCode == 200) {
        setState(() {
          _availability = FreePeriodAvailability.fromJson(
            jsonDecode(response.body) as Map<String, dynamic>,
          );
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

  Future<void> _claim(FreePeriodSlot slot, int index) async {
    if (_claimingSlotIndex != null) return;

    final token = await _authService.getToken();
    if (!mounted) return;
    if (token == null) {
      await _sessionLost();
      return;
    }

    setState(() => _claimingSlotIndex = index);

    try {
      final response = await _client
          .post(
            Uri.parse('${Environment.backendUrl}/teacher/free-periods/claim'),
            headers: teacherHeaders(token),
            body: jsonEncode({
              'day': slot.day,
              'start_time': slot.startTime,
              'end_time': slot.endTime,
              'division': 'D',
              'batch': slot.batch,
              'claim_date': _dateIso,
            }),
          )
          .timeout(kTeacherRequestTimeout);

      if (!mounted) return;

      if (response.statusCode == 201) {
        _showSnackBar(
          'Claimed ${slot.time} (${slot.batchLabel})',
          color: GlassColors.success,
        );
        await _load(isRefresh: true);
      } else if (response.statusCode == 401) {
        await _sessionLost();
      } else {
        // 409 = the period became unavailable: say exactly why.
        _showSnackBar(teacherMessageFromBody(response));
        await _load(isRefresh: true);
      }
    } catch (_) {
      if (!mounted) return;
      _showSnackBar(kTeacherUnreachableMessage);
    } finally {
      if (mounted) setState(() => _claimingSlotIndex = null);
    }
  }

  Future<void> _release(FreePeriodClaim claim) async {
    if (_releasingId != null) return;

    final token = await _authService.getToken();
    if (!mounted) return;
    if (token == null) {
      await _sessionLost();
      return;
    }

    setState(() => _releasingId = claim.id);

    try {
      final response = await _client
          .delete(
            Uri.parse(
              '${Environment.backendUrl}/teacher/free-periods/claims/${claim.id}',
            ),
            headers: teacherHeaders(token),
          )
          .timeout(kTeacherRequestTimeout);

      if (!mounted) return;

      if (response.statusCode == 200) {
        _showSnackBar('Claim released', color: GlassColors.success);
        await _load(isRefresh: true);
      } else if (response.statusCode == 401) {
        await _sessionLost();
      } else {
        _showSnackBar(teacherMessageFromBody(response));
      }
    } catch (_) {
      if (!mounted) return;
      _showSnackBar(kTeacherUnreachableMessage);
    } finally {
      if (mounted) setState(() => _releasingId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: GlassAppBar(
        title: const Text('Claim Free Period'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            onPressed: _isRefreshing ? null : () => _load(isRefresh: true),
            tooltip: 'Refresh',
          ),
        ],
      ),
      body: GlassBackground(
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 24, 24, 40),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: kTeacherMaxContentWidth,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildDateCard(),
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
                    else if (_availability != null)
                      ..._buildAvailability(_availability!),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDateCard() {
    return GlassContainer(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      borderRadius: 18,
      blurStrength: 15,
      opacity: 0.75,
      borderOpacity: 0.4,
      child: Row(
        children: [
          Expanded(
            child: Text(
              'Periods for',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: GlassColors.headingOf(context),
              ),
            ),
          ),
          GlassOutlinedButton(
            onPressed: () async {
              // A period that has passed can never be claimed, so the picker
              // cannot reach back past today either.
              final today = DateTime.now();
              final firstDate = DateTime(today.year, today.month, today.day);
              final initial = _date.isBefore(firstDate) ? firstDate : _date;
              final picked = await showDatePicker(
                context: context,
                initialDate: initial,
                firstDate: firstDate,
                lastDate: firstDate.add(const Duration(days: 120)),
              );
              if (picked == null || !mounted) return;
              setState(() => _date = picked);
              await _load();
            },
            width: 160,
            height: 44,
            borderRadius: 12,
            child: Text(
              '${_availability?.day ?? ''} $_dateIso'.trim(),
              style: const TextStyle(fontSize: 12),
            ),
          ),
        ],
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
              onPressed: _load,
              height: 44,
              borderRadius: 12,
              child: const Text('Retry'),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildAvailability(FreePeriodAvailability availability) {
    final eligible = availability.eligible;
    final unavailable = availability.slots
        .where((slot) => !slot.eligible)
        .toList();

    return [
      // The teacher's own classes being unknown is no longer a blocker (the
      // department's free periods are claimable by any active teacher account), so
      // this card is only for an account that genuinely cannot claim.
      if (!availability.canClaimFreePeriods && availability.message != null)
        Padding(
          padding: const EdgeInsets.only(bottom: 20),
          child: GlassContainer(
            width: double.infinity,
            padding: const EdgeInsets.all(20),
            borderRadius: 16,
            blurStrength: 15,
            opacity: 0.7,
            borderOpacity: 0.4,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(
                      Icons.info_outline_rounded,
                      color: GlassColors.warning,
                      size: 22,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Free periods cannot be claimed from this account',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: GlassColors.headingOf(context),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  availability.message!,
                  style: TextStyle(
                    fontSize: 13,
                    color: GlassColors.secondaryTextOf(context),
                  ),
                ),
              ],
            ),
          ),
        ),
      Row(
        children: [
          Expanded(
            child: Text(
              'Available periods',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: GlassColors.headingOf(context),
              ),
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: GlassColors.surfaceOf(context),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: GlassColors.borderOf(context)),
            ),
            child: Text(
              '${eligible.length} available',
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: GlassColors.primaryBlue,
              ),
            ),
          ),
        ],
      ),
      const SizedBox(height: 12),
      if (eligible.isEmpty)
        GlassContainer(
          width: double.infinity,
          padding: const EdgeInsets.all(24),
          borderRadius: 16,
          blurStrength: 15,
          opacity: 0.6,
          borderOpacity: 0.3,
          child: Text(
            'No free period is available for your classes on this date.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 14,
              color: GlassColors.secondaryTextOf(context),
            ),
          ),
        )
      else
        ...eligible.asMap().entries.map((entry) {
          final slot = entry.value;
          final isClaiming = _claimingSlotIndex == entry.key;
          return Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: GlassContainer(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              borderRadius: 16,
              blurStrength: 15,
              opacity: 0.75,
              borderOpacity: 0.4,
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text(
                              slot.time,
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                                color: GlassColors.headingOf(context),
                              ),
                            ),
                            if (slot.isFreePeriod) ...[
                              const SizedBox(width: 8),
                              _slotBadge('Free period'),
                            ],
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '${slot.day} • ${slot.batchLabel}',
                          style: TextStyle(
                            fontSize: 13,
                            color: GlassColors.secondaryTextOf(context),
                          ),
                        ),
                      ],
                    ),
                  ),
                  SizedBox(
                    width: 110,
                    child: GlassButton(
                      onPressed: isClaiming
                          ? null
                          : () => _claim(slot, entry.key),
                      height: 42,
                      borderRadius: 12,
                      isLoading: isClaiming,
                      disabled: isClaiming,
                      child: const Text(
                        'CLAIM',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        }),
      const SizedBox(height: 20),
      _buildClaims(availability),
      const SizedBox(height: 20),
      GlassOutlinedButton(
        onPressed: () => setState(() => _showUnavailable = !_showUnavailable),
        height: 44,
        borderRadius: 12,
        child: Text(
          _showUnavailable
              ? 'Hide unavailable periods'
              : 'Show unavailable periods (${unavailable.length})',
          style: const TextStyle(fontSize: 13),
        ),
      ),
      if (_showUnavailable) ...[
        const SizedBox(height: 12),
        ...unavailable
            .take(40)
            .map(
              (slot) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: GlassCard(
                  margin: EdgeInsets.zero,
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 110,
                        child: Text(
                          slot.time,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: GlassColors.headingOf(context),
                          ),
                        ),
                      ),
                      Expanded(
                        child: Row(
                          children: [
                            if (slot.isFreePeriod) ...[
                              _slotBadge('Free period'),
                              const SizedBox(width: 8),
                            ],
                            Expanded(
                              child: Text(
                                '${slot.batchLabel} • '
                                '${slot.claimed ? 'Already claimed by you' : (slot.reason ?? 'Not available')}',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: GlassColors.secondaryTextOf(context),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
      ],
    ];
  }

  /// A small solid-colour chip (no gradients, readable at 11px).
  Widget _slotBadge(String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: GlassColors.primaryBlue.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: GlassColors.borderOf(context).withValues(alpha: 0.6),
        ),
      ),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: GlassColors.primaryBlue,
        ),
      ),
    );
  }

  Widget _buildClaims(FreePeriodAvailability availability) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'My claimed periods',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.bold,
            color: GlassColors.headingOf(context),
          ),
        ),
        const SizedBox(height: 12),
        if (availability.claims.isEmpty)
          GlassContainer(
            width: double.infinity,
            padding: const EdgeInsets.all(20),
            borderRadius: 16,
            blurStrength: 15,
            opacity: 0.6,
            borderOpacity: 0.3,
            child: Text(
              'You have not claimed any period on this date.',
              style: TextStyle(
                fontSize: 14,
                color: GlassColors.secondaryTextOf(context),
              ),
            ),
          )
        else
          ...availability.claims.map(
            (claim) => Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: GlassCard(
                margin: EdgeInsets.zero,
                padding: const EdgeInsets.all(14),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${claim.day} ${claim.time}',
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: GlassColors.headingOf(context),
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '${claim.claimDate} • ${claim.batchLabel}',
                            style: TextStyle(
                              fontSize: 12,
                              color: GlassColors.secondaryTextOf(context),
                            ),
                          ),
                        ],
                      ),
                    ),
                    SizedBox(
                      width: 100,
                      child: GlassOutlinedButton(
                        onPressed: _releasingId == claim.id
                            ? null
                            : () => _release(claim),
                        height: 38,
                        borderRadius: 10,
                        child: _releasingId == claim.id
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Text(
                                'Release',
                                style: TextStyle(fontSize: 12),
                              ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}
