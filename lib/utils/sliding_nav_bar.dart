// The app's bottom navigation: one glass bar with a single pill that slides
// between equal-width tab slots.
//
// Motion (transitions.dev "Tabs sliding"):
// * the pill's position (and its width, when a slot's width ever differs)
//   animates over 250 ms on cubic-bezier(0.22, 1, 0.36, 1) - it arrives
//   quickly and settles without overshoot;
// * the icon and label colours animate on the same duration and curve, so the
//   new tab lights up exactly as the pill lands under it;
// * the first build snaps (zero duration): nothing slides in from tab 0 when a
//   screen opens, and the first genuine selection change is what animates;
// * a re-layout (rotation, window resize) re-snaps, because a tab width that
//   changed under the pill is not a tab change and must not be animated.
//
// Layout: every destination gets the same slot (bar width / count), so the pill
// never wobbles between differently sized labels. Labels are always visible -
// the pill identifies the selection, the text does not need to hide to do it.
//
// This is presentation only. Which tabs exist, what they are called and who may
// see them is decided by the screen; the backend still enforces every
// permission.

import 'package:flutter/material.dart';

import 'glass_container.dart';
import 'motion.dart';

/// One destination of a [SlidingNavBar].
///
/// Mirrors Material's [NavigationDestination] for the two things this bar needs:
/// the glyph (two states, so the selected tab can use the filled variant) and
/// the label, plus an optional [key] so a screen can keep addressing a tab in
/// tests as `Key('nav_assignments')`.
class SlidingNavDestination {
  const SlidingNavDestination({
    this.key,
    required this.icon,
    required this.selectedIcon,
    required this.label,
  });

  /// Key placed on the tab's tappable region (not on the icon).
  final Key? key;

  /// Drawn while the tab is not selected.
  final Widget icon;

  /// Drawn while the tab is selected.
  final Widget selectedIcon;

  final String label;
}

/// The sliding-pill bottom navigation.
class SlidingNavBar extends StatefulWidget {
  const SlidingNavBar({
    super.key,
    required this.selectedIndex,
    required this.onDestinationSelected,
    required this.destinations,
    this.height = 60,
    this.pillColor,
    this.pillKey = const Key('nav_pill'),
  });

  /// The slide/colour duration. One value everywhere, so the pill and the text
  /// never disagree about when the selection changed.
  static const Duration slideDuration = Duration(milliseconds: 250);

  /// cubic-bezier(0.22, 1, 0.36, 1): fast start, long ease-out, no bounce.
  static const Curve slideCurve = Cubic(0.22, 1.0, 0.36, 1.0);

  /// The pill floats inside its slot: this much space above, below and to each
  /// side of it.
  static const double pillInset = 4;

  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;
  final List<SlidingNavDestination> destinations;

  /// Height of the tab area (the bar's own padding is added by the caller).
  final double height;

  /// Defaults to the app's blue at 20 %.
  final Color? pillColor;

  /// Key on the sliding pill, so a test can read its position.
  final Key pillKey;

  @override
  State<SlidingNavBar> createState() => _SlidingNavBarState();
}

class _SlidingNavBarState extends State<SlidingNavBar> {
  /// Zero until the first selection change: the bar snaps into place on mount,
  /// then slides for every later change.
  Duration _slide = Duration.zero;

  /// Slot width seen by the previous build, used to tell a tab change
  /// (animate) from a re-layout (snap).
  double? _slotWidth;

  @override
  void didUpdateWidget(SlidingNavBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectedIndex != widget.selectedIndex) {
      _slide = motionDuration(context, SlidingNavBar.slideDuration);
    }
  }

  @override
  Widget build(BuildContext context) {
    final pillColor =
        widget.pillColor ??
        GlassColors.primaryBlue.withValues(alpha: 0.2);

    return SizedBox(
      height: widget.height,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final count = widget.destinations.length;
          final slotWidth = count == 0 ? 0.0 : constraints.maxWidth / count;

          // A slot width that changed under the pill is a re-layout, not a tab
          // change: snap. The value is stored after this build so the next
          // selection change animates again.
          final relaidOut =
              _slotWidth != null && (_slotWidth! - slotWidth).abs() > 0.5;
          final duration = relaidOut ? Duration.zero : _slide;
          _slotWidth = slotWidth;

          final pillWidth = (slotWidth - SlidingNavBar.pillInset * 2)
              .clamp(0.0, slotWidth);
          final pillHeight = widget.height - SlidingNavBar.pillInset * 2;

          return Stack(
            children: [
              // Behind the tabs: the pill. It never takes taps - the Row is
              // painted (and hit-tested) above it.
              AnimatedPositioned(
                key: widget.pillKey,
                duration: duration,
                curve: SlidingNavBar.slideCurve,
                top: SlidingNavBar.pillInset,
                left: widget.selectedIndex * slotWidth + SlidingNavBar.pillInset,
                width: pillWidth,
                height: pillHeight,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: pillColor,
                    borderRadius: BorderRadius.circular(pillHeight / 2),
                  ),
                ),
              ),
              Row(
                children: [
                  for (var i = 0; i < count; i++)
                    _NavTab(
                      destination: widget.destinations[i],
                      selected: i == widget.selectedIndex,
                      onTap: () => widget.onDestinationSelected(i),
                    ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}

class _NavTab extends StatelessWidget {
  const _NavTab({
    required this.destination,
    required this.selected,
    required this.onTap,
  });

  final SlidingNavDestination destination;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final Color target = selected
        ? GlassColors.primaryBlue
        : GlassColors.heading.withValues(alpha: 0.6);

    return Expanded(
      child: Semantics(
        button: true,
        selected: selected,
        label: destination.label,
        child: GestureDetector(
          key: destination.key,
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: TweenAnimationBuilder<Color?>(
            tween: ColorTween(end: target),
            duration: motionDuration(context, SlidingNavBar.slideDuration),
            curve: SlidingNavBar.slideCurve,
            builder: (context, animated, _) {
              final tint = animated ?? target;
              return Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconTheme.merge(
                    data: IconThemeData(size: 22, color: tint),
                    child: selected ? destination.selectedIcon : destination.icon,
                  ),
                  const SizedBox(height: 2),
                  AnimatedDefaultTextStyle(
                    duration: motionDuration(
                      context,
                      SlidingNavBar.slideDuration,
                    ),
                    curve: SlidingNavBar.slideCurve,
                    style: TextStyle(
                      fontSize: 11,
                      height: 1.1,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                      color: tint,
                    ),
                    child: Text(
                      destination.label,
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.fade,
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
