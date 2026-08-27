import 'package:flutter/material.dart';

/// 極簡留白配色：淺底白/淺灰、深字、細灰 caption。
class AppColors {
  AppColors._();

  static const Color bg = Color(0xFFF5F5F7);
  static const Color card = Color(0xFFF0F0F0);
  static const Color text = Color(0xFF1D1D1F);
  static const Color caption = Color(0xFF86868B);
  static const Color accent = Color(0xFF0A84FF);
  static const Color danger = Color(0xFFE53935);
}

class AppTheme {
  AppTheme._();

  static ThemeData get light {
    final ColorScheme scheme = ColorScheme.fromSeed(
      seedColor: AppColors.accent,
      surface: AppColors.bg,
    );
    return ThemeData(
      useMaterial3: true,
      scaffoldBackgroundColor: AppColors.bg,
      colorScheme: scheme.copyWith(
        primary: AppColors.accent,
        onPrimary: Colors.white,
        surface: AppColors.bg,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: AppColors.bg,
        foregroundColor: AppColors.text,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: AppColors.text,
          fontSize: 26,
          fontWeight: FontWeight.w700,
        ),
      ),
      textTheme: const TextTheme(
        headlineMedium: TextStyle(
          color: AppColors.text,
          fontSize: 30,
          fontWeight: FontWeight.w800,
        ),
        bodyMedium: TextStyle(color: AppColors.text, fontSize: 15),
        bodySmall: TextStyle(color: AppColors.caption, fontSize: 12.5),
      ),
      dividerTheme: const DividerThemeData(
        color: Color(0xFFE5E5EA),
        thickness: 1,
      ),
      checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? AppColors.accent
              : Colors.white,
        ),
        side: const BorderSide(color: AppColors.caption, width: 1.5),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
      ),
    );
  }
}