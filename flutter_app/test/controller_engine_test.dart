import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:landrop/landrop_controller.dart';
import 'package:landrop/zip_service.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'controller_test.dart' show LocalTestFile, deleteTestDirectory, upload;

class CountingFiles extends ListBase<SharedFile> {
  final List<SharedFile> _files = [];
  int snapshots = 0;
  Completer<void>? scanStarted;
  @override
  int get length => _files.length;
  @override
  set length(int value) => _files.length = value;
  @override
  SharedFile operator [](int index) => _files[index];
  @override
  void operator []=(int index, SharedFile file) => _files[index] = file;
  @override
  void add(SharedFile file) => _files.add(file);
  @override
  List<SharedFile> toList({bool growable = true}) {
    snapshots++;
    if (scanStarted != null && !scanStarted!.isCompleted) {
      scanStarted!.complete();
    }
    return _files.toList(growable: growable);
  }
}

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

  test('empty named transfer accepts legacy and chunk phone uploads by page ID',
      () async {
    expect(page.files, isEmpty);
    final empty = await request(port, 'GET', '/manifest');
    expect(empty.status, 200);
    expect(empty.json, {'title': 'Engine', 'files': []});
    expect((await request(port, 'GET', '/')).status, 200);
    final other = await controller.createPage(page.title);
    await controller.start(other);
    expect((await upload(port, 'phone.txt', 'phone')).$1, 201);
    final id = await create(size: 0, name: 'empty.txt');
    expect((await request(port, 'POST', '/uploads/$id/complete')).status, 201);
    expect(controller.receivedFilesFor(page), hasLength(2));
    expect(controller.receivedFilesFor(other), isEmpty);
    expect(
        controller.receivedFiles.every((file) => file.pageId == page.id), true);
    expect((await upload(controller.portFor(other)!, 'phone.txt', 'other')).$1,
        201);
    expect(controller.receivedFilesFor(other).single.pageId, other.id);
    final owned = controller.receivedFilesFor(page).first;
    expect(ReceivedFile.fromJson(owned.toJson())!.pageId, page.id);
    final legacy = Map<String, Object>.from(owned.toJson())..remove('pageId');
    expect(ReceivedFile.fromJson(legacy)!.pageId, isNull);
    page.title = 'Renamed';
    expect(controller.receivedFilesFor(page), hasLength(2));
    await controller.removePage(page);
    final replacement = await controller.createPage('Engine');
    expect(controller.receivedFilesFor(replacement), isEmpty);
    expect(controller.receivedFilesFor(other), hasLength(1));
    for (final item in controller.pages) {
      await controller.stop(item);
    }
    controller.dispose();
    controller = LanDropController(receiveDirectory: directory);
    await controller.initialize();
    final restoredOther = controller.pages.firstWhere((p) => p.id == other.id);
    final restoredNew =
        controller.pages.firstWhere((p) => p.id == replacement.id);
    expect(controller.receivedFilesFor(restoredOther), hasLength(1));
    expect(controller.receivedFilesFor(restoredNew), isEmpty);
    expect(controller.receivedFiles.where((f) => f.pageId == page.id),
        hasLength(2));
  });

  test('legacy history migrates once, ambiguous and orphan titles never rebind',
      () async {
    await controller.stop(page);
    controller.dispose();
    final unique = SharePage(id: newId(), title: 'Unique', files: []);
    final duplicate = SharePage(id: newId(), title: 'Duplicate', files: []);
    final duplicateTwo = SharePage(id: newId(), title: 'Duplicate', files: []);
    Map<String, Object> legacy(String title) => ReceivedFile(
            name: '$title.txt',
            path: '/old/$title.txt',
            size: 0,
            pageTitle: title,
            receivedAt: DateTime.utc(2025))
        .toJson();
    SharedPreferences.setMockInitialValues({
      'landrop.pages.v1': jsonEncode(
          [unique, duplicate, duplicateTwo].map((p) => p.toJson()).toList()),
      'landrop.received.v1':
          jsonEncode([legacy('Unique'), legacy('Duplicate'), legacy('Orphan')]),
    });
    controller = LanDropController(receiveDirectory: directory);
    await controller.initialize();
    final uniquePage = controller.pages.first;
    expect(controller.receivedFilesFor(uniquePage).single.pageId, unique.id);
    expect(controller.receivedFilesFor(controller.pages[1]), isEmpty);
    expect(controller.receivedFilesFor(controller.pages[2]), isEmpty);
    final persisted = jsonDecode((await SharedPreferences.getInstance())
        .getString('landrop.received.v1')!) as List;
    expect(persisted.first['pageId'], unique.id);
    controller.dispose();
    controller = LanDropController(receiveDirectory: directory);
    await controller.initialize();
    final migratedPage = controller.pages.first;
    expect(controller.receivedFilesFor(migratedPage).single.pageId, unique.id);
    await controller.removePage(migratedPage);
    await controller.removePage(controller.pages.last);
    final newUnique = await controller.createPage('Unique');
    final newOrphan = await controller.createPage('Orphan');
    expect(controller.receivedFilesFor(newUnique), isEmpty);
    expect(controller.receivedFilesFor(newOrphan), isEmpty);
    expect(controller.receivedFilesFor(controller.pages.first), isEmpty);
    controller.dispose();
    controller = LanDropController(receiveDirectory: directory);
    await controller.initialize();
    for (final current in controller.pages) {
      expect(controller.receivedFilesFor(current), isEmpty);
    }
    expect(controller.receivedFiles, hasLength(3));
  });

  test('legacy title fallback requires a unique page and exact ID wins',
      () async {
    final legacy = ReceivedFile(
        name: 'legacy.txt',
        path: '/legacy',
        size: 0,
        pageTitle: page.title,
        receivedAt: DateTime.utc(2025));
    controller.receivedFiles.add(legacy);
    expect(controller.receivedFilesFor(page), [legacy]);
    final sameTitle = await controller.createPage(page.title);
    expect(controller.receivedFilesFor(page), isEmpty);
    expect(controller.receivedFilesFor(sameTitle), isEmpty);
    controller.receivedFiles.add(ReceivedFile(
        name: 'bound.txt',
        path: '/bound',
        size: 0,
        pageTitle: page.title,
        pageId: page.id,
        receivedAt: DateTime.utc(2025)));
    expect(controller.receivedFilesFor(page).single.name, 'bound.txt');
    expect(controller.receivedFilesFor(sameTitle), isEmpty);
  });

  test(
      'manifest caches per page, coalesces concurrent scans and invalidates edits',
      () async {
    final counted = CountingFiles();
    final cachedPage =
        SharePage(id: newId(), title: page.title, files: counted);
    controller.pages.add(cachedPage);
    final source = File(p.join(directory.path, 'cached.png'));
    await source.writeAsString('old');
    await controller.addPaths(cachedPage, [source.path]);
    await controller.start(cachedPage);
    final cachedPort = controller.portFor(cachedPage)!;
    counted.snapshots = 0;
    final first = await Future.wait(
        List.generate(20, (_) => request(cachedPort, 'GET', '/manifest')));
    expect(counted.snapshots, 1, reason: 'concurrent polls join one scan');
    expect(first.every((r) => r.status == 200), true);
    expect(first.map((r) => utf8.decode(r.bytes)).toSet(), hasLength(1));
    expect((first.first.json['files'] as List).single['size'], 3);
    await source.writeAsString('changed externally');
    final repeated = await Future.wait(
        List.generate(8, (_) => request(cachedPort, 'GET', '/manifest')));
    expect(counted.snapshots, 1, reason: 'one-second cache avoids re-statting');
    expect(repeated.every((r) => r.bytes.length == first.first.bytes.length),
        true);
    expect(repeated.first.bytes, first.first.bytes);
    expect((await request(port, 'GET', '/manifest')).json['files'], isEmpty,
        reason: 'same-title pages do not share caches');

    final picked = File(p.join(directory.path, 'picked.txt'));
    await picked.writeAsString('picker');
    await controller
        .addFiles(cachedPage, [LocalTestFile(picked, 'picked.txt')]);
    final afterPicker = await request(cachedPort, 'GET', '/manifest');
    expect(counted.snapshots, 2);
    expect(afterPicker.json['files'], hasLength(2));
    expect((afterPicker.json['files'] as List).first['size'], 18);
    final extra = File(p.join(directory.path, 'added.txt'));
    await extra.writeAsString('extra');
    await controller.addPaths(cachedPage, [extra.path]);
    expect((await request(cachedPort, 'GET', '/manifest')).json['files'],
        hasLength(3));
    expect(counted.snapshots, 3);
    await controller.removeFile(cachedPage, counted.last);
    final afterRemove = await request(cachedPort, 'GET', '/manifest');
    expect(afterRemove.json['files'], hasLength(2));
    expect(counted.snapshots, 4);
    cachedPage.title = 'New title';
    expect((await request(cachedPort, 'GET', '/manifest')).json['title'],
        'New title');
    expect(counted.snapshots, 5);

    // Cache only metadata, never authorization. An externally replaced file
    // must immediately fail actual download, even before the cache expires.
    final cachedId = counted.first.id;
    expect(source.absolute.path, p.join(directory.absolute.path, 'cached.png'));
    await source.delete();
    await Link(source.path).create(picked.path);
    expect(picked.absolute.path, p.join(directory.absolute.path, 'picked.txt'));
    await picked.delete();
    expect((await request(cachedPort, 'HEAD', '/file/$cachedId')).status, 404);
    expect((await request(cachedPort, 'GET', '/manifest')).json['files'],
        hasLength(2));
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    final expired = await Future.wait(
        List.generate(12, (_) => request(cachedPort, 'GET', '/manifest')));
    expect(expired.every((r) => (r.json['files'] as List).isEmpty), true);
    expect(counted.snapshots, 6,
        reason: 'TTL expiry also coalesces to one scan');
    expect(controller.transfers, isEmpty);
  });

  test('file removal invalidates an already in-flight manifest scan', () async {
    final files = CountingFiles();
    final isolated = SharePage(id: newId(), title: 'Inflight', files: files);
    controller.pages.add(isolated);
    final source = File(p.join(directory.path, 'inflight.png'));
    await source.writeAsString('image');
    await controller.addPaths(isolated, [source.path]);
    final removed = files.single;
    await controller.start(isolated);
    files.snapshots = 0;
    files.scanStarted = Completer<void>();
    final pending = request(controller.portFor(isolated)!, 'GET', '/manifest');
    await files.scanStarted!.future;
    await controller.removeFile(isolated, removed);
    final response = await pending;
    expect(response.status, 200);
    expect(response.json['files'], isEmpty,
        reason: 'old scan cannot publish a just-removed file');
    expect(files.snapshots, 2,
        reason: 'invalidated scan retries using the new revision');
    expect(controller.transfers, isEmpty);
  });

  test('manifest is live, isolated, no-store and shares the inline whitelist',
      () async {
    final other = await controller.createPage('Other');
    await controller.start(other);
    for (final name in [
      'PHOTO.PNG',
      'song.mp3',
      'clip.mp4',
      'active.svg',
      'active.html',
      'notes.txt'
    ]) {
      final file = File(p.join(directory.path, name));
      await file.writeAsString('content');
      await controller.addPaths(page, [file.path]);
    }
    final tree = Directory(p.join(directory.path, 'nested'));
    await tree.create();
    await File(p.join(tree.path, 'image.jpg')).writeAsString('image');
    await controller.addPaths(page, [tree.path]);
    final privateFile = File(p.join(directory.path, 'private.txt'));
    await privateFile.writeAsString('private');
    await controller.addPaths(other, [privateFile.path]);
    final valid = page.files.toList();
    final missing = SharedFile(
        id: newId(),
        name: 'missing.png',
        path: p.join(directory.path, 'missing'),
        size: 1,
        managed: false);
    final link = Link(p.join(directory.path, 'link.png'));
    await link.create(privateFile.path);
    page.files.addAll([
      missing,
      SharedFile(
          id: newId(),
          name: 'link.png',
          path: link.path,
          size: 7,
          managed: false),
      SharedFile(
          id: '../unsafe',
          name: 'bad.png',
          path: privateFile.path,
          size: 7,
          managed: false)
    ]);
    final manifest = await request(port, 'GET', '/manifest');
    expect(manifest.status, 200);
    expect(manifest.headers, contains('content-type: application/json'));
    expect(manifest.headers, contains('cache-control: no-store'));
    expect(manifest.headers, contains('x-content-type-options: nosniff'));
    final files = manifest.json['files'] as List;
    expect(files, hasLength(7));
    expect(files.map((dynamic f) => f['previewKind']),
        ['image', 'audio', 'video', null, null, null, 'image']);
    expect(files.last['relativePath'], 'nested/image.jpg');
    expect(utf8.decode(manifest.bytes), isNot(contains(directory.path)));
    expect(files.every((dynamic f) => !(f as Map).containsKey('path')), true);
    final head = await request(port, 'HEAD', '/manifest');
    expect(head.status, 200);
    expect(head.bytes, isEmpty);
    expect(head.headers, contains('content-length: ${manifest.bytes.length}'));
    expect(head.headers, contains('cache-control: no-store'));
    expect((await request(port, 'POST', '/manifest')).status, 405);
    expect((await request(port, 'GET', '/manifest/')).status, 404);
    expect(controller.transfers, isEmpty);
    final otherManifest =
        await request(controller.portFor(other)!, 'GET', '/manifest');
    expect((otherManifest.json['files'] as List).single['id'],
        other.files.single.id);
    expect(
        (await request(port, 'GET', '/file/${other.files.single.id}')).status,
        404);
    expect(
        (await request(
                controller.portFor(other)!, 'GET', '/file/${valid.first.id}'))
            .status,
        404);
    for (var i = 0; i < valid.length; i++) {
      final inline =
          await request(port, 'HEAD', '/file/${valid[i].id}?inline=1');
      expect(inline.status, 200);
      expect(
          inline.headers,
          contains(
              'content-disposition: ${files[i]['previewKind'] == null ? 'attachment' : 'inline'};'));
    }
    expect(controller.transfers, isEmpty);
    await controller.removeFile(page, valid.first);
    page.title = 'Live title';
    final changed = await request(port, 'GET', '/manifest');
    expect(changed.json['title'], 'Live title');
    expect(changed.json['files'], hasLength(6));
    expect((await request(port, 'GET', '/file/${valid.first.id}')).status, 404);
    await File(valid[1].path).writeAsString('new bytes');
    // External FS edits are reflected when the short metadata cache expires.
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    final resized = await request(port, 'GET', '/manifest');
    expect((resized.json['files'] as List).first['size'], 9);
    final added = File(p.join(directory.path, 'added.webp'));
    await added.writeAsString('new image');
    await controller.addPaths(page, [added.path]);
    final expanded = await request(port, 'GET', '/manifest');
    expect(expanded.json['files'], hasLength(7));
    expect((expanded.json['files'] as List).last, {
      'id': page.files.last.id,
      'name': 'added.webp',
      'size': 9,
      'previewKind': 'image',
    });
    expect(controller.transfers, isEmpty);
  });

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
