import 'package:flutter/material.dart';

import 'login_page.dart';
import 'teacher_login_page.dart';
import 'utils/glass_container.dart';

class RoleSelectionPage extends StatelessWidget {
  const RoleSelectionPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      body: GlassBackground(
        showPattern: true,
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // App icon with glow
                Stack(
                  alignment: Alignment.center,
                  children: [
                    const GlowOrb(
                      position: Alignment.center,
                      size: 180,
                      color: GlassColors.primaryBlue,
                      opacity: 0.12,
                    ),
                    GlassContainer(
                      width: 120,
                      height: 120,
                      borderRadius: 32,
                      blurStrength: 30,
                      opacity: 0.8,
                      borderOpacity: 0.5,
                      padding: const EdgeInsets.all(28),
                      child: const Icon(
                        Icons.school_rounded,
                        size: 56,
                        color: GlassColors.primaryBlue,
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 28),

                Text(
                  'Stryve',
                  style: TextStyle(
                    fontSize: 38,
                    fontWeight: FontWeight.bold,
                    color: GlassColors.headingOf(context),
                    letterSpacing: -1,
                    height: 1.2,
                  ),
                ),

                const SizedBox(height: 10),

                Text(
                  'Your College. In One App.',
                  style: TextStyle(
                    fontSize: 17,
                    color: GlassColors.secondaryTextOf(context),
                    height: 1.5,
                  ),
                ),

                const SizedBox(height: 60),

                Text(
                  'Who are you?',
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w600,
                    color: GlassColors.headingOf(context),
                  ),
                ),

                const SizedBox(height: 30),

                // Both roles are equal choices, so they are the same button:
                // same fill, same white label and icon, same geometry.
                _RoleButton(
                  icon: Icons.school_rounded,
                  label: 'Student',
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => const LoginPage(),
                      ),
                    );
                  },
                ),

                const SizedBox(height: 18),

                _RoleButton(
                  icon: Icons.person_rounded,
                  label: 'Teacher',
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => const TeacherLoginPage(),
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// One role-choice button.
///
/// Student and teacher are first-class paths, so they are built from a single
/// place: identical solid fill, identical white label and icon, identical
/// geometry. The teacher option used to be the outlined variant, which made it
/// read as the secondary choice, and neither label set its own colour - both
/// inherited the ambient body text colour, which is why the label looked
/// washed out on the blue fill instead of white.
class _RoleButton extends StatelessWidget {
  const _RoleButton({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  /// 54dp: ~16 % shorter than the previous 64dp, and still well above the
  /// 48dp minimum touch target.
  static const double height = 54;
  static const double borderRadius = 18;

  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return GlassButton(
      onPressed: onPressed,
      color: GlassColors.primaryBlue,
      height: height,
      borderRadius: borderRadius,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 24, color: Colors.white),
          const SizedBox(width: 12),
          Text(
            label,
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              letterSpacing: 0,
              color: Colors.white,
            ),
          ),
        ],
      ),
    );
  }
}
