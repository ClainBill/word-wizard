import 'package:flutter/material.dart';

/// Palette lifted from the Lexery design doc — a warm "old dictionary
/// paper" light theme and its dark-mode counterpart.
class AppTheme {
  static const _lightPaper = Color(0xFFE9EAE0);
  static const _lightSurface = Color(0xFFF5F5EF);
  static const _lightInk = Color(0xFF1E2A22);
  static const _lightAccent = Color(0xFF8A5A22);
  static const _lightAccent2 = Color(0xFF35604F);

  static const _darkPaper = Color(0xFF14170F);
  static const _darkSurface = Color(0xFF1B1F17);
  static const _darkInk = Color(0xFFEDEBDF);
  static const _darkAccent = Color(0xFFD3A45C);
  static const _darkAccent2 = Color(0xFF7FBBA0);

  static ThemeData light() {
    final scheme = ColorScheme.fromSeed(
      seedColor: _lightAccent,
      brightness: Brightness.light,
      primary: _lightAccent,
      secondary: _lightAccent2,
      surface: _lightSurface,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: _lightPaper,
      textTheme: const TextTheme().apply(bodyColor: _lightInk, displayColor: _lightInk),
      appBarTheme: AppBarTheme(
        backgroundColor: _lightPaper,
        foregroundColor: _lightInk,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
      ),
      cardTheme: CardThemeData(
        color: _lightSurface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: scheme.outlineVariant),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: _lightSurface,
        indicatorColor: _lightAccent.withValues(alpha: 0.16),
      ),
    );
  }

  static ThemeData dark() {
    final scheme = ColorScheme.fromSeed(
      seedColor: _darkAccent,
      brightness: Brightness.dark,
      primary: _darkAccent,
      secondary: _darkAccent2,
      surface: _darkSurface,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: _darkPaper,
      textTheme: const TextTheme().apply(bodyColor: _darkInk, displayColor: _darkInk),
      appBarTheme: AppBarTheme(
        backgroundColor: _darkPaper,
        foregroundColor: _darkInk,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
      ),
      cardTheme: CardThemeData(
        color: _darkSurface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: scheme.outlineVariant),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: _darkSurface,
        indicatorColor: _darkAccent.withValues(alpha: 0.20),
      ),
    );
  }
}
