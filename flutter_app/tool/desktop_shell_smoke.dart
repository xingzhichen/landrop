// Native bridge smoke test, not the production entrypoint.
// Build with `flutter build macos --release -t tool/desktop_shell_smoke.dart`,
// then run the bundle executable. It never loads or changes the user's pages.
// ignore_for_file: avoid_print
import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:landrop/desktop_shell.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SizedBox.shrink());
  await WidgetsBinding.instance.endOfFrame;
  try {
    const shell = DesktopShell();
    if (!shell.isSupported) {
      throw StateError('A native desktop host is required');
    }
    final shown = Completer<void>();
    await shell.initialize(
        onDrop: (_) {},
        onShow: () {
          if (!shown.isCompleted) shown.complete();
        });
    print('NATIVE_SHELL initialize PASS');
    await shell.setBackgroundMode(false);
    await shell.setBackgroundMode(true);
    print('NATIVE_SHELL backgroundMode toggle PASS');
    await shell.showWindow();
    await shown.future.timeout(const Duration(seconds: 5));
    print('NATIVE_SHELL showWindow callback PASS');
    print('NATIVE_SHELL requesting native quit');
    await shell.quit();
  } catch (error, stack) {
    print('NATIVE_SHELL FAIL $error\n$stack');
    exit(1);
  }
}
