import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// AHBU Akıllı Ev & Bina Otomasyonu
/// Merkezi Tema & Renk Yönetimi (Design System)
///
/// Aydınlık ve Karanlık mod renklerini, fontları ve bileşen stillerini
/// tek bir noktadan yönetir.
class AppTheme {
  // --- KOYU MOD (DARK THEME) RENK PALETİ ---
  static const Color bgDark = Color(0xFF0B1120);
  static const Color surfaceDark = Color(0xFF131D31);
  static const Color cardDark = Color(0xFF1E293B);
  static const Color cardBorder = Color(0xFF334155);
  static const Color textPrimary = Color(0xFFF8FAFC);
  static const Color textMuted = Color(0xFF94A3B8);

  // --- AYDINLIK MOD (LIGHT THEME) RENK PALETİ ---
  static const Color bgLight = Color(0xFFF1F5F9);
  static const Color surfaceLight = Color(0xFFFFFFFF);
  static const Color cardLight = Color(0xFFFFFFFF);
  static const Color cardBorderLight = Color(0xFFCBD5E1);
  static const Color textPrimaryLight = Color(0xFF0F172A);
  static const Color textMutedLight = Color(0xFF64748B);

  // --- ORTAK VURGU (ACCENT) RENKLERİ ---
  static const Color primaryBlue = Color(0xFF2563EB);
  static const Color primaryBlueLight = Color(0xFF60A5FA);
  static const Color accentGreen = Color(0xFF10B981);
  static const Color accentAmber = Color(0xFFF59E0B);
  static const Color accentPurple = Color(0xFFA855F7);
  static const Color accentRed = Color(0xFFEF4444);
  static const Color accentCyan = Color(0xFF06B6D4);

  // --- CONTEXT-DUYARLI RENK YARDIMCILARI ---
  static bool isDark(BuildContext context) => Theme.of(context).brightness == Brightness.dark;

  static Color getScaffoldBg(BuildContext context) =>
      isDark(context) ? bgDark : bgLight;

  static Color getSurfaceColor(BuildContext context) =>
      isDark(context) ? surfaceDark : surfaceLight;

  static Color getCardColor(BuildContext context) =>
      isDark(context) ? cardDark : cardLight;

  static Color getCardBorder(BuildContext context) =>
      isDark(context) ? cardBorder : cardBorderLight;

  static Color getTextPrimary(BuildContext context) =>
      isDark(context) ? textPrimary : textPrimaryLight;

  static Color getTextMuted(BuildContext context) =>
      isDark(context) ? textMuted : textMutedLight;

  // --- KARANLIK TEMA (DARK THEME) ---
  static ThemeData get darkTheme {
    final baseTextTheme = ThemeData.dark().textTheme;
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: Colors.transparent,
      colorScheme: const ColorScheme.dark(
        primary: primaryBlue,
        secondary: primaryBlueLight,
        surface: surfaceDark,
        onSurface: textPrimary,
        error: accentRed,
      ),
      textTheme: GoogleFonts.interTextTheme(baseTextTheme).apply(
        bodyColor: textPrimary,
        displayColor: textPrimary,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        foregroundColor: textPrimary,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.w700,
          color: textPrimary,
        ),
        iconTheme: IconThemeData(color: textPrimary),
      ),
      cardTheme: CardThemeData(
        color: const Color(0xFF0F172A).withValues(alpha: 0.78),
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(
            color: const Color(0xFF38BDF8).withValues(alpha: 0.22),
            width: 1.2,
          ),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: const Color(0xFF0F172A).withValues(alpha: 0.92),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(
            color: const Color(0xFF38BDF8).withValues(alpha: 0.28),
            width: 1.2,
          ),
        ),
        titleTextStyle: const TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.bold,
          color: textPrimary,
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: const Color(0xFF0F172A),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: cardBorder),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: cardBorder),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: primaryBlueLight, width: 1.5),
        ),
        hintStyle: const TextStyle(color: textMuted, fontSize: 13),
      ),
      dividerTheme: const DividerThemeData(
        color: cardBorder,
        thickness: 1,
      ),
    );
  }

  // --- AYDINLIK TEMA (LIGHT THEME) ---
  static ThemeData get lightTheme {
    final baseTextTheme = ThemeData.light().textTheme;
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      scaffoldBackgroundColor: Colors.transparent,
      colorScheme: const ColorScheme.light(
        primary: primaryBlue,
        secondary: primaryBlueLight,
        surface: surfaceLight,
        onSurface: textPrimaryLight,
        error: accentRed,
      ),
      textTheme: GoogleFonts.interTextTheme(baseTextTheme).apply(
        bodyColor: textPrimaryLight,
        displayColor: textPrimaryLight,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        foregroundColor: textPrimaryLight,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.w700,
          color: textPrimaryLight,
        ),
        iconTheme: IconThemeData(color: textPrimaryLight),
      ),
      cardTheme: CardThemeData(
        color: cardLight,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: cardBorderLight, width: 1.2),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: surfaceLight,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: cardBorderLight),
        ),
        titleTextStyle: const TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.bold,
          color: textPrimaryLight,
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: const Color(0xFFF8FAFC),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: cardBorderLight),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: cardBorderLight),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: primaryBlue, width: 1.5),
        ),
        hintStyle: const TextStyle(color: textMutedLight, fontSize: 13),
      ),
      dividerTheme: const DividerThemeData(
        color: cardBorderLight,
        thickness: 1,
      ),
    );
  }
}
