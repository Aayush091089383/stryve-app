import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'home_page.dart';
import 'student.dart';
import 'config/environment.dart';
import 'services/auth_service.dart';
import 'utils/validators.dart';
import 'utils/glass_container.dart';

// ============================================================
// STUDENT LOGIN PAGE
// ============================================================

class LoginPage extends StatefulWidget {
  const LoginPage({super.key, this.client});

  /// Optional injectable HTTP client (tests); defaults to a real client.
  final http.Client? client;

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final emailController = TextEditingController();
  final passwordController = TextEditingController();

  http.Client? _ownedClient;

  http.Client get _client => widget.client ?? (_ownedClient ??= http.Client());

  bool obscurePassword = true;
  bool isLoading = false;

  @override
  void dispose() {
    emailController.dispose();
    passwordController.dispose();
    _ownedClient?.close();

    super.dispose();
  }

  // ==========================================================
  // LOGIN
  // ==========================================================

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
      final response = await _client.post(
        Uri.parse('${Environment.backendUrl}/login'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'email': email, 'password': password}),
      );

      final data = jsonDecode(response.body);

      // --------------------------------------------------------
      // LOGIN SUCCESS
      // --------------------------------------------------------

      if (response.statusCode == 200 && data['message'] == 'Login successful') {
        final int studentId = data['student_id'];
        final String name = data['name'];
        final String token = data['token'];
        final String tokenExpiresAt = data['token_expires_at'];
        final String branch = data['branch'];
        final int year = data['year'];
        final String division = data['division'];
        final String batch = data['batch'];
        final String rollNumber = data['roll_number'] ?? '';

        // Save auth data
        final authService = AuthService();
        await authService.saveAuthData(
          token: token,
          tokenExpiresAt: tokenExpiresAt,
          studentId: studentId.toString(),
          name: name,
          email: email,
          rollNumber: rollNumber,
          branch: branch,
          year: year,
          division: division,
          batch: batch,
        );

        // Create Student object
        final student = Student(
          name: name,
          studentId: studentId.toString(),
          rollNumber: rollNumber,
          college: 'Your College',
          course: branch,
          year: year,
          division: division,
          batch: batch,
          token: token,
        );

        if (!mounted) return;

        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (context) => HomePage(student: student)),
        );
      } else {
        // ------------------------------------------------------
        // LOGIN FAILED
        // ------------------------------------------------------

        // The backend reports the real reason (for example a pending or
        // rejected account) in `detail`; `message` is only sent on success.
        final message =
            data['message'] ?? data['detail'] ?? 'Invalid email or password';

        if (!mounted) return;

        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(message)));
      }
    } catch (e) {
      // --------------------------------------------------------
      // CONNECTION ERROR
      // --------------------------------------------------------

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

  // ==========================================================
  // LOGIN UI
  // ==========================================================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: const GlassAppBar(
        title: Text('Student Login'),
        automaticallyImplyLeading: false,
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
                    Icons.school_rounded,
                    size: 48,
                    color: GlassColors.primaryBlue,
                  ),
                ),

                const SizedBox(height: 24),

                const Text(
                  'Welcome Back',
                  style: TextStyle(
                    fontSize: 32,
                    fontWeight: FontWeight.bold,
                    color: GlassColors.heading,
                    letterSpacing: -0.5,
                  ),
                ),

                const SizedBox(height: 8),

                const Text(
                  'Login to your Stryve account',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 16,
                    color: GlassColors.secondaryText,
                    height: 1.5,
                  ),
                ),

                const SizedBox(height: 40),

                // EMAIL
                GlassTextField(
                  controller: emailController,
                  keyboardType: TextInputType.emailAddress,
                  labelText: 'Gmail',
                  hintText: 'example@gmail.com',
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
                      color: GlassColors.secondaryText,
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
                  child: const Text(
                    'LOGIN',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.5,
                    ),
                  ),
                ),

                const SizedBox(height: 20),

                // REGISTER
                TextButton(
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => const StudentRegisterPage(),
                      ),
                    );
                  },
                  child: const Text(
                    "Don't have an account? Register",
                    style: TextStyle(
                      fontSize: 15,
                      color: GlassColors.primaryBlue,
                      fontWeight: FontWeight.w500,
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

// ============================================================
// STUDENT REGISTRATION PAGE
// ============================================================

class StudentRegisterPage extends StatefulWidget {
  const StudentRegisterPage({super.key, this.client});

  /// Optional injectable HTTP client (tests); defaults to a real client.
  final http.Client? client;

  @override
  State<StudentRegisterPage> createState() => _StudentRegisterPageState();
}

class _StudentRegisterPageState extends State<StudentRegisterPage> {
  http.Client? _ownedClient;

  http.Client get _client => widget.client ?? (_ownedClient ??= http.Client());

  /// Wait this long after the last keystroke before asking the backend.
  ///
  /// The lookup endpoint is public and rate limited, so typing "72" must not
  /// fire two requests per keystroke.
  static const lookupDebounce = Duration(milliseconds: 400);

  Timer? _lookupDebounce;
  // ==========================================================
  // CONTROLLERS
  // ==========================================================

  final emailController = TextEditingController();

  final rollNumberController = TextEditingController();

  final passwordController = TextEditingController();

  final confirmPasswordController = TextEditingController();

  bool obscurePassword = true;

  bool obscureConfirmPassword = true;

  bool isLoading = false;

  // Student details fetched from registry (read-only).
  // The name is MASKED by the backend (initials only): the public lookup must
  // not hand out official full names to anyone who guesses a roll number.
  String? fetchedNameMasked;
  String? fetchedBranch;
  int? fetchedYear;
  String? fetchedDivision;
  String? fetchedBatch;
  bool isLookingUp = false;
  String? lookupError;

  @override
  void dispose() {
    _lookupDebounce?.cancel();
    emailController.dispose();
    rollNumberController.dispose();
    passwordController.dispose();
    confirmPasswordController.dispose();
    _ownedClient?.close();
    super.dispose();
  }

  // ==========================================================
  // ROLL NUMBER LOOKUP
  // ==========================================================

  /// Debounced entry point for the roll-number field: one request per typing
  /// pause instead of one per keystroke.
  void _onRollNumberChanged(String _) {
    _lookupDebounce?.cancel();
    _lookupDebounce = Timer(lookupDebounce, _lookupRollNumber);
  }

  Future<void> _lookupRollNumber() async {
    final rollNumber = rollNumberController.text.trim();
    if (rollNumber.isEmpty) return;

    setState(() {
      isLookingUp = true;
      lookupError = null;
      fetchedNameMasked = null;
      fetchedBranch = null;
      fetchedYear = null;
      fetchedDivision = null;
      fetchedBatch = null;
    });

    try {
      final baseUrl = Environment.backendUrl;
      final uri = Uri.parse(baseUrl).resolve('students/lookup/$rollNumber');

      final response = await _client.get(
        uri,
        headers: {'Content-Type': 'application/json'},
      );

      if (!mounted) return;

      // Ignore a reply for a roll number the student has already changed.
      if (rollNumber != rollNumberController.text.trim()) return;

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        setState(() {
          // The backend returns the official name MASKED (initials only).
          fetchedNameMasked = data['masked_name'];
          fetchedBranch = data['branch'];
          fetchedYear = data['year'];
          fetchedDivision = data['division'];
          fetchedBatch = data['batch'];
          isLookingUp = false;
        });
      } else if (response.statusCode == 429) {
        // The public lookup is rate limited; say so instead of pretending the
        // roll number is wrong.
        final data = jsonDecode(response.body);
        setState(() {
          lookupError = data['detail'] ??
              'Too many lookup attempts. Please wait a moment and try again.';
          isLookingUp = false;
        });
      } else if (response.statusCode == 404 || response.statusCode == 400) {
        final data = jsonDecode(response.body);
        setState(() {
          lookupError = data['detail'] ?? 'Roll number not found';
          isLookingUp = false;
        });
      } else {
        setState(() {
          lookupError = 'Failed to lookup roll number';
          isLookingUp = false;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        lookupError = 'Could not connect to server. Please check your connection.';
        isLookingUp = false;
      });
    }
  }

  // ==========================================================
  // REGISTER
  // ==========================================================

  Future<void> register() async {
    final email = emailController.text.trim();
    final rollNumber = rollNumberController.text.trim();
    final password = passwordController.text;
    final confirmPassword = confirmPasswordController.text;

    // ----------------------------------------------------------
    // BASIC VALIDATION
    // ----------------------------------------------------------

    if (email.isEmpty || rollNumber.isEmpty || password.isEmpty || confirmPassword.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please fill in all required fields.')),
      );
      return;
    }

    // Check if roll number was looked up
    if (fetchedNameMasked == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter your roll number and wait for lookup to complete.')),
      );
      return;
    }

    // ----------------------------------------------------------
    // EMAIL VALIDATION
    // ----------------------------------------------------------

    final emailError = validateGmail(email);
    if (emailError != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(emailError)));
      return;
    }

    // ----------------------------------------------------------
    // PASSWORD VALIDATION
    // ----------------------------------------------------------

    if (password.length < 6) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Password must be at least 6 characters.')),
      );
      return;
    }

    if (password != confirmPassword) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Passwords do not match.')),
      );
      return;
    }

    setState(() {
      isLoading = true;
    });

    try {
      final response = await _client.post(
        Uri.parse('${Environment.backendUrl}/register'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'roll_number': rollNumberController.text.trim(),
          'email': email,
          'password': password,
          'confirm_password': confirmPassword,
        }),
      );

      final data = jsonDecode(response.body);

      if (!mounted) return;

      if (response.statusCode == 201) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(data['message'] ?? 'Registration submitted for approval')),
        );
        if (mounted) {
          Navigator.pop(context);
        }
      } else {
        final message = data['message'] ?? data['detail'] ?? 'Registration failed';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(message)),
        );
      }
    } catch (e) {
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

  // ==========================================================
  // REGISTRATION UI
  // ==========================================================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: const GlassAppBar(
        title: Text('Student Registration'),
        automaticallyImplyLeading: false,
      ),
      body: GlassBackground(
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              children: [
                const SizedBox(height: 20),

                // Glass icon container
                GlassContainer(
                  width: 90,
                  height: 90,
                  borderRadius: 24,
                  blurStrength: 25,
                  opacity: 0.8,
                  borderOpacity: 0.5,
                  padding: const EdgeInsets.all(20),
                  child: const Icon(
                    Icons.person_add_alt_1_rounded,
                    size: 44,
                    color: GlassColors.primaryBlue,
                  ),
                ),

                const SizedBox(height: 18),

                const Text(
                  'Create Student Account',
                  style: TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.bold,
                    color: GlassColors.heading,
                    letterSpacing: -0.5,
                  ),
                ),

                const SizedBox(height: 30),

                // ROLL NUMBER
                GlassTextField(
                  controller: rollNumberController,
                  keyboardType: TextInputType.number,
                  labelText: 'Roll Number',
                  hintText: 'Enter your roll number',
                  prefixIcon: const Icon(Icons.badge_rounded),
                  onChanged: _onRollNumberChanged,
                ),

                if (isLookingUp) ...[
                  const SizedBox(height: 16),
                  const Center(
                    child: SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation<Color>(GlassColors.primaryBlue),
                      ),
                    ),
                  ),
                ],

                if (lookupError != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    lookupError!,
                    style: const TextStyle(
                      fontSize: 14,
                      color: GlassColors.error,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ],

                if (fetchedNameMasked != null) ...[
                  const SizedBox(height: 16),

                  // FETCHED STUDENT DETAILS (READ-ONLY)
                  GlassContainer(
                    width: double.infinity,
                    padding: const EdgeInsets.all(16),
                    borderRadius: 16,
                    blurStrength: 15,
                    opacity: 0.6,
                    borderOpacity: 0.3,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Verified Student Details',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: GlassColors.secondaryText,
                          ),
                        ),
                        const SizedBox(height: 12),
                        _buildDetailRow('Name (masked)', fetchedNameMasked!),
                        _buildDetailRow('Branch / Course', fetchedBranch!),
                        _buildDetailRow('Year', fetchedYear.toString()),
                        _buildDetailRow('Division', fetchedDivision!),
                        _buildDetailRow('Batch', fetchedBatch!),
                        const SizedBox(height: 10),
                        const Text(
                          'Only the initials of your official name are shown here. '
                          'Your full name is visible to the staff who review this '
                          'request.',
                          style: TextStyle(
                            fontSize: 12,
                            color: GlassColors.secondaryText,
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 20),

                ],

                // EMAIL
                GlassTextField(
                  controller: emailController,
                  keyboardType: TextInputType.emailAddress,
                  labelText: 'Gmail',
                  hintText: 'example@gmail.com',
                  prefixIcon: const Icon(Icons.email_rounded),
                ),

                const SizedBox(height: 16),

                // PASSWORD
                GlassTextField(
                  controller: passwordController,
                  obscureText: obscurePassword,
                  labelText: 'Password',
                  hintText: 'Enter password',
                  prefixIcon: const Icon(Icons.lock_rounded),
                  suffixIcon: IconButton(
                    icon: Icon(
                      obscurePassword
                          ? Icons.visibility_rounded
                          : Icons.visibility_off_rounded,
                      color: GlassColors.secondaryText,
                    ),
                    onPressed: () {
                      setState(() {
                        obscurePassword = !obscurePassword;
                      });
                    },
                  ),
                ),

                const SizedBox(height: 16),

                // CONFIRM PASSWORD
                GlassTextField(
                  controller: confirmPasswordController,
                  obscureText: obscureConfirmPassword,
                  labelText: 'Confirm Password',
                  hintText: 'Confirm password',
                  prefixIcon: const Icon(Icons.lock_outline_rounded),
                  suffixIcon: IconButton(
                    icon: Icon(
                      obscureConfirmPassword
                          ? Icons.visibility_rounded
                          : Icons.visibility_off_rounded,
                      color: GlassColors.secondaryText,
                    ),
                    onPressed: () {
                      setState(() {
                        obscureConfirmPassword = !obscureConfirmPassword;
                      });
                    },
                  ),
                ),

                const SizedBox(height: 28),

                // CREATE ACCOUNT
                GlassButton(
                  onPressed: isLoading ? null : register,
                  isLoading: isLoading,
                  height: 56,
                  borderRadius: 16,
                  child: const Text(
                    'SUBMIT FOR APPROVAL',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.5,
                    ),
                  ),
                ),

                const SizedBox(height: 20),

                // BACK TO LOGIN
                TextButton(
                  onPressed: () {
                    Navigator.pop(context);
                  },
                  child: const Text(
                    'Already have an account? Login',
                    style: TextStyle(
                      fontSize: 15,
                      color: GlassColors.primaryBlue,
                      fontWeight: FontWeight.w500,
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

  Widget _buildDetailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 100,
            child: Text(
              label,
              style: const TextStyle(
                fontSize: 13,
                color: GlassColors.secondaryText,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(
                fontSize: 13,
                color: GlassColors.heading,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
