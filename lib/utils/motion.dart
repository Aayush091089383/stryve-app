import 'package:flutter/widgets.dart';

/// Shared motion timings, so every animation in the app stays in one family.
///
/// Fast: press feedback. Just long enough to be seen, never long enough to
/// delay the action itself.
const Duration kMotionPress = Duration(milliseconds: 90);

/// Standard: content swaps and page transitions.
const Duration kMotionStandard = Duration(milliseconds: 220);

/// The badge's spring needs a little longer to settle its overshoot.
const Duration kMotionBadge = Duration(milliseconds: 340);

/// The platform's "reduce motion" preference (Android: Remove animations).
bool isMotionReduced(BuildContext context) =>
    MediaQuery.disableAnimationsOf(context);

/// [base], or zero when the user asked the platform for reduced motion.
///
/// An implicit animation with a zero duration still applies its final value on
/// the next frame, so the end state is always correct - it simply arrives
/// without motion.
Duration motionDuration(BuildContext context, Duration base) =>
    isMotionReduced(context) ? Duration.zero : base;
