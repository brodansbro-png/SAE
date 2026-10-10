import 'package:flutter/material.dart';

/// The app's visual language.
///
/// One theme object, shared by both platforms, so an Android phone and an
/// iPhone render the same screen identically. The only platform-conditional
/// piece is [adaptiveSpacing], which gives iOS its taller content insets.
class SaeTheme {
  const SaeTheme._();

  /// Primary brand colour — a deep teal, chosen to stay legible under the white
  /// text used on top of it in both light and dark themes.
  static const Color primary = Color(0xFF00695C);

  static const Color primaryDark = Color(0xFF004D40);

  /// Secondary accent, used for the check-out action so coming and going are
  /// distinguishable at a glance.
  static const Color secondary = Color(0xFF00695C);

  static const Color surface = Color(0xFFFAFAFA);

  static const Color error = Color(0xFFB3261E);

  static const Color warning = Color(0xFF8D5B00);

  static const Color success = Color(0xFF2E7D32);

  /// Light theme.
  static ThemeData light() {
    final scheme = ColorScheme.fromSeed(
      seedColor: primary,
      primary: primary,
      surface: surface,
    );

    return _base(scheme).copyWith(
      scaffoldBackgroundColor: surface,
    );
  }

  /// Dark theme.
  static ThemeData dark() {
    final scheme = ColorScheme.fromSeed(
      seedColor: primary,
      brightness: Brightness.dark,
    );

    return _base(scheme);
  }

  static ThemeData _base(ColorScheme scheme) {
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      // Nunito throughout, ported from the reference app. Its rounded terminals
      // stay legible at the small sizes a status bar uses, and the tall
      // x-height keeps Indonesian labels from crowding.
      fontFamily: 'Nunito',
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        elevation: 0,
        scrolledUnderElevation: 1,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: scheme.onSurface,
          fontSize: 20,
          fontWeight: FontWeight.w600,
        ),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: scheme.outlineVariant),
        ),
        color: scheme.surface,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: scheme.primary, width: 2),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: scheme.error),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: scheme.error, width: 2),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          // 52dp clears the 48dp minimum touch target with margin, which
          // matters most on the punch buttons: those are tapped one-handed,
          // often in a hurry, sometimes with gloves on.
          minimumSize: const Size.fromHeight(52),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size.fromHeight(48),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          minimumSize: const Size(64, 44),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      chipTheme: ChipThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant,
        space: 1,
        thickness: 1,
      ),
      listTileTheme: const ListTileThemeData(
        contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      ),
    );
  }

  /// Standard page padding, slightly larger on iOS to match its content inset
  /// convention.
  static EdgeInsets pagePadding(BuildContext context) => EdgeInsets.symmetric(
        horizontal: 16,
        vertical: Theme.of(context).platform == TargetPlatform.iOS ? 20 : 16,
      );

  /// Colour for an attendance status label.
  static Color statusColor(BuildContext context, String status) {
    final scheme = Theme.of(context).colorScheme;
    switch (status) {
      case 'COMPLETED':
        return success;
      case 'LATE':
      case 'EARLY_LEAVE':
        return warning;
      case 'ON_LEAVE':
        return scheme.tertiary;
      case 'CHECKED_IN':
        return primary;
      default:
        return scheme.outline;
    }
  }
}