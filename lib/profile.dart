import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import 'student.dart';
import 'role_selection_page.dart';
import 'services/auth_service.dart';
import 'utils/glass_container.dart';

class ProfilePage extends StatelessWidget {
  final Student student;

  const ProfilePage({super.key, required this.student});

  @override
  Widget build(BuildContext context) {
    // One shared backdrop blur for the glass surfaces that stack down this
    // screen (the six info cards) instead of one backdrop per card. Same
    // mechanism Home's tab and the Timetable page use; the avatar keeps its own
    // circular blur, and the chip on top of a card is a nested surface either
    // way.
    //
    // This group is load-bearing, not cosmetic: with it removed the page
    // measured 33.35 ms per frame (30.0 fps) where it holds 22.2 ms (45.0 fps),
    // i.e. the shared backdrop is worth one whole vsync here. Do not drop it as
    // a "simplification".
    return BackdropGroup(child: _ProfileContent(student: student));
  }
}

class _ProfileContent extends StatefulWidget {
  final Student student;

  const _ProfileContent({required this.student});

  @override
  State<_ProfileContent> createState() => _ProfileContentState();
}

class _ProfileContentState extends State<_ProfileContent> {
  final ImagePicker _picker = ImagePicker();
  String? _localPhotoPath;

  @override
  void initState() {
    super.initState();
    _localPhotoPath = widget.student.photoPath;
  }

  Future<void> _pickPhoto() async {
    try {
      final XFile? picked = await _picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 512,
        maxHeight: 512,
        imageQuality: 80,
      );

      if (picked == null) return;

      final file = File(picked.path);
      if (!await file.exists()) {
        _showError('Selected photo not found');
        return;
      }

      final authService = AuthService();
      await authService.savePhotoPath(file.path);

      if (!mounted) return;

      setState(() {
        _localPhotoPath = file.path;
      });

      _showSuccess('Profile photo updated');
    } catch (e) {
      _showError('Failed to pick photo: $e');
    }
  }

  Future<void> _removePhoto() async {
    try {
      final authService = AuthService();
      await authService.removePhotoPath();

      if (!mounted) return;

      setState(() {
        _localPhotoPath = null;
      });

      _showSuccess('Profile photo removed');
    } catch (e) {
      _showError('Failed to remove photo: $e');
    }
  }

  void _showPhotoOptions() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => GlassCard(
        margin: EdgeInsets.only(
          left: 16,
          right: 16,
          bottom: MediaQuery.of(ctx).viewInsets.bottom + 16,
        ),
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Profile Photo',
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: GlassColors.heading,
              ),
            ),
            const SizedBox(height: 16),
            if (_localPhotoPath != null)
              ListTile(
                leading: const Icon(
                  Icons.delete_outline,
                  color: GlassColors.error,
                ),
                title: const Text(
                  'Remove Photo',
                  style: TextStyle(color: GlassColors.error),
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  _removePhoto();
                },
              ),
            ListTile(
              leading: const Icon(
                Icons.photo_library,
                color: GlassColors.primaryBlue,
              ),
              title: const Text(
                'Choose from Gallery',
                style: TextStyle(color: GlassColors.heading),
              ),
              onTap: () {
                Navigator.pop(ctx);
                _pickPhoto();
              },
            ),
            ListTile(
              leading: const Icon(
                Icons.close,
                color: GlassColors.secondaryText,
              ),
              title: const Text(
                'Cancel',
                style: TextStyle(color: GlassColors.heading),
              ),
              onTap: () => Navigator.pop(ctx),
            ),
          ],
        ),
      ),
    );
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: GlassColors.error),
    );
  }

  void _showSuccess(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: GlassColors.success),
    );
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final double topPadding = media.padding.top + kToolbarHeight + 8;
    final double bottomPadding = media.padding.bottom + 76 + 8;

    return ListView(
      padding: EdgeInsets.fromLTRB(20, topPadding, 20, bottomPadding),
      children: [
        // Profile icon - tap to change
        Center(
          child: GestureDetector(
            onTap: _showPhotoOptions,
            child: Stack(
              children: [
                GlassContainer(
                  width: 110,
                  height: 110,
                  borderRadius: 55,
                  // Tuned 25 -> 8 -> 4 for perf; measure before reverting. This
                  // circle was the single most expensive filter on the page:
                  // its blur cost grows with sigma squared and the photo covers
                  // most of what it frosts.
                  blurStrength: 4,
                  opacity: 0.8,
                  borderOpacity: 0.5,
                  padding: EdgeInsets.zero,
                  child: _buildAvatar(),
                ),
                Positioned(
                  right: 0,
                  bottom: 0,
                  child: GlassContainer(
                    width: 32,
                    height: 32,
                    borderRadius: 16,
                    blurStrength: 15,
                    opacity: 0.9,
                    borderOpacity: 0.5,
                    padding: EdgeInsets.zero,
                    child: const Icon(
                      Icons.camera_alt_rounded,
                      size: 16,
                      color: GlassColors.primaryBlue,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),

        const SizedBox(height: 20),

        // Name
        Text(
          widget.student.name,
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 26,
            fontWeight: FontWeight.bold,
            color: GlassColors.heading,
            letterSpacing: -0.5,
          ),
        ),

        const SizedBox(height: 6),

        Text(
          '${widget.student.course} \u2022 ${widget.student.division}',
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 16,
            color: GlassColors.secondaryText,
            fontWeight: FontWeight.w400,
          ),
        ),

        const SizedBox(height: 28),

        _glassInfoCard(
          icon: Icons.badge_rounded,
          title: 'Roll Number',
          value: widget.student.rollNumber,
        ),

        _glassInfoCard(
          icon: Icons.school_rounded,
          title: 'College',
          value: 'R.H. Sapat College Of Engineering, Mgt.Studies & Research',
        ),

        _glassInfoCard(
          icon: Icons.menu_book_rounded,
          title: 'Course',
          value: widget.student.course,
        ),

        _glassInfoCard(
          icon: Icons.calendar_today_rounded,
          title: 'Year',
          value: _getYearText(widget.student.year),
        ),

        _glassInfoCard(
          icon: Icons.groups_rounded,
          title: 'Division',
          value: widget.student.division,
        ),

        _glassInfoCard(
          icon: Icons.groups_2_rounded,
          title: 'Batch',
          value: widget.student.batch,
        ),

        const SizedBox(height: 24),

        // LOG OUT BUTTON
        GlassOutlinedButton(
          onPressed: () async {
            final authService = AuthService();
            // Revokes the session on the backend when reachable, and always
            // clears the local student credentials (never the teacher's).
            await authService.logout();

            if (!context.mounted) return;

            Navigator.of(context).pushAndRemoveUntil(
              MaterialPageRoute(
                builder: (context) => const RoleSelectionPage(),
              ),
              (route) => false,
            );
          },
          height: 56,
          borderRadius: 16,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.logout_rounded, size: 20),
              const SizedBox(width: 10),
              const Text(
                'Log Out',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),

        const SizedBox(height: 20),
      ],
    );
  }

  Widget _buildAvatar() {
    if (_localPhotoPath != null && _localPhotoPath!.isNotEmpty) {
      final file = File(_localPhotoPath!);
      if (file.existsSync()) {
        return ClipOval(
          child: Image.file(file, width: 110, height: 110, fit: BoxFit.cover),
        );
      }
    }

    return const Icon(
      Icons.person_rounded,
      size: 56,
      color: GlassColors.primaryBlue,
    );
  }

  String _getYearText(int year) {
    switch (year) {
      case 1:
        return '1st Year (F.E.)';
      case 2:
        return '2nd Year (S.E.)';
      case 3:
        return '3rd Year (T.E.)';
      case 4:
        return '4th Year (B.E.)';
      default:
        return '$year th Year';
    }
  }

  Widget _glassInfoCard({
    required IconData icon,
    required String title,
    required String value,
  }) {
    return GlassCard(
      // Tuned 15 -> 8 -> 4 for perf; measure before reverting. These six cards
      // are the largest glass surfaces in the app, and the page was the only one
      // still stuck at 2 vsyncs per frame.
      blurStrength: 4,
      padding: const EdgeInsets.all(16),
      margin: const EdgeInsets.only(bottom: 12),
      borderRadius: 16,
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
            child: Icon(icon, size: 22, color: GlassColors.primaryBlue),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 12,
                    color: GlassColors.secondaryText,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  value,
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.bold,
                    color: GlassColors.heading,
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
