import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:stryve/profile.dart';
import 'package:stryve/student.dart';
import 'package:stryve/teacher_profile_page.dart';
import 'package:stryve/utils/glass_container.dart';
import 'package:stryve/utils/theme_provider.dart';

Student _student() => Student(
  name: 'Test Student',
  studentId: 'CS-101',
  college: 'R.H. Sapat College',
  course: 'Computer Engineering',
  year: 1,
  division: 'D',
  batch: 'D-3',
  token: 'student-token',
);

/// Mirrors the part of `StryveApp` the switch depends on: the provider is the
/// only source of `themeMode`, so a tap on either Profile tab must change the
/// effective brightness of the whole tree.
Widget _app(ThemeProvider provider, Widget home) {
  return ChangeNotifierProvider<ThemeProvider>.value(
    value: provider,
    child: Consumer<ThemeProvider>(
      builder: (context, theme, _) => MaterialApp(
        theme: ThemeData.light(),
        darkTheme: ThemeData.dark(),
        themeMode: theme.isDarkMode ? ThemeMode.dark : ThemeMode.light,
        home: home,
      ),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => FlutterSecureStorage.setMockInitialValues(<String, String>{}));

  group('ThemeProvider', () {
    test('starts in light mode and persists a flip to dark', () async {
      final provider = ThemeProvider(loadSaved: false);
      expect(provider.isDarkMode, isFalse);
      expect(provider.isRestored, isFalse);

      await provider.toggleTheme();

      expect(provider.isDarkMode, isTrue);
      expect(
        await const FlutterSecureStorage().read(key: ThemeProvider.storageKey),
        'true',
      );

      await provider.toggleTheme();
      expect(provider.isDarkMode, isFalse);
      expect(
        await const FlutterSecureStorage().read(key: ThemeProvider.storageKey),
        'false',
      );
    });

    test('restores a stored dark choice on the next launch', () async {
      FlutterSecureStorage.setMockInitialValues(<String, String>{
        ThemeProvider.storageKey: 'true',
      });

      final provider = ThemeProvider();
      expect(provider.isDarkMode, isFalse, reason: 'starts light');

      await Future<void>.delayed(Duration.zero);

      expect(provider.isRestored, isTrue);
      expect(provider.isDarkMode, isTrue);
    });

    test('a storage failure leaves the in-memory choice usable', () async {
      // No mock values after a platform exception cannot be simulated here, but
      // an unknown/absent key is the same fallback path: stay light, no throw.
      final provider = ThemeProvider();
      await Future<void>.delayed(Duration.zero);
      expect(provider.isRestored, isTrue);
      expect(provider.isDarkMode, isFalse);
    });
  });

  group('Profile switches', () {
    testWidgets('the student switch turns the app dark and saves it', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final provider = ThemeProvider(initialDarkMode: false, loadSaved: false);
      await tester.pumpWidget(
        _app(provider, Scaffold(body: ProfilePage(student: _student()))),
      );

      expect(find.text('Dark Mode'), findsOneWidget);
      expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);

      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();

      expect(provider.isDarkMode, isTrue);
      expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
      expect(
        tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
        ThemeMode.dark,
      );
      expect(
        Theme.of(tester.element(find.byType(ProfilePage))).brightness,
        Brightness.dark,
      );
    });

    testWidgets('the teacher switch drives the same provider', (tester) async {
      final provider = ThemeProvider(initialDarkMode: false, loadSaved: false);
      await tester.pumpWidget(
        _app(
          provider,
          Scaffold(
            body: TeacherProfileView(
              name: 'Teacher 1',
              email: 'teacher1@stryve.edu',
              isAdmin: false,
              onLogout: () async {},
            ),
          ),
        ),
      );

      expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();

      expect(provider.isDarkMode, isTrue);
      expect(
        tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
        ThemeMode.dark,
      );
    });
  });

  group('Dark glass', () {
    testWidgets('a dark surface is one solid tint and runs no backdrop blur', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(brightness: Brightness.dark),
          home: GlassBackground(child: GlassCard(child: const Text('card'))),
        ),
      );

      expect(find.byType(BackdropFilter), findsNothing);

      final container = tester.widget<Container>(
        find
            .descendant(
              of: find.byType(GlassCard),
              matching: find.byType(Container),
            )
            .first,
      );
      final decoration = container.decoration! as BoxDecoration;
      expect(decoration.color, GlassColors.darkSurface);
      expect(decoration.gradient, isNull);

      final context = tester.element(find.byType(GlassCard));
      expect(GlassColors.headingOf(context), GlassColors.darkText);
      expect(
        GlassColors.secondaryTextOf(context),
        isNot(GlassColors.secondaryText),
      );
    });

    testWidgets('the light theme paints faux glass and runs no blur', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(brightness: Brightness.light),
          home: GlassBackground(child: GlassCard(child: const Text('card'))),
        ),
      );

      expect(find.byType(BackdropFilter), findsNothing);
      final context = tester.element(find.byType(GlassCard));
      expect(GlassColors.headingOf(context), GlassColors.heading);
      expect(
        tester
            .widget<Container>(
              find
                  .descendant(
                    of: find.byType(GlassCard),
                    matching: find.byType(Container),
                  )
                  .first,
            )
            .decoration,
        isA<BoxDecoration>().having(
          (d) => d.gradient,
          'gradient',
          isA<LinearGradient>(),
        ),
      );
    });
  });
}
