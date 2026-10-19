import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'teacher_panel_page.dart';
import 'role_selection_page.dart';
import 'config/environment.dart';
import 'services/teacher_auth_service.dart';
import 'utils/glass_container.dart';

/// Teacher/Admin login page matching the Campus Sync glassmorphism design
class TeacherLoginPage extends StatefulWidget {
  const TeacherLoginPage({super.key});

  @override
  State<TeacherLoginPage> createState() => _TeacherLoginPageState();
}

class _TeacherLoginPageState extends State<TeacherLoginPage> {
  final emailController = TextEditingController();
  final passwordController = TextEditingController();

  bool obscurePassword = true;
  bool isLoading = false;

  @override
  void dispose() {
    emailController.dispose();
    passwordController.dispose();
    super.dispose();
  }

  /// Authenticate against the backend POST /teacher/login endpoint
  Future<void> login() async {
    final email = emailController.text.trim();
    final password = passwordController.text;

    if (email.isEmpty || password.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter your email and password.')),
      );
      return;
    }

    setState(() {
      isLoading = true;
    });

    try {
      final response = await http.post(
        Uri.parse('${Environment.backendUrl}/teacher/login'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'email': email, 'password': password}),
      );

      final data = jsonDecode(response.body);

      // LOGIN SUCCESS
      if (response.statusCode == 200 && data['message'] == 'Login successful') {
        final int teacherId = data['teacher_id'];
        final String name = data['name'];
        final String token = data['token'];
        final String tokenExpiresAt = data['token_expires_at'];
        final String role = data['role'];
        final String email = data['email'];

        // Save auth data
        final authService = TeacherAuthService();
        await authService.saveAuthData(
          token: token,
          tokenExpiresAt: tokenExpiresAt,
          teacherId: teacherId,
          name: name,
          email: email,
          role: role,
        );

        if (!mounted) return;

        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (context) => const TeacherPanelPage()),
        );
      } else {
        // LOGIN FAILED
        final message =
            data['message'] ?? data['detail'] ?? 'Invalid email or password';

        if (!mounted) return;

        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(message)));
      }
    } catch (e) {
      // CONNECTION ERROR
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Could not connect to Stryve server. Please check your internet connection and try again.',
          ),
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          isLoading = false;
        });
      }
    }
  }

  /// Back to Role Selection. This page is usually pushed from there, so a pop
  /// is enough; after a logout or an expired session it is the root route, so
  /// replace it rather than leaving a button that does nothing.
  Future<void> _backToRoleSelection() async {
    final navigator = Navigator.of(context);
    if (await navigator.maybePop()) return;
    if (!mounted) return;
    navigator.pushReplacement(
      MaterialPageRoute(builder: (_) => const RoleSelectionPage()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: GlassAppBar(
        title: const Text('Teacher Login'),
        automaticallyImplyLeading: false,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          // Same label Flutter's own BackButton carries, so screen readers and
          // long-press both name the action.
          tooltip: 'Back',
          onPressed: _backToRoleSelection,
        ),
      ),
      body: GlassBackground(
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              children: [
                const SizedBox(height: 30),

                // Glass icon container
                GlassContainer(
                  width: 100,
                  height: 100,
                  borderRadius: 28,
                  blurStrength: 25,
                  opacity: 0.8,
                  borderOpacity: 0.5,
                  padding: const EdgeInsets.all(24),
                  child: const Icon(
                    Icons.person_rounded,
                    size: 48,
                    color: GlassColors.primaryBlue,
                  ),
                ),

                const SizedBox(height: 24),

                Text(
                  'Teacher Portal',
                  style: TextStyle(
                    fontSize: 32,
                    fontWeight: FontWeight.bold,
                    color: GlassColors.headingOf(context),
                    letterSpacing: -0.5,
                  ),
                ),

                const SizedBox(height: 8),

                Text(
                  'Sign in to manage student registrations',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 16,
                    color: GlassColors.secondaryTextOf(context),
                    height: 1.5,
                  ),
                ),

                const SizedBox(height: 40),

                // EMAIL
                GlassTextField(
                  controller: emailController,
                  keyboardType: TextInputType.emailAddress,
                  labelText: 'Email',
                  hintText: 'Enter your email address',
                  prefixIcon: const Icon(Icons.email_rounded),
                ),

                const SizedBox(height: 16),

                // PASSWORD
                GlassTextField(
                  controller: passwordController,
                  obscureText: obscurePassword,
                  labelText: 'Password',
                  hintText: 'Enter your password',
                  prefixIcon: const Icon(Icons.lock_rounded),
                  suffixIcon: IconButton(
                    icon: Icon(
                      obscurePassword
                          ? Icons.visibility_rounded
                          : Icons.visibility_off_rounded,
                      color: GlassColors.secondaryTextOf(context),
                    ),
                    onPressed: () {
                      setState(() {
                        obscurePassword = !obscurePassword;
                      });
                    },
                  ),
                ),

                const SizedBox(height: 28),

                // LOGIN BUTTON
                GlassButton(
                  onPressed: isLoading ? null : login,
                  isLoading: isLoading,
                  height: 56,
                  borderRadius: 16,
                  // Flat brand blue instead of the default gradient, so the
                  // label sits on one solid colour.
                  color: GlassColors.primaryBlue,
                  child: const Text(
                    'LOGIN',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.5,
                      color: Colors.white,
                    ),
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
