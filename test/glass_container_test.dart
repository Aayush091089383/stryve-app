// GlassContainer shadow semantics.
//
// What is pinned here:
// * passing a fully transparent `shadowColor` removes BOTH shadow layers, so a
//   caller that asks for a flat surface actually gets one - the nav bar used to
//   keep a hardcoded secondary shadow (blur 40, offset (0, 8)) that read as a
//   halo around the pill, biased towards the bottom edge;
// * the default (no shadowColor override) still draws both layers, so the fix
//   cannot silently flatten every other glass surface in the app.
//
// Safety: pure widget test, no backend, no database.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:campus_sync/utils/glass_container.dart';

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
}
