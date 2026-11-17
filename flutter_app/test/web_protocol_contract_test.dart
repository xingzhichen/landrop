import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:landrop/landrop_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'controller_test.dart' show deleteTestDirectory;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
      'actual emitted web JS and live server share the session/media/ZIP contract',
      () async {
    SharedPreferences.setMockInitialValues({});
    final directory = await Directory.systemTemp
        .createTemp('landrop-controller-web-contract-');
    final controller = LanDropController(receiveDirectory: directory);
    Process? node;
    try {
      final source = await Directory('${directory.path}/目录').create();
      await File('${source.path}/photo.png').writeAsBytes([137, 80, 78, 71]);
      await File('${source.path}/active.svg').writeAsString('<svg/>');
      await File('${source.path}/active.html')
          .writeAsString('<script>evil()</script>');
      await controller.initialize();
      final page = await controller.createPage('Web protocol integration');
      await controller.addPaths(page, [source.path]);
      await controller.start(page);
      node = await Process.start('node', [
        'test/web/download_page_live.cjs',
        'http://127.0.0.1:${controller.portFor(page)}',
      ]);
      final stdout = node.stdout.transform(utf8.decoder).join();
      final stderr = node.stderr.transform(utf8.decoder).join();
      final exit = await node.exitCode.timeout(const Duration(seconds: 35),
          onTimeout: () {
        node?.kill();
        throw StateError('Live web/server protocol child timed out');
      });
      final output = await stdout;
      final errors = await stderr;
      expect(exit, 0, reason: '$output\n$errors');
      expect(output, contains('live web/server contract passed'));
      expect(controller.receivedFiles.map((record) => record.name),
          unorderedEquals(['live 空格&_#%.bin', 'live-reselect.bin']));
      for (final record in controller.receivedFiles) {
        final saved = await File(record.path).readAsBytes();
        expect(saved.length, 4 * 1024 * 1024 + 37);
        expect(saved.every((byte) => byte == 97), isTrue,
            reason: 'chunk/resume must preserve exact file bytes');
      }
      final receivePath = await controller.receiveDirectoryFor(page);
      expect(
          await Directory(receivePath)
              .list()
              .where((entry) => entry.path.endsWith('.part'))
              .toList(),
          isEmpty,
          reason: 'complete and active abort+DELETE must leave no parts');
    } finally {
      node?.kill();
      for (final page in controller.pages.toList()) {
        await controller.stop(page);
      }
      controller.dispose();
      await deleteTestDirectory(directory);
    }
  }, timeout: const Timeout(Duration(seconds: 45)));
}
