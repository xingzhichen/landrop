// Flutter 3.50 retains Material while the replacement package stabilizes.
// ignore_for_file: deprecated_member_use
import 'package:flutter/material.dart';

/// Shared visual tokens for the native LanDrop workspace.
abstract final class AppTheme {
  static const background = Color(0xFFEEF0F3);
  static const surface = Color(0xFFFFFFFF);
  static const ink = Color(0xFF0B0C0E);
  static const primary = Color(0xFF1F2DE6);
  static const muted = Color(0xFF626975);
  static const border = Color(0xFFDDE1E7);
  static const primaryTint = Color(0xFFE8EBFF);

  static ThemeData get light {
    final scheme = ColorScheme.fromSeed(
      seedColor: primary,
      brightness: Brightness.light,
      primary: primary,
      onPrimary: Colors.white,
      surface: surface,
      onSurface: ink,
      onSurfaceVariant: muted,
      outline: border,
      error: const Color(0xFFB33D32),
    );
    final base =
        ThemeData(useMaterial3: true, colorScheme: scheme, fontFamily: 'Arial');
    final shape =
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(12));
    return base.copyWith(
      scaffoldBackgroundColor: background,
      textTheme: base.textTheme.apply(bodyColor: ink, displayColor: ink),
      dividerTheme:
          const DividerThemeData(color: border, thickness: 1, space: 1),
      cardTheme: CardThemeData(
        color: surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: border),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: border),
        ),
        titleTextStyle: const TextStyle(
            color: ink, fontSize: 23, fontWeight: FontWeight.w700),
      ),
      filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
        backgroundColor: primary,
        foregroundColor: surface,
        minimumSize: const Size(0, 44),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        shape: shape,
        textStyle: const TextStyle(
            fontFamily: 'Arial', fontSize: 14, fontWeight: FontWeight.w600),
      )),
      outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
        foregroundColor: ink,
        minimumSize: const Size(0, 44),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        side: const BorderSide(color: border),
        shape: shape,
      )),
      textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(
        foregroundColor: primary,
        minimumSize: const Size(0, 44),
        shape: shape,
      )),
      iconButtonTheme: IconButtonThemeData(
          style: IconButton.styleFrom(
        foregroundColor: muted,
        minimumSize: const Size(44, 44),
        shape: shape,
      )),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: background,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
        border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: border)),
        enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: border)),
        focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: primary, width: 1.5)),
      ),
      tooltipTheme: TooltipThemeData(
        decoration:
            BoxDecoration(color: ink, borderRadius: BorderRadius.circular(8)),
        textStyle: const TextStyle(color: surface, fontSize: 12),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: ink,
        contentTextStyle: const TextStyle(color: surface),
        behavior: SnackBarBehavior.floating,
        shape: shape,
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(
          color: primary, linearTrackColor: primaryTint),
    );
  }
}

/// Native type indicators: colour is supplementary to the familiar file icon.
class FileTypeIcon extends StatelessWidget {
  const FileTypeIcon({super.key, required this.name});
  final String name;

  @override
  Widget build(BuildContext context) {
    final extension = name.split('.').last.toLowerCase();
    final (icon, color) = switch (extension) {
      'jpg' || 'jpeg' || 'png' || 'gif' || 'webp' || 'heic' => (
          Icons.image_outlined,
          const Color(0xFF277C66)
        ),
      'pdf' => (Icons.picture_as_pdf_outlined, const Color(0xFFB45145)),
      'zip' || 'rar' || '7z' || 'tar' || 'gz' => (
          Icons.folder_zip_outlined,
          const Color(0xFF9A711D)
        ),
      'mp4' || 'mov' || 'mkv' || 'avi' => (
          Icons.movie_outlined,
          const Color(0xFF436BA0)
        ),
      'mp3' || 'wav' || 'm4a' || 'flac' => (
          Icons.audio_file_outlined,
          const Color(0xFF9C5A38)
        ),
      'xls' || 'xlsx' || 'csv' => (
          Icons.table_chart_outlined,
          const Color(0xFF277C66)
        ),
      'doc' || 'docx' || 'txt' || 'md' => (
          Icons.description_outlined,
          const Color(0xFF436BA0)
        ),
      _ => (Icons.insert_drive_file_outlined, AppTheme.muted),
    };
    return Container(
      width: 42,
      height: 46,
      decoration: BoxDecoration(
          color: color.withValues(alpha: 0.09),
          borderRadius: BorderRadius.circular(10)),
      child: Icon(icon, color: color, size: 23),
    );
  }
}
