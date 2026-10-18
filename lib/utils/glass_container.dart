import 'package:flutter/material.dart';

import 'dart:ui';

import 'motion.dart';

/// Color constants for the light-blue glassmorphism theme.
class GlassColors {
  static const Color background = Color(0xFFF3F8FE);
  static const Color surface = Color(0xFFFFFFFF);
  static const Color border = Color(0xFFD7E5F5);
  static const Color primaryBlue = Color(0xFF2563EB);
  static const Color primaryBlueDark = Color(0xFF1D4ED8);
  static const Color heading = Color(0xFF183153);
  static const Color secondaryText = Color(0xFF5B708B);
  static const Color disabled = Color(0xFF9CAFBF);
  static const Color error = Color(0xFFE74C3C);
  static const Color success = Color(0xFF10B981);
  static const Color warning = Color(0xFFF59E0B);
}

/// Marks the content painted *on top of* a glass surface.
///
/// The engine can perform one shared backdrop blur for several [BackdropFilter]
/// widgets that use the same backdrop key, but filters that overlap each other
/// must not share a key: the overlapping region would then be filtered only
/// once. [GlassContainer] is used nested - a small glass tile inside a glass
/// card - so each surface marks its own child here. A nested surface therefore
/// keeps its own private blur, exactly as it always had, while the sibling
/// surfaces around it can share one.
class _NestedGlass extends InheritedWidget {
  const _NestedGlass({required super.child});

  @override
  bool updateShouldNotify(_NestedGlass oldWidget) => false;
}

/// A reusable glassmorphism container with configurable properties.
/// Provides frosted-glass blur, thin borders, rounded corners, and subtle shadows.
class GlassContainer extends StatelessWidget {
  const GlassContainer({
    super.key,
    required this.child,
    this.padding,
    this.margin,
    this.width,
    this.height,
    this.borderRadius = 20,
    this.blurStrength = 20,
    this.opacity = 0.7,
    this.borderOpacity = 0.5,
    this.borderColor,
    this.shadowColor,
    this.gradient,
    this.onTap,
    this.borderRadiusGeometry,
  });

  final Widget child;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;
  final double? width;
  final double? height;
  final double borderRadius;
  final double blurStrength;
  final double opacity;
  final double borderOpacity;
  final Color? borderColor;
  final Color? shadowColor;
  final Gradient? gradient;
  final VoidCallback? onTap;
  final BorderRadiusGeometry? borderRadiusGeometry;

  @override
  Widget build(BuildContext context) {
    final effectiveBorderRadius =
        borderRadiusGeometry ?? BorderRadius.circular(borderRadius);
    final effectiveBorderColor =
        borderColor ?? GlassColors.border.withValues(alpha: borderOpacity);
    final effectiveShadowColor =
        shadowColor ?? GlassColors.heading.withValues(alpha: 0.08);
    final effectiveGradient =
        gradient ??
        LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            GlassColors.surface.withValues(alpha: opacity + 0.1),
            GlassColors.surface.withValues(alpha: opacity),
            GlassColors.surface.withValues(alpha: opacity + 0.05),
          ],
        );

    // Sibling glass surfaces - the cards of one scrolling list - can share a
    // single backdrop blur instead of each filtering the backdrop again. A
    // surface painted on top of another one must not: sharing the key would
    // filter the overlapping part only once and change how it looks, so a
    // nested surface keeps the private blur it has always used, via the marker
    // [_NestedGlass] that every surface puts above its own content.
    //
    // `BackdropFilter.grouped` resolves the nearest [BackdropGroup] and falls
    // back to a private blur when there is none, so a screen that has no group
    // renders exactly as it did before this change.
    final isNested =
        context.dependOnInheritedWidgetOfExactType<_NestedGlass>() != null;
    final blur = ImageFilter.blur(sigmaX: blurStrength, sigmaY: blurStrength);

    final surface = _NestedGlass(
      child: Container(
        width: width,
        height: height,
        padding: padding,
        margin: margin,
        decoration: BoxDecoration(
          borderRadius: effectiveBorderRadius,
          gradient: effectiveGradient,
          border: Border.all(color: effectiveBorderColor, width: 1),
          // When the caller passes a fully-transparent shadowColor, both shadow
          // layers are skipped (otherwise the hardcoded secondary layer would
          // still render, defeating the caller's intent).
          boxShadow: effectiveShadowColor.a == 0
              ? const <BoxShadow>[]
              : [
                  BoxShadow(
                    color: effectiveShadowColor,
                    blurRadius: 20,
                    offset: const Offset(0, 4),
                    spreadRadius: -2,
                  ),
                  BoxShadow(
                    color: GlassColors.heading.withValues(alpha: 0.04),
                    blurRadius: 40,
                    offset: const Offset(0, 8),
                    spreadRadius: -4,
                  ),
                ],
        ),
        child: child,
      ),
    );

    // A nested surface sits on top of an already-blurred parent card, so its
    // own backdrop filter only re-blurs a blur - it changes nothing visible
    // but costs a full clip + blur pass per surface (7 of Home's 15 filters
    // were exactly this). Nested surfaces therefore paint their surface
    // directly; the parent card still blurs everything behind it.
    final glassWidget = isNested
        ? surface
        : ClipRRect(
            borderRadius: effectiveBorderRadius,
            child: BackdropFilter.grouped(filter: blur, child: surface),
          );

    if (onTap != null) {
      return _PressFeedback(
        onTap: onTap!,
        borderRadius: effectiveBorderRadius is BorderRadius
            ? effectiveBorderRadius
            : BorderRadius.circular(borderRadius),
        child: glassWidget,
      );
    }

    return glassWidget;
  }
}

/// Adds visible press feedback to a tappable glass surface.
///
/// The ink splash alone is not enough here: [GlassContainer] paints an opaque
/// gradient *above* the [InkWell]'s material, so the ripple is hidden behind
/// the card. A small scale keeps the response visible without changing colour,
/// size, shape or tap target.
///
/// The scale is driven by [InkWell.onHighlightChanged], so no extra gesture
/// recogniser competes for the tap: the action fires immediately and the scale
/// is purely visual.
class _PressFeedback extends StatefulWidget {
  const _PressFeedback({
    required this.onTap,
    required this.borderRadius,
    required this.child,
  });

  final VoidCallback onTap;
  final BorderRadius borderRadius;
  final Widget child;

  @override
  State<_PressFeedback> createState() => _PressFeedbackState();
}

class _PressFeedbackState extends State<_PressFeedback> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: widget.onTap,
        borderRadius: widget.borderRadius,
        onHighlightChanged: (value) {
          if (_pressed != value) {
            setState(() => _pressed = value);
          }
        },
        child: AnimatedScale(
          scale: _pressed ? 0.985 : 1,
          duration: motionDuration(context, kMotionPress),
          curve: Curves.easeOut,
          child: widget.child,
        ),
      ),
    );
  }
}

/// A glassmorphism card variant with a more subtle appearance for list items.
class GlassCard extends StatelessWidget {
  const GlassCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.margin,
    this.borderRadius = 16,
    this.blurStrength = 15,
    this.opacity = 0.6,
    this.borderOpacity = 0.4,
    this.onTap,
    this.borderRadiusGeometry,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry? margin;
  final double borderRadius;
  final double blurStrength;
  final double opacity;
  final double borderOpacity;
  final VoidCallback? onTap;
  final BorderRadiusGeometry? borderRadiusGeometry;

  @override
  Widget build(BuildContext context) {
    return GlassContainer(
      padding: padding,
      margin: margin,
      borderRadius: borderRadius,
      blurStrength: blurStrength,
      opacity: opacity,
      borderOpacity: borderOpacity,
      borderRadiusGeometry: borderRadiusGeometry,
      onTap: onTap,
      child: child,
    );
  }
}

/// Full-screen background with light blue gradient.
class GlassBackground extends StatelessWidget {
  const GlassBackground({
    super.key,
    required this.child,
    this.showPattern = false,
  });

  final Widget child;
  final bool showPattern;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFFF3F8FE), Color(0xFFE8F1FA), Color(0xFFF3F8FE)],
          stops: [0.0, 0.5, 1.0],
        ),
      ),
      child: Stack(children: [if (showPattern) _buildPatternOverlay(), child]),
    );
  }

  Widget _buildPatternOverlay() {
    return CustomPaint(painter: _GlassPatternPainter(), size: Size.infinite);
  }
}

class _GlassPatternPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = GlassColors.primaryBlue.withValues(alpha: 0.02)
      ..style = PaintingStyle.fill;

    final spacing = 100.0;
    final radius = 50.0;

    for (double x = -spacing; x < size.width + spacing; x += spacing) {
      for (double y = -spacing; y < size.height + spacing; y += spacing) {
        canvas.drawCircle(Offset(x, y), radius, paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Glassmorphism app bar with translucent background.
class GlassAppBar extends StatelessWidget implements PreferredSizeWidget {
  const GlassAppBar({
    super.key,
    this.title,
    this.leading,
    this.actions,
    this.backgroundColor,
    this.elevation = 0,
    this.automaticallyImplyLeading = true,
  });

  final Widget? title;
  final Widget? leading;
  final List<Widget>? actions;
  final Color? backgroundColor;
  final double elevation;
  final bool automaticallyImplyLeading;

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) {
    return AppBar(
      title: title,
      leading: leading,
      actions: actions,
      automaticallyImplyLeading: automaticallyImplyLeading,
      backgroundColor: backgroundColor ?? Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: elevation,
      scrolledUnderElevation: 0,
      flexibleSpace: ClipRect(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
          child: Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  GlassColors.surface.withValues(alpha: 0.8),
                  GlassColors.surface.withValues(alpha: 0.6),
                  GlassColors.surface.withValues(alpha: 0.8),
                ],
              ),
              border: Border(
                bottom: BorderSide(
                  color: GlassColors.border.withValues(alpha: 0.5),
                  width: 1,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Glassmorphism text field wrapper.
class GlassTextField extends StatelessWidget {
  const GlassTextField({
    super.key,
    required this.controller,
    this.labelText,
    this.hintText,
    this.prefixIcon,
    this.suffixIcon,
    this.keyboardType,
    this.obscureText = false,
    this.textCapitalization = TextCapitalization.none,
    this.onChanged,
    this.validator,
    this.enabled = true,
  });

  final TextEditingController controller;
  final String? labelText;
  final String? hintText;
  final Widget? prefixIcon;
  final Widget? suffixIcon;
  final TextInputType? keyboardType;
  final bool obscureText;
  final TextCapitalization textCapitalization;
  final ValueChanged<String>? onChanged;
  final String? Function(String?)? validator;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      padding: EdgeInsets.zero,
      margin: EdgeInsets.zero,
      borderRadius: 14,
      opacity: 0.5,
      borderOpacity: 0.3,
      child: TextField(
        controller: controller,
        enabled: enabled,
        keyboardType: keyboardType,
        obscureText: obscureText,
        textCapitalization: textCapitalization,
        onChanged: onChanged,
        style: const TextStyle(color: GlassColors.heading, fontSize: 16),
        decoration: InputDecoration(
          labelText: labelText,
          hintText: hintText,
          prefixIcon: prefixIcon != null
              ? IconTheme(
                  data: const IconThemeData(
                    color: GlassColors.secondaryText,
                    size: 22,
                  ),
                  child: prefixIcon!,
                )
              : null,
          suffixIcon: suffixIcon,
          labelStyle: const TextStyle(color: GlassColors.secondaryText),
          hintStyle: const TextStyle(color: GlassColors.disabled),
          border: InputBorder.none,
          enabledBorder: InputBorder.none,
          focusedBorder: InputBorder.none,
          errorBorder: InputBorder.none,
          disabledBorder: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 16,
          ),
          filled: false,
        ),
      ),
    );
  }
}

/// Glassmorphism button with primary blue background.
class GlassButton extends StatelessWidget {
  const GlassButton({
    super.key,
    required this.onPressed,
    required this.child,
    this.width,
    this.height = 56,
    this.borderRadius = 16,
    this.gradient,
    this.color,
    this.isLoading = false,
    this.disabled = false,
  });

  final VoidCallback? onPressed;
  final Widget child;
  final double? width;
  final double height;
  final double borderRadius;
  final Gradient? gradient;

  /// When set, the button is filled with this flat color instead of the
  /// default blue gradient.
  final Color? color;
  final bool isLoading;
  final bool disabled;

  @override
  Widget build(BuildContext context) {
    final inactive = disabled || isLoading;
    final fillColor = color ?? GlassColors.primaryBlue;
    final effectiveGradient =
        gradient ??
        (color != null
            ? null
            : const LinearGradient(
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
                colors: [
                  GlassColors.primaryBlue,
                  GlassColors.primaryBlueDark,
                  GlassColors.primaryBlue,
                ],
              ));

    return SizedBox(
      width: width ?? double.infinity,
      height: height,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(borderRadius),
          gradient: inactive ? null : effectiveGradient,
          color: inactive ? fillColor.withValues(alpha: 0.5) : color,
          boxShadow: inactive
              ? null
              : [
                  BoxShadow(
                    color: fillColor.withValues(alpha: 0.3),
                    blurRadius: 20,
                    offset: const Offset(0, 6),
                    spreadRadius: -2,
                  ),
                ],
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: disabled || isLoading ? null : onPressed,
            borderRadius: BorderRadius.circular(borderRadius),
            child: Center(
              child: isLoading
                  ? const SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.5,
                        valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                      ),
                    )
                  : child,
            ),
          ),
        ),
      ),
    );
  }
}

/// Glassmorphism outlined button.
class GlassOutlinedButton extends StatelessWidget {
  const GlassOutlinedButton({
    super.key,
    required this.onPressed,
    required this.child,
    this.width,
    this.height = 56,
    this.borderRadius = 16,
    this.borderColor,
    this.textColor,
  });

  final VoidCallback? onPressed;
  final Widget child;
  final double? width;
  final double height;
  final double borderRadius;
  final Color? borderColor;
  final Color? textColor;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width ?? double.infinity,
      height: height,
      child: GlassContainer(
        padding: EdgeInsets.zero,
        margin: EdgeInsets.zero,
        borderRadius: borderRadius,
        blurStrength: 15,
        opacity: 0.5,
        borderOpacity: 0.5,
        borderColor: borderColor ?? GlassColors.primaryBlue,
        onTap: onPressed,
        child: Center(
          child: DefaultTextStyle(
            style: TextStyle(
              color: textColor ?? GlassColors.primaryBlue,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}

/// Decorative glow orb for background ambiance.
class GlowOrb extends StatelessWidget {
  const GlowOrb({
    super.key,
    required this.position,
    this.size = 200,
    this.color = GlassColors.primaryBlue,
    this.opacity = 0.1,
  });

  final Alignment position;
  final double size;
  final Color color;
  final double opacity;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: position,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(
            colors: [
              color.withValues(alpha: opacity),
              color.withValues(alpha: opacity * 0.5),
              Colors.transparent,
            ],
            stops: const [0.0, 0.5, 1.0],
          ),
        ),
      ),
    );
  }
}
