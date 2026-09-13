import 'package:flutter/material.dart';

class ListenookTheme {
  static const seed = Color(0xFF8855D9);
  static const coral = Color(0xFFFF7D6B);

  static ThemeData light() => _theme(Brightness.light);
  static ThemeData dark() => _theme(Brightness.dark);

  static ThemeData _theme(Brightness brightness) {
    final colors = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: brightness,
      dynamicSchemeVariant: DynamicSchemeVariant.fidelity,
    );
    final dark = brightness == Brightness.dark;
    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: colors,
      scaffoldBackgroundColor: dark
          ? const Color(0xFF111015)
          : const Color(0xFFF8F6FA),
      fontFamily: '.SF Pro Text',
      visualDensity: VisualDensity.compact,
      cardTheme: CardThemeData(
        elevation: 0,
        color: dark
            ? const Color(0xFF1B191F)
            : Colors.white.withValues(alpha: .92),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      inputDecorationTheme: InputDecorationTheme(
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 12,
        ),
        filled: true,
        fillColor: dark ? const Color(0xFF242127) : const Color(0xFFF1EDF5),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: dark
            ? const Color(0xFF18161B)
            : const Color(0xFFF1EDF5),
        indicatorColor: colors.primaryContainer,
        useIndicator: true,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(40, 40),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(40, 40),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
      tooltipTheme: TooltipThemeData(
        waitDuration: const Duration(milliseconds: 450),
        decoration: BoxDecoration(
          color: dark ? const Color(0xFFF3EDF7) : const Color(0xFF211F24),
          borderRadius: BorderRadius.circular(8),
        ),
        textStyle: TextStyle(color: dark ? Colors.black : Colors.white),
      ),
    );
  }
}
