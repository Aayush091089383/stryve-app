import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Owns the app's light/dark choice.
///
/// The switch in the Profile tabs is the only writer: the app never follows the
/// system theme, so what the student picked stays what they get. The choice is
/// kept in the platform's secure storage (the same store as the session
/// tokens), so it survives a restart and a reinstall does not inherit it.
class ThemeProvider extends ChangeNotifier {
  ThemeProvider({
    FlutterSecureStorage? storage,
    bool? initialDarkMode,
    bool loadSaved = true,
  }) : _storage = storage ?? const FlutterSecureStorage(),
       _isDarkMode = initialDarkMode ?? false {
    if (initialDarkMode == null && loadSaved) {
      // Fire and forget: the app starts in light mode and switches as soon as
      // the stored value arrives. Storage failure is not fatal - a theme
      // preference must never stop the app from opening.
      _restore();
    }
  }

  /// Secure-storage key. Namespaced so it cannot collide with a credential.
  static const String storageKey = 'stryve_theme_dark';

  final FlutterSecureStorage _storage;

  bool _isDarkMode;

  /// True once the stored value has been read (or proven unreadable).
  bool _restored = false;

  /// Set as soon as the user flips the switch. A late read must not overwrite
  /// a choice the user just made while storage was still loading.
  bool _userChose = false;

  bool get isDarkMode => _isDarkMode;

  /// Whether the stored preference has finished loading.
  bool get isRestored => _restored;

  Future<void> _restore() async {
    String? saved;
    try {
      saved = await _storage.read(key: storageKey);
    } catch (_) {
      // No secure storage on this platform (or it is locked): stay light.
      saved = null;
    }

    _restored = true;

    if (_userChose) return;

    final shouldBeDark = saved == 'true';
    if (shouldBeDark != _isDarkMode) {
      _isDarkMode = shouldBeDark;
      notifyListeners();
    }
  }

  /// Flips the theme and persists the new value.
  Future<void> toggleTheme() => setDarkMode(!_isDarkMode);

  /// Applies [value] immediately, then writes it to storage.
  ///
  /// The UI must not wait for the disk: the listener is notified first, and a
  /// storage failure leaves the in-memory choice in place for this session.
  Future<void> setDarkMode(bool value) async {
    if (_isDarkMode == value) return;

    _userChose = true;
    _isDarkMode = value;
    notifyListeners();

    try {
      await _storage.write(key: storageKey, value: value ? 'true' : 'false');
    } catch (_) {
      // Best effort: the choice still applies until the app is closed.
    }
  }
}
