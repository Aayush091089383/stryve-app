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

                const Text(
                  'CampusSync',
                  style: TextStyle(
                    fontSize: 38,
                    fontWeight: FontWeight.bold,
                    color: GlassColors.heading,
                    letterSpacing: -1,
                    height: 1.2,
                  ),
                ),

                const SizedBox(height: 10),

                const Text(
                  'Your College. In One App.',
                  style: TextStyle(
                    fontSize: 17,
                    color: GlassColors.secondaryText,
                    height: 1.5,
                  ),
                ),

                const SizedBox(height: 60),

                const Text(
                  'Who are you?',
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w600,
                    color: GlassColors.heading,
                  ),
                ),

                const SizedBox(height: 30),

                // Student button
                GlassButton(
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => const LoginPage(),
                      ),
                    );
                  },
                  height: 64,
                  borderRadius: 18,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.school_rounded, size: 24),
                      const SizedBox(width: 12),
                      const Text(
                        'STUDENT',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 18),

                // Teacher button (outlined)
                GlassOutlinedButton(
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => const TeacherLoginPage(),
                      ),
                    );
                  },
                  height: 64,
                  borderRadius: 18,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.person_rounded, size: 24),
                      const SizedBox(width: 12),
                      const Text(
                        'TEACHER',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.5,
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
    );
  }
}
