import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:landrop/desktop_file_manager.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const manager = DesktopFileManager();
  late Directory directory;
  late File file;
  late List<MethodCall> calls;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('landrop-folder-test-');
    file = await File(
            '${directory.path}${Platform.pathSeparator}手机 照片 (1), test.jpg')
        .writeAsString('test');
    calls = [];
    messenger.setMockMethodCallHandler(DesktopFileManager.channel,
        (call) async {
      calls.add(call);
      return null;
    });
  });
  tearDown(() async {
    messenger.setMockMethodCallHandler(DesktopFileManager.channel, null);
    final resolved = await directory.resolveSymbolicLinks();
    final temp = await Directory.systemTemp.resolveSymbolicLinks();
    if (!resolved
        .startsWith('$temp${Platform.pathSeparator}landrop-folder-test-')) {
      throw StateError('Refusing to delete unexpected test path: $resolved');
    }
    await directory.delete(recursive: true);
  });

  test('opens an existing directory with an absolute path', () async {
    await manager.openDirectory(directory.path);
    expect(calls.single.method, 'openDirectory');
    expect(calls.single.arguments, {'path': directory.absolute.path});
  });

  test('reveals a Unicode file without parsing it as commands or URLs',
      () async {
    await manager.revealFile(file.path);
    expect(calls.single.method, 'revealFile');
    expect(calls.single.arguments, {'path': file.absolute.path});
  });

  test('missing paths and wrong file types never reach native opener',
      () async {
    for (final action in <Future<void> Function()>[
      () => manager.openDirectory('${directory.path}/missing'),
      () => manager.revealFile('${directory.path}/missing.jpg'),
      () => manager.openDirectory(file.path),
      () => manager.revealFile(directory.path),
    ]) {
      await expectLater(action(), throwsA(isA<FileManagerException>()));
    }
    expect(calls, isEmpty);
  });

  test('a native race with deletion returns a friendly missing-file error',
      () async {
    messenger.setMockMethodCallHandler(DesktopFileManager.channel, (_) async {
      throw PlatformException(code: 'not_found');
    });
    await expectLater(
        manager.revealFile(file.path),
        throwsA(isA<FileManagerException>()
            .having((error) => error.message, 'message', contains('不存在'))));
  });

  test('native access or launch failures are visible and retryable', () async {
    messenger.setMockMethodCallHandler(DesktopFileManager.channel, (_) async {
      throw PlatformException(code: 'open_failed');
    });
    await expectLater(
        manager.openDirectory(directory.path),
        throwsA(isA<FileManagerException>()
            .having((error) => error.message, 'message', contains('访问权限'))));
  });

  test('unsupported platform does not silently ignore the request', () async {
    messenger.setMockMethodCallHandler(DesktopFileManager.channel, null);
    await expectLater(
        manager.openDirectory(directory.path),
        throwsA(isA<FileManagerException>()
            .having((error) => error.message, 'message', contains('暂不支持'))));
  });
}
