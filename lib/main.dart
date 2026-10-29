import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'role_selection_page.dart';
import 'home_page.dart';
import 'teacher_panel_page.dart';
import 'services/app_updater.dart';
import 'services/auth_service.dart';
import 'services/push_notification_service.dart';
import 'services/teacher_auth_service.dart';
import 'utils/glass_container.dart';
import 'utils/theme_provider.dart';

export 'role_selection_page.dart';
export 'home_page.dart';
export 'teacher_panel_page.dart';

// System bars stay edge-to-edge and transparent in both themes; only the
// icon brightness flips. Declared once here and applied per theme below.
const SystemUiOverlayStyle _lightOverlay = SystemUiOverlayStyle(
  statusBarColor: Colors.transparent,
  statusBarIconBrightness: Brightness.dark,
  statusBarBrightness: Brightness.light,
  systemNavigationBarColor: Colors.transparent,
  systemNavigationBarIconBrightness: Brightness.dark,
  systemNavigationBarDividerColor: Colors.transparent,
);

const SystemUiOverlayStyle _darkOverlay = SystemUiOverlayStyle(
  statusBarColor: Colors.transparent,
  statusBarIconBrightness: Brightness.light,
  statusBarBrightness: Brightness.dark,
  systemNavigationBarColor: Colors.transparent,
  systemNavigationBarIconBrightness: Brightness.light,
  systemNavigationBarDividerColor: Colors.transparent,
);

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  // Use edge-to-edge with light status/navigation bars matching glassmorphism design
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(_lightOverlay);

  // A push that arrives while the app is closed is handled in a separate
  // isolate, so the handler has to be registered before anything else runs.
  // Android-only: the Windows build has no FCM implementation.
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
  }

  runApp(const StryveApp());

  // One update check per cold start, Android only, once the first frame is up
  // and after a short delay so it never competes with the session check.
  WidgetsBinding.instance.addPostFrameCallback((_) {
    AppUpdater.scheduleStartupCheck(StryveApp.navigatorKey);
  });
}

class StryveApp extends StatelessWidget {
  const StryveApp({super.key});

  /// The root navigator. The update prompt is pushed from `main()` against this
  /// key, not against a page that the startup check is about to replace.
  static final GlobalKey<NavigatorState> navigatorKey =
      GlobalKey<NavigatorState>();

  /// One transition for every route, in both themes. Every screen is pushed
  /// with MaterialPageRoute, so this changes the motion without touching a
  /// single Navigator call site.
  static const PageTransitionsTheme _pageTransitions = PageTransitionsTheme(
    builders: <TargetPlatform, PageTransitionsBuilder>{
      TargetPlatform.android: _FadeSlidePageTransitionsBuilder(),
      TargetPlatform.iOS: _FadeSlidePageTransitionsBuilder(),
      TargetPlatform.linux: _FadeSlidePageTransitionsBuilder(),
      TargetPlatform.macOS: _FadeSlidePageTransitionsBuilder(),
      TargetPlatform.windows: _FadeSlidePageTransitionsBuilder(),
      TargetPlatform.fuchsia: _FadeSlidePageTransitionsBuilder(),
    },
  );

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider<ThemeProvider>(
      create: (_) => ThemeProvider(),
      child: Consumer<ThemeProvider>(
        builder: (context, theme, _) {
          return MaterialApp(
            navigatorKey: navigatorKey,
            debugShowCheckedModeBanner: false,
            title: 'Stryve',

            theme: _buildGlassmorphismTheme(),
            darkTheme: _buildDarkTheme(),
            // In-app choice only: never follows the system setting, so the
            // switch in the Profile tab is always the single source of truth.
            themeMode: theme.isDarkMode ? ThemeMode.dark : ThemeMode.light,

            scrollBehavior: const MaterialScrollBehavior().copyWith(
              overscroll: false,
            ),

            // The status/navigation icons painted dark at startup would be
            // invisible on the dark backdrop, so every screen - including the
            // ones without an AppBar - declares the right brightness here.
            builder: (context, child) => AnnotatedRegion<SystemUiOverlayStyle>(
              value: theme.isDarkMode ? _darkOverlay : _lightOverlay,
              child: child ?? const SizedBox.shrink(),
            ),

            home: const AuthCheckPage(),
          );
        },
      ),
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
      pageTransitionsTheme: _pageTransitions,
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
          side: BorderSide(
            color: primaryBlue.withValues(alpha: 0.5),
            width: 1.5,
          ),
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
        contentTextStyle: TextStyle(color: secondaryText, fontSize: 16),
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
        subtitleTextStyle: TextStyle(color: secondaryText, fontSize: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        tileColor: surface.withValues(alpha: 0.5),
        selectedTileColor: primaryBlue.withValues(alpha: 0.1),
      ),
      textTheme: TextTheme(
        displayLarge: TextStyle(color: heading, fontWeight: FontWeight.bold),
        displayMedium: TextStyle(color: heading, fontWeight: FontWeight.bold),
        displaySmall: TextStyle(color: heading, fontWeight: FontWeight.bold),
        headlineLarge: TextStyle(color: heading, fontWeight: FontWeight.bold),
        headlineMedium: TextStyle(color: heading, fontWeight: FontWeight.bold),
        headlineSmall: TextStyle(color: heading, fontWeight: FontWeight.w600),
        titleLarge: TextStyle(color: heading, fontWeight: FontWeight.w600),
        titleMedium: TextStyle(color: heading, fontWeight: FontWeight.w500),
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

  /// Dark counterpart of the glass theme.
  ///
  /// Surfaces are solid tints instead of translucent glass: a dark backdrop
  /// blur is both expensive (a full-screen filter on every card) and barely
  /// visible, so dark mode deliberately drops it and keeps the layout, radii
  /// and elevation identical. Colours come from [GlassColors] so a screen that
  /// reads its palette through the theme and a screen that hardcodes a
  /// `GlassColors.*Of(context)` value cannot drift apart.
  ThemeData _buildDarkTheme() {
    const Color primaryBlue = GlassColors.primaryBlue;
    const Color background = GlassColors.darkBackground;
    const Color surface = GlassColors.darkSurface;
    const Color border = GlassColors.darkBorder;
    const Color heading = GlassColors.darkText;
    const Color secondaryText = Color(0xFFA9B7C6);
    const Color disabled = Color(0xFF7A8794);
    const Color error = GlassColors.error;

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: background,
      colorScheme: const ColorScheme.dark(
        primary: primaryBlue,
        secondary: Color(0xFF5B8DEF),
        tertiary: heading,
        surface: surface,
        onPrimary: Colors.white,
        onSecondary: Colors.white,
        onSurface: heading,
        outline: border,
        outlineVariant: Color(0xFF262631),
        shadow: Colors.black,
        error: error,
        onError: Colors.white,
      ),
      pageTransitionsTheme: _pageTransitions,
      appBarTheme: const AppBarTheme(
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
          statusBarIconBrightness: Brightness.light,
          statusBarBrightness: Brightness.dark,
          systemNavigationBarColor: Colors.transparent,
          systemNavigationBarIconBrightness: Brightness.light,
          systemNavigationBarDividerColor: Colors.transparent,
        ),
      ),
      cardTheme: CardThemeData(
        color: surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shadowColor: Colors.black.withValues(alpha: 0.4),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: border.withValues(alpha: 0.8), width: 1),
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
          side: BorderSide(
            color: primaryBlue.withValues(alpha: 0.7),
            width: 1.5,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: const Color(0xFF7BA6F5),
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surface.withValues(alpha: 0.7),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 16,
        ),
        labelStyle: const TextStyle(color: secondaryText),
        hintStyle: const TextStyle(color: disabled),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: border.withValues(alpha: 0.8)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: border.withValues(alpha: 0.8)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: primaryBlue, width: 2),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: error, width: 1.5),
        ),
        disabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: border.withValues(alpha: 0.4)),
        ),
        prefixIconColor: secondaryText,
        suffixIconColor: secondaryText,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: surface.withValues(alpha: 0.95),
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
                ? const Color(0xFF7BA6F5)
                : secondaryText,
          ),
        ),
        indicatorColor: primaryBlue.withValues(alpha: 0.28),
        iconTheme: WidgetStateProperty.resolveWith<IconThemeData>(
          (states) => IconThemeData(
            color: states.contains(WidgetState.selected)
                ? const Color(0xFF7BA6F5)
                : secondaryText,
            size: 24,
          ),
        ),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith<Color>(
          (states) => states.contains(WidgetState.selected)
              ? Colors.white
              : const Color(0xFF8A94A6),
        ),
        trackColor: WidgetStateProperty.resolveWith<Color>(
          (states) => states.contains(WidgetState.selected)
              ? primaryBlue
              : const Color(0xFF3A3A44),
        ),
        trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: primaryBlue.withValues(alpha: 0.18),
        disabledColor: primaryBlue.withValues(alpha: 0.08),
        selectedColor: primaryBlue.withValues(alpha: 0.3),
        secondarySelectedColor: primaryBlue.withValues(alpha: 0.35),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        labelStyle: const TextStyle(color: heading, fontSize: 12),
        secondaryLabelStyle: const TextStyle(
          color: secondaryText,
          fontSize: 12,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(color: border.withValues(alpha: 0.8)),
        ),
        side: BorderSide(color: border.withValues(alpha: 0.6)),
        brightness: Brightness.dark,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        elevation: 24,
        shadowColor: Colors.black.withValues(alpha: 0.5),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: border.withValues(alpha: 0.9), width: 1),
        ),
        titleTextStyle: const TextStyle(
          color: heading,
          fontSize: 20,
          fontWeight: FontWeight.bold,
        ),
        contentTextStyle: const TextStyle(color: secondaryText, fontSize: 16),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        elevation: 24,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        modalBackgroundColor: surface,
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: const Color(0xFF2A2A33),
        contentTextStyle: const TextStyle(color: heading, fontSize: 14),
        actionTextColor: const Color(0xFF7BA6F5),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: border.withValues(alpha: 0.6)),
        ),
        elevation: 8,
      ),
      dividerTheme: DividerThemeData(
        color: border.withValues(alpha: 0.6),
        thickness: 1,
        space: 1,
      ),
      listTileTheme: ListTileThemeData(
        iconColor: const Color(0xFF7BA6F5),
        textColor: heading,
        titleTextStyle: const TextStyle(
          color: heading,
          fontSize: 16,
          fontWeight: FontWeight.w500,
        ),
        subtitleTextStyle: const TextStyle(color: secondaryText, fontSize: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        tileColor: surface.withValues(alpha: 0.6),
        selectedTileColor: primaryBlue.withValues(alpha: 0.2),
      ),
      textTheme: const TextTheme(
        displayLarge: TextStyle(color: heading, fontWeight: FontWeight.bold),
        displayMedium: TextStyle(color: heading, fontWeight: FontWeight.bold),
        displaySmall: TextStyle(color: heading, fontWeight: FontWeight.bold),
        headlineLarge: TextStyle(color: heading, fontWeight: FontWeight.bold),
        headlineMedium: TextStyle(color: heading, fontWeight: FontWeight.bold),
        headlineSmall: TextStyle(color: heading, fontWeight: FontWeight.w600),
        titleLarge: TextStyle(color: heading, fontWeight: FontWeight.w600),
        titleMedium: TextStyle(color: heading, fontWeight: FontWeight.w500),
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
  const AuthCheckPage({
    super.key,
    this.studentAuthService,
    this.teacherAuthService,
  });

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
    final teacherAuthService =
        widget.teacherAuthService ?? TeacherAuthService();
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
