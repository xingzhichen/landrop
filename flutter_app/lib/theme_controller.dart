// Flutter 3.50 retains Material while the replacement package stabilizes.
// ignore_for_file: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Persists a preference, not a snapshot of the platform's current brightness.
///
/// Changes are committed and announced only after storage succeeds. Reads and
/// writes are serialized so a slow write cannot win over a later user choice.
class ThemeController extends ChangeNotifier {
  ThemeController({Future<SharedPreferences> Function()? preferencesLoader})
      : _preferencesLoader = preferencesLoader ?? SharedPreferences.getInstance;

  static const preferenceKey = 'landrop.theme.v1';

  final Future<SharedPreferences> Function() _preferencesLoader;
  Future<void> _pending = Future<void>.value();
  ThemeMode _mode = ThemeMode.system;
  bool _initialized = false;
  bool _hasManualSelection = false;
  bool _disposed = false;

  ThemeMode get mode => _mode;

  /// Safe to call again; a restored or manually selected mode is never reset.
  /// A failed initialization may be retried.
  Future<void> initialize() => _enqueue(() async {
        if (_initialized) return;
        if (!_hasManualSelection) {
          final preferences = await _preferencesLoader();
          // The legacy plugin caches optimistically, even when a write fails.
          // Reading storage afresh also makes a newly created controller honest.
          await preferences.reload();
          final value = preferences.get(preferenceKey);
          final restored = switch (value) {
            'light' => ThemeMode.light,
            'dark' => ThemeMode.dark,
            _ => ThemeMode.system,
          };
          if (_mode != restored) {
            _mode = restored;
            if (!_disposed) notifyListeners();
          }
        }
        _initialized = true;
      });

  /// Throws when persistence fails and leaves [mode] unchanged in that case.
  Future<void> setMode(ThemeMode mode) => _enqueue(() async {
        final preferences = await _preferencesLoader();
        try {
          final saved = await preferences.setString(preferenceKey, mode.name);
          if (!saved) {
            throw StateError('Could not save the theme preference.');
          }
        } catch (_) {
          // Undo the plugin's optimistic cache without pretending a failed
          // write succeeded. Preserve the original error if reloading fails.
          try {
            await preferences.reload();
          } catch (_) {
            // initialize() always reloads before trusting this cache again.
          }
          rethrow;
        }
        _hasManualSelection = true;
        _mode = mode;
        if (!_disposed) notifyListeners();
      });

  Future<void> _enqueue(Future<void> Function() operation) {
    final result = _pending.then((_) => operation());
    // A rejected operation is still returned to its caller, but must not poison
    // the queue and prevent the next selection or initialization from running.
    _pending = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
