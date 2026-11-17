import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Native desktop lifecycle and OS file drops. No dropped item is opened here.
///
/// Install from a widget's initState, not main(). Repeated initialize calls
/// replace callbacks, so a host can safely bind a replacement controller.
/// Only one initialized shell owns the platform channel at a time.
class DesktopShell {
  const DesktopShell({
    this.channel = const MethodChannel('landrop/desktop_shell'),
    this.enabled = true,
  });

  /// Explicit injectable no-op for widget tests and non-desktop hosts.
  const DesktopShell.noop()
      : channel = const MethodChannel('landrop/desktop_shell'),
        enabled = false;

  const DesktopShell.disabled()
      : channel = const MethodChannel('landrop/desktop_shell'),
        enabled = false;

  final MethodChannel channel;
  final bool enabled;
  static final Expando<_ShellState> _states = Expando<_ShellState>();
  static DesktopShell? _owner;
  _ShellState get _state => _states[this] ??= _ShellState();

  bool get isSupported =>
      enabled &&
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.macOS ||
          defaultTargetPlatform == TargetPlatform.windows);

  Future<void> initialize({
    required void Function(List<String>) onDrop,
    required void Function() onShow,
    void Function(bool)? onDragChanged,
  }) async {
    final state = _state;
    state.onDrop = onDrop;
    state.onShow = onShow;
    state.onDragChanged = onDragChanged;
    if (!isSupported) return;
    _owner = this;
    channel.setMethodCallHandler((call) async {
      if (!identical(_owner, this)) return;
      final arguments = call.arguments;
      switch (call.method) {
        case 'filesDropped':
          if (arguments is! Map || arguments['paths'] is! List) return;
          final paths = (arguments['paths'] as List)
              .whereType<String>()
              .where(_isAbsolutePath)
              .toSet()
              .toList(growable: false);
          state.onDragChanged?.call(false);
          if (paths.isNotEmpty) state.onDrop?.call(paths);
        case 'showWindow':
          state.onShow?.call();
        case 'dragChanged':
          if (arguments is Map && arguments['dragging'] is bool) {
            state.onDragChanged?.call(arguments['dragging'] as bool);
          }
      }
    });
    try {
      await channel.invokeMethod<void>('initialize');
    } on MissingPluginException {
      // A native-free test host (or unsupported embedder) stays usable.
      dispose();
    } catch (_) {
      dispose();
      rethrow;
    }
  }

  Future<void> showWindow() => _invoke('showWindow');
  Future<void> quit() => _invoke('quit');

  /// True by default natively. False means the next window close exits.
  /// If already hidden, disabling background mode first restores the window.
  Future<void> setBackgroundMode(bool enabled) =>
      _invoke('setBackgroundMode', {'enabled': enabled});

  Future<void> _invoke(String method, [Object? arguments]) async {
    if (!isSupported) return;
    try {
      await channel.invokeMethod<void>(method, arguments);
    } on MissingPluginException {
      // No-op for tests without a native runner.
    }
  }

  /// Detaches Dart callbacks only; does not stop in-flight native transfers.
  void dispose() {
    if (identical(_owner, this)) {
      channel.setMethodCallHandler(null);
      _owner = null;
    }
    _states[this] = null;
  }

  static bool _isAbsolutePath(String path) {
    if (path.isEmpty || path.contains('\u0000')) return false;
    if (path.startsWith('/')) return true;
    return RegExp(r'^[a-zA-Z]:[\\/]').hasMatch(path) ||
        (RegExp(r'^\\\\[^\\]+\\[^\\]+(?:\\.*)?$').hasMatch(path) &&
            !path.startsWith('\\\\?\\') &&
            !path.startsWith('\\\\.\\'));
  }
}

class _ShellState {
  void Function(List<String>)? onDrop;
  void Function()? onShow;
  void Function(bool)? onDragChanged;
}
