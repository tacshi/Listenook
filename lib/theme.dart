import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

class ListenookTheme {
  static const seed = Color(0xFF8855D9);
  static const coral = Color(0xFFFF7D6B);

  static ThemeData light() => _theme(Brightness.light);
  static ThemeData dark() => _theme(Brightness.dark);

  // Neutral surfaces close to Windows 11 / Fluent, so the accent only shows
  // where something is actionable or selected.
  static ColorScheme _colors(Brightness brightness) {
    final base = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: brightness,
      dynamicSchemeVariant: DynamicSchemeVariant.tonalSpot,
    );
    if (brightness == Brightness.dark) {
      return base.copyWith(
        surface: const Color(0xFF1C1C1C),
        surfaceDim: const Color(0xFF161616),
        surfaceBright: const Color(0xFF383838),
        surfaceContainerLowest: const Color(0xFF141414),
        surfaceContainerLow: const Color(0xFF202020),
        surfaceContainer: const Color(0xFF242424),
        surfaceContainerHigh: const Color(0xFF2B2B2B),
        surfaceContainerHighest: const Color(0xFF333333),
        onSurface: const Color(0xFFF2F2F2),
        onSurfaceVariant: const Color(0xFFB8B8B8),
        outline: const Color(0xFF6E6E6E),
        outlineVariant: const Color(0xFF3A3A3A),
        secondaryContainer: const Color(0xFF333333),
        onSecondaryContainer: const Color(0xFFF2F2F2),
        surfaceTint: Colors.transparent,
      );
    }
    return base.copyWith(
      surface: const Color(0xFFFAFAFA),
      surfaceDim: const Color(0xFFE6E6E6),
      surfaceBright: const Color(0xFFFFFFFF),
      surfaceContainerLowest: const Color(0xFFFFFFFF),
      surfaceContainerLow: const Color(0xFFF7F7F7),
      surfaceContainer: const Color(0xFFF3F3F3),
      surfaceContainerHigh: const Color(0xFFEDEDED),
      surfaceContainerHighest: const Color(0xFFE8E8E8),
      onSurface: const Color(0xFF1B1B1B),
      onSurfaceVariant: const Color(0xFF5C5C5C),
      outline: const Color(0xFF8A8A8A),
      outlineVariant: const Color(0xFFE0E0E0),
      secondaryContainer: const Color(0xFFE8E8E8),
      onSecondaryContainer: const Color(0xFF1B1B1B),
      surfaceTint: Colors.transparent,
    );
  }

  static String? get _fontFamily => switch (defaultTargetPlatform) {
    TargetPlatform.windows => 'Segoe UI Variable Text',
    TargetPlatform.macOS || TargetPlatform.iOS => '.SF Pro Text',
    _ => null,
  };

  static ThemeData _theme(Brightness brightness) {
    final colors = _colors(brightness);
    final dark = brightness == Brightness.dark;
    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: colors,
      scaffoldBackgroundColor: colors.surface,
      fontFamily: _fontFamily,
      fontFamilyFallback: const ['Segoe UI'],
      visualDensity: VisualDensity.compact,
      dividerTheme: DividerThemeData(color: colors.outlineVariant),
      cardTheme: CardThemeData(
        elevation: 0,
        // Cards sit above the canvas: white in light, a step lighter in dark.
        color: dark ? colors.surfaceContainer : colors.surfaceContainerLowest,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: colors.outlineVariant),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 12,
        ),
        filled: true,
        fillColor: colors.surfaceContainer,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: colors.primary, width: 1.5),
        ),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: colors.surfaceContainer,
        indicatorColor: colors.surfaceContainerHighest,
        indicatorShape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
        ),
        selectedIconTheme: IconThemeData(color: colors.primary),
        unselectedIconTheme: IconThemeData(color: colors.onSurfaceVariant),
        selectedLabelTextStyle: TextStyle(
          color: colors.onSurface,
          fontWeight: FontWeight.w600,
        ),
        unselectedLabelTextStyle: TextStyle(color: colors.onSurfaceVariant),
        useIndicator: true,
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          visualDensity: VisualDensity.compact,
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
          side: WidgetStatePropertyAll(
            BorderSide(color: colors.outlineVariant),
          ),
          backgroundColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.selected)
                ? colors.surfaceContainerHighest
                : Colors.transparent,
          ),
          foregroundColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.selected)
                ? colors.onSurface
                : colors.onSurfaceVariant,
          ),
          iconColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.selected)
                ? colors.primary
                : colors.onSurfaceVariant,
          ),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(40, 40),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(40, 40),
          side: BorderSide(color: colors.outlineVariant),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
      tooltipTheme: TooltipThemeData(
        waitDuration: const Duration(milliseconds: 450),
        decoration: BoxDecoration(
          color: dark ? const Color(0xFFF2F2F2) : const Color(0xFF2B2B2B),
          borderRadius: BorderRadius.circular(6),
        ),
        textStyle: TextStyle(color: dark ? Colors.black : Colors.white),
      ),
    );
  }
}
