import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class AppTheme {
  // Primary colors
  static const Color primaryDark = Color(0xFF0D1B2A);
  static const Color primaryMid = Color(0xFF1B2838);
  static const Color primaryLight = Color(0xFF243447);
  
  // Accent colors
  static const Color accentBlue = Color(0xFF4DA8DA);
  static const Color accentGreen = Color(0xFF4CAF50);
  static const Color accentOrange = Color(0xFFFF9800);
  static const Color accentRed = Color(0xFFEF5350);
  static const Color accentYellow = Color(0xFFFFCA28);
  
  // Text colors
  static const Color textPrimary = Color(0xFFE0E0E0);
  static const Color textSecondary = Color(0xFF9E9E9E);
  static const Color textMuted = Color(0xFF616161);
  
  // Card colors
  static const Color cardBackground = Color(0xFF1E2D3D);
  static const Color cardBorder = Color(0xFF2A3F52);
  
  // Status colors
  static const Color statusExcellent = Color(0xFF4CAF50);
  static const Color statusGood = Color(0xFF66BB6A);
  static const Color statusFair = Color(0xFFFFCA28);
  static const Color statusPoor = Color(0xFFFF9800);
  static const Color statusCritical = Color(0xFFEF5350);
  
  // Severity colors
  static Color severityColor(String severity) {
    switch (severity.toUpperCase()) {
      case 'CRITICAL': return accentRed;
      case 'HIGH': return accentOrange;
      case 'MEDIUM': return accentYellow;
      case 'LOW': return accentBlue;
      default: return textSecondary;
    }
  }
  
  // Health score color
  static Color healthScoreColor(int score) {
    if (score >= 90) return statusExcellent;
    if (score >= 75) return statusGood;
    if (score >= 50) return statusFair;
    if (score >= 25) return statusPoor;
    return statusCritical;
  }
  
  // Health score label
  static String healthScoreLabel(int score) {
    if (score >= 90) return 'EXCELLENT';
    if (score >= 75) return 'GOOD';
    if (score >= 50) return 'FAIR';
    if (score >= 25) return 'POOR';
    return 'CRITICAL';
  }
  
  static ThemeData get darkTheme {
    return ThemeData(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: primaryDark,
      primaryColor: accentBlue,
      colorScheme: const ColorScheme.dark(
        primary: accentBlue,
        secondary: accentGreen,
        surface: cardBackground,
        error: accentRed,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        titleTextStyle: TextStyle(
          fontFamily: 'Inter',
          fontSize: 18,
          fontWeight: FontWeight.w600,
          color: textPrimary,
        ),
      ),
      cardTheme: CardThemeData(
        color: cardBackground,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: cardBorder, width: 0.5),
        ),
      ),
      textTheme: TextTheme(
        headlineLarge: GoogleFonts.orbitron(fontSize: 28, fontWeight: FontWeight.w700, color: textPrimary),
        headlineMedium: GoogleFonts.orbitron(fontSize: 22, fontWeight: FontWeight.w600, color: textPrimary),
        headlineSmall: GoogleFonts.orbitron(fontSize: 18, fontWeight: FontWeight.w600, color: textPrimary),
        bodyLarge: GoogleFonts.inter(fontSize: 16, fontWeight: FontWeight.w400, color: textPrimary),
        bodyMedium: GoogleFonts.inter(fontSize: 14, fontWeight: FontWeight.w400, color: textSecondary),
        bodySmall: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w400, color: textMuted),
        labelLarge: GoogleFonts.inter(fontSize: 14, fontWeight: FontWeight.w600, color: textPrimary),
      ),
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        backgroundColor: primaryMid,
        selectedItemColor: accentBlue,
        unselectedItemColor: textMuted,
        type: BottomNavigationBarType.fixed,
        elevation: 0,
      ),
    );
  }
}
