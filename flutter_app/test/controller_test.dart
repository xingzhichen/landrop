import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';

import 'package:cross_file/cross_file.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:landrop/landrop_controller.dart';
import 'package:landrop/secure_receive_file.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'secure_receive_file_test_helper.dart';

final class _GatedReceiveController extends LanDropController {
  _GatedReceiveController({required Directory receiveDirectory})
      : super(receiveDirectory: receiveDirectory);

  final receiveDirectoryEntered = Completer<void>();
  final releaseReceiveDirectory = Completer<void>();

  @override
  Future<String> receiveDirectoryFor(SharePage page) async {
    if (!receiveDirectoryEntered.isCompleted) {
      receiveDirectoryEntered.complete();
    }
    await releaseReceiveDirectory.future;
    return super.receiveDirectoryFor(page);
  }
}

Future<void> _expectNoReceiveArtifacts(Directory pageDirectory) async {
  if (await FileSystemEntity.type(pageDirectory.path, followLinks: false) !=
      FileSystemEntityType.directory) {
    return;
  }
  final entries = await pageDirectory.list(followLinks: false).toList();
  final quarantineRoots = entries
      .where((entry) =>
          p.basename(entry.path) == SecureReceiveFile.quarantineDirectoryName)
      .toList();
  expect(entries, hasLength(quarantineRoots.length));
  expect(quarantineRoots.length, lessThanOrEqualTo(1));
  if (quarantineRoots.isNotEmpty) {
    expect(
        await Directory(quarantineRoots.single.path)
            .list(followLinks: false)
            .toList(),
        isEmpty);
  }
}

final class LocalTestFile extends PlatformFile {
  LocalTestFile(this.file, this.name, {this.withoutPath = false});
  final File file;
  final bool withoutPath;
  @override
  String? get path => withoutPath ? null : super.path;
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
  installSecureReceiveFileMock();

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

      final quarantineRootName =
          await upload(port, '.landrop-quarantine', 'reserved internal name');
      expect(quarantineRootName.$1, 201);
      expect((jsonDecode(quarantineRootName.$2) as Map)['name'],
          '_.landrop-quarantine');
      final internalPartName = await upload(
          port, '.123e4567-e89b-12d3-a456-426614174000.part', 'reserved part');
      expect(internalPartName.$1, 201);
      expect((jsonDecode(internalPartName.$2) as Map)['name'],
          '_.123e4567-e89b-12d3-a456-426614174000.part');

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
      final decomposedName = '${List.filled(178, 'a').join()}e\u0301';
      final graphemeLimit =
          await upload(port, decomposedName, 'grapheme boundary');
      expect(graphemeLimit.$1, 201);
      final graphemeSafeName =
          (jsonDecode(graphemeLimit.$2) as Map)['name'] as String;
      expect(graphemeSafeName, List.filled(178, 'a').join());
      expect(graphemeSafeName.endsWith('e'), isFalse,
          reason: 'UTF-8 truncation must not keep a bare base character');
      expect(utf8.encode(graphemeSafeName).length, lessThanOrEqualTo(180));
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
      final longCombiningCluster = 'CONe${List.filled(90, '\u0301').join()}';
      final truncatedReserved =
          await upload(port, longCombiningCluster, 'reserved after truncation');
      expect(truncatedReserved.$1, 201);
      final truncatedReservedName =
          (jsonDecode(truncatedReserved.$2) as Map)['name'] as String;
      expect(truncatedReservedName, startsWith('_CON'));
      expect(truncatedReservedName, isNot('CON'));
      final contents = await Directory(pagePath).list().toList();
      expect(contents, hasLength(controller.receivedFiles.length));
      expect(contents.whereType<File>().map((file) => p.basename(file.path)),
          everyElement(isNot(matches(RegExp(r'^\.[0-9a-f-]{36}\.part$')))));
    } finally {
      for (final page in controller.pages.toList()) {
        await controller.stop(page);
      }
      controller.dispose();
      await deleteTestDirectory(directory);
    }
  });

  test('failed raw-upload metadata write compensates received-file records',
      () async {
    SharedPreferences.setMockInitialValues({});
    final directory =
        await Directory.systemTemp.createTemp('landrop-controller-');
    final controller = LanDropController(receiveDirectory: directory);
    try {
      await controller.initialize();
      final page = await controller.createPage('回滚原始上传');
      await controller.start(page);
      final port = controller.portFor(page)!;
      controller.beforePersistKey = (key) async {
        if (key == 'landrop.uploadReceipts.v1') {
          throw const FileSystemException(
              'injected receipt persistence failure');
        }
      };

      final (status, _) = await upload(port, 'uncommitted.txt', 'payload');
      expect(status, HttpStatus.internalServerError);
      expect(controller.receivedFiles, isEmpty);
      final preferences = await SharedPreferences.getInstance();
      expect(jsonDecode(preferences.getString('landrop.received.v1') ?? '[]'),
          isEmpty);
    } finally {
      controller.beforePersistKey = null;
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

  test('setup failure drains an already subscribed upload without hanging',
      () async {
    SharedPreferences.setMockInitialValues({});
    final directory =
        await Directory.systemTemp.createTemp('landrop-controller-');
    final blocked = File('${directory.path}${Platform.pathSeparator}blocked');
    await blocked.writeAsString('not a directory');
    final controller =
        _GatedReceiveController(receiveDirectory: Directory(blocked.path));
    Socket? socket;
    try {
      await controller.initialize();
      final page = await controller.createPage('接收目录错误');
      final uploadFinished = Completer<void>();
      void observeUploadCompletion() {
        if (controller.transfers
            .any((task) => task.pageId == page.id && task.status != 'active')) {
          if (!uploadFinished.isCompleted) uploadFinished.complete();
        }
      }

      controller.addListener(observeUploadCompletion);
      await controller.start(page);
      final port = controller.portFor(page)!;
      socket = await Socket.connect(InternetAddress.loopbackIPv4, port);
      final reply =
          socket.fold<List<int>>(<int>[], (out, chunk) => out..addAll(chunk));
      socket.write('POST /upload?name=partial.bin HTTP/1.1\r\n'
          'Host: 127.0.0.1:$port\r\n'
          'Content-Length: 100000\r\n\r\n');
      await socket.flush();
      await controller.receiveDirectoryEntered.future
          .timeout(const Duration(seconds: 5));
      socket.write('partial');
      await socket.flush();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      controller.releaseReceiveDirectory.complete();

      final response =
          latin1.decode(await reply.timeout(const Duration(seconds: 5)));
      expect(response, contains('HTTP/1.1 500'));
      await uploadFinished.future.timeout(const Duration(seconds: 5));
      controller.removeListener(observeUploadCompletion);
      expect(controller.transfers.single.status, 'failed');
      expect(controller.receivedFiles, isEmpty);
      await controller.stop(page).timeout(const Duration(seconds: 5));
      expect(await directory.list().toList(), hasLength(1));
    } finally {
      if (!controller.releaseReceiveDirectory.isCompleted) {
        controller.releaseReceiveDirectory.complete();
      }
      socket?.destroy();
      for (final page in controller.pages.toList()) {
        await controller.stop(page);
      }
      controller.dispose();
      await deleteTestDirectory(directory);
    }
  });

  test('disconnect during receive setup handles the pending body error',
      () async {
    SharedPreferences.setMockInitialValues({});
    final directory =
        await Directory.systemTemp.createTemp('landrop-controller-');
    final controller = _GatedReceiveController(receiveDirectory: directory);
    Socket? socket;
    try {
      await controller.initialize();
      final page = await controller.createPage('接收准备时断开');
      final uploadFinished = Completer<void>();
      void observeUploadCompletion() {
        if (controller.transfers
            .any((task) => task.pageId == page.id && task.status != 'active')) {
          if (!uploadFinished.isCompleted) uploadFinished.complete();
        }
      }

      controller.addListener(observeUploadCompletion);
      await controller.start(page);
      final port = controller.portFor(page)!;
      socket = await Socket.connect(InternetAddress.loopbackIPv4, port);
      socket.write('POST /upload?name=disconnect.bin HTTP/1.1\r\n'
          'Host: 127.0.0.1:$port\r\n'
          'Content-Length: 100000\r\n\r\n');
      await socket.flush();
      await controller.receiveDirectoryEntered.future
          .timeout(const Duration(seconds: 5));
      socket.destroy();
      socket = null;
      controller.releaseReceiveDirectory.complete();

      await uploadFinished.future.timeout(const Duration(seconds: 5));
      controller.removeListener(observeUploadCompletion);
      expect(controller.transfers.single.status, 'failed');
      expect(controller.receivedFiles, isEmpty);
      await controller.stop(page).timeout(const Duration(seconds: 5));
      final pageDirectory =
          Directory('${directory.path}${Platform.pathSeparator}'
              'LanDrop${Platform.pathSeparator}${page.id}');
      if (await pageDirectory.exists()) {
        await _expectNoReceiveArtifacts(pageDirectory);
      }
    } finally {
      if (!controller.releaseReceiveDirectory.isCompleted) {
        controller.releaseReceiveDirectory.complete();
      }
      socket?.destroy();
      for (final page in controller.pages.toList()) {
        await controller.stop(page);
      }
      controller.dispose();
      await deleteTestDirectory(directory);
    }
  });

  test('raw partial cleanup preserves a post-validation replacement', () async {
    SharedPreferences.setMockInitialValues({});
    final directory =
        await Directory.systemTemp.createTemp('landrop-controller-');
    Directory? pageDirectory;
    String? replacedPath;
    final replacementReady = Completer<void>();
    final controller = LanDropController(
      receiveDirectory: directory,
      beforeSecureReceiveUnlink: () async {
        if (replacementReady.isCompleted || pageDirectory == null) return;
        final partials = (await pageDirectory.list(followLinks: false).toList())
            .whereType<File>()
            .where((file) => RegExp(r'^\.[0-9a-f-]{36}\.part$')
                .hasMatch(p.basename(file.path)))
            .toList();
        if (partials.isEmpty) return;
        replacedPath = partials.single.path;
        replaceMockReceiveLeafIdentity(replacedPath!);
        replacementReady.complete();
      },
    );
    Socket? socket;
    try {
      await controller.initialize();
      final page = await controller.createPage('隔离清理替换');
      await controller.start(page);
      final port = controller.portFor(page)!;
      pageDirectory = Directory(p.join(directory.path, 'LanDrop', page.id));
      socket = await Socket.connect(InternetAddress.loopbackIPv4, port);
      socket.listen((_) {}, onError: (Object _) {});
      socket.write('POST /upload?name=partial.bin HTTP/1.1\r\n'
          'Host: 127.0.0.1:$port\r\nContent-Length: 100000\r\n\r\npartial');
      await socket.flush();
      await (() async {
        for (var attempt = 0; attempt < 200; attempt++) {
          if (controller.transfers.any(
              (task) => task.pageId == page.id && task.transferredBytes > 0)) {
            return;
          }
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        fail('Upload body did not make progress');
      })()
          .timeout(const Duration(seconds: 5),
              onTimeout: () => throw TimeoutException('Upload body timeout'));
      socket.destroy();
      socket = null;
      await replacementReady.future.timeout(const Duration(seconds: 5));
      final quarantineRoot = Directory(p.join(
          pageDirectory.path, SecureReceiveFile.quarantineDirectoryName));
      var cleanupFinished = false;
      for (var attempt = 0; attempt < 200; attempt++) {
        final uploadActive = controller.transfers
            .any((task) => task.pageId == page.id && task.status == 'active');
        final replacementExists =
            replacedPath != null && await File(replacedPath!).exists();
        final sessionId = replacedPath == null
            ? null
            : RegExp(r'^\.([0-9a-f-]{36})\.part$')
                .firstMatch(p.basename(replacedPath!))?[1];
        final quarantineSession = sessionId == null
            ? null
            : Directory(p.join(quarantineRoot.path, sessionId));
        final quarantineReady = Platform.isWindows
            ? !(await quarantineRoot.exists())
            : quarantineSession != null &&
                await quarantineSession.exists() &&
                (await quarantineSession.list(followLinks: false).toList())
                    .isEmpty;
        if (!uploadActive && replacementExists && quarantineReady) {
          cleanupFinished = true;
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(cleanupFinished, isTrue);
      expect(replacedPath, isNotNull);
      expect(await File(replacedPath!).readAsString(), 'partial');
      if (!Platform.isWindows) {
        final sessionId = RegExp(r'^\.([0-9a-f-]{36})\.part$')
            .firstMatch(p.basename(replacedPath!))![1]!;
        final preferences = await SharedPreferences.getInstance();
        final journal =
            jsonDecode(preferences.getString('landrop.rawReceiveCleanup.v1')!)
                as List;
        expect(journal.single['id'], sessionId);
        expect(controller.managedFileCleanupWarnings,
            contains('rawQuarantine:$sessionId'));
      }
    } finally {
      socket?.destroy();
      for (final page in controller.pages.toList()) {
        await controller.stop(page);
      }
      controller.dispose();
      await deleteTestDirectory(directory);
    }
  });

  test('raw destination cleanup quarantines post-validation replacements',
      () async {
    SharedPreferences.setMockInitialValues({});
    final directory =
        await Directory.systemTemp.createTemp('landrop-controller-');
    Directory? pageDirectory;
    final replacementReady = Completer<void>();
    final unlinkHookReached = Completer<void>();
    final controller = LanDropController(
      receiveDirectory: directory,
      beforeSecureReceiveUnlink: () async {
        final currentPageDirectory = pageDirectory;
        if (replacementReady.isCompleted || currentPageDirectory == null) {
          return;
        }
        if (!unlinkHookReached.isCompleted) unlinkHookReached.complete();
        final destination =
            File(p.join(currentPageDirectory.path, 'orphan.bin'));
        if (await destination.exists()) {
          replaceMockReceiveLeafIdentity(destination.path);
          replacementReady.complete();
        }
      },
    );
    var failRecordsPersistence = true;
    try {
      await controller.initialize();
      final page = await controller.createPage('目标占位清理替换');
      await controller.start(page);
      pageDirectory = Directory(p.join(directory.path, 'LanDrop', page.id));
      controller.beforePersistKey = (key) async {
        if (failRecordsPersistence && key == 'landrop.received.v1') {
          failRecordsPersistence = false;
          throw const FileSystemException('Injected receive-record failure');
        }
      };
      final (status, _) =
          await upload(controller.portFor(page)!, 'orphan.bin', 'payload');
      expect(status, HttpStatus.internalServerError);
      await unlinkHookReached.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () => throw TimeoutException('unlink hook was not reached'),
      );
      await replacementReady.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () => throw TimeoutException('destination was not found'),
      );
      final destination = File(p.join(pageDirectory.path, 'orphan.bin'));
      final quarantineRoot = Directory(p.join(
          pageDirectory.path, SecureReceiveFile.quarantineDirectoryName));
      final preferences = await SharedPreferences.getInstance();
      final journal =
          jsonDecode(preferences.getString('landrop.rawReceiveCleanup.v1')!)
              as List;
      final sessionId = journal.single['id'] as String;
      final quarantineSession =
          Directory(p.join(quarantineRoot.path, sessionId));
      var cleanupFinished = false;
      for (var attempt = 0; attempt < 200; attempt++) {
        if (await destination.exists() &&
            await quarantineSession.exists() &&
            (await quarantineSession.list(followLinks: false).toList())
                .isEmpty &&
            controller.managedFileCleanupWarnings
                .containsKey('rawQuarantine:$sessionId')) {
          cleanupFinished = true;
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(cleanupFinished, isTrue);
      expect(await destination.readAsString(), 'payload');
      expect(controller.receivedFiles, isEmpty);
      expect(controller.managedFileCleanupWarnings,
          contains('rawQuarantine:$sessionId'));
    } finally {
      for (final page in controller.pages.toList()) {
        await controller.stop(page);
      }
      controller.dispose();
      await deleteTestDirectory(directory);
    }
  }, skip: !(Platform.isAndroid || Platform.isIOS || Platform.isMacOS));

  test('invalid raw cleanup journal is preserved fail-closed', () async {
    const malformedJournal = '{not-json';
    SharedPreferences.setMockInitialValues(
        {'landrop.rawReceiveCleanup.v1': malformedJournal});
    final directory =
        await Directory.systemTemp.createTemp('landrop-controller-');
    final controller = LanDropController(receiveDirectory: directory);
    try {
      await controller.initialize();
      final preferences = await SharedPreferences.getInstance();
      expect(preferences.getString('landrop.rawReceiveCleanup.v1'),
          malformedJournal);
      expect(controller.managedFileCleanupWarnings,
          contains('rawQuarantineJournal'));
    } finally {
      for (final page in controller.pages.toList()) {
        await controller.stop(page);
      }
      controller.dispose();
      await deleteTestDirectory(directory);
    }
  });

  test('raw cleanup intent survives a failed post-unlink journal commit',
      () async {
    SharedPreferences.setMockInitialValues({});
    final directory =
        await Directory.systemTemp.createTemp('landrop-controller-');
    LanDropController? controller;
    Socket? socket;
    final unlinkReached = Completer<void>();
    final allowUnlink = Completer<void>();
    try {
      controller = LanDropController(
        receiveDirectory: directory,
        beforeSecureReceiveUnlink: () async {
          if (!unlinkReached.isCompleted) unlinkReached.complete();
          await allowUnlink.future;
        },
      );
      await controller.initialize();
      final page = await controller.createPage('清理日志提交顺序');
      await controller.start(page);
      final port = controller.portFor(page)!;
      socket = await Socket.connect(InternetAddress.loopbackIPv4, port);
      socket.listen((_) {}, onError: (Object _) {});
      socket.write('POST /upload?name=interrupted.bin HTTP/1.1\r\n'
          'Host: 127.0.0.1:$port\r\nContent-Length: 100000\r\n\r\npartial');
      await socket.flush();
      final pageDirectory =
          Directory(p.join(directory.path, 'LanDrop', page.id));
      for (var attempt = 0; attempt < 200; attempt++) {
        if (controller.transfers.any(
            (task) => task.pageId == page.id && task.transferredBytes > 0)) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      final partials = (await pageDirectory.list(followLinks: false).toList())
          .whereType<File>()
          .map((file) => p.basename(file.path))
          .where((name) => RegExp(r'^\.[0-9a-f-]{36}\.part$').hasMatch(name))
          .toList();
      expect(partials, hasLength(1));
      final sessionId =
          RegExp(r'^\.([0-9a-f-]{36})\.part$').firstMatch(partials.single)![1]!;
      socket.destroy();
      socket = null;
      await unlinkReached.future.timeout(const Duration(seconds: 5));

      final preferences = await SharedPreferences.getInstance();
      final journalBeforeUnlink =
          jsonDecode(preferences.getString('landrop.rawReceiveCleanup.v1')!)
              as List;
      expect(journalBeforeUnlink.single['id'], sessionId);
      var journalWrites = 0;
      controller.beforePersistKey = (key) async {
        if (key == 'landrop.rawReceiveCleanup.v1') {
          journalWrites++;
          if (journalWrites == 1) {
            throw const FileSystemException('Injected journal-clear failure');
          }
        }
      };
      allowUnlink.complete();

      final quarantineRoot = Directory(p.join(
          pageDirectory.path, SecureReceiveFile.quarantineDirectoryName));
      final quarantineSession =
          Directory(p.join(quarantineRoot.path, sessionId));
      final quarantineFile =
          File(p.join(quarantineSession.path, '.$sessionId.quarantine'));
      for (var attempt = 0; attempt < 200; attempt++) {
        final uploadActive = controller.transfers
            .any((task) => task.pageId == page.id && task.status == 'active');
        if (!uploadActive &&
            await quarantineSession.exists() &&
            !await quarantineFile.exists()) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      final journal =
          jsonDecode(preferences.getString('landrop.rawReceiveCleanup.v1')!)
              as List;
      expect(journalWrites, 1);
      expect(journal, hasLength(1));
      expect(journal.single['id'], sessionId);
      expect(await quarantineSession.exists(), isTrue);
      expect(await quarantineFile.exists(), isFalse);
      expect(await File(p.join(pageDirectory.path, partials.single)).exists(),
          isFalse);
      expect(controller.managedFileCleanupWarnings,
          contains('rawQuarantine:$sessionId'));

      controller.beforePersistKey = null;
      await controller.stop(page);
      controller.dispose();
      controller = LanDropController(receiveDirectory: directory);
      await controller.initialize();

      final journalAfterRestart =
          jsonDecode(preferences.getString('landrop.rawReceiveCleanup.v1')!)
              as List;
      expect(journalAfterRestart, isEmpty);
      expect(await quarantineSession.exists(), isFalse);
    } finally {
      socket?.destroy();
      if (!allowUnlink.isCompleted) allowUnlink.complete();
      if (controller != null) {
        controller.beforePersistKey = null;
        for (final page in controller.pages.toList()) {
          await controller.stop(page);
        }
        controller.dispose();
      }
      await deleteTestDirectory(directory);
    }
  }, skip: !(Platform.isAndroid || Platform.isIOS || Platform.isMacOS));

  test('invalid raw cleanup records remain persisted fail-closed', () async {
    final directory =
        await Directory.systemTemp.createTemp('landrop-controller-');
    const sessionId = '123e4567-e89b-12d3-a456-426614174000';
    final invalidRecord = <String, Object?>{
      'id': sessionId,
      'root': p.join(directory.path, '..', 'unsafe-root'),
      'relativeParent': '',
      'leaf': 'safe.txt',
      'expectedRootIdentity': 'opaque-root-id',
      'expectedParentIdentity': null,
      'expectedLeafIdentity': 'opaque-leaf-id',
      'expectedQuarantineIdentity': 'opaque-quarantine-id',
    };
    final journal = jsonEncode([invalidRecord]);
    SharedPreferences.setMockInitialValues(
        {'landrop.rawReceiveCleanup.v1': journal});
    final controller = LanDropController(receiveDirectory: directory);
    try {
      await controller.initialize();
      final preferences = await SharedPreferences.getInstance();
      expect(preferences.getString('landrop.rawReceiveCleanup.v1'), journal);
      expect(controller.managedFileCleanupWarnings,
          contains('rawQuarantineJournal'));
    } finally {
      for (final page in controller.pages.toList()) {
        await controller.stop(page);
      }
      controller.dispose();
      await deleteTestDirectory(directory);
    }
  });

  test('raw quarantine deletion replays after an interrupted cleanup',
      () async {
    SharedPreferences.setMockInitialValues({});
    final directory =
        await Directory.systemTemp.createTemp('landrop-controller-');
    LanDropController? controller;
    Socket? socket;
    try {
      controller = LanDropController(receiveDirectory: directory);
      await controller.initialize();
      final page = await controller.createPage('隔离日志恢复');
      await controller.start(page);
      final port = controller.portFor(page)!;
      socket = await Socket.connect(InternetAddress.loopbackIPv4, port);
      socket.listen((_) {}, onError: (Object _) {});
      socket.write('POST /upload?name=interrupted.bin HTTP/1.1\r\n'
          'Host: 127.0.0.1:$port\r\nContent-Length: 100000\r\n\r\npartial');
      await socket.flush();
      final pageDirectory =
          Directory(p.join(directory.path, 'LanDrop', page.id));
      String? sourceLeaf;
      for (var attempt = 0; attempt < 200 && sourceLeaf == null; attempt++) {
        final entries = await pageDirectory.exists()
            ? await pageDirectory.list(followLinks: false).toList()
            : <FileSystemEntity>[];
        final partials = entries
            .whereType<File>()
            .map((file) => p.basename(file.path))
            .where((name) => RegExp(r'^\.[0-9a-f-]{36}\.part$').hasMatch(name))
            .toList();
        if (partials.isNotEmpty) sourceLeaf = partials.single;
        if (sourceLeaf == null) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
      }
      expect(sourceLeaf, isNotNull);
      final sessionId =
          RegExp(r'^\.([0-9a-f-]{36})\.part$').firstMatch(sourceLeaf!)![1]!;
      failNextReceiveQuarantineAfterRenameForTest(sourceLeaf);
      socket.destroy();
      socket = null;

      final quarantineRoot = Directory(p.join(
          pageDirectory.path, SecureReceiveFile.quarantineDirectoryName));
      final quarantineSession =
          Directory(p.join(quarantineRoot.path, sessionId));
      final quarantineFile =
          File(p.join(quarantineSession.path, '.$sessionId.quarantine'));
      for (var attempt = 0; attempt < 200; attempt++) {
        if (await quarantineFile.exists()) break;
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(await quarantineFile.exists(), isTrue);
      var preferences = await SharedPreferences.getInstance();
      var journal =
          jsonDecode(preferences.getString('landrop.rawReceiveCleanup.v1')!)
              as List;
      expect(journal.single['id'], sessionId);

      await controller.stop(page);
      controller.dispose();
      controller = LanDropController(receiveDirectory: directory);
      await controller.initialize();

      preferences = await SharedPreferences.getInstance();
      journal =
          jsonDecode(preferences.getString('landrop.rawReceiveCleanup.v1')!)
              as List;
      expect(journal, isEmpty);
      expect(await quarantineFile.exists(), isFalse);
      expect(await quarantineSession.exists(), isFalse);
    } finally {
      socket?.destroy();
      if (controller != null) {
        for (final page in controller.pages.toList()) {
          await controller.stop(page);
        }
        controller.dispose();
      }
      await deleteTestDirectory(directory);
    }
  }, skip: !(Platform.isAndroid || Platform.isIOS || Platform.isMacOS));

  test('stop cancels a raw upload before its first body chunk', () async {
    SharedPreferences.setMockInitialValues({});
    final directory =
        await Directory.systemTemp.createTemp('landrop-controller-');
    final controller = LanDropController(receiveDirectory: directory);
    Socket? socket;
    try {
      await controller.initialize();
      final page = await controller.createPage('取消前无数据');
      await controller.start(page);
      final port = controller.portFor(page)!;
      socket = await Socket.connect(InternetAddress.loopbackIPv4, port);
      socket.listen((_) {}, onError: (Object _) {});
      socket.write('POST /upload?name=not-started.bin HTTP/1.1\r\n'
          'Host: 127.0.0.1:$port\r\n'
          'Content-Length: 100000\r\n\r\n');
      await socket.flush();
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
        fail('Upload temp file did not appear before receiving any bytes');
      })()
          .timeout(const Duration(seconds: 5),
              onTimeout: () =>
                  throw TimeoutException('temp file creation timed out'));
      expect(controller.transfers.single.transferredBytes, 0);
      await controller.stop(page).timeout(const Duration(seconds: 5),
          onTimeout: () =>
              throw TimeoutException('early upload stop timed out'));
      await _expectNoReceiveArtifacts(pageDirectory);
      expect(controller.receivedFiles, isEmpty);
    } finally {
      socket?.destroy();
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
        // Wait until the server consumes a body chunk, not just the temp file.
        final pageDirectory =
            Directory('${directory.path}${Platform.pathSeparator}'
                'LanDrop${Platform.pathSeparator}${page.id}');
        await (() async {
          for (var attempt = 0; attempt < 200; attempt++) {
            if (controller.transfers.any((task) =>
                task.pageId == page.id && task.transferredBytes > 0)) {
              return;
            }
            await Future<void>.delayed(const Duration(milliseconds: 5));
          }
          fail('Upload body did not make progress');
        })()
            .timeout(const Duration(seconds: 5),
                onTimeout: () => throw TimeoutException(
                    'Upload body did not progress during $action'));
        if (action == 'remove') {
          await controller.removePage(page).timeout(const Duration(seconds: 5),
              onTimeout: () => throw TimeoutException('removePage timed out'));
        } else if (action == 'stop') {
          await controller.stop(page).timeout(const Duration(seconds: 5),
              onTimeout: () => throw TimeoutException('stop timed out'));
        } else {
          socket.destroy();
          for (var attempt = 0; attempt < 200; attempt++) {
            if ((await pageDirectory.list().toList()).isEmpty) break;
            await Future<void>.delayed(const Duration(milliseconds: 5));
          }
        }
        await _expectNoReceiveArtifacts(pageDirectory);
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
