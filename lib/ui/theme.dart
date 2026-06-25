import 'package:flutter/material.dart';

/// Design tokens for the IRNet redesign.
///
/// Colours, fonts and gradients mirror the "IRNet Redesign" design doc
/// (a dark, teal-accented dashboard). Kept in one place so every widget pulls
/// from the same palette.
class AppColors {
  AppColors._();

  static const bg = Color(0xFF0B0F14);
  static const panel = Color(0xFF0F1620);
  static const card = Color(0xFF141D28);
  static const card2 = Color(0xFF18222E);

  static const line = Color(0x12FFFFFF); // rgba(255,255,255,.07)
  static const line2 = Color(0x21FFFFFF); // rgba(255,255,255,.13)
  static const outerBorder = Color(0xFF232C36);

  static const text = Color(0xFFE7EEF5);
  static const text2 = Color(0xFF94A3B2);
  static const text3 = Color(0xFF5D6B7A);

  static const accent = Color(0xFF33D6C6);
  static const accent2 = Color(0xFF1F8F86);
  static const onAccent = Color(0xFF04211E);

  static const good = Color(0xFF4ADE80);
  static const warn = Color(0xFFFBBF24);
  static const bad = Color(0xFFFB6A6A);

  /// Translucent accent fills used for icon tiles / pills.
  static const accentSoft = Color(0x1F33D6C6); // ~.12
  static const goodSoft = Color(0x1F4ADE80);
  static const badSoft = Color(0x10FB6A6A);
  static const badBorder = Color(0x40FB6A6A);
}

class AppFonts {
  AppFonts._();
  static const ui = 'SpaceGrotesk';
  static const mono = 'JetBrainsMono';
}

class AppGradients {
  AppGradients._();

  /// Hero / elevated card background.
  static const card = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [AppColors.card2, AppColors.card],
  );

  /// Brand mark (logo square).
  static const brand = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [AppColors.accent, AppColors.accent2],
  );

  /// Progress fill.
  static const progress = LinearGradient(
    colors: [AppColors.accent2, AppColors.accent],
  );
}

/// Text helpers. Both families are variable fonts, so we set the `wght` axis
/// explicitly (in addition to [FontWeight]) to guarantee the rendered weight.
class AppText {
  AppText._();

  static TextStyle ui(
    double size,
    FontWeight weight,
    Color color, {
    double? height,
    double? letterSpacing,
  }) =>
      TextStyle(
        fontFamily: AppFonts.ui,
        fontSize: size,
        fontWeight: weight,
        color: color,
        height: height,
        letterSpacing: letterSpacing,
        fontVariations: [FontVariation('wght', weight.value.toDouble())],
      );

  static TextStyle mono(
    double size,
    FontWeight weight,
    Color color, {
    double? height,
    double? letterSpacing,
  }) =>
      TextStyle(
        fontFamily: AppFonts.mono,
        fontSize: size,
        fontWeight: weight,
        color: color,
        height: height,
        letterSpacing: letterSpacing,
        fontVariations: [FontVariation('wght', weight.value.toDouble())],
      );

  /// Small uppercase label ("CONNECTED FROM", section captions).
  static TextStyle overline(Color color) =>
      ui(10, FontWeight.w500, color, letterSpacing: 0.9);
}

ThemeData buildAppTheme() {
  const scheme = ColorScheme.dark(
    primary: AppColors.accent,
    onPrimary: AppColors.onAccent,
    secondary: AppColors.accent,
    onSecondary: AppColors.onAccent,
    surface: AppColors.card,
    onSurface: AppColors.text,
    error: AppColors.bad,
  );

  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: scheme,
    scaffoldBackgroundColor: AppColors.bg,
    canvasColor: AppColors.bg,
    fontFamily: AppFonts.ui,
    splashFactory: InkRipple.splashFactory,
    textSelectionTheme: const TextSelectionThemeData(
      cursorColor: AppColors.accent,
      selectionColor: AppColors.accentSoft,
      selectionHandleColor: AppColors.accent,
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: AppColors.card2,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.line2),
      ),
      textStyle: AppText.ui(12, FontWeight.w500, AppColors.text),
    ),
  );
}
