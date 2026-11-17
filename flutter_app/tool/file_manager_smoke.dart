// Manual native smoke test: `flutter run -d macos -t tool/file_manager_smoke.dart`.
// Opens the OS file manager for an isolated temporary fixture, then exits.
// This is not the production entrypoint and never opens a received file itself.
// ignore_for_file: avoid_print
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:landrop/desktop_file_manager.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SizedBox.shrink());
  await WidgetsBinding.instance.endOfFrame;
  try {
    final directory =
        await Directory.systemTemp.createTemp('landrop-native-folders-');
    final file =
        await File('${directory.path}${Platform.pathSeparator}接收 文件 (1).txt')
            .writeAsString('LanDrop native folder integration smoke test.');
    const manager = DesktopFileManager();
    await manager.openDirectory(directory.path);
    print('NATIVE_SMOKE openDirectory PASS');
    await manager.revealFile(file.path);
    print('NATIVE_SMOKE revealFile PASS');
    try {
      await DesktopFileManager.channel.invokeMethod<void>('revealFile',
          {'path': '${directory.path}${Platform.pathSeparator}missing-file'});
      throw StateError('Native missing-file validation was not enforced');
    } on PlatformException catch (error) {
      if (error.code != 'not_found') rethrow;
      print('NATIVE_SMOKE missingFile PASS');
    }
    print('NATIVE_SMOKE fixture: ${file.path}');
    // Keep the tiny fixture so the selection can be inspected in the file manager.
    exit(0);
  } catch (error, stack) {
    print('NATIVE_SMOKE FAIL: $error\n$stack');
    exit(1);
  }
}
