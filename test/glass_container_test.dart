// GlassContainer shadow semantics.
//
// What is pinned here:
// * passing a fully transparent `shadowColor` removes BOTH shadow layers, so a
//   caller that asks for a flat surface actually gets one - the nav bar used to
//   keep a hardcoded secondary shadow (blur 40, offset (0, 8)) that read as a
//   halo around the pill, biased towards the bottom edge;
// * the default (no shadowColor override) still draws both layers, so the fix
//   cannot silently flatten every other glass surface in the app;
// * no surface runs a backdrop filter: the faux-glass gradient replaced it in
//   both themes, and a nested tile behind a card no longer costs a second
//   clip + blur pass;
// * the light fill is the faux-glass gradient (white 0.85 -> 0.65), and
//   `useBlur: false` still paints that surface without changing the shadow
//   contract.
//
// Safety: pure widget test, no backend, no database.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:stryve/utils/glass_container.dart';

/// The `BoxDecoration` the glass surface actually paints with.
///
/// `GlassContainer` paints exactly one decorated `Container` (the child it is
/// given is a plain `SizedBox` here), so scoping the search to the container's
/// own subtree cannot pick up an unrelated surface.
BoxDecoration glassDecoration(WidgetTester tester) {
  final container = tester.widget<Container>(
    find
        .descendant(
          of: find.byType(GlassContainer),
          matching: find.byType(Container),
        )
        .first,
  );
  final decoration = container.decoration;
  expect(decoration, isA<BoxDecoration>());
  return decoration! as BoxDecoration;
}

void main() {
  testWidgets('a fully transparent shadowColor removes every shadow layer', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: GlassContainer(
            shadowColor: Colors.transparent,
            child: SizedBox(width: 100, height: 100),
          ),
        ),
      ),
    );

    final decoration = glassDecoration(tester);

    // Both layers are gone, including the hardcoded secondary one.
    expect(decoration.boxShadow, isEmpty);
    // ...and the rest of the glass surface is untouched.
    expect(decoration.gradient, isNotNull);
    expect(decoration.border, isNotNull);
  });

  testWidgets('neither a parent nor a nested surface runs a backdrop filter', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: GlassContainer(
            child: GlassContainer(child: SizedBox(width: 40, height: 40)),
          ),
        ),
      ),
    );

    final surfaces = find.byType(GlassContainer);
    expect(surfaces, findsNWidgets(2));
    expect(find.byType(BackdropFilter), findsNothing);

    // Both paint the faux-glass fill, so the inner tile still reads as glass.
    for (var index = 0; index < 2; index++) {
      final container = tester.widget<Container>(
        find
            .descendant(
              of: surfaces.at(index),
              matching: find.byType(Container),
            )
            .first,
      );
      expect(
        (container.decoration! as BoxDecoration).gradient,
        isA<LinearGradient>(),
      );
    }
  });

  testWidgets('the light fill is a white faux-glass gradient', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: GlassContainer(child: SizedBox(width: 40, height: 40)),
        ),
      ),
    );

    expect(find.byType(BackdropFilter), findsNothing);

    final gradient = glassDecoration(tester).gradient! as LinearGradient;
    expect(gradient.begin, Alignment.topLeft);
    expect(gradient.end, Alignment.bottomRight);
    expect(gradient.colors, hasLength(3));
    // White at 85% down to 65%: bright enough for the navy text to stay
    // readable, faint enough to keep the page gradient behind it.
    expect(gradient.colors.first, Colors.white.withValues(alpha: 0.85));
    expect(gradient.colors.last, Colors.white.withValues(alpha: 0.65));
    expect(gradient.colors[1].a, inInclusiveRange(0.65, 0.85));
  });

  testWidgets('the default surface still draws both shadow layers', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: GlassContainer(child: SizedBox(width: 100, height: 100)),
        ),
      ),
    );

    final decoration = glassDecoration(tester);

    expect(decoration.boxShadow, hasLength(2));
    // Neither layer is invisible: the primary one honours the default colour
    // and the secondary one keeps its own hardcoded tint.
    expect(decoration.boxShadow!.first.color.a, greaterThan(0));
    expect(decoration.boxShadow!.last.color.a, greaterThan(0));
  });

  testWidgets('useBlur: false paints the surface without a filter', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: GlassContainer(
            useBlur: false,
            child: SizedBox(width: 100, height: 100),
          ),
        ),
      ),
    );

    expect(find.byType(BackdropFilter), findsNothing);
    final decoration = glassDecoration(tester);
    expect(decoration.gradient, isA<LinearGradient>());
    expect(decoration.border, isNotNull);
    expect(decoration.boxShadow, hasLength(2));
  });

  testWidgets('GlassCard forwards useBlur to its container', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: GlassCard(
            useBlur: false,
            child: SizedBox(width: 100, height: 60),
          ),
        ),
      ),
    );

    expect(find.byType(BackdropFilter), findsNothing);
    expect(
      tester.widget<GlassContainer>(find.byType(GlassContainer)).useBlur,
      isFalse,
    );
  });
}
