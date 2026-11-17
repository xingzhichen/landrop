import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:landrop/landrop_controller.dart';
import 'package:landrop/zip_service.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'controller_test.dart' show deleteTestDirectory, upload;

class Reply {
  Reply(this.status, this.headers, this.bytes);
  final int status;
  final String headers;
  final List<int> bytes;
  dynamic get json => jsonDecode(utf8.decode(bytes));
}

Future<Reply> request(int port, String method, String path,
    {List<int> body = const [], String extra = ''}) async {
  final socket = await Socket.connect(InternetAddress.loopbackIPv4, port);
  socket.write('$method $path HTTP/1.1\r\nHost: 127.0.0.1:$port\r\n'
      'Content-Length: ${body.length}\r\n$extra'
      'Connection: close\r\n\r\n');
  socket.add(body);
  final data = await socket.fold<List<int>>(
      [], (a, b) => a..addAll(b)).timeout(const Duration(seconds: 15));
  var split = -1;
  for (var i = 0; i + 3 < data.length; i++) {
    if (data[i] == 13 &&
        data[i + 1] == 10 &&
        data[i + 2] == 13 &&
        data[i + 3] == 10) {
      split = i;
      break;
    }
  }
  expect(split, greaterThan(0));
  final header = latin1.decode(data.sublist(0, split)).toLowerCase();
  return Reply(
      int.parse(header.substring(9, 12)), header, data.sublist(split + 4));
}

Future<void> until(bool Function() condition) async {
  for (var i = 0; i < 400; i++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('State did not settle');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late LanDropController controller;
  late SharePage page;
  late int port;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    directory = await Directory.systemTemp.createTemp('landrop-controller-');
    controller = LanDropController(receiveDirectory: directory);
    await controller.initialize();
    page = await controller.createPage('Engine');
    await controller.start(page);
    port = controller.portFor(page)!;
  });
  tearDown(() async {
    for (final item in controller.pages.toList()) {
      await controller.stop(item);
    }
    controller.dispose();
    await deleteTestDirectory(directory);
  });
  Future<String> create(
      {String fingerprint = 'stable',
      int size = 6,
      String name = 'a.txt'}) async {
    final result = await request(port, 'POST',
        '/uploads?name=$name&size=$size&fingerprint=$fingerprint');
    expect(result.status, 201);
    expect(result.json['offset'], 0);
    return result.json['id'] as String;
  }

  test('directory tree skips symlinks, JSON compatibility and safe ZIP names',
      () async {
    final tree = Directory('${directory.path}/tree/sub');
    await tree.create(recursive: true);
    await File('${tree.path}/a.txt').writeAsString('nested');
    await File('${directory.path}/secret').writeAsString('secret');
    await Link('${tree.path}/escape').create('${directory.path}/secret');
    await Link('${tree.path}/cycle').create('${directory.path}/tree');
    await controller.addPaths(page, ['${directory.path}/tree']);
    expect(page.files.single.relativePath, 'tree/sub/a.txt');
    expect(SharedFile.fromJson(page.files.single.toJson())!.relativePath,
        'tree/sub/a.txt');
    final legacy = Map<String, Object>.from(page.files.single.toJson())
      ..remove('relativePath');
    expect(SharedFile.fromJson(legacy)!.relativePath, isNull);
    final original = page.files.single;
    page.files.add(SharedFile(
        id: newId(),
        name: 'a.txt',
        path: original.path,
        size: original.size,
        managed: false,
        relativePath: original.relativePath));
    final result = await request(port, 'GET', '/download.zip');
    expect(result.status, 200);
    final archive = ZipDecoder().decodeBytes(result.bytes, verify: true);
    expect(archive.files.map((f) => f.name),
        ['tree/sub/a.txt', 'tree/sub/a (1).txt']);
    expect(utf8.decode(archive.files.first.content as List<int>), 'nested');
    expect(controller.transfers.first.status, 'completed');
    expect(controller.transfers.first.transferredBytes, result.bytes.length);
    expect(controller.transfers.first.progress, 1);
    expect((await request(port, 'GET', '/download.zip?ids=${newId()}')).status,
        404);
    expect((await request(port, 'GET', '/download.zip?ids=../x')).status, 400);
    expect(
        (await request(port, 'GET', '/download.zip?ids=x&ids=y')).status, 400);
    page.files.add(SharedFile(
        id: newId(),
        name: 'bad',
        path: original.path,
        size: 6,
        managed: false,
        relativePath: '../escape.txt'));
    expect((await request(port, 'GET', '/download.zip')).status, 400);
  });

  test(
      'session repeat, offsets, chunk limits, isolation, complete and records recovery',
      () async {
    final concurrent = await Future.wait(List.generate(
        3,
        (_) => request(
            port, 'POST', '/uploads?name=a.txt&size=6&fingerprint=stable')));
    expect(concurrent.map((r) => r.status), everyElement(201));
    expect(concurrent.map((r) => r.json['id']).toSet(), hasLength(1));
    final id = concurrent.first.json['id'] as String;
    final repeated = await request(
        port, 'POST', '/uploads?name=a.txt&size=6&fingerprint=stable');
    expect(repeated.status, 201);
    expect(repeated.json['id'], id);
    expect(
        (await request(port, 'PATCH', '/uploads/$id?offset=1', body: [1]))
            .json['offset'],
        0);
    final other = await controller.createPage('Other');
    await controller.start(other);
    expect(
        (await request(controller.portFor(other)!, 'GET', '/uploads/$id'))
            .status,
        404);
    expect((await request(port, 'POST', '/uploads/$id/complete')).status, 409);
    expect(
        (await request(port, 'PATCH', '/uploads/$id?offset=0',
                body: utf8.encode('abc')))
            .json['offset'],
        3);
    expect((await request(port, 'GET', '/uploads/$id')).json['offset'], 3);
    expect(
        (await request(port, 'PATCH', '/uploads/$id?offset=3',
                body: utf8.encode('defg')))
            .status,
        413);
    expect(
        (await request(port, 'PATCH', '/uploads/$id?offset=3',
                body: utf8.encode('def')))
            .json['offset'],
        6);
    expect((await request(port, 'POST', '/uploads/$id/complete')).status, 201);
    expect(await File(controller.receivedFiles.single.path).readAsString(),
        'abcdef');
    expect(
        controller.transfers.firstWhere((t) => t.id == id).status, 'completed');
    expect((await request(port, 'GET', '/uploads/$id')).json,
        {'id': id, 'offset': 6, 'size': 6});
    final duplicate = await request(port, 'POST', '/uploads/$id/complete');
    expect(duplicate.status, 201);
    expect(duplicate.json, {'name': 'a.txt', 'size': 6});
    expect(controller.receivedFiles, hasLength(1));
    expect(
        (await request(port, 'PATCH', '/uploads/$id?offset=6', body: [1]))
            .status,
        409);
    expect(
        (await request(controller.portFor(other)!, 'GET', '/uploads/$id'))
            .status,
        404);
    expect(
        (await request(
                controller.portFor(other)!, 'POST', '/uploads/$id/complete'))
            .status,
        404);
    expect(
        (await request(controller.portFor(other)!, 'DELETE', '/uploads/$id'))
            .status,
        404);
    for (final item in controller.pages) {
      await controller.stop(item);
    }
    controller.dispose();
    controller = LanDropController(receiveDirectory: directory);
    await controller.initialize();
    expect(controller.receivedFiles.single.name, 'a.txt');
    expect(await File(controller.receivedFiles.single.path).readAsString(),
        'abcdef');
    page = controller.pages.first;
    await controller.start(page);
    port = controller.portFor(page)!;
    final restored = await request(port, 'POST', '/uploads/$id/complete');
    expect(restored.status, 201);
    expect(restored.json, duplicate.json);
    expect(controller.receivedFiles, hasLength(1));
    expect((await request(port, 'GET', '/uploads/$id')).json,
        {'id': id, 'offset': 6, 'size': 6});
    // Completion receipts do not deduplicate a deliberate new upload.
    final next = await create();
    expect(next, isNot(id));
    await controller.cancelTransfer(next);
    expect((await request(port, 'DELETE', '/uploads/$id')).status, 204);
    expect((await request(port, 'GET', '/uploads/$id')).status, 404);
    expect(await File(controller.receivedFiles.single.path).readAsString(),
        'abcdef');
    final saved = (await SharedPreferences.getInstance())
        .getString('landrop.uploadReceipts.v1')!;
    expect(jsonDecode(saved), isEmpty);
  });

  test(
      'sessions persist true disk offset across stop, restore, cancel and page removal',
      () async {
    final id = await create();
    await request(port, 'PATCH', '/uploads/$id?offset=0',
        body: utf8.encode('abc'));
    await controller.stop(page);
    final part = File('${directory.path}/LanDrop/${page.id}/.$id.part');
    expect(await part.readAsString(), 'abc');
    // A real interrupted write can advance disk after the last preference write.
    await part.writeAsString('abcd');
    controller.dispose();
    controller = LanDropController(receiveDirectory: directory);
    await controller.initialize();
    page = controller.pages.single;
    await controller.start(page);
    port = controller.portFor(page)!;
    expect((await request(port, 'GET', '/uploads/$id')).json['offset'], 4);
    expect(controller.transfers.single.status, 'paused');
    expect((await request(port, 'DELETE', '/uploads/$id')).status, 204);
    expect(await part.exists(), false);
    expect(controller.transfers.single.status, 'cancelled');
    final second = await create(fingerprint: 'next');
    await controller.removePage(page);
    expect(
        await File('${directory.path}/LanDrop/${page.id}/.$second.part')
            .exists(),
        false);
  });

  test('network disconnect and active stop preserve resumable bytes', () async {
    for (final stop in [false, true]) {
      final id = await create(fingerprint: 'disconnect-$stop', size: 100000);
      final socket = await Socket.connect(InternetAddress.loopbackIPv4, port);
      socket.listen((_) {}, onError: (Object _) {});
      socket.write(
          'PATCH /uploads/$id?offset=0 HTTP/1.1\r\nHost: 127.0.0.1:$port\r\nContent-Length: 100000\r\n\r\npartial');
      await socket.flush();
      await until(() =>
          controller.transfers.firstWhere((t) => t.id == id).transferredBytes ==
          7);
      if (stop) {
        await controller.stop(page);
      } else {
        socket.destroy();
      }
      await until(() =>
          controller.transfers.firstWhere((t) => t.id == id).status ==
          'paused');
      socket.destroy();
      if (stop) {
        await controller.start(page);
        port = controller.portFor(page)!;
      }
      expect((await request(port, 'GET', '/uploads/$id')).json['offset'], 7);
      expect(
          (await request(port, 'PATCH', '/uploads/$id?offset=7', body: [1]))
              .json['offset'],
          8);
      await controller.cancelTransfer(id);
    }
  });

  test(
      'custom receive options, raw records persist and inline MIME is whitelist only',
      () async {
    final base = p.join(directory.path, 'custom');
    await controller.setReceiveOptions(page,
        directory: base, organizeByDate: true);
    final target = await controller.receiveDirectoryFor(page);
    expect(p.dirname(target), p.join(base, page.id));
    expect(p.basename(target), matches(RegExp(r'^\d{4}-\d{2}-\d{2}$')));
    expect(controller.receiveDirectory, p.join(directory.path, 'LanDrop'));
    expect((await upload(port, 'photo.png', 'image')).$1, 201);
    expect(controller.receivedFiles.single.path, p.join(target, 'photo.png'));
    await controller.addPaths(page, [controller.receivedFiles.single.path]);
    final image =
        await request(port, 'GET', '/file/${page.files.single.id}?inline=1');
    expect(image.headers, contains('content-type: image/png'));
    expect(image.headers, contains('content-disposition: inline;'));
    expect(image.headers, contains('x-content-type-options: nosniff'));
    final html = File('${directory.path}/active.svg');
    await html.writeAsString('<svg/>');
    await controller.addPaths(page, [html.path]);
    final active =
        await request(port, 'GET', '/file/${page.files.last.id}?inline=1');
    expect(active.headers, contains('content-type: application/octet-stream'));
    expect(active.headers, contains('content-disposition: attachment;'));
    await controller.stop(page);
    controller.dispose();
    controller = LanDropController(receiveDirectory: directory);
    await controller.initialize();
    expect(controller.pages.single.receiveDirectory, base);
    expect(controller.pages.single.organizeByDate, true);
    expect(controller.receivedFiles.single.path, p.join(target, 'photo.png'));
  });

  test('all session mutations enforce origin, session count is bounded',
      () async {
    final id = await create();
    for (final (method, path) in [
      ('PATCH', '/uploads/$id?offset=0'),
      ('POST', '/uploads/$id/complete'),
      ('DELETE', '/uploads/$id'),
      ('POST', '/uploads?name=x&size=0&fingerprint=new')
    ]) {
      expect(
          (await request(port, method, path,
                  extra: 'Origin: https://evil.example\r\n'))
              .status,
          403);
    }
    expect(
        (await request(
                port, 'POST', '/uploads?name=x&size=1073741825&fingerprint=x'))
            .status,
        413);
    for (var i = 1; i < 16; i++) {
      await create(fingerprint: 'session-$i');
    }
    expect(
        (await request(
                port, 'POST', '/uploads?name=x&size=0&fingerprint=seventeenth'))
            .status,
        429);
  });

  test('active chunk excludes parallel chunk/complete and DELETE cancels it',
      () async {
    final id = await create(size: 100000);
    final socket = await Socket.connect(InternetAddress.loopbackIPv4, port);
    socket.listen((_) {}, onError: (Object _) {});
    socket.write(
        'PATCH /uploads/$id?offset=0 HTTP/1.1\r\nHost: 127.0.0.1:$port\r\nContent-Length: 100000\r\n\r\npartial');
    await socket.flush();
    await until(() => controller.transfers.first.transferredBytes == 7);
    expect((await request(port, 'POST', '/uploads/$id/complete')).status, 409);
    expect(
        (await request(port, 'PATCH', '/uploads/$id?offset=7', body: [1]))
            .status,
        409);
    expect((await request(port, 'DELETE', '/uploads/$id')).status, 204);
    expect((await request(port, 'GET', '/uploads/$id')).status, 404);
    socket.destroy();
    expect(
        await File('${directory.path}/LanDrop/${page.id}/.$id.part').exists(),
        false);
  });

  test('missing part fails safely and ZIP preparation can be cancelled',
      () async {
    final id = await create();
    final part = File('${directory.path}/LanDrop/${page.id}/.$id.part');
    expect(part.absolute.path,
        '${directory.absolute.path}/LanDrop/${page.id}/.$id.part');
    await part.delete(); // Verified, test-created .part only.
    expect(
        (await request(port, 'PATCH', '/uploads/$id?offset=0', body: [1]))
            .status,
        500);
    expect(controller.transfers.first.status, 'failed');
    await controller.cancelTransfer(id);
    final source = File('${directory.path}/zip-large.bin');
    final file = await source.open(mode: FileMode.write);
    await file.truncate(128 * 1024 * 1024);
    await file.close();
    await controller.addPaths(page, [source.path]);
    final pending = request(port, 'GET', '/download.zip');
    await until(() => controller.transfers.first.direction == 'download');
    final task = controller.transfers.first;
    await controller.cancelTransfer(task.id);
    expect((await pending).status, 400);
    expect(task.status, 'cancelled');
  });

  test('ZIP worker cancellation closes native source and output before exit',
      () async {
    final source = File(p.join(directory.path, 'worker-source.bin'));
    final output = File(p.join(directory.path, 'worker-output.zip'));
    final cancellation = File(p.join(directory.path, 'worker-cancel'));
    final handle = await source.open(mode: FileMode.write);
    await handle.truncate(512 * 1024 * 1024);
    await handle.close();
    final messages = ReceivePort();
    final observer = ReceivePort();
    final exits = ReceivePort();
    final result = messages.first;
    final opened = observer.first;
    final exited = exits.first;
    await Isolate.spawn(
        buildZipWorker,
        <Object>[
          messages.sendPort,
          output.path,
          [
            [source.path, 'source.bin']
          ],
          cancellation.path,
          observer.sendPort,
        ],
        onExit: exits.sendPort);
    try {
      expect(await opened, 'opened');
      await cancellation.create();
      final reply = await result as Map;
      expect(reply['error'], contains('cancelled'));
      await exited;
      // A separate OS process observes the actual native-handle lifetime, not
      // just Dart task status. Windows refuses FileShare.None if a handle leaks;
      // macOS permits unlinking open files, so query its native descriptor table.
      if (Platform.isMacOS) {
        final check = await Process.run(
            '/usr/sbin/lsof', ['-t', '--', source.path, output.path]);
        expect(check.exitCode, 1,
            reason: 'Leaked ZIP handles: ${check.stdout} ${check.stderr}');
      } else if (Platform.isWindows) {
        final check = await Process.run('powershell.exe', [
          '-NoProfile',
          '-NonInteractive',
          '-Command',
          r'$ErrorActionPreference="Stop"; foreach($p in @($env:LANDROP_SOURCE,$env:LANDROP_OUTPUT)) { $h=[System.IO.File]::Open($p,[System.IO.FileMode]::Open,[System.IO.FileAccess]::ReadWrite,[System.IO.FileShare]::None); $h.Dispose() }'
        ], environment: {
          'LANDROP_SOURCE': source.path,
          'LANDROP_OUTPUT': output.path
        });
        expect(check.exitCode, 0, reason: '${check.stdout} ${check.stderr}');
      }
      final renamed =
          await source.rename(p.join(directory.path, 'worker-renamed.bin'));
      expect(await renamed.exists(), true);
      // Verified fixed test-owned output: native handles must already be closed.
      expect(output.path, p.join(directory.path, 'worker-output.zip'));
      await output.delete();
      expect(await output.exists(), false);
    } finally {
      // Also release a worker after a failed assertion; do not abandon its files.
      await cancellation.create();
      await exited;
      messages.close();
      observer.close();
      exits.close();
    }
  });

  test('file validators preserve Range only for a matching If-Range', () async {
    final source = File('${directory.path}/validator.txt');
    await source.writeAsString('0123456789');
    await source.setLastModified(DateTime.utc(2025, 1, 2, 3, 4, 5));
    await controller.addPaths(page, [source.path]);
    final path = '/file/${page.files.single.id}';
    final whole = await request(port, 'GET', path);
    final etag = RegExp(r'^etag: (.+)$', multiLine: true)
        .firstMatch(whole.headers)!
        .group(1)!
        .trim();
    final modified = HttpDate.format(await source.lastModified());
    expect(whole.status, 200);
    expect(whole.headers, contains('last-modified: ${modified.toLowerCase()}'));
    final head = await request(port, 'HEAD', path);
    expect(head.status, 200);
    expect(head.bytes, isEmpty);
    expect(head.headers, contains('etag: $etag'));
    expect(head.headers, contains('last-modified: ${modified.toLowerCase()}'));
    final matched = await request(port, 'GET', path,
        extra: 'Range: bytes=3-5\r\nIf-Range: $etag\r\n');
    expect(matched.status, 206);
    expect(utf8.decode(matched.bytes), '345');
    final dated = await request(port, 'GET', path,
        extra: 'Range: bytes=3-5\r\nIf-Range: $modified\r\n');
    expect(dated.status, 206);
    for (final validator in ['"stale"', 'W/$etag', 'invalid-date']) {
      final stale = await request(port, 'GET', path,
          extra: 'Range: bytes=3-5\r\nIf-Range: $validator\r\n');
      expect(stale.status, 200);
      expect(utf8.decode(stale.bytes), '0123456789');
      expect(stale.headers, isNot(contains('content-range:')));
    }
    await source.writeAsString('abcdefghij');
    await source.setLastModified(DateTime.utc(2025, 1, 2, 3, 4, 6));
    final changed = await request(port, 'GET', path,
        extra: 'Range: bytes=3-5\r\nIf-Range: $etag\r\n');
    expect(changed.status, 200);
    expect(utf8.decode(changed.bytes), 'abcdefghij');
    expect(changed.headers, isNot(contains('etag: $etag')));
    final oldDate = await request(port, 'GET', path,
        extra: 'Range: bytes=3-5\r\nIf-Range: $modified\r\n');
    expect(oldDate.status, 200);
    final compatible =
        await request(port, 'GET', path, extra: 'Range: bytes=3-5\r\n');
    expect(compatible.status, 206);
    expect(utf8.decode(compatible.bytes), 'def');
    final zip = await request(port, 'GET', '/download.zip',
        extra: 'Range: bytes=3-5\r\nIf-Range: $etag\r\n');
    expect(zip.status, 200);
    expect(zip.headers, contains('accept-ranges: none'));
    expect(
        ZipDecoder().decodeBytes(zip.bytes, verify: true).files, hasLength(1));
  });

  test('lost complete response can be confirmed without a duplicate save',
      () async {
    final id = await create(size: 0, fingerprint: 'lost-response');
    final socket = await Socket.connect(InternetAddress.loopbackIPv4, port);
    final subscription = socket.listen((_) {});
    subscription.pause(); // Simulate a client that never observes the 201 body.
    socket.write(
        'POST /uploads/$id/complete HTTP/1.1\r\nHost: 127.0.0.1:$port\r\nContent-Length: 0\r\n\r\n');
    await socket.flush();
    await until(() => controller.receivedFiles.isNotEmpty);
    socket.destroy();
    await subscription.cancel();
    final status = await request(port, 'GET', '/uploads/$id');
    expect(status.status, 200);
    expect(status.json, {'id': id, 'offset': 0, 'size': 0});
    final retry = await request(port, 'POST', '/uploads/$id/complete');
    expect(retry.status, 201);
    expect(retry.json, {'name': 'a.txt', 'size': 0});
    expect(controller.receivedFiles, hasLength(1));
    expect(await File(controller.receivedFiles.single.path).exists(), true);
  });

  test(
      'completion receipts expire and restore enforces count bounds without paths',
      () async {
    await controller.stop(page);
    final pagesJson =
        jsonEncode(controller.pages.map((p) => p.toJson()).toList());
    final now = DateTime.now();
    final expired = newId();
    final ids = List.generate(70, (_) => newId());
    final receipts = [
      {
        'id': expired,
        'pageId': page.id,
        'name': 'expired.txt',
        'size': 0,
        'completedAt': now.subtract(const Duration(hours: 25)).toIso8601String()
      },
      for (var i = 0; i < ids.length; i++)
        {
          'id': ids[i],
          'pageId': page.id,
          'name': 'received-$i.txt',
          'size': i,
          'completedAt':
              now.subtract(Duration(seconds: 70 - i)).toIso8601String()
        },
    ];
    controller.dispose();
    SharedPreferences.setMockInitialValues({
      'landrop.pages.v1': pagesJson,
      'landrop.uploadReceipts.v1': jsonEncode(receipts)
    });
    controller = LanDropController(receiveDirectory: directory);
    await controller.initialize();
    page = controller.pages.single;
    await controller.start(page);
    port = controller.portFor(page)!;
    expect((await request(port, 'GET', '/uploads/$expired')).status, 404);
    expect((await request(port, 'GET', '/uploads/${ids.first}')).status, 404);
    final result = await request(port, 'POST', '/uploads/${ids.last}/complete');
    expect(result.status, 201);
    expect(result.json, {'name': 'received-69.txt', 'size': 69});
    final stored = jsonDecode((await SharedPreferences.getInstance())
        .getString('landrop.uploadReceipts.v1')!) as List;
    expect(stored, hasLength(64));
    expect(stored.every((dynamic item) => !(item as Map).containsKey('path')),
        true);
    await controller.removePage(page);
    expect(
        jsonDecode((await SharedPreferences.getInstance())
            .getString('landrop.uploadReceipts.v1')!),
        isEmpty);
  });

  test('single download cancellation interrupts real socket stream', () async {
    final source = File('${directory.path}/large.bin');
    final file = await source.open(mode: FileMode.write);
    await file.truncate(128 * 1024 * 1024);
    await file.close();
    await controller.addPaths(page, [source.path]);
    final socket = await Socket.connect(InternetAddress.loopbackIPv4, port);
    final subscription = socket.listen((_) {});
    subscription.pause();
    socket.write(
        'GET /file/${page.files.single.id} HTTP/1.1\r\nHost: 127.0.0.1:$port\r\n\r\n');
    await socket.flush();
    await until(() =>
        controller.transfers.isNotEmpty &&
        controller.transfers.first.transferredBytes > 0);
    final task = controller.transfers.first;
    await controller
        .cancelTransfer(task.id)
        .timeout(const Duration(seconds: 5));
    expect(task.status, 'cancelled');
    expect(task.transferredBytes, lessThan(task.totalBytes));
    socket.destroy();
    await subscription.cancel();
  });
}
