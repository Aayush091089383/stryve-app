// Role chooser treatment.
//
// What is pinned here:
// * both roles are equal choices: the same solid blue fill, so the teacher
//   option is no longer the outlined "secondary" variant;
// * both labels are solid white (alpha 255) and so are both icons. The labels
//   used to set no colour at all, so they inherited the ambient body text
//   colour (a muted grey-blue) and read as washed out on the blue fill;
// * the labels are title case and carry no letter spacing, and the buttons are
//   shorter than the previous 64dp while staying above the 48dp touch minimum;
// * the two buttons share one geometry, so they cannot drift apart;
// * tapping still routes each role to its own login screen.
//
// Safety: pure widget test, no backend, no database.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:stryve/login_page.dart';
import 'package:stryve/role_selection_page.dart';
import 'package:stryve/teacher_login_page.dart';
import 'package:stryve/utils/glass_container.dart';

Future<void> pumpRoleSelection(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(const MaterialApp(home: RoleSelectionPage()));
  await tester.pump();
}

void main() {
  testWidgets('both roles use the same solid blue button, none outlined', (
    tester,
  ) async {
    await pumpRoleSelection(tester);

    final buttons = tester
        .widgetList<GlassButton>(find.byType(GlassButton))
        .toList();

    expect(buttons, hasLength(2));
    for (final button in buttons) {
      expect(
        button.color,
        GlassColors.primaryBlue,
        reason: 'both roles are primary: same solid fill, no bordered variant',
      );
    }
    expect(
      find.byType(GlassOutlinedButton),
      findsNothing,
      reason: 'the teacher path is not a secondary, outlined choice',
    );
  });

  testWidgets('both labels are solid white title case with white icons', (
    tester,
  ) async {
    await pumpRoleSelection(tester);

    for (final label in ['Student', 'Teacher']) {
      final text = tester.widget<Text>(find.text(label));
      expect(text.style!.color, Colors.white, reason: '"$label" must be white');
      expect(
        text.style!.color!.a,
        1.0,
        reason: '"$label" must be fully opaque, not tinted or translucent',
      );
      expect(text.style!.letterSpacing, 0, reason: 'no tracking on "$label"');
      // Title case, not the old form-field style.
      expect(find.text(label.toUpperCase()), findsNothing);
    }

    final icons = tester.widgetList<Icon>(
      find.descendant(
        of: find.byType(GlassButton),
        matching: find.byType(Icon),
      ),
    );

    expect(icons, hasLength(2));
    for (final icon in icons) {
      expect(icon.color, Colors.white);
      expect(icon.size, 24);
    }
  });

  testWidgets('both roles share one shorter geometry', (tester) async {
    await pumpRoleSelection(tester);

    final buttons = tester
        .widgetList<GlassButton>(find.byType(GlassButton))
        .toList();

    expect(buttons.map((button) => button.height).toSet(), {54.0});
    expect(buttons.map((button) => button.borderRadius).toSet(), {18.0});
    expect(
      buttons.first.height,
      greaterThanOrEqualTo(48),
      reason: 'still a compliant touch target',
    );
    expect(
      buttons.first.height,
      lessThan(64),
      reason: 'shorter than the previous 64dp',
    );

    final student = tester.widget<Text>(find.text('Student'));
    final teacher = tester.widget<Text>(find.text('Teacher'));
    expect(student.style!.fontSize, teacher.style!.fontSize);
    expect(student.style!.fontWeight, teacher.style!.fontWeight);

    expect(
      tester.getSize(find.widgetWithText(GlassButton, 'Student')),
      tester.getSize(find.widgetWithText(GlassButton, 'Teacher')),
      reason: 'same width and height for both roles',
    );
  });

  testWidgets('each role still opens its own login screen', (tester) async {
    await pumpRoleSelection(tester);
    await tester.tap(find.text('Student'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byType(LoginPage), findsOneWidget);

    // A fresh tree: the student tap left LoginPage pushed on the same
    // navigator, so re-pumping the page would otherwise sit behind it.
    await tester.pumpWidget(const SizedBox.shrink());
    await pumpRoleSelection(tester);
    await tester.tap(find.text('Teacher'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byType(TeacherLoginPage), findsOneWidget);
  });
}
