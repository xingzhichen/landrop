import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';

import 'package:cross_file/cross_file.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:landrop/landrop_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

final class LocalTestFile extends PlatformFile {
  LocalTestFile(this.file, this.name);
  final File file;
  @override
  final String name;
  @override
  Uri get uri => file.uri;
  @override
  XFile get xFile => XFile(file.path);
  @override
  int? lengthSync() => file.lengthSync();
  @override
  Future<int?> length() => file.length();
  @override
  Future<Uint8List> readAsBytes() => file.readAsBytes();
  @override
  Stream<Uint8List> readAsByteStream() =>
      file.openRead().map(Uint8List.fromList);
}

Future<void> deleteTestDirectory(Directory directory) async {
  final root = await Directory.systemTemp.resolveSymbolicLinks();
  final target = await directory.resolveSymbolicLinks();
  expect(target, startsWith('$root${Platform.pathSeparator}'));
  expect(target.split(Platform.pathSeparator).last,
      startsWith('landrop-controller-'));
  await directory.delete(recursive: true);
}

Future<(int, String)> upload(
  int port,
  String name,
  String body, {
  String? origin,
  String? fetchSite,
  String? host,
  bool chunked = false,
  int? contentLength,
}) async {
  final socket = await Socket.connect(InternetAddress.loopbackIPv4, port);
  final payload = utf8.encode(body);
  socket.write(
      'POST /upload?name=${Uri.encodeQueryComponent(name)} HTTP/1.1\r\n'
      'Host: ${host ?? '127.0.0.1:$port'}\r\n'
      '${origin == null ? '' : 'Origin: $origin\r\n'}'
      '${fetchSite == null ? '' : 'Sec-Fetch-Site: $fetchSite\r\n'}'
      '${chunked ? 'Transfer-Encoding: chunked' : 'Content-Length: ${contentLength ?? payload.length}'}\r\n'
      'Connection: close\r\n\r\n');
  if (chunked) {
    socket.write('${payload.length.toRadixString(16)}\r\n');
    socket.add(payload);
    socket.write('\r\n0\r\n\r\n');
  } else {
    socket.add(payload);
  }
  final bytes = await socket
      .fold<List<int>>(<int>[], (out, chunk) => out..addAll(chunk)).timeout(
          const Duration(seconds: 5), onTimeout: () {
    socket.destroy();
    throw TimeoutException('Upload response: origin=$origin, site=$fetchSite, '
        'host=$host, length=$contentLength');
  });
  final result = utf8.decode(bytes);
  final divider = result.indexOf('\r\n\r\n');
  expect(divider, greaterThan(0));
  expect(result.toLowerCase(), isNot(contains('access-control-allow-origin')));
  return (int.parse(result.substring(9, 12)), result.substring(divider + 4));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('independent pages download, range and stop', () async {
    SharedPreferences.setMockInitialValues({});
    final directory =
        await Directory.systemTemp.createTemp('landrop-controller-');
    final source = File('${directory.path}/source.txt');
    await source.writeAsString('0123456789');
    final controller = LanDropController(receiveDirectory: directory);
    try {
      await controller.initialize();
      final one = await controller.createPage('第一页');
      final two = await controller.createPage('第二页');
      await controller.addFiles(one, [
        LocalTestFile(source, 'demo.txt'),
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
      for (final page in controller.pages.toList()) {
        await controller.stop(page);
      }
      controller.dispose();
      await deleteTestDirectory(directory);
    }
  });

  test('raw uploads are streamed, named safely and never overwrite', () async {
    SharedPreferences.setMockInitialValues({});
    final directory =
        await Directory.systemTemp.createTemp('landrop-controller-');
    final controller = LanDropController(receiveDirectory: directory);
    try {
      await controller.initialize();
      final page = await controller.createPage('手机上传');
      await controller.start(page);
      final port = controller.portFor(page)!;
      var notifications = 0;
      controller.addListener(() => notifications++);
      final first = await upload(port, '../../照片.txt', '你好电脑',
          origin: 'http://127.0.0.1:$port', fetchSite: 'same-origin');
      expect(first.$1, 201);
      expect(jsonDecode(first.$2), {'name': '照片.txt', 'size': 12});
      final receivedRoot = '${directory.path}${Platform.pathSeparator}LanDrop';
      final pagePath = '$receivedRoot${Platform.pathSeparator}${page.id}';
      expect(controller.receiveDirectory, receivedRoot);
      final received = controller.receivedFiles.single;
      expect(received.name, '照片.txt');
      expect(received.size, 12);
      expect(received.pageTitle, '手机上传');
      expect(
          received.receivedAt
              .isAfter(DateTime.now().subtract(const Duration(minutes: 1))),
          isTrue);
      expect(received.path, '$pagePath${Platform.pathSeparator}照片.txt');
      expect(await File(received.path).readAsString(), '你好电脑');
      expect(notifications, greaterThan(0));

      final second =
          await upload(port, r'C:\private\照片.txt', 'second', chunked: true);
      expect(second.$1, 201);
      final secondName = (jsonDecode(second.$2) as Map)['name'];
      expect(secondName, '照片 (1).txt');
      expect(await File(received.path).readAsString(), '你好电脑');
      expect(await File(controller.receivedFiles.first.path).readAsString(),
          'second');
      final duplicates = await Future.wait([
        upload(port, 'same.txt', 'one'),
        upload(port, 'same.txt', 'two'),
      ]);
      expect(duplicates.map((result) => result.$1), everyElement(201));
      expect(
          duplicates
              .map((result) => (jsonDecode(result.$2) as Map)['name'])
              .toSet(),
          hasLength(2));

      final controls = await upload(port, '../a\u0000\u001f\u007f.txt', 'safe');
      expect(controls.$1, 201);
      expect((jsonDecode(controls.$2) as Map)['name'], 'a___.txt');
      final longName = await upload(port, List.filled(200, '长').join(), 'long');
      expect(longName.$1, 201);
      expect(
          utf8
              .encode((jsonDecode(longName.$2) as Map)['name'] as String)
              .length,
          lessThanOrEqualTo(180));
      for (final reserved in [
        'CON',
        'prn.txt',
        'AUX.dat',
        'NUL',
        'COM1.log',
        'COM¹.txt',
        'LPT².dat',
        'LPT9'
      ]) {
        final result = await upload(port, reserved, 'safe');
        expect(result.$1, 201);
        expect((jsonDecode(result.$2) as Map)['name'], '_$reserved');
      }
      final contents = await Directory(pagePath).list().toList();
      expect(contents, hasLength(controller.receivedFiles.length));
      expect(contents.whereType<File>().map((file) => file.path),
          everyElement(isNot(endsWith('.part'))));
    } finally {
      for (final page in controller.pages.toList()) {
        await controller.stop(page);
      }
      controller.dispose();
      await deleteTestDirectory(directory);
    }
  });

  test(
      'uploads reject cross-site, DNS rebinding, bad names and oversized bodies',
      () async {
    SharedPreferences.setMockInitialValues({});
    final directory =
        await Directory.systemTemp.createTemp('landrop-controller-');
    final controller = LanDropController(receiveDirectory: directory);
    try {
      await controller.initialize();
      final page = await controller.createPage('安全');
      await controller.start(page);
      final port = controller.portFor(page)!;
      expect(
          (await upload(port, 'a.txt', 'bad', origin: 'https://evil.example'))
              .$1,
          403);
      expect((await upload(port, 'a.txt', 'bad', origin: 'null')).$1, 403);
      expect(
          (await upload(port, 'a.txt', 'bad',
                  origin: 'http://127.0.0.1:${port + 1}'))
              .$1,
          403);
      expect((await upload(port, 'a.txt', 'bad', fetchSite: 'cross-site')).$1,
          403);
      expect(
          (await upload(port, 'a.txt', 'bad', fetchSite: 'same-site')).$1, 403);
      expect(
          (await upload(port, 'a.txt', 'bad',
                  host: 'evil.example:$port',
                  origin: 'http://evil.example:$port'))
              .$1,
          403);
      expect((await upload(port, '', '')).$1, 400);
      expect(
          (await upload(port, 'huge.bin', '',
                  contentLength: 1024 * 1024 * 1024 + 1))
              .$1,
          413);
      expect(controller.receivedFiles, isEmpty);
      expect(await directory.list().toList(), isEmpty);
    } finally {
      for (final page in controller.pages.toList()) {
        await controller.stop(page);
      }
      controller.dispose();
      await deleteTestDirectory(directory);
    }
  });

  test('unwritable receive directory returns 500 without recording a file',
      () async {
    SharedPreferences.setMockInitialValues({});
    final directory =
        await Directory.systemTemp.createTemp('landrop-controller-');
    final blocked = File('${directory.path}${Platform.pathSeparator}blocked');
    await blocked.writeAsString('do not replace');
    final controller =
        LanDropController(receiveDirectory: Directory(blocked.path));
    try {
      await controller.initialize();
      final page = await controller.createPage('磁盘错误');
      await controller.start(page);
      final result = await upload(controller.portFor(page)!, 'file.txt', '',
          contentLength: 100000);
      expect(result.$1, 500);
      expect(controller.receivedFiles, isEmpty);
      expect(await blocked.readAsString(), 'do not replace');
      expect(await directory.list().toList(), hasLength(1));
    } finally {
      for (final page in controller.pages.toList()) {
        await controller.stop(page);
      }
      controller.dispose();
      await deleteTestDirectory(directory);
    }
  });

  test('stop, delete and disconnect cancel uploads and remove partial files',
      () async {
    SharedPreferences.setMockInitialValues({});
    final directory =
        await Directory.systemTemp.createTemp('landrop-controller-');
    final controller = LanDropController(receiveDirectory: directory);
    final sockets = <Socket>[];
    try {
      await controller.initialize();
      for (final action in ['stop', 'remove', 'disconnect']) {
        final page = await controller.createPage('中止');
        await controller.start(page);
        final port = controller.portFor(page)!;
        final socket = await Socket.connect(InternetAddress.loopbackIPv4, port);
        sockets.add(socket);
        socket.listen((_) {}, onError: (Object _) {});
        socket.write('POST /upload?name=partial.bin HTTP/1.1\r\n'
            'Host: 127.0.0.1:$port\r\nContent-Length: 100000\r\n\r\npartial');
        await socket.flush();
        // Wait for observable filesystem progress, not an arbitrary long delay.
        final pageDirectory =
            Directory('${directory.path}${Platform.pathSeparator}'
                'LanDrop${Platform.pathSeparator}${page.id}');
        await (() async {
          for (var attempt = 0; attempt < 200; attempt++) {
            if (await pageDirectory.exists() &&
                (await pageDirectory.list().toList()).isNotEmpty) {
              return;
            }
            await Future<void>.delayed(const Duration(milliseconds: 5));
          }
          fail('Upload did not create a temporary file');
        })()
            .timeout(const Duration(seconds: 5));
        if (action == 'remove') {
          await controller.removePage(page).timeout(const Duration(seconds: 5));
        } else if (action == 'stop') {
          await controller.stop(page).timeout(const Duration(seconds: 5));
        } else {
          socket.destroy();
          for (var attempt = 0; attempt < 200; attempt++) {
            if ((await pageDirectory.list().toList()).isEmpty) break;
            await Future<void>.delayed(const Duration(milliseconds: 5));
          }
        }
        expect(await pageDirectory.list().toList(), isEmpty);
        expect(controller.receivedFiles, isEmpty);
      }
    } finally {
      for (final socket in sockets) {
        socket.destroy();
      }
      for (final page in controller.pages.toList()) {
        await controller.stop(page);
      }
      controller.dispose();
      await deleteTestDirectory(directory);
    }
  });
}
