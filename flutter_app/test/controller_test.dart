import 'dart:io';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:landrop/landrop_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('independent pages download, range and stop', () async {
    SharedPreferences.setMockInitialValues({});
    final source = File('${Directory.systemTemp.path}/landrop-${newId()}.txt');
    await source.writeAsString('0123456789');
    final controller = LanDropController();
    try {
      await controller.initialize();
      final one = await controller.createPage('第一页');
      final two = await controller.createPage('第二页');
      await controller.addFiles(one, [
        PlatformFile(name: 'demo.txt', size: 10, path: source.path),
      ]);
      await controller.start(one);
      await controller.start(two);
      final firstPort = controller.portFor(one)!;
      final secondPort = controller.portFor(two)!;
      expect(firstPort, isNot(secondPort));
      final fileId = one.files.single.id;
      final filePath = '/file/$fileId';

      Future<(int, String)> fetch(
        int port,
        String path, {
        String? range,
      }) async {
        // Raw Socket bypasses flutter_test's global HttpClient mock (HTTP 400).
        final socket = await Socket.connect(InternetAddress.loopbackIPv4, port);
        socket.write('GET $path HTTP/1.1\r\nHost: 127.0.0.1\r\n'
            '${range == null ? '' : 'Range: $range\r\n'}Connection: close\r\n\r\n');
        final bytes = await socket
            .fold<List<int>>(<int>[], (out, chunk) => out..addAll(chunk));
        final result = utf8.decode(bytes);
        final divider = result.indexOf('\r\n\r\n');
        expect(divider, greaterThan(0));
        final status = int.parse(result.substring(9, 12));
        return (status, result.substring(divider + 4));
      }

      expect(await fetch(firstPort, filePath), (200, '0123456789'));
      expect(await fetch(firstPort, filePath, range: 'bytes=3-5'), (
        206,
        '345',
      ));
      expect((await fetch(secondPort, filePath)).$1, 404);
      expect((await fetch(firstPort, '/')).$2, contains('demo.txt'));
      await controller.stop(one);
      expect(controller.portFor(one), isNull);
      expect(controller.portFor(two), isNotNull);
      await controller.removePage(one);
      await controller.removePage(two);
    } finally {
      controller.dispose();
      if (await source.exists()) await source.delete();
    }
  });
}
