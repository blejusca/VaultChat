import 'package:flutter/material.dart';

class SecureChatColors {
  static const Color voidBlack = Color(0xFF060913);
  static const Color deepNavy = Color(0xFF0B1020);
  static const Color midnight = Color(0xFF101729);
  static const Color card = Color(0xFF141B2D);
  static const Color cardAlt = Color(0xFF1B2438);
  static const Color cardSoft = Color(0xFF202B43);
  static const Color violet = Color(0xFF6C5CE7);
  static const Color violetBright = Color(0xFF8B7CFF);
  static const Color violetSoft = Color(0xFFB2A8FF);
  static const Color turquoise = Color(0xFF00C2A8);
  static const Color text = Color(0xFFF5F7FA);
  static const Color mutedText = Color(0xFFAAB0C8);
  static const Color softText = Color(0xFF76809A);
  static const Color danger = Color(0xFFFF6B6B);
  static const Color warning = Color(0xFFFFB86B);
  static const Color border = Color(0xFF27304A);
  static const Color borderSoft = Color(0xFF34405E);
  static const Color field = Color(0xFF111827);
}

class SecureChatRadius {
  static const double sm = 12;
  static const double md = 16;
  static const double lg = 22;
  static const double xl = 28;
  static const double xxl = 34;
}

class SecureChatSpacing {
  static const double xs = 6;
  static const double sm = 10;
  static const double md = 14;
  static const double lg = 20;
  static const double xl = 28;
}

class SecureChatMotion {
  static const Duration fast = Duration(milliseconds: 140);
  static const Duration normal = Duration(milliseconds: 220);
  static const Duration slow = Duration(milliseconds: 320);
  static const Curve curve = Curves.easeOutCubic;
}

class SecureChatShadows {
  static List<BoxShadow> soft = [
    BoxShadow(
      color: Colors.black.withValues(alpha: 0.22),
      blurRadius: 18,
      offset: const Offset(0, 10),
    ),
  ];

  static List<BoxShadow> card = [
    BoxShadow(
      color: Colors.black.withValues(alpha: 0.18),
      blurRadius: 24,
      offset: const Offset(0, 14),
    ),
  ];

  static List<BoxShadow> subtleGlow = [
    BoxShadow(
      color: SecureChatColors.violet.withValues(alpha: 0.16),
      blurRadius: 22,
      offset: const Offset(0, 10),
    ),
  ];

  static List<BoxShadow> greenGlow = [
    BoxShadow(
      color: SecureChatColors.turquoise.withValues(alpha: 0.18),
      blurRadius: 14,
    ),
  ];
}

class SecureChatGradients {
  static const LinearGradient background = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [
      SecureChatColors.voidBlack,
      SecureChatColors.deepNavy,
      Color(0xFF11162A),
    ],
  );

  static const LinearGradient card = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [
      Color(0xFF1A2338),
      Color(0xFF121A2C),
    ],
  );

  static const LinearGradient primary = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF7568F2), Color(0xFF4F46E5)],
  );

  static const LinearGradient accent = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [SecureChatColors.violet, SecureChatColors.turquoise],
  );
}

class SecureChatTheme {
  static ThemeData dark() {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: SecureChatColors.violet,
      brightness: Brightness.dark,
      primary: SecureChatColors.violet,
      secondary: SecureChatColors.turquoise,
      surface: SecureChatColors.deepNavy,
      error: SecureChatColors.danger,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: SecureChatColors.deepNavy,
      fontFamily: 'Roboto',
      appBarTheme: const AppBarTheme(
        centerTitle: false,
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: Colors.transparent,
        foregroundColor: SecureChatColors.text,
        titleTextStyle: TextStyle(
          color: SecureChatColors.text,
          fontSize: 22,
          fontWeight: FontWeight.w800,
          letterSpacing: -0.35,
        ),
      ),
      textTheme: const TextTheme(
        headlineLarge: TextStyle(
          color: SecureChatColors.text,
          fontSize: 32,
          fontWeight: FontWeight.w800,
          letterSpacing: -0.7,
        ),
        headlineMedium: TextStyle(
          color: SecureChatColors.text,
          fontSize: 27,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.5,
        ),
        titleLarge: TextStyle(
          color: SecureChatColors.text,
          fontSize: 20,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.15,
        ),
        titleMedium: TextStyle(
          color: SecureChatColors.text,
          fontSize: 16,
          fontWeight: FontWeight.w700,
        ),
        bodyLarge: TextStyle(
          color: SecureChatColors.text,
          fontSize: 16,
          height: 1.35,
        ),
        bodyMedium: TextStyle(
          color: SecureChatColors.mutedText,
          fontSize: 14,
          height: 1.38,
        ),
        labelLarge: TextStyle(
          color: SecureChatColors.text,
          fontSize: 15,
          fontWeight: FontWeight.w700,
        ),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: SecureChatColors.card,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(SecureChatRadius.lg),
          side: const BorderSide(color: SecureChatColors.border),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: Color(0xFF6658E8),
          foregroundColor: Colors.white,
          minimumSize: const Size(52, 52),
          disabledBackgroundColor: SecureChatColors.cardSoft,
          disabledForegroundColor: SecureChatColors.softText,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(SecureChatRadius.xl),
          ),
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: SecureChatColors.text,
          side: const BorderSide(color: SecureChatColors.borderSoft),
          minimumSize: const Size(52, 52),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(SecureChatRadius.xl),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: SecureChatColors.violetSoft,
          textStyle: const TextStyle(fontWeight: FontWeight.w700),
        ),
      ),
      floatingActionButtonTheme: const FloatingActionButtonThemeData(
        backgroundColor: Color(0xFF6658E8),
        foregroundColor: Colors.white,
        elevation: 4,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: SecureChatColors.field.withValues(alpha: 0.72),
        hintStyle: const TextStyle(color: SecureChatColors.softText),
        labelStyle: const TextStyle(color: SecureChatColors.mutedText),
        contentPadding: const EdgeInsets.symmetric(horizontal: 15, vertical: 14),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(SecureChatRadius.md),
          borderSide: const BorderSide(color: SecureChatColors.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(SecureChatRadius.md),
          borderSide: const BorderSide(color: SecureChatColors.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(SecureChatRadius.md),
          borderSide: const BorderSide(color: SecureChatColors.violetBright, width: 1.25),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: SecureChatColors.card,
        surfaceTintColor: Colors.transparent,
        insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(SecureChatRadius.xl),
          side: const BorderSide(color: SecureChatColors.border),
        ),
        titleTextStyle: const TextStyle(
          color: SecureChatColors.text,
          fontSize: 22,
          fontWeight: FontWeight.w800,
          letterSpacing: -0.25,
        ),
        contentTextStyle: const TextStyle(
          color: SecureChatColors.mutedText,
          fontSize: 13.5,
          height: 1.38,
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        elevation: 0,
        backgroundColor: SecureChatColors.cardAlt,
        contentTextStyle: const TextStyle(color: SecureChatColors.text),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(SecureChatRadius.md),
        ),
      ),
      dividerTheme: const DividerThemeData(
        color: SecureChatColors.border,
        thickness: 1,
        space: 28,
      ),
    );
  }
}

class SecureChatStatusColor {
  static Color fromStateName(String name) {
    if (name.contains('connected') || name.contains('Conectat')) {
      return SecureChatColors.turquoise;
    }
    if (name.contains('error') || name.contains('Offline')) {
      return SecureChatColors.danger;
    }
    return SecureChatColors.warning;
  }
}

class SecureChatAvatar {
  static int _hash(String seed) {
    var hash = 0;
    for (final codeUnit in seed.codeUnits) {
      hash = 0x1fffffff & (hash + codeUnit);
      hash = 0x1fffffff & (hash + ((0x0007ffff & hash) << 10));
      hash ^= (hash >> 6);
    }
    hash = 0x1fffffff & (hash + ((0x03ffffff & hash) << 3));
    hash ^= (hash >> 11);
    hash = 0x1fffffff & (hash + ((0x00003fff & hash) << 15));
    return hash.abs();
  }

  static LinearGradient gradientFor(String seed) {
    final palettes = <List<Color>>[
      [const Color(0xFF8B7CFF), const Color(0xFF00C2A8)],
      [const Color(0xFF5E7CFF), const Color(0xFF31D0AA)],
      [const Color(0xFF7C5CFF), const Color(0xFFFFB86B)],
      [const Color(0xFF3B82F6), const Color(0xFF8B7CFF)],
      [const Color(0xFF00C2A8), const Color(0xFF4F46E5)],
      [const Color(0xFFB2A8FF), const Color(0xFF00A38F)],
    ];
    final selected = palettes[_hash(seed) % palettes.length];
    return LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: selected,
    );
  }
}
