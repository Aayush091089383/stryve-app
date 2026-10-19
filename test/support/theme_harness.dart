import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:stryve/utils/theme_provider.dart';

/// Wraps a pumped screen in the app's [ThemeProvider].
///
/// The Profile tabs (student and teacher) read the in-app dark-mode switch from
/// this provider, so a test that pumps those pages directly needs it above the
/// widget - exactly as `StryveApp` provides it in production. Persistence is
/// skipped: tests must not touch a platform channel.
Widget withThemeProvider(Widget child, {bool darkMode = false}) {
  return ChangeNotifierProvider<ThemeProvider>(
    create: (_) => ThemeProvider(initialDarkMode: darkMode, loadSaved: false),
    child: child,
  );
}
