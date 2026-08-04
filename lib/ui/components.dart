import 'package:country_flags/country_flags.dart';
import 'package:flutter/material.dart';

import 'theme.dart';

/// A rounded surface used for every panel in the redesign.
class AppCard extends StatelessWidget {
  const AppCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(18),
    this.radius = 16,
    this.gradient,
    this.color,
    this.borderColor = AppColors.line,
    this.clip = false,
    this.onTap,
  });

  final Widget child;
  final EdgeInsets padding;
  final double radius;
  final Gradient? gradient;
  final Color? color;
  final Color borderColor;
  final bool clip;

  /// When set, the whole card becomes tappable (with an ink ripple).
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final decoration = BoxDecoration(
      color: gradient == null ? (color ?? AppColors.card) : null,
      gradient: gradient,
      borderRadius: BorderRadius.circular(radius),
      border: Border.all(color: borderColor),
    );
    if (onTap == null) {
      return Container(
        padding: padding,
        clipBehavior: clip ? Clip.antiAlias : Clip.none,
        decoration: decoration,
        child: child,
      );
    }
    return Material(
      type: MaterialType.transparency,
      child: Ink(
        decoration: decoration,
        child: InkWell(
          borderRadius: BorderRadius.circular(radius),
          onTap: onTap,
          child: Padding(padding: padding, child: child),
        ),
      ),
    );
  }
}

/// Flag of [countryCode], falling back to the globe marker while the country
/// is still unknown (or has no flag of its own).
///
/// Sized to a rounded square like [IconTile] so it can stand in for the globe
/// wherever the current location is shown.
class CountryFlagTile extends StatelessWidget {
  const CountryFlagTile({
    super.key,
    required this.countryCode,
    this.size = 44,
    this.width,
    this.iconSize = 22,
    this.radius = 13,
  });

  final String? countryCode;
  final double size;

  /// Defaults to [size] (a square tile); set it wider for a flag-shaped swatch.
  final double? width;
  final double iconSize;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final code = countryCode;
    if (code == null || FlagCode.fromCountryCode(code.toUpperCase()) == null) {
      return IconTile(
        icon: Icons.public,
        size: size,
        iconSize: iconSize,
        radius: radius,
      );
    }
    final tileWidth = width ?? size;
    return Container(
      width: tileWidth,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: AppColors.line2),
      ),
      clipBehavior: Clip.antiAlias,
      child: CountryFlag.fromCountryCode(
        code,
        theme: ImageTheme(width: tileWidth, height: size),
      ),
    );
  }
}

/// Rounded square holding a single icon (e.g. the globe / wallet markers).
class IconTile extends StatelessWidget {
  const IconTile({
    super.key,
    required this.icon,
    this.size = 44,
    this.iconSize = 22,
    this.background = AppColors.accentSoft,
    this.color = AppColors.accent,
    this.radius = 13,
    this.gradient,
  });

  final IconData icon;
  final double size;
  final double iconSize;
  final Color background;
  final Color color;
  final double radius;
  final Gradient? gradient;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: gradient == null ? background : null,
        gradient: gradient,
        borderRadius: BorderRadius.circular(radius),
      ),
      child: Icon(icon, size: iconSize, color: color),
    );
  }
}

/// The IRNet logo mark + optional wordmark.
class BrandMark extends StatelessWidget {
  const BrandMark({
    super.key,
    this.size = 28,
    this.showWordmark = true,
    this.tagline,
    this.version,
  });

  final double size;
  final bool showWordmark;
  final String? tagline;

  /// Optional version string shown after the "IRNet" wordmark (e.g. "v1.5.0").
  final String? version;

  @override
  Widget build(BuildContext context) {
    final mark = IconTile(
      icon: Icons.shield,
      size: size,
      iconSize: size * 0.57,
      gradient: AppGradients.brand,
      color: AppColors.onAccent,
      radius: size * 0.32,
    );
    if (!showWordmark) return mark;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        mark,
        const SizedBox(width: 10),
        Flexible(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Flexible(
                    child: Text('IRNet',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.ui(16, FontWeight.w700, AppColors.text, height: 1)),
                  ),
                  if (version != null && version!.isNotEmpty) ...[
                    const SizedBox(width: 6),
                    Text('v$version',
                        style: AppText.mono(11, FontWeight.w500, AppColors.text3, height: 1)),
                  ],
                ],
              ),
              if (tagline != null) ...[
                const SizedBox(height: 2),
                Text(tagline!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.ui(9, FontWeight.w400, AppColors.text3)),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class StatusDot extends StatelessWidget {
  const StatusDot(this.color, {super.key, this.size = 7});
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}

/// Pill with an optional leading dot and a coloured label/border.
class Pill extends StatelessWidget {
  const Pill({
    super.key,
    required this.label,
    this.dotColor,
    this.textColor = AppColors.text2,
    this.background,
    this.borderColor,
    this.leading,
  });

  final String label;
  final Color? dotColor;
  final Color textColor;
  final Color? background;
  final Color? borderColor;
  final Widget? leading;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(999),
        border: borderColor == null ? null : Border.all(color: borderColor!),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (leading != null) ...[leading!, const SizedBox(width: 7)],
          if (dotColor != null) ...[StatusDot(dotColor!, size: 6), const SizedBox(width: 7)],
          Text(label, style: AppText.ui(11, FontWeight.w600, textColor, letterSpacing: 0.3)),
        ],
      ),
    );
  }
}

/// Small monospace code badge, e.g. the "NL" country code.
class CodeBadge extends StatelessWidget {
  const CodeBadge(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: AppColors.line2),
      ),
      child: Text(text, style: AppText.mono(10, FontWeight.w600, AppColors.text2)),
    );
  }
}

/// Uppercase caption used above groups / inside cards.
class Overline extends StatelessWidget {
  const Overline(this.text, {super.key, this.color = AppColors.text3});
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Text(text.toUpperCase(), style: AppText.overline(color));
  }
}

/// Linear progress track with a gradient fill.
class TrackBar extends StatelessWidget {
  const TrackBar({super.key, required this.fraction, this.height = 6});
  final double fraction;
  final double height;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(height / 2),
      child: Container(
        height: height,
        color: AppColors.line,
        alignment: Alignment.centerLeft,
        child: FractionallySizedBox(
          widthFactor: fraction.clamp(0.0, 1.0),
          child: Container(
            decoration: const BoxDecoration(gradient: AppGradients.progress),
          ),
        ),
      ),
    );
  }
}

enum AppButtonKind { primary, outline, danger, ghostAccent }

class AppButton extends StatelessWidget {
  const AppButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.kind = AppButtonKind.primary,
    this.expand = false,
    this.height = 48,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final AppButtonKind kind;
  final bool expand;
  final double height;

  @override
  Widget build(BuildContext context) {
    late final Color bg;
    late final Color fg;
    Color? border;
    switch (kind) {
      case AppButtonKind.primary:
        bg = AppColors.accent;
        fg = AppColors.onAccent;
        break;
      case AppButtonKind.outline:
        bg = Colors.transparent;
        fg = AppColors.text2;
        border = AppColors.line2;
        break;
      case AppButtonKind.danger:
        bg = AppColors.badSoft;
        fg = AppColors.bad;
        border = AppColors.badBorder;
        break;
      case AppButtonKind.ghostAccent:
        bg = Colors.transparent;
        fg = AppColors.accent;
        border = const Color(0x4D33D6C6);
        break;
    }

    final radius = height >= 44 ? 13.0 : 10.0;
    final child = Material(
      color: bg,
      borderRadius: BorderRadius.circular(radius),
      child: InkWell(
        borderRadius: BorderRadius.circular(radius),
        onTap: onPressed,
        child: Container(
          height: height,
          padding: EdgeInsets.symmetric(horizontal: height >= 44 ? 16 : 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(radius),
            border: border == null ? null : Border.all(color: border),
          ),
          alignment: Alignment.center,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (icon != null) ...[
                Icon(icon, size: height >= 44 ? 16 : 14, color: fg),
                const SizedBox(width: 7),
              ],
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.fade,
                  style: AppText.ui(height >= 44 ? 14 : 12.5, FontWeight.w600, fg),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    return expand ? SizedBox(width: double.infinity, child: child) : child;
  }
}

/// Icon-only square button (mobile header refresh / exit).
class IconActionButton extends StatelessWidget {
  const IconActionButton({
    super.key,
    required this.icon,
    required this.onPressed,
    this.danger = false,
    this.size = 34,
  });

  final IconData icon;
  final VoidCallback? onPressed;
  final bool danger;
  final double size;

  @override
  Widget build(BuildContext context) {
    final fg = danger ? AppColors.bad : AppColors.text2;
    return Material(
      color: danger ? AppColors.badSoft : Colors.transparent,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onPressed,
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: danger ? AppColors.badBorder : AppColors.line),
          ),
          child: Icon(icon, size: 16, color: fg),
        ),
      ),
    );
  }
}

/// Custom pill toggle matching the design (teal track, dark knob).
class AppSwitch extends StatelessWidget {
  const AppSwitch({super.key, required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    const w = 46.0, h = 26.0, knob = 20.0;
    return GestureDetector(
      onTap: onChanged == null ? null : () => onChanged!(!value),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOut,
        width: w,
        height: h,
        decoration: BoxDecoration(
          color: value ? AppColors.accent : AppColors.line2,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Stack(
          children: [
            AnimatedAlign(
              duration: const Duration(milliseconds: 160),
              curve: Curves.easeOut,
              alignment: value ? Alignment.centerRight : Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.all(3),
                child: Container(
                  width: knob,
                  height: knob,
                  decoration: BoxDecoration(
                    color: value ? AppColors.onAccent : AppColors.text2,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
