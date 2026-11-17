// Flutter 3.50 retains Material while the replacement package stabilizes.
// ignore_for_file: deprecated_member_use
import 'package:flutter/material.dart';

/// Immutable semantic colours shared by the native workspace and its dialogs.
@immutable
class AppColors extends ThemeExtension<AppColors> {
  const AppColors({
    required this.background,
    required this.surface,
    required this.ink,
    required this.primary,
    required this.muted,
    required this.border,
    required this.primaryTint,
  });

  final Color background;
  final Color surface;
  final Color ink;
  final Color primary;
  final Color muted;
  final Color border;
  final Color primaryTint;

  @override
  AppColors copyWith({
    Color? background,
    Color? surface,
    Color? ink,
    Color? primary,
    Color? muted,
    Color? border,
    Color? primaryTint,
  }) =>
      AppColors(
        background: background ?? this.background,
        surface: surface ?? this.surface,
        ink: ink ?? this.ink,
        primary: primary ?? this.primary,
        muted: muted ?? this.muted,
        border: border ?? this.border,
        primaryTint: primaryTint ?? this.primaryTint,
      );

  @override
  AppColors lerp(covariant AppColors? other, double t) {
    if (other == null) return this;
    return AppColors(
      background: Color.lerp(background, other.background, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      ink: Color.lerp(ink, other.ink, t)!,
      primary: Color.lerp(primary, other.primary, t)!,
      muted: Color.lerp(muted, other.muted, t)!,
      border: Color.lerp(border, other.border, t)!,
      primaryTint: Color.lerp(primaryTint, other.primaryTint, t)!,
    );
  }
}

/// Shared visual tokens for the native LanDrop workspace.
abstract final class AppTheme {
  // Legacy light constants remain available to callers outside the workspace.
  static const background = Color(0xFFEEF0F3);
  static const surface = Color(0xFFFFFFFF);
  static const ink = Color(0xFF0B0C0E);
  static const primary = Color(0xFF1F2DE6);
  static const muted = Color(0xFF626975);
  static const border = Color(0xFFDDE1E7);
  static const primaryTint = Color(0xFFE8EBFF);

  static const lightColors = AppColors(
    background: background,
    surface: surface,
    ink: ink,
    primary: primary,
    muted: muted,
    border: border,
    primaryTint: primaryTint,
  );
  static const darkColors = AppColors(
    background: Color(0xFF111317),
    surface: Color(0xFF1B1E24),
    ink: Color(0xFFF2F4F8),
    primary: Color(0xFF8996FF),
    muted: Color(0xFFA4ACB9),
    border: Color(0xFF343B47),
    primaryTint: Color(0xFF29314B),
  );

  /// Resolves against the live inherited theme (including theme animation).
  static AppColors colorsOf(BuildContext context) {
    final theme = Theme.of(context);
    return theme.extension<AppColors>() ??
        (theme.brightness == Brightness.dark ? darkColors : lightColors);
  }

  static ThemeData get light => _build(lightColors, Brightness.light);
  static ThemeData get dark => _build(darkColors, Brightness.dark);

  static ThemeData _build(AppColors colors, Brightness brightness) {
    final isDark = brightness == Brightness.dark;
    final onPrimary = isDark ? const Color(0xFF11152C) : Colors.white;
    final scheme = ColorScheme.fromSeed(
      seedColor: colors.primary,
      brightness: brightness,
      primary: colors.primary,
      onPrimary: onPrimary,
      primaryContainer: colors.primaryTint,
      onPrimaryContainer: colors.ink,
      surface: colors.surface,
      onSurface: colors.ink,
      onSurfaceVariant: colors.muted,
      outline: colors.border,
      outlineVariant: colors.border,
      error: isDark ? const Color(0xFFFFB4A9) : const Color(0xFFB33D32),
    );
    final base =
        ThemeData(useMaterial3: true, colorScheme: scheme, fontFamily: 'Arial');
    final shape =
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(12));
    OutlineInputBorder inputBorder(Color color, [double width = 1]) =>
        OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: color, width: width),
        );
    return base.copyWith(
      extensions: <ThemeExtension<dynamic>>[colors],
      scaffoldBackgroundColor: colors.background,
      canvasColor: colors.surface,
      disabledColor: colors.muted.withValues(alpha: 0.5),
      textTheme:
          base.textTheme.apply(bodyColor: colors.ink, displayColor: colors.ink),
      iconTheme: IconThemeData(color: colors.muted),
      dividerTheme:
          DividerThemeData(color: colors.border, thickness: 1, space: 1),
      cardTheme: CardThemeData(
        color: colors.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: colors.border),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: colors.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: colors.border),
        ),
        titleTextStyle: TextStyle(
            color: colors.ink, fontSize: 23, fontWeight: FontWeight.w700),
        contentTextStyle: TextStyle(color: colors.ink, fontSize: 14),
      ),
      filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
        backgroundColor: colors.primary,
        foregroundColor: onPrimary,
        disabledBackgroundColor: colors.primary.withValues(alpha: 0.14),
        disabledForegroundColor: colors.muted,
        minimumSize: const Size(0, 44),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        shape: shape,
        textStyle: const TextStyle(
            fontFamily: 'Arial', fontSize: 14, fontWeight: FontWeight.w600),
      )),
      outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
        foregroundColor: colors.ink,
        disabledForegroundColor: colors.muted,
        minimumSize: const Size(0, 44),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        side: BorderSide(color: colors.border),
        shape: shape,
      )),
      textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(
        foregroundColor: colors.primary,
        disabledForegroundColor: colors.muted,
        minimumSize: const Size(0, 44),
        shape: shape,
      )),
      iconButtonTheme: IconButtonThemeData(
          style: IconButton.styleFrom(
        foregroundColor: colors.muted,
        minimumSize: const Size(44, 44),
        shape: shape,
      )),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: colors.background,
        hintStyle: TextStyle(color: colors.muted),
        labelStyle: TextStyle(color: colors.muted),
        helperStyle: TextStyle(color: colors.muted),
        prefixIconColor: colors.muted,
        suffixIconColor: colors.muted,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
        border: inputBorder(colors.border),
        enabledBorder: inputBorder(colors.border),
        disabledBorder: inputBorder(colors.border.withValues(alpha: 0.6)),
        focusedBorder: inputBorder(colors.primary, 1.5),
        errorBorder: inputBorder(scheme.error),
        focusedErrorBorder: inputBorder(scheme.error, 1.5),
      ),
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: colors.primary,
        selectionColor: colors.primary.withValues(alpha: 0.3),
        selectionHandleColor: colors.primary,
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.disabled)) return colors.muted;
          return states.contains(WidgetState.selected)
              ? onPrimary
              : colors.muted;
        }),
        trackColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.disabled)) return colors.border;
          return states.contains(WidgetState.selected)
              ? colors.primary
              : colors.background;
        }),
        trackOutlineColor: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.selected)
                ? Colors.transparent
                : colors.border),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
            color: colors.ink, borderRadius: BorderRadius.circular(8)),
        textStyle: TextStyle(color: colors.surface, fontSize: 12),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: colors.ink,
        contentTextStyle: TextStyle(color: colors.surface),
        actionTextColor: isDark ? primary : darkColors.primary,
        behavior: SnackBarBehavior.floating,
        shape: shape,
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
          color: colors.primary, linearTrackColor: colors.primaryTint),
    );
  }
}

/// Native type indicators: colour is supplementary to the familiar file icon.
class FileTypeIcon extends StatelessWidget {
  const FileTypeIcon({super.key, required this.name});
  final String name;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final extension = name.split('.').last.toLowerCase();
    final (icon, lightColor, darkColor) = switch (extension) {
      'jpg' || 'jpeg' || 'png' || 'gif' || 'webp' || 'heic' => (
          Icons.image_outlined,
          const Color(0xFF277C66),
          const Color(0xFF7CD8B5),
        ),
      'pdf' => (
          Icons.picture_as_pdf_outlined,
          const Color(0xFFB45145),
          const Color(0xFFFFA394),
        ),
      'zip' || 'rar' || '7z' || 'tar' || 'gz' => (
          Icons.folder_zip_outlined,
          const Color(0xFF9A711D),
          const Color(0xFFE8C374),
        ),
      'mp4' || 'mov' || 'mkv' || 'avi' => (
          Icons.movie_outlined,
          const Color(0xFF436BA0),
          const Color(0xFF9BC1F8),
        ),
      'mp3' || 'wav' || 'm4a' || 'flac' => (
          Icons.audio_file_outlined,
          const Color(0xFF9C5A38),
          const Color(0xFFF0B48D),
        ),
      'xls' || 'xlsx' || 'csv' => (
          Icons.table_chart_outlined,
          const Color(0xFF277C66),
          const Color(0xFF7CD8B5),
        ),
      'doc' || 'docx' || 'txt' || 'md' => (
          Icons.description_outlined,
          const Color(0xFF436BA0),
          const Color(0xFF9BC1F8),
        ),
      _ => (
          Icons.insert_drive_file_outlined,
          AppTheme.colorsOf(context).muted,
          AppTheme.colorsOf(context).muted,
        ),
    };
    final color = isDark ? darkColor : lightColor;
    return Container(
      width: 42,
      height: 46,
      decoration: BoxDecoration(
          color: color.withValues(alpha: isDark ? 0.16 : 0.09),
          borderRadius: BorderRadius.circular(10)),
      child: Icon(icon, color: color, size: 23),
    );
  }
}
