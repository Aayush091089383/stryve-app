// Motion polish: the count badge, press feedback, and reduced-motion handling.
//
// These tests pin the behaviour the polish must NOT change:
// * the badge only animates when a count appears or grows, never on a plain
//   rebuild (otherwise every parent setState would replay it);
// * a count of 0 renders nothing at all (an unknown count is never drawn);
// * tap feedback is visual only - the tap still fires, and the press target
//   scale returns to exactly 1;
// * reduced motion disables the movement but keeps the final state.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:stryve/utils/animated_count_badge.dart';
import 'package:stryve/utils/glass_container.dart';

double _badgeOpacity(WidgetTester tester) {
  final opacity = tester.widget<Opacity>(find.byType(Opacity).first);
  return opacity.opacity;
}

void main() {
  group('AnimatedCountBadge', () {
    testWidgets('count 0 renders no badge', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: AnimatedCountBadge(
              count: 0,
              child: Icon(Icons.notifications_outlined),
            ),
          ),
        ),
      );

      expect(find.byType(Opacity), findsNothing);
      expect(find.text('0'), findsNothing);
    });

    testWidgets('a new count springs in and settles', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: AnimatedCountBadge(
              count: 3,
              child: Icon(Icons.notifications_outlined),
            ),
          ),
        ),
      );

      // Frame 1 is the first layout; the spring is started after it.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));

      expect(find.text('3'), findsOneWidget);
      expect(
        _badgeOpacity(tester),
        lessThan(1.0),
        reason: 'the badge should still be entering, not fully opaque',
      );

      await tester.pumpAndSettle();

      expect(_badgeOpacity(tester), moreOrLessEquals(1.0, epsilon: 0.001));
    });

    testWidgets('a plain rebuild with the same count does not replay',
        (tester) async {
      Widget host(int count, {Key? childKey}) {
        return MaterialApp(
          home: Scaffold(
            body: AnimatedCountBadge(
              key: childKey,
              count: count,
              child: const Icon(Icons.notifications_outlined),
            ),
          ),
        );
      }

      await tester.pumpWidget(host(4));
      await tester.pumpAndSettle();
      expect(_badgeOpacity(tester), moreOrLessEquals(1.0, epsilon: 0.001));

      // Same count, new widget instance: nothing should restart.
      await tester.pumpWidget(host(4));
      await tester.pump(const Duration(milliseconds: 16));

      expect(
        _badgeOpacity(tester),
        moreOrLessEquals(1.0, epsilon: 0.001),
        reason: 'an unrelated rebuild must not replay the entrance',
      );
    });

    testWidgets('an increased count animates again', (tester) async {
      Widget host(int count) => MaterialApp(
            home: Scaffold(
              body: AnimatedCountBadge(
                count: count,
                child: const Icon(Icons.notifications_outlined),
              ),
            ),
          );

      await tester.pumpWidget(host(2));
      await tester.pumpAndSettle();

      await tester.pumpWidget(host(7));
      await tester.pump(const Duration(milliseconds: 16));

      expect(find.text('7'), findsOneWidget);
      expect(_badgeOpacity(tester), lessThan(1.0));
      await tester.pumpAndSettle();
      expect(_badgeOpacity(tester), moreOrLessEquals(1.0, epsilon: 0.001));
    });

    testWidgets('reduced motion shows the badge without movement',
        (tester) async {
      await tester.pumpWidget(
        const MediaQuery(
          data: MediaQueryData(disableAnimations: true),
          child: MaterialApp(
            home: Scaffold(
              body: AnimatedCountBadge(
                count: 5,
                child: Icon(Icons.notifications_outlined),
              ),
            ),
          ),
        ),
      );

      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));

      expect(find.text('5'), findsOneWidget);
      expect(_badgeOpacity(tester), moreOrLessEquals(1.0, epsilon: 0.001));
    });

    testWidgets('large counts are capped so the icon never stretches',
        (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: AnimatedCountBadge(
              count: 128,
              child: Icon(Icons.notifications_outlined),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('99+'), findsOneWidget);
      expect(find.text('128'), findsNothing);
    });
  });

  group('GlassContainer press feedback', () {
    testWidgets('scales while pressed and still fires the tap', (tester) async {
      var taps = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: GlassCard(
                onTap: () => taps++,
                child: const SizedBox(width: 200, height: 80),
              ),
            ),
          ),
        ),
      );

      expect(tester.widget<AnimatedScale>(find.byType(AnimatedScale)).scale, 1);

      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(GlassCard)),
      );
      await tester.pump(const Duration(milliseconds: 16));

      expect(
        tester.widget<AnimatedScale>(find.byType(AnimatedScale)).scale,
        lessThan(1),
      );

      await gesture.up();
      await tester.pumpAndSettle();

      expect(taps, 1, reason: 'the action must fire, not be delayed by motion');
      expect(
        tester.widget<AnimatedScale>(find.byType(AnimatedScale)).scale,
        1,
      );
    });

    testWidgets('no press feedback when the surface is not tappable',
        (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Center(
              child: GlassCard(child: SizedBox(width: 120, height: 60)),
            ),
          ),
        ),
      );

      expect(find.byType(AnimatedScale), findsNothing);
    });
  });
}
