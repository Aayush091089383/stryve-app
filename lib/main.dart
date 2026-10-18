import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'role_selection_page.dart';
import 'home_page.dart';
import 'teacher_panel_page.dart';
import 'services/auth_service.dart';
import 'services/teacher_auth_service.dart';

export 'role_selection_page.dart';
export 'home_page.dart';
export 'teacher_panel_page.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  // Use edge-to-edge with light status/navigation bars matching glassmorphism design
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.dark,
    statusBarBrightness: Brightness.light,
    systemNavigationBarColor: Colors.transparent,
    systemNavigationBarIconBrightness: Brightness.dark,
    systemNavigationBarDividerColor: Colors.transparent,
  ));

  runApp(const StryveApp());
}

class StryveApp extends StatelessWidget {
  const StryveApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Stryve',

      theme: _buildGlassmorphismTheme(),

      scrollBehavior: const MaterialScrollBehavior().copyWith(
        overscroll: false,
      ),

      home: const AuthCheckPage(),
    );
  }

  ThemeData _buildGlassmorphismTheme() {
    // Light-blue glassmorphism color palette
    const Color primaryBlue = Color(0xFF2563EB);
    const Color primaryBlueDark = Color(0xFF1D4ED8);
    const Color heading = Color(0xFF183153);
    const Color secondaryText = Color(0xFF5B708B);
    const Color background = Color(0xFFF3F8FE);
    const Color surface = Color(0xFFFFFFFF);
    const Color border = Color(0xFFD7E5F5);
    const Color disabled = Color(0xFF9CAFBF);
    const Color error = Color(0xFFE74C3C);

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      scaffoldBackgroundColor: background,
      colorScheme: ColorScheme.light(
        primary: primaryBlue,
        secondary: primaryBlueDark,
        tertiary: heading,
        surface: surface,
        onPrimary: Colors.white,
        onSecondary: Colors.white,
        onSurface: heading,
        outline: border,
        outlineVariant: border.withValues(alpha: 0.5),
        shadow: heading.withValues(alpha: 0.08),
        error: error,
        onError: Colors.white,
      ),
      // One transition for every route. Every screen is pushed with
      // MaterialPageRoute, so this changes the motion without touching a
      // single Navigator call site: route history, back handling, deep links
      // and the auth/role redirects all behave exactly as before.
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: <TargetPlatform, PageTransitionsBuilder>{
          TargetPlatform.android: _FadeSlidePageTransitionsBuilder(),
          TargetPlatform.iOS: _FadeSlidePageTransitionsBuilder(),
          TargetPlatform.linux: _FadeSlidePageTransitionsBuilder(),
          TargetPlatform.macOS: _FadeSlidePageTransitionsBuilder(),
          TargetPlatform.windows: _FadeSlidePageTransitionsBuilder(),
          TargetPlatform.fuchsia: _FadeSlidePageTransitionsBuilder(),
        },
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: heading,
          fontSize: 20,
          fontWeight: FontWeight.bold,
        ),
        iconTheme: IconThemeData(color: heading),
        actionsIconTheme: IconThemeData(color: heading),
        systemOverlayStyle: SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: Brightness.dark,
          statusBarBrightness: Brightness.light,
        ),
      ),
      cardTheme: CardThemeData(
        color: surface.withValues(alpha: 0.7),
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shadowColor: heading.withValues(alpha: 0.08),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: border.withValues(alpha: 0.5), width: 1),
        ),
        margin: const EdgeInsets.all(8),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: primaryBlue,
          foregroundColor: Colors.white,
          elevation: 0,
          shadowColor: primaryBlue.withValues(alpha: 0.3),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: primaryBlue,
          side: BorderSide(color: primaryBlue.withValues(alpha: 0.5), width: 1.5),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: primaryBlue,
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surface.withValues(alpha: 0.5),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 16,
        ),
        labelStyle: TextStyle(color: secondaryText),
        hintStyle: TextStyle(color: disabled),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: border.withValues(alpha: 0.3)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: border.withValues(alpha: 0.3)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: primaryBlue, width: 2),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: error, width: 1.5),
        ),
        disabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: border.withValues(alpha: 0.2)),
        ),
        prefixIconColor: secondaryText,
        suffixIconColor: secondaryText,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: surface.withValues(alpha: 0.8),
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        height: 72,
        labelTextStyle: WidgetStateProperty.resolveWith<TextStyle>(
          (states) => TextStyle(
            fontSize: 12,
            fontWeight: states.contains(WidgetState.selected)
                ? FontWeight.w600
                : FontWeight.w400,
            color: states.contains(WidgetState.selected)
                ? primaryBlue
                : secondaryText,
          ),
        ),
        indicatorColor: primaryBlue.withValues(alpha: 0.2),
        iconTheme: WidgetStateProperty.resolveWith<IconThemeData>(
          (states) => IconThemeData(
            color: states.contains(WidgetState.selected)
                ? primaryBlue
                : secondaryText,
            size: 24,
          ),
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: primaryBlue.withValues(alpha: 0.1),
        disabledColor: primaryBlue.withValues(alpha: 0.05),
        selectedColor: primaryBlue.withValues(alpha: 0.2),
        secondarySelectedColor: primaryBlue.withValues(alpha: 0.3),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        labelStyle: TextStyle(color: heading, fontSize: 12),
        secondaryLabelStyle: TextStyle(color: secondaryText, fontSize: 12),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(color: border.withValues(alpha: 0.3)),
        ),
        side: BorderSide(color: border.withValues(alpha: 0.2)),
        brightness: Brightness.light,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: surface.withValues(alpha: 0.95),
        surfaceTintColor: Colors.transparent,
        elevation: 24,
        shadowColor: heading.withValues(alpha: 0.1),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: border.withValues(alpha: 0.3), width: 1),
        ),
        titleTextStyle: TextStyle(
          color: heading,
          fontSize: 20,
          fontWeight: FontWeight.bold,
        ),
        contentTextStyle: TextStyle(
          color: secondaryText,
          fontSize: 16,
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: surface.withValues(alpha: 0.95),
        surfaceTintColor: Colors.transparent,
        elevation: 24,
        shadowColor: heading.withValues(alpha: 0.1),
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          side: BorderSide(color: border, width: 0.5),
        ),
        modalBackgroundColor: surface.withValues(alpha: 0.95),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: heading.withValues(alpha: 0.9),
        contentTextStyle: const TextStyle(color: Colors.white, fontSize: 14),
        actionTextColor: primaryBlue,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: border.withValues(alpha: 0.2)),
        ),
        elevation: 8,
      ),
      dividerTheme: DividerThemeData(
        color: border.withValues(alpha: 0.3),
        thickness: 1,
        space: 1,
      ),
      listTileTheme: ListTileThemeData(
        iconColor: primaryBlue,
        textColor: heading,
        titleTextStyle: TextStyle(
          color: heading,
          fontSize: 16,
          fontWeight: FontWeight.w500,
        ),
        subtitleTextStyle: TextStyle(
          color: secondaryText,
          fontSize: 14,
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        tileColor: surface.withValues(alpha: 0.5),
        selectedTileColor: primaryBlue.withValues(alpha: 0.1),
      ),
      textTheme: TextTheme(
        displayLarge: TextStyle(
          color: heading,
          fontWeight: FontWeight.bold,
        ),
        displayMedium: TextStyle(
          color: heading,
          fontWeight: FontWeight.bold,
        ),
        displaySmall: TextStyle(
          color: heading,
          fontWeight: FontWeight.bold,
        ),
        headlineLarge: TextStyle(
          color: heading,
          fontWeight: FontWeight.bold,
        ),
        headlineMedium: TextStyle(
          color: heading,
          fontWeight: FontWeight.bold,
        ),
        headlineSmall: TextStyle(
          color: heading,
          fontWeight: FontWeight.w600,
        ),
        titleLarge: TextStyle(color: heading, fontWeight: FontWeight.w600),
        titleMedium: TextStyle(
          color: heading,
          fontWeight: FontWeight.w500,
        ),
        titleSmall: TextStyle(
          color: secondaryText,
          fontWeight: FontWeight.w500,
        ),
        bodyLarge: TextStyle(color: heading),
        bodyMedium: TextStyle(color: secondaryText),
        bodySmall: TextStyle(color: disabled),
        labelLarge: TextStyle(color: heading, fontWeight: FontWeight.w600),
      ),
    );
  }
}

/// A quick, quiet page transition: a short fade with a 2% upward slide.
///
/// Deliberately built on the theme (not on individual routes) and kept under
/// 250 ms, so navigation feels lighter than the platform default without
/// becoming a separate navigation path to maintain.
class _FadeSlidePageTransitionsBuilder extends PageTransitionsBuilder {
  const _FadeSlidePageTransitionsBuilder();

  static const Duration _forward = Duration(milliseconds: 220);
  static const Duration _reverse = Duration(milliseconds: 180);

  @override
  Duration get transitionDuration => _forward;

  @override
  Duration get reverseTransitionDuration => _reverse;

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    // Respect the platform's "remove animations" preference: the destination
    // simply appears, fully laid out and interactive.
    if (MediaQuery.disableAnimationsOf(context)) {
      return child;
    }

    final curved = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );

    return FadeTransition(
      opacity: curved,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, 0.02),
          end: Offset.zero,
        ).animate(curved),
        child: child,
      ),
    );
  }
}

class AuthCheckPage extends StatefulWidget {
  const AuthCheckPage({super.key, this.studentAuthService, this.teacherAuthService});
  
  final AuthService? studentAuthService;
  final TeacherAuthService? teacherAuthService;

  @override
  State<AuthCheckPage> createState() => _AuthCheckPageState();
}

class _AuthCheckPageState extends State<AuthCheckPage> {
  @override
  void initState() {
    super.initState();
    _checkAuth();
  }

  Future<void> _checkAuth() async {
    // Check student auth first
    final authService = widget.studentAuthService ?? AuthService();
    final student = await authService.getStudent();

    if (!mounted) return;

    if (student != null) {
      // Validate session with backend before proceeding
      final validation = await authService.validateSession();
      if (!mounted) return;

      if (validation == true) {
        // Valid approved session - proceed to HomePage
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (context) => HomePage(student: student)),
        );
        return;
      } else if (validation == false) {
        // Invalid session (401/403) - already cleared by validateSession
        // Fall through to role selection
      } else {
        // validation == null (backend unreachable)
        // Preserve credentials for retry, go to role selection
        // Student can retry from login screen
      }
    }

    // Check teacher/admin auth
    final teacherAuthService = widget.teacherAuthService ?? TeacherAuthService();
    final teacher = await teacherAuthService.getTeacher();

    if (!mounted) return;

    if (teacher != null) {
      // Validate the teacher session with the backend before opening the panel.
      final teacherValidation = await teacherAuthService.validateSession();
      if (!mounted) return;

      if (teacherValidation == true) {
        // Confirmed valid, active teacher/admin session.
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (context) => const TeacherPanelPage()),
        );
        return;
      }

      // `false` = rejected (401/403): credentials already cleared.
      // `null` = backend unreachable: fail closed and keep credentials so the
      // user can retry later - never open the panel unvalidated.
    }

    // No valid auth - go to role selection
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (context) => const RoleSelectionPage()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(body: Center(child: CircularProgressIndicator()));
  }
}
