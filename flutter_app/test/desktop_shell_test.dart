import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:landrop/desktop_shell.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const channel = MethodChannel('landrop/desktop_shell');
  const shell = DesktopShell();
  const codec = StandardMethodCodec();
  late List<MethodCall> calls;

  Future<void> nativeCall(String method, [Object? arguments]) async {
    final done = Completer<void>();
    await messenger.handlePlatformMessage(
      channel.name,
      codec.encodeMethodCall(MethodCall(method, arguments)),
      (_) => done.complete(),
    );
    await done.future;
  }

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    calls = [];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
  });
  tearDown(() {
    shell.dispose();
    messenger.setMockMethodCallHandler(channel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  test('initializes and forwards explicit lifecycle/background commands',
      () async {
    await shell.initialize(onDrop: (_) {}, onShow: () {});
    await shell.showWindow();
    await shell.setBackgroundMode(false);
    await shell.setBackgroundMode(true);
    await shell.quit();
    expect(calls.map((call) => call.method), [
      'initialize',
      'showWindow',
      'setBackgroundMode',
      'setBackgroundMode',
      'quit',
    ]);
    expect(calls[2].arguments, {'enabled': false});
    expect(calls[3].arguments, {'enabled': true});
  });

  test('receives Unicode file and folder paths without opening them', () async {
    List<String>? dropped;
    var shows = 0;
    final dragging = <bool>[];
    await shell.initialize(
      onDrop: (paths) => dropped = paths,
      onShow: () => shows++,
      onDragChanged: dragging.add,
    );
    await nativeCall('dragChanged', {'dragging': true});
    await nativeCall('filesDropped', {
      'paths': [
        '/tmp/手机 照片.jpg',
        '/tmp/folder',
        r'C:\Users\测试',
        r'\\server\share\folder'
      ],
    });
    await nativeCall('showWindow');
    expect(dropped, [
      '/tmp/手机 照片.jpg',
      '/tmp/folder',
      r'C:\Users\测试',
      r'\\server\share\folder'
    ]);
    expect(dragging, [true, false]);
    expect(shows, 1);
    expect(calls.map((call) => call.method), ['initialize']);
  });

  test('rejects malformed, relative, URL, device, duplicate and NUL paths',
      () async {
    final drops = <List<String>>[];
    await shell.initialize(onDrop: drops.add, onShow: () {});
    await nativeCall('filesDropped', null);
    await nativeCall('filesDropped', {'paths': 'invalid'});
    await nativeCall('filesDropped', {
      'paths': [
        null,
        42,
        '',
        'relative',
        'https://example.com/file',
        r'\\?\C:\device',
        r'\\.\device',
        '/tmp/invalid\u0000path',
        '/tmp/ok',
        '/tmp/ok'
      ],
    });
    expect(drops, [
      ['/tmp/ok']
    ]);
  });

  test('reinitialize replaces callbacks and dispose detaches handler',
      () async {
    var oldDrops = 0;
    var newDrops = 0;
    await shell.initialize(onDrop: (_) => oldDrops++, onShow: () {});
    await shell.initialize(onDrop: (_) => newDrops++, onShow: () {});
    await nativeCall('filesDropped', {
      'paths': ['/tmp/file']
    });
    expect(oldDrops, 0);
    expect(newDrops, 1);
    shell.dispose();
    await nativeCall('filesDropped', {
      'paths': ['/tmp/file']
    });
    expect(newDrops, 1);
  });

  test('disabled and unsupported hosts need no native plugin', () async {
    const disabled = DesktopShell.disabled();
    await disabled.initialize(
        onDrop: (_) => fail('disabled drop'), onShow: () {});
    await disabled.showWindow();
    await disabled.setBackgroundMode(false);
    await disabled.quit();
    disabled.dispose();
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await shell.initialize(onDrop: (_) {}, onShow: () {});
    await shell.quit();
    expect(calls, isEmpty);
  });

  test('missing native runner is a safe no-op', () async {
    messenger.setMockMethodCallHandler(channel, null);
    await shell.initialize(onDrop: (_) {}, onShow: () {});
    await shell.showWindow();
    await shell.quit();
  });

  test('native failures remain visible to the root UI', () async {
    messenger.setMockMethodCallHandler(channel, (_) async {
      throw PlatformException(code: 'tray_unavailable');
    });
    await expectLater(
      shell.initialize(onDrop: (_) {}, onShow: () {}),
      throwsA(isA<PlatformException>()),
    );
  });
}
