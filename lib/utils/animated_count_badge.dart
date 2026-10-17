import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

import 'glass_container.dart';
import 'motion.dart';

/// A count badge that springs into place when the count appears or grows.
///
/// Motion: the badge enters diagonally from its top-right corner while scaling
/// up, overshoots slightly, then settles - a spring, not a fixed-duration curve,
/// so the settle looks physical without being bouncy.
///
/// It animates ONLY on a genuine change:
/// * count 0 -> n (a new item appeared),
/// * n -> m where m > n (something new arrived),
/// * the first time it is built with a non-zero count.
/// A plain rebuild with the same count never replays it, because the decision
/// lives in [didUpdateWidget], not in [build].
///
/// Count 0 hides the badge entirely; a null/unknown count must be passed as 0
/// so "we could not fetch it" is never rendered as a badge.
class AnimatedCountBadge extends StatefulWidget {
  const AnimatedCountBadge({
    super.key,
    required this.count,
    required this.child,
  });

  /// Number of pending items. 0 hides the badge.
  final int count;

  /// The icon (or other widget) the badge is attached to.
  final Widget child;

  @override
  State<AnimatedCountBadge> createState() => _AnimatedCountBadgeState();
}

class _AnimatedCountBadgeState extends State<AnimatedCountBadge>
    with SingleTickerProviderStateMixin {
  /// Unbounded: a spring is allowed to pass 1.0, which is exactly what makes
  /// the overshoot visible. A bounded controller would clamp it away.
  late final AnimationController _controller =
      AnimationController.unbounded(vsync: this, value: 1);

  bool _reducedMotion = false;

  /// Spring description: a damping ratio of ~0.69 (mass 1, stiffness 300,
  /// damping 24) gives a small, settled overshoot instead of a bounce.
  static const SpringDescription _spring = SpringDescription(
    mass: 1,
    stiffness: 300,
    damping: 24,
  );

  @override
  void initState() {
    super.initState();
    if (widget.count > 0) {
      // Play after the first frame: the reduced-motion flag is read from
      // MediaQuery, which is not available during initState.
      _controller.value = 0;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _play();
      });
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reducedMotion = isMotionReduced(context);
  }

  @override
  void didUpdateWidget(AnimatedCountBadge oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.count > 0 &&
        (oldWidget.count <= 0 || widget.count > oldWidget.count)) {
      _play();
    }
  }

  void _play() {
    if (_reducedMotion) {
      _controller.value = 1;
      return;
    }
    _controller.value = 0;
    _controller.animateWith(
      SpringSimulation(_spring, 0, 1, 0),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        widget.child,
        if (widget.count > 0)
          Positioned(
            top: -6,
            right: -8,
            child: AnimatedBuilder(
              animation: _controller,
              builder: (context, child) {
                final progress = _controller.value.clamp(0.0, 1.0);
                final scale = 0.55 + 0.45 * _controller.value;
                return Opacity(
                  opacity: progress,
                  child: Transform.translate(
                    offset: Offset(6 * (1 - progress), -6 * (1 - progress)),
                    child: Transform.scale(scale: scale, child: child),
                  ),
                );
              },
              child: _BadgePill(count: widget.count),
            ),
          ),
      ],
    );
  }
}

class _BadgePill extends StatelessWidget {
  const _BadgePill({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final label = count > 99 ? '99+' : '$count';
    return Semantics(
      label: '$count pending',
      // The pill's own text would otherwise be announced a second time.
      excludeSemantics: true,
      child: Container(
        height: 18,
        constraints: const BoxConstraints(minWidth: 18),
        padding: EdgeInsets.symmetric(horizontal: label.length > 1 ? 5 : 0),
        decoration: BoxDecoration(
          color: GlassColors.primaryBlue,
          borderRadius: BorderRadius.circular(9),
          border: Border.all(color: GlassColors.surface, width: 1.5),
          boxShadow: [
            BoxShadow(
              color: GlassColors.heading.withValues(alpha: 0.18),
              blurRadius: 6,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Center(
          child: Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 10.5,
              fontWeight: FontWeight.w700,
              height: 1,
            ),
          ),
        ),
      ),
    );
  }
}
