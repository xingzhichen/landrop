import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:landrop/landrop_controller.dart';
import 'package:landrop/secure_receive_file.dart';
import 'package:landrop/zip_service.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'controller_test.dart' show LocalTestFile, deleteTestDirectory, upload;
import 'secure_receive_file_test_helper.dart';

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

Reply parseHttpReply(List<int> data) {
  var offset = 0;
  while (offset < data.length) {
    var split = -1;
    for (var i = offset; i + 3 < data.length; i++) {
      if (data[i] == 13 &&
          data[i + 1] == 10 &&
          data[i + 2] == 13 &&
          data[i + 3] == 10) {
        split = i;
        break;
      }
    }
    expect(split, greaterThan(offset));
    final header = latin1.decode(data.sublist(offset, split)).toLowerCase();
    final status = int.parse(header.substring(9, 12));
    final bodyStart = split + 4;
    if (status >= 100 && status < 200 && status != 101) {
      offset = bodyStart;
      continue;
    }
    return Reply(status, header, data.sublist(bodyStart));
  }
  fail('No final HTTP response');
}

Future<Reply> request(int port, String method, String path,
    {List<int> body = const [], String extra = ''}) async {
  final socket = await Socket.connect(InternetAddress.loopbackIPv4, port);
  socket.write('$method $path HTTP/1.1\r\nHost: 127.0.0.1:$port\r\n'
      'Content-Length: ${body.length}\r\n$extra'
      'Connection: close\r\n\r\n');
  socket.add(body);
  await socket.flush();
  final data = await socket.fold<List<int>>(
      [], (a, b) => a..addAll(b)).timeout(const Duration(seconds: 15));
  return parseHttpReply(data);
}

Future<Reply> keepAliveRequest(
    Socket socket, int port, String method, String path,
    {Completer<void>? onClosed}) async {
  final received = <int>[];
  final reply = Completer<Reply>();
  socket.listen(
    (chunk) {
      received.addAll(chunk);
      if (reply.isCompleted) return;
      var split = -1;
      for (var i = 0; i + 3 < received.length; i++) {
        if (received[i] == 13 &&
            received[i + 1] == 10 &&
            received[i + 2] == 13 &&
            received[i + 3] == 10) {
          split = i;
          break;
        }
      }
      if (split < 0) return;
      final header = latin1.decode(received.sublist(0, split)).toLowerCase();
      final contentLength = int.tryParse(
              RegExp(r'content-length:\s*(\d+)').firstMatch(header)?.group(1) ??
                  '') ??
          0;
      final bodyStart = split + 4;
      if (received.length < bodyStart + contentLength) return;
      reply.complete(Reply(int.parse(header.substring(9, 12)), header,
          received.sublist(bodyStart, bodyStart + contentLength)));
    },
    onError: (Object error, StackTrace stackTrace) {
      if (!reply.isCompleted) reply.completeError(error, stackTrace);
    },
    onDone: () {
      if (onClosed != null && !onClosed.isCompleted) onClosed.complete();
      if (!reply.isCompleted) {
        reply.completeError(StateError('Socket closed before HTTP reply'));
      }
    },
  );
  socket.write('$method $path HTTP/1.1\r\n'
      'Host: 127.0.0.1:$port\r\n'
      'Connection: keep-alive\r\n\r\n');
  await socket.flush();
  return reply.future.timeout(const Duration(seconds: 5));
}

Future<Reply> chunkedRequest(int port, String method, String path,
    {String body = '1\r\nx\r\n0\r\n\r\n'}) async {
  final socket = await Socket.connect(InternetAddress.loopbackIPv4, port);
  socket.write('$method $path HTTP/1.1\r\n'
      'Host: 127.0.0.1:$port\r\n'
      'Transfer-Encoding: chunked\r\n'
      'Connection: close\r\n\r\n'
      '$body');
  await socket.flush();
  final data = await socket.fold<List<int>>(
      [], (a, b) => a..addAll(b)).timeout(const Duration(seconds: 15));
  return parseHttpReply(data);
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
  installSecureReceiveFileMock();
  late Directory directory;
  late LanDropController controller;
  late SharePage page;
  late int port;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    directory = await Directory.systemTemp.createTemp('landrop-controller-');
    controller = LanDropController(receiveDirectory: directory);
    controller.fileDirectoryForTesting =
        Directory(p.join(directory.path, 'managed-files'));
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

  test('transfer progress uses a local listenable without model notifications',
      () {
    var modelNotifications = 0;
    var progressNotifications = 0;
    void onModelChanged() => modelNotifications++;
    void onProgressChanged() => progressNotifications++;
    controller.addListener(onModelChanged);
    controller.transferProgressRevision.addListener(onProgressChanged);

    controller.notifyTransferProgressForTesting();
    expect(progressNotifications, 1);
    expect(modelNotifications, 0);
    controller.notifyTransferProgressForTesting();
    expect(progressNotifications, 1);
    expect(modelNotifications, 0);

    controller.removeListener(onModelChanged);
    controller.transferProgressRevision.removeListener(onProgressChanged);
  });

  test('disposing closes active listeners and preserves auto-restore state',
      () async {
    final preferences = await SharedPreferences.getInstance();
    final savedRunningPage = preferences.getString('landrop.pages.v1');
    expect(savedRunningPage, isNotNull);

    controller.dispose();
    expect(controller.portFor(page), isNull,
        reason: 'dispose must synchronously close listener admission');
    await controller.shutdown();

    expect(controller.portFor(page), isNull);
    expect(page.running, isFalse, reason: 'the disposed model is not live');
    expect(preferences.getString('landrop.pages.v1'), savedRunningPage,
        reason: 'next controller can still restore the saved running page');
    await expectLater(
      Socket.connect(InternetAddress.loopbackIPv4, port,
          timeout: const Duration(milliseconds: 500)),
      throwsA(isA<SocketException>()),
    );
  });

  test('disposing during restored server registration prevents late binding',
      () async {
    final preferences = await SharedPreferences.getInstance();
    final savedRunningPage = preferences.getString('landrop.pages.v1')!;
    await controller.stop(page);
    await preferences.setString('landrop.pages.v1', savedRunningPage);

    final entered = Completer<void>();
    final release = Completer<void>();
    final restoring = LanDropController(
      receiveDirectory: directory,
      beforeServerRegistration: () async {
        if (!entered.isCompleted) entered.complete();
        await release.future;
      },
    );
    final initialization = restoring.initialize();
    expect(identical(initialization, restoring.initialize()), isTrue);
    await entered.future.timeout(const Duration(seconds: 2));
    final shutdown = restoring.shutdown();
    release.complete();
    await initialization;
    await shutdown;

    expect(restoring.pages, hasLength(1));
    expect(restoring.pages.single.running, isFalse);
    expect(restoring.portFor(restoring.pages.single), isNull);
    expect(preferences.getString('landrop.pages.v1'), savedRunningPage);
    await restoring.start(restoring.pages.single);
    expect(restoring.portFor(restoring.pages.single), isNull);
    restoring.dispose();
  });

  test('initialize coalesces repeated calls without duplicating restored pages',
      () async {
    final originalPort = controller.portFor(page);
    final first = controller.initialize();
    final second = controller.initialize();
    expect(identical(first, second), isTrue);
    await first;
    expect(controller.pages, hasLength(1));
    expect(controller.portFor(page), originalPort);
  });

  test('duplicate persisted page IDs stay quarantined and unbound', () async {
    final preferences = await SharedPreferences.getInstance();
    final source = File(p.join(directory.path, 'ambiguous-managed-source.txt'));
    await source.writeAsString('preserve ambiguous managed copy');
    await controller.addFiles(page, [
      LocalTestFile(source, 'ambiguous-shared.txt', withoutPath: true),
    ]);
    final managedCopy = File(page.files.single.path);
    expect(page.files.single.managed, isTrue);
    expect(await managedCopy.exists(), isTrue);

    final unrelatedPage = await controller.createPage('Unaffected');
    await controller.start(unrelatedPage);
    await controller.stop(page);
    await controller.stop(unrelatedPage);
    final saved =
        jsonDecode(preferences.getString('landrop.pages.v1')!) as List;
    final record = Map<String, Object?>.from(
        saved.singleWhere((item) => (item as Map)['id'] == page.id) as Map);
    final unrelatedRecord = Map<String, Object?>.from(saved
        .singleWhere((item) => (item as Map)['id'] == unrelatedPage.id) as Map)
      ..['running'] = true;
    final first = <String, Object?>{
      ...record,
      'title': 'First conflicting record',
      'running': true,
    };
    final second = <String, Object?>{
      ...record,
      'title': 'Second conflicting record',
      'running': true
    };
    final malformedDuplicate = <String, Object?>{
      ...record,
      'title': 42,
      'running': true
    };
    await preferences.setString('landrop.pages.v1',
        jsonEncode([first, second, malformedDuplicate, unrelatedRecord]));
    await preferences.setString(
        'landrop.received.v1',
        jsonEncode([
          ReceivedFile(
            name: 'ambiguous-received.txt',
            path: p.join(directory.path, 'ambiguous-received.txt'),
            size: 1,
            pageTitle: 'First conflicting record',
            receivedAt: DateTime.now(),
            pageId: page.id,
          ).toJson(),
        ]));
    await preferences.setString(
        'landrop.uploadReceipts.v1',
        jsonEncode([
          {
            'id': newId(),
            'pageId': page.id,
            'name': 'ambiguous-receipt.txt',
            'size': 1,
            'completedAt': DateTime.now().toIso8601String(),
          }
        ]));
    controller.dispose();

    final restoring = LanDropController(receiveDirectory: directory);
    restoring.mobileForTesting = true;
    restoring.fileDirectoryForTesting =
        Directory(p.join(directory.path, 'managed-files'));
    await restoring.initialize();

    expect(restoring.pages, hasLength(2));
    final conflicted =
        restoring.pages.singleWhere(restoring.hasConflictingPageId);
    final unaffected = restoring.pages
        .singleWhere((candidate) => !restoring.hasConflictingPageId(candidate));
    expect(unaffected.id, unrelatedPage.id);
    expect(unaffected.title, 'Unaffected');
    expect(unaffected.running, isTrue);
    expect(restoring.portFor(unaffected), isNotNull);
    expect(restoring.hasConflictingPageId(conflicted), isTrue);
    expect(conflicted.running, isFalse);
    expect(conflicted.files, isEmpty);
    expect(restoring.portFor(conflicted), isNull);
    expect(restoring.pageErrors[conflicted.id], contains('重复的传输 ID'));
    expect(restoring.managedFileCleanupWarnings, isNotEmpty);
    expect(await managedCopy.exists(), isTrue,
        reason: 'duplicate metadata quarantines orphan cleanup');
    expect(restoring.receivedFiles, hasLength(1));
    expect(restoring.receivedFilesFor(conflicted), isEmpty);
    expect(restoring.receiptCountForPageForTesting(conflicted.id), 1);
    await expectLater(
        restoring.receiveDirectoryFor(conflicted), throwsStateError);
    expect(await Directory(p.join(directory.path, conflicted.id)).exists(),
        isFalse);
    await expectLater(restoring.start(conflicted), throwsStateError);
    expect(restoring.portFor(conflicted), isNull);
    await restoring.stop(unaffected);

    final preserved =
        jsonDecode(preferences.getString('landrop.pages.v1')!) as List;
    expect(preserved, hasLength(4));
    final preservedTitles = preserved.map((item) => (item as Map)['title']);
    expect(
        preservedTitles,
        containsAll([
          'Unaffected',
          'First conflicting record',
          'Second conflicting record',
          42,
        ]));

    restoring.beforePersistKey = (key) async {
      if (key == 'landrop.pages.v1') {
        throw const FileSystemException(
            'injected page-list persistence failure');
      }
    };
    await expectLater(
        restoring.removePage(conflicted), throwsA(isA<FileSystemException>()));
    expect(restoring.hasConflictingPageId(conflicted), isTrue);
    expect(restoring.pages, contains(conflicted));
    await expectLater(restoring.start(conflicted), throwsStateError);
    expect(
        jsonDecode(preferences.getString('landrop.pages.v1')!), hasLength(4));
    restoring.beforePersistKey = null;

    await restoring.removePage(conflicted);
    final afterConflictRemoval =
        jsonDecode(preferences.getString('landrop.pages.v1')!) as List;
    expect(afterConflictRemoval, hasLength(1));
    expect((afterConflictRemoval.single as Map)['title'], 'Unaffected');
    expect(await managedCopy.exists(), isTrue,
        reason: 'removing a conflict cannot delete ambiguously owned copies');
    expect(restoring.receiptCountForPageForTesting(conflicted.id), 0);
    expect(jsonDecode(preferences.getString('landrop.uploadReceipts.v1')!),
        isEmpty);
    expect(restoring.managedFileCleanupWarnings, isNotEmpty,
        reason: 'ambiguous file ownership must remain quarantined');
    restoring.dispose();
  });

  test('quarantined records keep shared managed files referenced', () async {
    final source =
        File(p.join(directory.path, 'quarantined-shared-source.txt'));
    await source.writeAsString('quarantined shared content');
    await controller.addFiles(page, [
      LocalTestFile(source, 'quarantined-shared.txt', withoutPath: true),
    ]);
    final managedCopy = File(page.files.single.path);
    await controller.stop(page);

    final preferences = await SharedPreferences.getInstance();
    final saved =
        jsonDecode(preferences.getString('landrop.pages.v1')!) as List;
    final healthy = Map<String, Object?>.from(saved.single as Map);
    final conflictId = newId();
    final firstConflict = <String, Object?>{
      ...healthy,
      'id': conflictId,
      'title': 'First preserved conflict',
    };
    final secondConflict = <String, Object?>{
      ...healthy,
      'id': conflictId,
      'title': 'Second preserved conflict',
    };
    await preferences.setString('landrop.pages.v1',
        jsonEncode([healthy, firstConflict, secondConflict]));
    controller.dispose();

    final restoring = LanDropController(receiveDirectory: directory);
    restoring.mobileForTesting = true;
    restoring.fileDirectoryForTesting =
        Directory(p.join(directory.path, 'managed-files'));
    await restoring.initialize();
    final restoredHealthy =
        restoring.pages.singleWhere((candidate) => candidate.id == page.id);
    final conflict =
        restoring.pages.singleWhere(restoring.hasConflictingPageId);
    final restoredFile = restoredHealthy.files.single;

    await restoring.removeFile(restoredHealthy, restoredFile);
    expect(restoredHealthy.files, isEmpty);
    expect(await managedCopy.exists(), isTrue,
        reason: 'the quarantined raw record still owns this managed ID');

    await restoring.removePage(conflict);
    expect(await managedCopy.exists(), isTrue,
        reason: 'removing ambiguous metadata preserves the copied file');
    await restoring.shutdown();
    restoring.dispose();
  });

  test('quarantined legacy symlink aliases block managed-file unlink',
      () async {
    final source = File(p.join(directory.path, 'legacy-alias-source.txt'));
    await source.writeAsString('managed alias target');
    await controller.addFiles(page, [
      LocalTestFile(source, 'legacy-alias-target.txt', withoutPath: true),
    ]);
    final managedCopy = File(page.files.single.path);
    await controller.stop(page);

    final alias = Link(p.join(directory.path, 'legacy-managed-alias'));
    await alias.create(managedCopy.path);
    final preferences = await SharedPreferences.getInstance();
    final saved =
        jsonDecode(preferences.getString('landrop.pages.v1')!) as List;
    final healthy = Map<String, Object?>.from(saved.single as Map);
    final conflictId = newId();
    final legacyAlias = <String, Object?>{
      'id': newId(),
      'name': 'legacy alias',
      'path': alias.path,
      'size': 1,
      'managed': false,
    };
    final firstConflict = <String, Object?>{
      ...healthy,
      'id': conflictId,
      'title': 'First symlink conflict',
      'files': [legacyAlias],
    };
    final secondConflict = <String, Object?>{
      ...healthy,
      'id': conflictId,
      'title': 'Second symlink conflict',
      'files': [legacyAlias],
    };
    await preferences.setString('landrop.pages.v1',
        jsonEncode([healthy, firstConflict, secondConflict]));
    controller.dispose();

    final restoring = LanDropController(receiveDirectory: directory);
    restoring.mobileForTesting = true;
    restoring.fileDirectoryForTesting =
        Directory(p.join(directory.path, 'managed-files'));
    await restoring.initialize();
    final restoredHealthy =
        restoring.pages.singleWhere((candidate) => candidate.id == page.id);

    await restoring.removeFile(restoredHealthy, restoredHealthy.files.single);
    expect(await managedCopy.exists(), isTrue,
        reason:
            'the quarantined symlink can still resolve to the managed file');
    expect(await alias.exists(), isTrue);
    await restoring.shutdown();
    restoring.dispose();
  },
      skip: Platform.isWindows
          ? 'Windows symlink creation may require elevation'
          : false);

  test('quarantined legacy case aliases use physical file identity', () async {
    final source = File(p.join(directory.path, 'case-alias-source.txt'));
    await source.writeAsString('case alias target');
    await controller.addFiles(page, [
      LocalTestFile(source, 'case-alias-target.txt', withoutPath: true),
    ]);
    final managedCopy = File(page.files.single.path);
    await controller.stop(page);
    final saved = (jsonDecode((await SharedPreferences.getInstance())
        .getString('landrop.pages.v1')!) as List);
    final healthy = Map<String, Object?>.from(saved.single as Map);
    var caseAliasPath = managedCopy.path
        .replaceAllMapped(RegExp('[a-f]'), (match) => match[0]!.toUpperCase());
    if (caseAliasPath == managedCopy.path) {
      caseAliasPath = managedCopy.path.toUpperCase();
    }
    var sameEntity = false;
    if (await FileSystemEntity.type(caseAliasPath, followLinks: false) !=
        FileSystemEntityType.notFound) {
      try {
        sameEntity =
            await FileSystemEntity.identical(caseAliasPath, managedCopy.path);
      } on FileSystemException {
        sameEntity = true;
      }
    }
    final conflictId = newId();
    final legacyAlias = <String, Object?>{
      'id': newId(),
      'name': 'legacy case alias',
      'path': caseAliasPath,
      'size': 1,
      'managed': false,
    };
    final firstConflict = <String, Object?>{
      ...healthy,
      'id': conflictId,
      'title': 'First case conflict',
      'files': [legacyAlias],
    };
    final secondConflict = <String, Object?>{
      ...healthy,
      'id': conflictId,
      'title': 'Second case conflict',
      'files': [legacyAlias],
    };
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString('landrop.pages.v1',
        jsonEncode([healthy, firstConflict, secondConflict]));
    controller.dispose();

    final restoring = LanDropController(receiveDirectory: directory);
    restoring.mobileForTesting = true;
    restoring.fileDirectoryForTesting =
        Directory(p.join(directory.path, 'managed-files'));
    await restoring.initialize();
    final restoredHealthy =
        restoring.pages.singleWhere((candidate) => candidate.id == page.id);
    await restoring.removeFile(restoredHealthy, restoredHealthy.files.single);
    expect(await managedCopy.exists(), sameEntity,
        reason: 'case-insensitive aliases must retain the same physical file');
    await restoring.shutdown();
    restoring.dispose();
  });

  test('ordinary case-only path aliases use physical file identity', () async {
    final source = File(p.join(directory.path, 'ordinary-case-source.txt'));
    await source.writeAsString('ordinary case alias target');
    await controller.addFiles(page, [
      LocalTestFile(source, 'ordinary-case-target.txt', withoutPath: true),
    ]);
    final managedCopy = File(page.files.single.path);
    await controller.stop(page);
    final originalPageId = page.id;
    var caseAliasPath = managedCopy.path
        .replaceAllMapped(RegExp('[a-f]'), (match) => match[0]!.toUpperCase());
    if (caseAliasPath == managedCopy.path) {
      caseAliasPath = managedCopy.path.toUpperCase();
    }
    var sameEntity = false;
    if (await FileSystemEntity.type(caseAliasPath, followLinks: false) !=
        FileSystemEntityType.notFound) {
      try {
        sameEntity =
            await FileSystemEntity.identical(caseAliasPath, managedCopy.path);
      } on FileSystemException {
        sameEntity = true;
      }
    }

    final other = await controller.createPage('Ordinary case alias owner');
    final otherPageId = other.id;
    other.files.add(SharedFile(
      id: newId(),
      name: 'ordinary case alias',
      path: caseAliasPath,
      canonicalPath: caseAliasPath,
      size: 1,
      managed: false,
    ));
    await controller.start(other);
    await controller.shutdown();
    controller.dispose();

    controller = LanDropController(receiveDirectory: directory);
    controller.fileDirectoryForTesting =
        Directory(p.join(directory.path, 'managed-files'));
    await controller.initialize();
    page = controller.pages
        .singleWhere((candidate) => candidate.id == originalPageId);
    final restoredOther = controller.pages
        .singleWhere((candidate) => candidate.id == otherPageId);
    expect(restoredOther.files.single.canonicalPath, caseAliasPath);

    await controller.removeFile(page, page.files.single);
    expect(await managedCopy.exists(), sameEntity);
  });

  test('legacy page symlink aliases preserve managed files on removal',
      () async {
    final source = File(p.join(directory.path, 'legacy-page-alias-source.txt'));
    await source.writeAsString('legacy page managed alias');
    await controller.addFiles(page, [
      LocalTestFile(source, 'legacy-page-target.txt', withoutPath: true),
    ]);
    final managedCopy = File(page.files.single.path);
    await controller.stop(page);
    final originalPageId = page.id;

    final alias = Link(p.join(directory.path, 'legacy-page-alias'));
    await alias.create(managedCopy.path);
    final other = await controller.createPage('Legacy alias owner');
    final otherPageId = other.id;
    other.files.add(SharedFile(
      id: newId(),
      name: 'legacy alias file',
      path: alias.path,
      size: 1,
      managed: false,
    ));
    await controller.start(other);
    await controller.shutdown();
    controller.dispose();

    controller = LanDropController(receiveDirectory: directory);
    controller.fileDirectoryForTesting =
        Directory(p.join(directory.path, 'managed-files'));
    await controller.initialize();
    page = controller.pages
        .singleWhere((candidate) => candidate.id == originalPageId);
    final restoredOther = controller.pages
        .singleWhere((candidate) => candidate.id == otherPageId);
    expect(restoredOther.files.single.canonicalPath, isEmpty);

    await controller.removeFile(page, page.files.single);
    expect(await managedCopy.exists(), isTrue,
        reason: 'the restored symlink still resolves to this managed file');
  },
      skip: Platform.isWindows
          ? 'Windows symlink creation may require elevation'
          : false);

  test('duplicate IDs do not suppress retry of pinned upload deletions',
      () async {
    final id = await create();
    await request(port, 'PATCH', '/uploads/$id?offset=0',
        body: utf8.encode('abc'));
    final root = Directory('${directory.path}/LanDrop/${page.id}');
    final detachedRoot = Directory('${directory.path}/detached-${page.id}');
    await root.rename(detachedRoot.path);
    await expectLater(
        controller.cancelTransfer(id), throwsA(isA<FileSystemException>()));
    final part = File('${detachedRoot.path}/.$id.part');
    expect(await part.exists(), isTrue);
    await controller.stop(page);

    final preferences = await SharedPreferences.getInstance();
    final savedPages =
        jsonDecode(preferences.getString('landrop.pages.v1')!) as List;
    final original = Map<String, Object?>.from(savedPages.single as Map);
    final duplicate = <String, Object?>{
      ...original,
      'title': 'Duplicate page record',
      'running': true,
    };
    await preferences.setString(
        'landrop.pages.v1', jsonEncode([original, duplicate]));
    controller.dispose();

    controller = LanDropController(receiveDirectory: directory);
    controller.fileDirectoryForTesting =
        Directory(p.join(directory.path, 'managed-files'));
    await controller.initialize();
    final conflicted = controller.pages.single;
    expect(controller.hasConflictingPageId(conflicted), isTrue);
    expect(await part.exists(), isTrue,
        reason: 'missing pinned root keeps the deletion retryable');
    final deferred =
        (jsonDecode(preferences.getString('landrop.sessions.v1')!) as List)
            .cast<Map>();
    expect(deferred, hasLength(1));
    expect(deferred.single['deleting'], isTrue);

    await controller.shutdown();
    controller.dispose();
    await detachedRoot.rename(root.path);
    controller = LanDropController(receiveDirectory: directory);
    controller.fileDirectoryForTesting =
        Directory(p.join(directory.path, 'managed-files'));
    await controller.initialize();

    expect(controller.pages.single.running, isFalse);
    expect(await File('${root.path}/.$id.part').exists(), isFalse);
    expect(jsonDecode(preferences.getString('landrop.sessions.v1')!), isEmpty);
  });

  test('late notifications are ignored after controller disposal', () {
    final disposed = LanDropController(receiveDirectory: directory);
    disposed.dispose();
    expect(disposed.notifyModelForTesting, returnsNormally);
    expect(disposed.notifyTransferProgressForTesting, returnsNormally);
    disposed.dispose();
  });

  test('unknown-size raw uploads stay indeterminate until completion',
      () async {
    final socket = await Socket.connect(InternetAddress.loopbackIPv4, port);
    final reply =
        socket.fold<List<int>>(<int>[], (out, chunk) => out..addAll(chunk));
    socket.write('POST /upload?name=streamed.txt HTTP/1.1\r\n'
        'Host: 127.0.0.1:$port\r\n'
        'Transfer-Encoding: chunked\r\n'
        'Connection: close\r\n\r\n'
        '3\r\nabc\r\n');
    await socket.flush();
    try {
      await until(() => controller.transfers.any((task) =>
          task.name == 'streamed.txt' &&
          task.status == 'active' &&
          task.transferredBytes >= 3));
      final task = controller.transfers
          .firstWhere((task) => task.name == 'streamed.txt');
      expect(task.totalBytes, 0);
      expect(task.transferredBytes, 3);
      expect(task.progress, 0);
      expect(task.remainingSeconds, isNull);

      socket.write('3\r\ndef\r\n0\r\n\r\n');
      await socket.flush();
      final response =
          latin1.decode(await reply.timeout(const Duration(seconds: 5)));
      expect(response, contains('201 Created'));
      expect(task.status, 'completed');
      expect(task.totalBytes, 6);
      expect(task.progress, 1);
    } finally {
      socket.destroy();
    }
  });

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
    expect(controller.receivedFiles.where((f) => f.pageId == page.id), isEmpty);
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
    expect(controller.receivedFiles, hasLength(2),
        reason:
            'legacy ambiguous/orphan entries remain; page-owned history is removed');
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
    final quarantine = Directory(p.join(
        directory.path, 'tree', SecureReceiveFile.quarantineDirectoryName));
    await quarantine.create();
    await File(p.join(quarantine.path, 'private.part'))
        .writeAsString('private');
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
    expect(result.headers,
        contains('content-disposition: attachment; filename="download.zip"'));
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
    // Cancellation must not delete a receipt or claim its saved destination was cleaned.
    expect(
        (await request(port, 'DELETE', '/uploads/$id?cancel=1')).status, 409);
    expect((await request(port, 'GET', '/uploads/$id')).status, 200);
    expect(await File(controller.receivedFiles.single.path).readAsString(),
        'abcdef');
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

  test('saved running transfer auto-binds and resumes its persisted session',
      () async {
    final id = await create();
    await request(port, 'PATCH', '/uploads/$id?offset=0',
        body: utf8.encode('abc'));
    final savedPage = Map<String, Object>.from(page.toJson());
    expect(savedPage['running'], isTrue);
    await controller.stop(page);
    final preferences = await SharedPreferences.getInstance();
    expect(
        await preferences.setString(
            'landrop.pages.v1', jsonEncode([savedPage])),
        isTrue);
    controller.dispose();

    controller = LanDropController(receiveDirectory: directory);
    await controller.initialize();
    page = controller.pages.single;
    expect(page.running, isTrue);
    expect(controller.portFor(page), isNotNull);
    port = controller.portFor(page)!;
    expect((await request(port, 'GET', '/manifest')).status, 200);
    expect((await request(port, 'GET', '/uploads/$id')).json,
        {'id': id, 'offset': 3, 'size': 6});

    final resumed = await request(port, 'PATCH', '/uploads/$id?offset=3',
        body: utf8.encode('def'));
    expect(resumed.status, 200);
    expect(resumed.json, {'id': id, 'offset': 6, 'size': 6});
    final part = File('${directory.path}/LanDrop/${page.id}/.$id.part');
    expect(await part.readAsString(), 'abcdef');
  });

  test('restart rebinds the listener and preserves resumable offset', () async {
    final id = await create();
    await request(port, 'PATCH', '/uploads/$id?offset=0',
        body: utf8.encode('abc'));
    final previousPort = port;
    final previousSocket =
        await Socket.connect(InternetAddress.loopbackIPv4, previousPort);
    final previousSocketClosed = Completer<void>();
    try {
      expect(
          (await keepAliveRequest(
                  previousSocket, previousPort, 'GET', '/manifest',
                  onClosed: previousSocketClosed))
              .status,
          200);
      expect(previousSocketClosed.isCompleted, isFalse);
      await controller.restart(page).timeout(const Duration(seconds: 5));
      await previousSocketClosed.future.timeout(const Duration(seconds: 5));
      expect(page.running, isTrue);
      expect(controller.portFor(page), isNotNull);
      port = controller.portFor(page)!;
      expect((await request(port, 'GET', '/manifest')).status, 200);
      if (port != previousPort) {
        final staleConnection =
            Socket.connect(InternetAddress.loopbackIPv4, previousPort);
        try {
          final staleListener =
              await staleConnection.timeout(const Duration(seconds: 2));
          staleListener.destroy();
          fail('The old listener still accepts connections.');
        } on SocketException {
          // A different new port means the old listener should be released.
        } on TimeoutException {
          // Some Windows runners silently drop SYNs to unbound local ports.
          // Treat no connection within the probe window as released, but close
          // the socket if the OS eventually completes the pending connect.
          unawaited(staleConnection.then<void>(
            (socket) => socket.destroy(),
            onError: (Object _) {},
          ));
        }
      }
      expect((await request(port, 'GET', '/uploads/$id')).json,
          {'id': id, 'offset': 3, 'size': 6});
      final resumed = await request(port, 'PATCH', '/uploads/$id?offset=3',
          body: utf8.encode('def'));
      expect(resumed.status, 200);
      expect(resumed.json, {'id': id, 'offset': 6, 'size': 6});
    } finally {
      previousSocket.destroy();
    }
  });

  test('inaccessible restored session does not abort or erase startup state',
      () async {
    final blockedId = await create(fingerprint: 'restore-blocked');
    final usableId = await create(fingerprint: 'restore-usable');
    final blockedPatch = await request(
        port, 'PATCH', '/uploads/$blockedId?offset=0',
        body: utf8.encode('abc'));
    expect(blockedPatch.status, 200);
    expect(blockedPatch.json['offset'], 3);
    final usablePatch = await request(
        port, 'PATCH', '/uploads/$usableId?offset=0',
        body: utf8.encode('abc'));
    expect(usablePatch.status, 200);
    expect(usablePatch.json['offset'], 3);
    final externalRoot = Directory('${directory.path}/external-volume');
    final offlineRoot = Directory('${directory.path}/external-volume-offline');
    await controller.setReceiveOptions(page, directory: externalRoot.path);
    final missingRootId = await create(fingerprint: 'restore-missing-root');
    final missingRootPatch = await request(
        port, 'PATCH', '/uploads/$missingRootId?offset=0',
        body: utf8.encode('abc'));
    expect(missingRootPatch.status, 200);
    expect(missingRootPatch.json['offset'], 3);
    final missingPart =
        File('${externalRoot.path}/${page.id}/.$missingRootId.part');
    expect(await missingPart.readAsString(), 'abc');
    final savedPage = Map<String, Object>.from(page.toJson());
    expect(savedPage['running'], isTrue);
    await controller.stop(page);
    final preferences = await SharedPreferences.getInstance();
    expect(
        await preferences.setString(
            'landrop.pages.v1', jsonEncode([savedPage])),
        isTrue);
    await externalRoot.rename(offlineRoot.path);
    expect(
        await File('${offlineRoot.path}/${page.id}/.$missingRootId.part')
            .readAsString(),
        'abc');
    controller.dispose();

    controller = LanDropController(
        receiveDirectory: directory,
        pendingSessionLimit: 3,
        beforeRestoredSessionFileCheck: (path) async {
          if (path.endsWith('.$blockedId.part')) {
            throw FileSystemException('injected access failure', path);
          }
        });
    await controller.initialize();
    page = controller.pages.single;
    expect(page.running, isTrue);
    expect(controller.pageRecoveryWarnings[page.id], contains('续传记录已保留'));
    expect(controller.portFor(page), isNotNull);
    port = controller.portFor(page)!;
    expect((await request(port, 'GET', '/manifest')).status, 200);
    expect((await request(port, 'GET', '/uploads/$blockedId')).status, 404);
    expect((await request(port, 'GET', '/uploads/$missingRootId')).status, 404);
    expect((await request(port, 'GET', '/uploads/$usableId')).json,
        {'id': usableId, 'offset': 3, 'size': 6});
    expect(
        (await request(port, 'POST',
                '/uploads?name=other.txt&size=6&fingerprint=another'))
            .status,
        429);
    expect(
        (await request(port, 'POST',
                '/uploads?name=a.txt&size=6&fingerprint=restore-blocked'))
            .status,
        409);
    final savedSessions =
        jsonDecode(preferences.getString('landrop.sessions.v1')!) as List;
    expect(savedSessions.map((session) => session['id']),
        containsAll([blockedId, missingRootId, usableId]));

    await expectLater(
        controller.removePage(page), throwsA(isA<FileSystemException>()));
    expect(controller.pages.single.id, page.id);
    expect(controller.pageRecoveryWarnings[page.id], contains('续传记录已保留'));
    final stillSavedSessions =
        jsonDecode(preferences.getString('landrop.sessions.v1')!) as List;
    expect(stillSavedSessions.map((session) => session['id']),
        contains(missingRootId));

    await offlineRoot.rename(externalRoot.path);
    await controller.removePage(page);
    expect(controller.pageRecoveryWarnings.containsKey(page.id), isFalse);
    expect(jsonDecode(preferences.getString('landrop.sessions.v1')!), isEmpty);
    expect(
        await File('${directory.path}/LanDrop/${page.id}/.$blockedId.part')
            .exists(),
        isFalse);
    expect(
        await File('${externalRoot.path}/${page.id}/.$missingRootId.part')
            .exists(),
        isFalse);
  });

  test('page removal preserves deferred upload until offline root returns',
      () async {
    final externalRoot = Directory('${directory.path}/deferred-volume');
    final offlineRoot = Directory('${directory.path}/deferred-volume-offline');
    await controller.setReceiveOptions(page, directory: externalRoot.path);
    final id = await create(fingerprint: 'deferred-offline');
    final patch = await request(port, 'PATCH', '/uploads/$id?offset=0',
        body: utf8.encode('abc'));
    expect(patch.status, 200);
    expect(patch.json['offset'], 3);
    final savedPage = Map<String, Object>.from(page.toJson());
    expect(savedPage['running'], isTrue);
    await controller.stop(page);
    final preferences = await SharedPreferences.getInstance();
    expect(
        await preferences.setString(
            'landrop.pages.v1', jsonEncode([savedPage])),
        isTrue);
    await externalRoot.rename(offlineRoot.path);
    controller.dispose();
    final offlinePart = File('${offlineRoot.path}/${page.id}/.$id.part');
    expect(await offlinePart.readAsString(), 'abc');

    controller = LanDropController(receiveDirectory: directory);
    await controller.initialize();
    page = controller.pages.single;
    expect(page.running, isTrue);
    expect(controller.portFor(page), isNotNull);
    expect(controller.pageRecoveryWarnings[page.id], contains('续传记录已保留'));
    await expectLater(
        controller.removePage(page), throwsA(isA<FileSystemException>()));
    expect(controller.pages.single.id, page.id);
    await until(() => page.running);
    expect(controller.pageRecoveryWarnings[page.id], contains('续传记录已保留'));
    expect(
        (jsonDecode(preferences.getString('landrop.sessions.v1')!) as List)
            .map((session) => session['id']),
        contains(id));
    expect(await offlinePart.readAsString(), 'abc');
    await controller.stop(page);
    final pendingDelete =
        (jsonDecode(preferences.getString('landrop.sessions.v1')!) as List)
            .single as Map;
    expect(pendingDelete['deleting'], isTrue);

    controller.dispose();
    final movedAfterValidation =
        Directory('${directory.path}/deferred-volume-moved-after-check');
    final outside = Directory('${directory.path}/deferred-outside');
    await outside.create();
    final sentinel = File('${outside.path}/.$id.part');
    await sentinel.writeAsString('external');
    var swapAfterValidation = true;
    controller = LanDropController(
        receiveDirectory: directory,
        beforeSecureReceiveUnlink: () async {
          if (!swapAfterValidation) return;
          swapAfterValidation = false;
          await externalRoot.rename(movedAfterValidation.path);
          await Link(externalRoot.path).create(outside.path);
        });
    await controller.initialize();
    page = controller.pages.single;
    expect(page.running, isFalse);
    expect(controller.portFor(page), isNull);
    expect(controller.pageRecoveryWarnings[page.id], contains('续传记录已保留'));
    final restoredDeleteMarker =
        (jsonDecode(preferences.getString('landrop.sessions.v1')!) as List)
            .single as Map;
    expect(restoredDeleteMarker['deleting'], isTrue);
    expect(await offlinePart.readAsString(), 'abc');

    await offlineRoot.rename(externalRoot.path);
    final restoredPart = File('${externalRoot.path}/${page.id}/.$id.part');
    await expectLater(
        controller.removePage(page), throwsA(isA<FileSystemException>()));
    expect(controller.pages.single.id, page.id);
    expect(
        await File('${movedAfterValidation.path}/${page.id}/.$id.part')
            .readAsString(),
        'abc');
    expect(await sentinel.readAsString(), 'external');
    final stillDeleting =
        (jsonDecode(preferences.getString('landrop.sessions.v1')!) as List)
            .single as Map;
    expect(stillDeleting['deleting'], isTrue);

    await Link(externalRoot.path).delete();
    await movedAfterValidation.rename(externalRoot.path);
    await controller.removePage(page);
    expect(controller.pages, isEmpty);
    expect(jsonDecode(preferences.getString('landrop.sessions.v1')!), isEmpty);
    expect(await restoredPart.exists(), isFalse);
    expect(await sentinel.readAsString(), 'external');
  });

  test('page removal waits for in-flight file imports', () async {
    final source = File(p.join(directory.path, 'pending-managed-file.txt'));
    await source.writeAsString('managed payload');
    final managedDirectory = Directory(p.join(directory.path, 'managed-files'));
    await managedDirectory.create();
    controller.fileDirectoryForTesting = managedDirectory;
    final importStarted = Completer<void>();
    final releaseImport = Completer<void>();
    controller.beforeAddFileCommit = () async {
      if (!importStarted.isCompleted) importStarted.complete();
      await releaseImport.future;
    };
    final import = controller.addFiles(page, [
      LocalTestFile(source, 'managed.txt', withoutPath: true),
    ]);
    await importStarted.future;

    var removalCompleted = false;
    final removal = controller.removePage(page).then<void>((_) {
      removalCompleted = true;
    });
    await until(() => !page.running);
    expect(removalCompleted, isFalse);

    releaseImport.complete();
    await import;
    expect(page.files.single.managed, isTrue);
    final managedPath = page.files.single.path;
    await removal;
    expect(removalCompleted, isTrue);
    expect(controller.pages, isEmpty);
    expect(await File(managedPath).exists(), isFalse);
  });

  test('shared managed file survives until its last page reference is removed',
      () async {
    final source = File(p.join(directory.path, 'shared-managed-source.txt'));
    await source.writeAsString('shared managed content');
    await controller.addFiles(page, [
      LocalTestFile(source, 'shared-managed.txt', withoutPath: true),
    ]);
    final shared = page.files.single;
    final managedCopy = File(shared.path);
    expect(await managedCopy.exists(), isTrue);

    final originalPageId = page.id;
    final other = await controller.createPage('Second owner');
    final otherPageId = other.id;
    other.files.add(shared);
    await controller.start(other);
    await controller.shutdown();
    controller.dispose();

    controller = LanDropController(receiveDirectory: directory);
    controller.fileDirectoryForTesting =
        Directory(p.join(directory.path, 'managed-files'));
    await controller.initialize();
    page = controller.pages
        .singleWhere((candidate) => candidate.id == originalPageId);
    final restoredOther = controller.pages
        .singleWhere((candidate) => candidate.id == otherPageId);
    final restoredShared = page.files.single;
    expect(restoredOther.files.single.id, restoredShared.id);

    await controller.removeFile(page, restoredShared);
    expect(page.files, isEmpty);
    expect(restoredOther.files.map((candidate) => candidate.id),
        [restoredShared.id]);
    expect(await managedCopy.exists(), isTrue,
        reason: 'removing one reference must not unlink another page\'s file');

    await controller.removePage(restoredOther);
    expect(await managedCopy.exists(), isFalse,
        reason: 'the final reference still authorizes cleanup');
  });

  test('path imports preserve references to managed-file locations', () async {
    controller.mobileForTesting = false;
    final source = File(p.join(directory.path, 'path-reference-source.txt'));
    await source.writeAsString('managed file path reference');
    await controller.addFiles(page, [
      LocalTestFile(source, 'managed-path.txt', withoutPath: true),
    ]);
    final managedCopy = File(page.files.single.path);
    final originalPageId = page.id;

    final other = await controller.createPage('Path reference owner');
    final otherPageId = other.id;
    await controller.addFiles(other, [
      LocalTestFile(managedCopy, 'file-picker-reference.txt'),
    ]);
    await controller.addPaths(other, [managedCopy.path]);
    expect(other.files, hasLength(2));
    expect(other.files.every((file) => !file.managed), isTrue);

    await controller.shutdown();
    controller.dispose();
    controller = LanDropController(receiveDirectory: directory);
    controller.mobileForTesting = false;
    controller.fileDirectoryForTesting =
        Directory(p.join(directory.path, 'managed-files'));
    await controller.initialize();
    page = controller.pages
        .singleWhere((candidate) => candidate.id == originalPageId);
    final restoredOther = controller.pages
        .singleWhere((candidate) => candidate.id == otherPageId);
    expect(restoredOther.files, hasLength(2));
    expect(restoredOther.files.every((file) => !file.managed), isTrue);

    await controller.removeFile(page, page.files.single);
    expect(page.files, isEmpty);
    expect(await managedCopy.exists(), isTrue,
        reason: 'path-based shares still refer to the same canonical file');
    expect(
        restoredOther.files
            .every((file) => file.canonicalPath == managedCopy.path),
        isTrue);
  });

  test('non-managed removal waits for managed reference inspection', () async {
    controller.mobileForTesting = false;
    final source = File(p.join(directory.path, 'reference-lock-source.txt'));
    await source.writeAsString('reference lock payload');
    await controller.addFiles(page, [
      LocalTestFile(source, 'reference-lock-managed.txt', withoutPath: true),
    ]);
    final managedFile = page.files.single;
    final managedPath = File(managedFile.path);
    final pathOwner = await controller.createPage('Concurrent path owner');
    await controller.addPaths(pathOwner, [managedFile.path]);
    final pathReference = pathOwner.files.single;

    final checkEntered = Completer<void>();
    final releaseCheck = Completer<void>();
    controller.beforeManagedFileReferenceCheck = () async {
      if (checkEntered.isCompleted) return;
      checkEntered.complete();
      await releaseCheck.future;
    };
    final managedRemoval = controller.removeFile(page, managedFile);
    await checkEntered.future.timeout(const Duration(seconds: 5));
    var pathRemovalCompleted = false;
    final pathRemoval = controller
        .removeFile(pathOwner, pathReference)
        .then<void>((_) => pathRemovalCompleted = true);
    await Future<void>.delayed(Duration.zero);
    expect(pathRemovalCompleted, isFalse,
        reason: 'path-reference mutations must wait for the ownership check');
    expect(pathOwner.files.single.id, pathReference.id);

    releaseCheck.complete();
    await managedRemoval;
    controller.beforeManagedFileReferenceCheck = null;
    await pathRemoval;
    expect(pathOwner.files, isEmpty);
    expect(await managedPath.exists(), isTrue,
        reason: 'the managed unlink check observed the still-committed path');
  });

  test('startup orphan sweep preserves path-only managed-file references',
      () async {
    controller.mobileForTesting = false;
    final managedDirectory = Directory(p.join(directory.path, 'managed-files'));
    controller.fileDirectoryForTesting = managedDirectory;
    final source = File(p.join(directory.path, 'orphan-path-source.txt'));
    await source.writeAsString('still shareable after restart');
    await controller.addFiles(page, [
      LocalTestFile(source, 'orphan-path-target.txt', withoutPath: true),
    ]);
    final managedPath = File(page.files.single.path);

    final ownerPageId = page.id;
    final pathOwner = await controller.createPage('Path-only owner');
    final pathOwnerId = pathOwner.id;
    await controller.addPaths(pathOwner, [managedPath.path]);
    expect(pathOwner.files.single.managed, isFalse);

    final unrelatedManagedPage =
        await controller.createPage('Unrelated managed page');
    final unrelatedPageId = unrelatedManagedPage.id;
    await controller.addFiles(unrelatedManagedPage, [
      LocalTestFile(source, 'unrelated-managed.txt', withoutPath: true),
    ]);
    final originalManaged = page.files.single;
    await controller.removeFile(page, originalManaged);
    expect(await managedPath.exists(), isTrue);

    await controller.shutdown();
    controller.dispose();
    controller = LanDropController(receiveDirectory: directory);
    controller.mobileForTesting = false;
    controller.fileDirectoryForTesting = managedDirectory;
    await controller.initialize();
    page = controller.pages
        .singleWhere((candidate) => candidate.id == ownerPageId);
    final restoredPathOwner = controller.pages
        .singleWhere((candidate) => candidate.id == pathOwnerId);
    final restoredUnrelated = controller.pages
        .singleWhere((candidate) => candidate.id == unrelatedPageId);
    expect(restoredUnrelated.files.single.managed, isTrue);
    expect(restoredPathOwner.files, hasLength(1));
    expect(await managedPath.exists(), isTrue,
        reason: 'the startup orphan sweep must honor path-only references');

    await controller.start(restoredPathOwner);
    final response = await request(controller.portFor(restoredPathOwner)!,
        'GET', '/file/${restoredPathOwner.files.single.id}');
    expect(response.status, 200);
    expect(utf8.decode(response.bytes), 'still shareable after restart');
    await controller.shutdown();
  });

  test('orphan sweep is serialized with path imports', () async {
    controller.mobileForTesting = false;
    final managedDirectory = Directory(p.join(directory.path, 'managed-files'));
    controller.fileDirectoryForTesting = managedDirectory;
    final source = File(p.join(directory.path, 'sweep-race-source.txt'));
    await source.writeAsString('unrelated retained file');
    await controller.addFiles(page, [
      LocalTestFile(source, 'sweep-trigger.txt', withoutPath: true),
    ]);
    final importingPage = await controller.createPage('Sweep import target');
    final importingPageId = importingPage.id;
    final managedId = newId();
    final orphanPath = p.join(managedDirectory.path, managedId);
    await File(orphanPath).writeAsString('unclaimed managed leaf');

    await controller.shutdown();
    controller.dispose();
    controller = LanDropController(receiveDirectory: directory);
    controller.mobileForTesting = false;
    controller.fileDirectoryForTesting = managedDirectory;
    final sweepEntered = Completer<void>();
    final releaseSweep = Completer<void>();
    controller.beforeOrphanManagedFileCheck = (id) async {
      if (id == managedId) {
        if (!sweepEntered.isCompleted) sweepEntered.complete();
        await releaseSweep.future;
      }
    };

    final initialization = controller.initialize();
    await sweepEntered.future.timeout(const Duration(seconds: 5));
    final restoredImportingPage = controller.pages
        .singleWhere((candidate) => candidate.id == importingPageId);
    var pathImportCompleted = false;
    final pathImport = controller.addPaths(restoredImportingPage,
        [orphanPath]).then<void>((_) => pathImportCompleted = true);
    var managedImportCompleted = false;
    final managedImport = controller.addFiles(restoredImportingPage, [
      LocalTestFile(source, 'managed-after-sweep.txt', withoutPath: true),
    ]).then<void>((_) => managedImportCompleted = true);
    await Future<void>.delayed(Duration.zero);
    expect(pathImportCompleted, isFalse);
    expect(managedImportCompleted, isFalse,
        reason: 'both import APIs must wait while the sweep owns the lock');
    expect(restoredImportingPage.files, isEmpty);

    releaseSweep.complete();
    await initialization;
    await pathImport;
    await managedImport;
    expect(await File(orphanPath).exists(), isFalse);
    expect(restoredImportingPage.files, hasLength(1));
    expect(restoredImportingPage.files.single.managed, isTrue);
    expect(await File(restoredImportingPage.files.single.path).exists(), isTrue,
        reason:
            'managed addFiles must finish after the sweep releases the lock');
    await controller.shutdown();
  });

  test('failed path-reference removal restores the persisted owner', () async {
    controller.mobileForTesting = false;
    final source = File(p.join(directory.path, 'path-rollback-source.txt'));
    await source.writeAsString('path reference survives failed removal');
    await controller.addFiles(page, [
      LocalTestFile(source, 'path-rollback-managed.txt', withoutPath: true),
    ]);
    final managedFile = page.files.single;
    final managedPath = File(managedFile.path);
    final pathOwner = await controller.createPage('Failed path removal');
    await controller.addPaths(pathOwner, [managedFile.path]);
    final pathReference = pathOwner.files.single;
    var failPageList = true;
    controller.beforePersistKey = (key) async {
      if (key == 'landrop.pages.v1' && failPageList) {
        failPageList = false;
        throw const FileSystemException('injected path-owner removal failure');
      }
    };

    await expectLater(
      controller.removeFile(pathOwner, pathReference),
      throwsA(isA<FileSystemException>()),
    );
    expect(pathOwner.files.single.id, pathReference.id);
    controller.beforePersistKey = null;
    await controller.removeFile(page, managedFile);
    expect(await managedPath.exists(), isTrue,
        reason: 'rollback must restore the reference before a managed unlink');
  });

  test('page removal rollback is serialized with shared-file unlink', () async {
    final source = File(p.join(directory.path, 'rollback-shared-source.txt'));
    await source.writeAsString('shared rollback content');
    await controller.addFiles(page, [
      LocalTestFile(source, 'rollback-shared.txt', withoutPath: true),
    ]);
    final shared = page.files.single;
    final managedCopy = File(shared.path);
    final other = await controller.createPage('Concurrent owner');
    other.files.add(shared);
    await controller.start(other);

    final removalWriteStarted = Completer<void>();
    final releaseRemovalWrite = Completer<void>();
    var injectedFailure = false;
    controller.beforePersistKey = (key) async {
      if (key == 'landrop.pages.v1' && !injectedFailure) {
        injectedFailure = true;
        removalWriteStarted.complete();
        await releaseRemovalWrite.future;
        throw const FileSystemException('injected page-list failure');
      }
    };
    final removePage = controller.removePage(page);
    await removalWriteStarted.future;

    var otherRemovalCompleted = false;
    final removeOtherReference = controller
        .removeFile(other, shared)
        .then<void>((_) => otherRemovalCompleted = true);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(otherRemovalCompleted, isFalse,
        reason: 'another reference mutation must wait for removal rollback');
    expect(other.files.single.id, shared.id);

    releaseRemovalWrite.complete();
    await expectLater(removePage, throwsA(isA<FileSystemException>()));
    controller.beforePersistKey = null;
    await removeOtherReference;

    expect(controller.pages, contains(page));
    expect(page.files.single.id, shared.id);
    expect(other.files, isEmpty);
    expect(await managedCopy.exists(), isTrue,
        reason: 'the rollback-restored page still owns the managed file');
  });

  test('managed path import rolls back copies after page persistence fails',
      () async {
    controller.mobileForTesting = true;
    final managedDirectory = Directory(p.join(directory.path, 'managed-files'));
    await managedDirectory.create();
    controller.fileDirectoryForTesting = managedDirectory;
    final sources = Directory(p.join(directory.path, 'path-import'));
    await sources.create();
    await File(p.join(sources.path, 'one.txt')).writeAsString('one');
    await File(p.join(sources.path, 'two.txt')).writeAsString('two');
    var injectedFailure = false;
    controller.beforePersistKey = (key) async {
      if (key == 'landrop.pages.v1' && !injectedFailure) {
        injectedFailure = true;
        throw const FileSystemException('injected page-list failure');
      }
    };

    await expectLater(
      controller.addPaths(page, [sources.path]),
      throwsA(isA<FileSystemException>()),
    );
    expect(injectedFailure, isTrue);
    expect(page.files, isEmpty);
    expect(await managedDirectory.list(followLinks: false).toList(), isEmpty);
    final preferences = await SharedPreferences.getInstance();
    final savedPages =
        jsonDecode(preferences.getString('landrop.pages.v1')!) as List;
    expect((savedPages.single as Map)['files'], isEmpty);
  });

  test('managed path import keeps copies after a later metadata write fails',
      () async {
    controller.mobileForTesting = true;
    final managedDirectory = Directory(p.join(directory.path, 'managed-files'));
    await managedDirectory.create();
    controller.fileDirectoryForTesting = managedDirectory;
    final sources = Directory(p.join(directory.path, 'committed-path-import'));
    await sources.create();
    await File(p.join(sources.path, 'one.txt')).writeAsString('one');
    var injectedFailure = false;
    controller.beforePersistKey = (key) async {
      if (key == 'landrop.received.v1' && !injectedFailure) {
        injectedFailure = true;
        throw const FileSystemException('injected post-page commit failure');
      }
    };

    await controller.addPaths(page, [sources.path]);

    expect(injectedFailure, isTrue);
    expect(page.files, hasLength(1));
    expect(page.files.single.managed, isTrue);
    expect(
        SecureReceiveFile.isValidLeafIdentity(
            page.files.single.managedLeafIdentity),
        isTrue);
    expect(await File(page.files.single.path).readAsString(), 'one');
    final preferences = await SharedPreferences.getInstance();
    final savedPages =
        jsonDecode(preferences.getString('landrop.pages.v1')!) as List;
    final savedFile =
        ((savedPages.single as Map)['files'] as List).single as Map;
    expect(savedFile['managedLeafIdentity'],
        page.files.single.managedLeafIdentity);
  });

  test('managed add retains the file after a later metadata write fails',
      () async {
    final managedDirectory = Directory(p.join(directory.path, 'managed-files'));
    await managedDirectory.create();
    controller.fileDirectoryForTesting = managedDirectory;
    final source = File(p.join(directory.path, 'committed-source.txt'));
    await source.writeAsString('committed managed payload');
    var injectedFailure = false;
    controller.beforePersistKey = (key) async {
      if (key == 'landrop.received.v1' && !injectedFailure) {
        injectedFailure = true;
        throw const FileSystemException('injected post-page commit failure');
      }
    };

    await controller.addFiles(page, [
      LocalTestFile(source, 'committed.txt', withoutPath: true),
    ]);

    expect(injectedFailure, isTrue);
    expect(page.files, hasLength(1));
    expect(await File(page.files.single.path).readAsString(),
        'committed managed payload');
    final preferences = await SharedPreferences.getInstance();
    final savedPages =
        jsonDecode(preferences.getString('landrop.pages.v1')!) as List;
    expect((savedPages.single as Map)['files'], hasLength(1));
  });

  test('managed removal reports success after a later metadata write fails',
      () async {
    final managedDirectory = Directory(p.join(directory.path, 'managed-files'));
    await managedDirectory.create();
    controller.fileDirectoryForTesting = managedDirectory;
    final source = File(p.join(directory.path, 'remove-source.txt'));
    await source.writeAsString('managed payload');
    await controller.addFiles(page, [
      LocalTestFile(source, 'managed.txt', withoutPath: true),
    ]);
    final managedFile = page.files.single;
    var injectedFailure = false;
    controller.beforePersistKey = (key) async {
      if (key == 'landrop.received.v1' && !injectedFailure) {
        injectedFailure = true;
        throw const FileSystemException('injected post-page commit failure');
      }
    };

    await controller.removeFile(page, managedFile);

    expect(injectedFailure, isTrue);
    expect(page.files, isEmpty);
    expect(await File(managedFile.path).exists(), isFalse);
    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getString('landrop.managedFileDeletions.v1'), '[]');
  });

  test('managed root can rebind without references but quarantines orphans',
      () async {
    controller.mobileForTesting = true;
    final managedDirectory = Directory(p.join(directory.path, 'managed-files'));
    await managedDirectory.create();
    controller.fileDirectoryForTesting = managedDirectory;
    final firstSource = File(p.join(directory.path, 'first-root-source.txt'));
    await firstSource.writeAsString('first');
    await controller.addFiles(page, [
      LocalTestFile(firstSource, 'first.txt', withoutPath: true),
    ]);
    await controller.removeFile(page, page.files.single);
    expect(page.files, isEmpty);

    final orphan = File(p.join(managedDirectory.path, newId()));
    await orphan.writeAsString('unknown replacement occupant');
    replaceMockDirectoryIdentity(managedDirectory.path);
    final nextSource = File(p.join(directory.path, 'next-root-source.txt'));
    await nextSource.writeAsString('next');
    await controller.addFiles(page, [
      LocalTestFile(nextSource, 'next.txt', withoutPath: true),
    ]);

    expect(page.files, hasLength(1));
    expect(await File(page.files.single.path).readAsString(), 'next');
    expect(await orphan.exists(), isTrue);
    final preferences = await SharedPreferences.getInstance();
    expect(
        preferences.getBool('landrop.managedFileCleanupQuarantine.v1'), true);

    controller.dispose();
    controller = LanDropController(receiveDirectory: directory);
    controller.mobileForTesting = true;
    controller.fileDirectoryForTesting = managedDirectory;
    await controller.initialize();
    expect(await orphan.exists(), isTrue);
    expect(controller.pages.single.files, hasLength(1));
  });

  test('startup root rebind quarantines replacement UUID entries before scan',
      () async {
    controller.mobileForTesting = true;
    final managedDirectory = Directory(p.join(directory.path, 'managed-files'));
    await managedDirectory.create();
    controller.fileDirectoryForTesting = managedDirectory;
    final source = File(p.join(directory.path, 'startup-rebind-source.txt'));
    await source.writeAsString('managed payload');
    await controller.addFiles(page, [
      LocalTestFile(source, 'managed.txt', withoutPath: true),
    ]);
    await controller.removeFile(page, page.files.single);
    await controller.stop(page);
    final orphan = File(p.join(managedDirectory.path, newId()));
    await orphan.writeAsString('unknown replacement occupant');
    replaceMockDirectoryIdentity(managedDirectory.path);
    controller.dispose();

    controller = LanDropController(receiveDirectory: directory);
    controller.mobileForTesting = true;
    controller.fileDirectoryForTesting = managedDirectory;
    await controller.initialize();

    expect(await orphan.exists(), isTrue);
    final preferences = await SharedPreferences.getInstance();
    expect(
        preferences.getBool('landrop.managedFileCleanupQuarantine.v1'), true);
    expect(controller.managedFileCleanupWarnings['rootIdentity'], isNotNull);
  });

  test('failed multi-file intent staging rolls back earlier additions',
      () async {
    controller.mobileForTesting = false;
    final managedDirectory = Directory(p.join(directory.path, 'managed-files'));
    controller.fileDirectoryForTesting = managedDirectory;
    final sourceA = File(p.join(directory.path, 'intent-stage-a.txt'));
    final sourceB = File(p.join(directory.path, 'intent-stage-b.txt'));
    await sourceA.writeAsString('first staged file');
    await sourceB.writeAsString('second staged file');
    await controller.addFiles(page, [
      LocalTestFile(sourceA, 'first.txt', withoutPath: true),
      LocalTestFile(sourceB, 'second.txt', withoutPath: true),
    ]);
    final first = page.files[0];
    final validSecond = page.files[1];
    page.files[1] = SharedFile(
      id: validSecond.id,
      name: validSecond.name,
      path: validSecond.path,
      canonicalPath: validSecond.canonicalPath,
      size: validSecond.size,
      managed: true,
      managedRoot: validSecond.managedRoot,
      managedRootIdentity: validSecond.managedRootIdentity,
      managedLeafIdentity: validSecond.managedLeafIdentity,
      managedPinBlocked: true,
    );

    await expectLater(
      controller.removePage(page),
      throwsA(isA<FileSystemException>()),
    );
    expect(page.files, hasLength(2));
    page.files[1] = validSecond;
    var failNextJournalWrite = true;
    controller.beforePersistKey = (key) async {
      if (key == 'landrop.managedFileDeletions.v1' && failNextJournalWrite) {
        failNextJournalWrite = false;
        throw const FileSystemException('injected retry journal failure');
      }
    };
    await expectLater(
      controller.removeFile(page, first),
      throwsA(isA<FileSystemException>()),
    );
    expect(page.files.map((file) => file.id), [first.id, validSecond.id],
        reason: 'retry must persist a fresh intent before page mutation');

    controller.beforePersistKey = null;
    failNextManagedFileUnlinkForTest(first.id);
    await expectLater(
      controller.removeFile(page, first),
      throwsA(isA<FileSystemException>()),
    );
    expect(page.files.single.id, validSecond.id);
    final firstPath = File(first.path);
    expect(await firstPath.exists(), isTrue);
    await controller.shutdown();
    controller.dispose();
    controller = LanDropController(receiveDirectory: directory);
    controller.mobileForTesting = false;
    controller.fileDirectoryForTesting = managedDirectory;
    await controller.initialize();
    expect(await firstPath.exists(), isFalse,
        reason: 'the retry intent must recover even with another managed file');
  });

  test('failed deletion intent write is retried before unlink is authorized',
      () async {
    controller.mobileForTesting = false;
    final managedDirectory = Directory(p.join(directory.path, 'managed-files'));
    controller.fileDirectoryForTesting = managedDirectory;
    final source = File(p.join(directory.path, 'intent-write-retry.txt'));
    await source.writeAsString('deletion intent recovery');
    await controller.addFiles(page, [
      LocalTestFile(source, 'intent-write-retry.txt', withoutPath: true),
    ]);
    final managedFile = page.files.single;
    final managedPath = File(managedFile.path);
    var failFirstJournalWrite = true;
    controller.beforePersistKey = (key) async {
      if (key == 'landrop.managedFileDeletions.v1' && failFirstJournalWrite) {
        failFirstJournalWrite = false;
        throw const FileSystemException('injected first journal write failure');
      }
    };

    await expectLater(
      controller.removeFile(page, managedFile),
      throwsA(isA<FileSystemException>()),
    );
    expect(page.files.single.id, managedFile.id,
        reason: 'a failed journal write must not commit page removal');
    final preferences = await SharedPreferences.getInstance();
    final failedJournalValue =
        preferences.getString('landrop.managedFileDeletions.v1');
    expect(
      failedJournalValue == null ||
          (jsonDecode(failedJournalValue) as List).isEmpty,
      isTrue,
    );

    controller.beforePersistKey = null;
    failNextManagedFileUnlinkForTest(managedFile.id);
    await expectLater(
      controller.removeFile(page, managedFile),
      throwsA(isA<FileSystemException>()),
    );
    expect(page.files, isEmpty);
    expect(await managedPath.exists(), isTrue);
    expect(
        (jsonDecode(preferences.getString('landrop.managedFileDeletions.v1')!)
                as List)
            .map((entry) => (entry as Map)['file']['id']),
        contains(managedFile.id));

    await controller.shutdown();
    controller.dispose();
    controller = LanDropController(receiveDirectory: directory);
    controller.mobileForTesting = false;
    controller.fileDirectoryForTesting = managedDirectory;
    await controller.initialize();
    expect(await managedPath.exists(), isFalse,
        reason: 'the durably retried intent must recover after restart');
  });

  test('managed removal keeps a pending intent after journal clear fails',
      () async {
    final managedDirectory = Directory(p.join(directory.path, 'managed-files'));
    await managedDirectory.create();
    controller.fileDirectoryForTesting = managedDirectory;
    final source = File(p.join(directory.path, 'journal-clear-source.txt'));
    await source.writeAsString('managed payload');
    await controller.addFiles(page, [
      LocalTestFile(source, 'managed.txt', withoutPath: true),
    ]);
    final managedFile = page.files.single;
    var journalWrites = 0;
    controller.beforePersistKey = (key) async {
      if (key == 'landrop.managedFileDeletions.v1' && ++journalWrites == 2) {
        throw const FileSystemException('injected journal clear failure');
      }
    };

    await controller.removeFile(page, managedFile);

    expect(page.files, isEmpty);
    expect(await File(managedFile.path).exists(), isFalse);
    expect(
        controller.managedFileCleanupWarnings[managedFile.id], contains('已删除'));
    final preferences = await SharedPreferences.getInstance();
    expect(
        (jsonDecode(preferences.getString('landrop.managedFileDeletions.v1')!)
                as List)
            .map((entry) => (entry as Map)['file']['id']),
        contains(managedFile.id));

    controller.dispose();
    controller = LanDropController(receiveDirectory: directory);
    controller.fileDirectoryForTesting = managedDirectory;
    await controller.initialize();
    expect(
        jsonDecode((await SharedPreferences.getInstance())
            .getString('landrop.managedFileDeletions.v1')!),
        isEmpty);
    expect(await File(managedFile.path).exists(), isFalse);
  });

  test('managed creation leaf pin blocks replacement on read and deletion',
      () async {
    controller.mobileForTesting = false;
    final managedDirectory = Directory(p.join(directory.path, 'managed-files'));
    controller.fileDirectoryForTesting = managedDirectory;
    final source = File(p.join(directory.path, 'managed-creation-pin.txt'));
    await source.writeAsString('managed source payload');
    await controller.addFiles(page, [
      LocalTestFile(source, 'managed-creation-pin.txt', withoutPath: true),
    ]);
    final managedFile = page.files.single;
    final managedPath = File(managedFile.path);
    final originalLeafIdentity = managedFile.managedLeafIdentity;
    expect(SecureReceiveFile.isValidLeafIdentity(originalLeafIdentity), isTrue);

    final preferences = await SharedPreferences.getInstance();
    final savedPages =
        jsonDecode(preferences.getString('landrop.pages.v1')!) as List;
    expect(
        ((savedPages.single as Map)['files'] as List)
            .single['managedLeafIdentity'],
        originalLeafIdentity,
        reason: 'the creation-time leaf pin must be persisted with the share');
    final initialChunk = await SecureReceiveFile.readManagedFileChunk(
      root: managedFile.managedRoot!,
      leaf: managedFile.id,
      expectedRootIdentity: managedFile.managedRootIdentity!,
      expectedLeafIdentity: originalLeafIdentity!,
      offset: 0,
      maxBytes: 8,
    );
    expect(utf8.decode(initialChunk.bytes), 'managed ');
    expect(initialChunk.fileLength, 'managed source payload'.length);
    final beyondEnd = await SecureReceiveFile.readManagedFileChunk(
      root: managedFile.managedRoot!,
      leaf: managedFile.id,
      expectedRootIdentity: managedFile.managedRootIdentity!,
      expectedLeafIdentity: originalLeafIdentity,
      offset: initialChunk.fileLength + 100,
      maxBytes: 1,
    );
    expect(beyondEnd.bytes, isEmpty);

    expect(
        replaceMockReceiveLeafIdentity(managedFile.path), originalLeafIdentity);
    expect((await request(port, 'GET', '/manifest')).json['files'], isEmpty);
    expect((await request(port, 'GET', '/file/${managedFile.id}')).status,
        HttpStatus.notFound);
    expect(
        (await request(port, 'GET', '/download.zip?ids=${managedFile.id}'))
            .status,
        HttpStatus.badRequest);
    await expectLater(controller.removeFile(page, managedFile),
        throwsA(isA<FileSystemException>()));
    expect(page.files.single.id, managedFile.id);
    expect(await managedPath.readAsString(), 'managed source payload');

    await controller.shutdown();
    controller.dispose();
    controller = LanDropController(receiveDirectory: directory);
    controller.mobileForTesting = false;
    controller.fileDirectoryForTesting = managedDirectory;
    await controller.initialize();
    page = controller.pages.single;
    await controller.start(page);
    port = controller.portFor(page)!;

    expect(page.files.single.managedLeafIdentity, originalLeafIdentity);
    expect((await request(port, 'GET', '/file/${managedFile.id}')).status,
        HttpStatus.notFound);
    expect(await managedPath.readAsString(), 'managed source payload');
  });

  test('managed download rejects a leaf replacement just before reading',
      () async {
    await controller.shutdown();
    controller.dispose();
    SharedPreferences.setMockInitialValues({});
    String? managedPath;
    controller = LanDropController(
      receiveDirectory: directory,
      beforeFileStream: () async {
        if (managedPath != null) replaceMockReceiveLeafIdentity(managedPath);
      },
    );
    await controller.initialize();
    controller.mobileForTesting = false;
    final managedDirectory = Directory(p.join(directory.path, 'managed-files'));
    controller.fileDirectoryForTesting = managedDirectory;
    page = await controller.createPage('Pinned read');
    await controller.start(page);
    port = controller.portFor(page)!;
    final source = File(p.join(directory.path, 'managed-pre-read-race.txt'));
    await source.writeAsString('must not be read from replacement');
    await controller.addFiles(page, [
      LocalTestFile(source, 'managed-pre-read-race.txt', withoutPath: true),
    ]);
    final managedFile = page.files.single;
    managedPath = managedFile.path;

    final response = await request(port, 'GET', '/file/${managedFile.id}');

    expect(response.status, HttpStatus.notFound);
    expect(response.bytes, isEmpty);
    expect(await File(managedFile.path).readAsString(),
        'must not be read from replacement');
  });

  test('shared download rejects ancestor replacement just before reading',
      () async {
    await controller.shutdown();
    controller.dispose();
    SharedPreferences.setMockInitialValues({});
    final selectedRoot = p.join(directory.path, 'selected-shared');
    final movedRoot = p.join(directory.path, 'moved-shared');
    final outsideRoot = p.join(directory.path, 'outside-shared');
    controller = LanDropController(
      receiveDirectory: directory,
      beforeFileStream: () async {
        await Directory(selectedRoot).rename(movedRoot);
        await Link(selectedRoot).create(outsideRoot);
      },
    );
    await controller.initialize();
    controller.mobileForTesting = false;
    page = await controller.createPage('Shared pre-read race');
    await controller.start(page);
    port = controller.portFor(page)!;

    final selectedSource = File(p.join(selectedRoot, 'sub', 'a.txt'));
    await selectedSource.parent.create(recursive: true);
    await selectedSource.writeAsString('inside!!');
    final outsideSource = File(p.join(outsideRoot, 'sub', 'a.txt'));
    await outsideSource.parent.create(recursive: true);
    await outsideSource.writeAsString('secret!!');
    await controller.addPaths(page, [selectedSource.path]);

    final response =
        await request(port, 'GET', '/file/${page.files.single.id}');

    expect(response.status, HttpStatus.notFound);
    expect(response.bytes, isEmpty);
    expect(await File(p.join(movedRoot, 'sub', 'a.txt')).readAsString(),
        'inside!!');
    expect(await outsideSource.readAsString(), 'secret!!');
  });

  test('managed ZIP stages multi-chunk sources with pinned reads', () async {
    controller.mobileForTesting = false;
    final managedDirectory = Directory(p.join(directory.path, 'managed-files'));
    controller.fileDirectoryForTesting = managedDirectory;
    final payload = Uint8List.fromList(List<int>.generate(
        SecureReceiveFile.managedFileReadChunkLimit + 17,
        (index) => index % 251));
    final source = File(p.join(directory.path, 'managed-zip-source.bin'));
    await source.writeAsBytes(payload);
    await controller.addFiles(page, [
      LocalTestFile(source, 'managed-zip-source.bin', withoutPath: true),
    ]);
    final managedFile = page.files.single;
    final workersBefore = controller.zipWorkerSpawnCountForTesting;

    final response =
        await request(port, 'GET', '/download.zip?ids=${managedFile.id}');

    expect(response.status, HttpStatus.ok);
    expect(controller.zipWorkerSpawnCountForTesting, workersBefore + 1);
    final archive = ZipDecoder().decodeBytes(response.bytes, verify: true);
    expect(archive.files, hasLength(1));
    expect(archive.files.single.name, 'managed-zip-source.bin');
    expect(archive.files.single.content as List<int>, payload);
  });

  test('managed ZIP refuses replacement while staging before worker launch',
      () async {
    await controller.shutdown();
    controller.dispose();
    SharedPreferences.setMockInitialValues({});
    String? managedPath;
    controller = LanDropController(
      receiveDirectory: directory,
      beforeZipBuild: () async {
        if (managedPath != null) replaceMockReceiveLeafIdentity(managedPath);
      },
    );
    await controller.initialize();
    controller.mobileForTesting = false;
    final managedDirectory = Directory(p.join(directory.path, 'managed-files'));
    controller.fileDirectoryForTesting = managedDirectory;
    page = await controller.createPage('Pinned ZIP');
    await controller.start(page);
    port = controller.portFor(page)!;
    final source = File(p.join(directory.path, 'managed-zip-race.txt'));
    await source.writeAsString('must not reach the zip worker');
    await controller.addFiles(page, [
      LocalTestFile(source, 'managed-zip-race.txt', withoutPath: true),
    ]);
    final managedFile = page.files.single;
    managedPath = managedFile.path;

    final workersBefore = controller.zipWorkerSpawnCountForTesting;
    final response =
        await request(port, 'GET', '/download.zip?ids=${managedFile.id}');

    expect(response.status, HttpStatus.internalServerError);
    expect(response.bytes, isEmpty);
    expect(controller.zipWorkerSpawnCountForTesting, workersBefore);
    expect(await File(managedFile.path).readAsString(),
        'must not reach the zip worker');
  });

  test('ZIP rejects ancestor replacement after source validation', () async {
    await controller.shutdown();
    controller.dispose();
    SharedPreferences.setMockInitialValues({});
    final selectedRoot = p.join(directory.path, 'zip-selected');
    final movedRoot = p.join(directory.path, 'zip-moved');
    final outsideRoot = p.join(directory.path, 'zip-outside');
    controller = LanDropController(
      receiveDirectory: directory,
      beforeZipBuild: () async {
        await Directory(selectedRoot).rename(movedRoot);
        await Link(selectedRoot).create(outsideRoot);
      },
    );
    await controller.initialize();
    controller.mobileForTesting = false;
    page = await controller.createPage('Shared ZIP pre-build race');
    await controller.start(page);
    port = controller.portFor(page)!;

    final selectedSource = File(p.join(selectedRoot, 'sub', 'a.txt'));
    await selectedSource.parent.create(recursive: true);
    await selectedSource.writeAsString('inside!!');
    final outsideSource = File(p.join(outsideRoot, 'sub', 'a.txt'));
    await outsideSource.parent.create(recursive: true);
    await outsideSource.writeAsString('secret!!');
    await controller.addPaths(page, [selectedSource.path]);
    final workersBefore = controller.zipWorkerSpawnCountForTesting;

    final response =
        await request(port, 'GET', '/download.zip?ids=${page.files.single.id}');

    expect(response.status, HttpStatus.internalServerError);
    expect(response.bytes, isEmpty);
    expect(controller.zipWorkerSpawnCountForTesting, workersBefore);
    expect(await File(p.join(movedRoot, 'sub', 'a.txt')).readAsString(),
        'inside!!');
    expect(await outsideSource.readAsString(), 'secret!!');
  });

  test('legacy managed share gets one-time leaf pin and keeps it', () async {
    controller.mobileForTesting = false;
    final managedDirectory = Directory(p.join(directory.path, 'managed-files'));
    controller.fileDirectoryForTesting = managedDirectory;
    final source = File(p.join(directory.path, 'managed-legacy-migration.txt'));
    await source.writeAsString('legacy managed payload');
    await controller.addFiles(page, [
      LocalTestFile(source, 'managed-legacy-migration.txt', withoutPath: true),
    ]);
    final imported = page.files.single;
    final originalIdentity = imported.managedLeafIdentity;
    final managedPath = File(imported.path);
    final preferences = await SharedPreferences.getInstance();
    final savedPages =
        jsonDecode(preferences.getString('landrop.pages.v1')!) as List;
    final savedPage = Map<String, Object?>.from(savedPages.single as Map);
    final savedFiles = (savedPage['files'] as List)
        .map((raw) => Map<String, Object?>.from(raw as Map))
        .toList();
    savedFiles.single.remove('managedLeafIdentity');
    savedPage['files'] = savedFiles;
    await preferences.setString('landrop.pages.v1', jsonEncode([savedPage]));

    await controller.shutdown();
    controller.dispose();
    controller = LanDropController(receiveDirectory: directory);
    controller.mobileForTesting = false;
    controller.fileDirectoryForTesting = managedDirectory;
    await controller.initialize();
    page = controller.pages.single;
    expect(page.files.single.managedLeafIdentity, originalIdentity);
    await controller.start(page);
    port = controller.portFor(page)!;
    expect((await request(port, 'GET', '/file/${imported.id}')).status,
        HttpStatus.ok);

    await controller.shutdown();
    controller.dispose();
    expect(replaceMockReceiveLeafIdentity(imported.path), originalIdentity);
    controller = LanDropController(receiveDirectory: directory);
    controller.mobileForTesting = false;
    controller.fileDirectoryForTesting = managedDirectory;
    await controller.initialize();
    page = controller.pages.single;
    await controller.start(page);
    port = controller.portFor(page)!;

    expect(page.files.single.managedLeafIdentity, originalIdentity);
    expect((await request(port, 'GET', '/manifest')).json['files'], isEmpty);
    expect(await managedPath.readAsString(), 'legacy managed payload');
    await expectLater(controller.removeFile(page, page.files.single),
        throwsA(isA<FileSystemException>()));
  });

  test('malformed persisted managed root identity blocks the share', () {
    final id = newId();
    final file = SharedFile.fromJson({
      'id': id,
      'name': 'invalid-root-pin.txt',
      'path': p.join(directory.path, 'managed-files', id),
      'size': 0,
      'managed': true,
      'managedRoot': p.join(directory.path, 'managed-files'),
      'managedRootIdentity': 'malformed-root-pin',
      'managedLeafIdentity': 'dev=0;ino=1',
    });

    expect(file, isNotNull);
    final pinnedFile = file!;
    expect(pinnedFile.managedPinBlocked, isTrue);
    expect(pinnedFile.managedRootIdentity, 'malformed-root-pin');
    expect(pinnedFile.managedLeafIdentity, 'dev=0;ino=1');
  });

  test('malformed persisted managed leaf identity is not recaptured', () async {
    controller.mobileForTesting = false;
    final managedDirectory = Directory(p.join(directory.path, 'managed-files'));
    controller.fileDirectoryForTesting = managedDirectory;
    final source = File(p.join(directory.path, 'managed-malformed-pin.txt'));
    await source.writeAsString('preserve malformed pin target');
    await controller.addFiles(page, [
      LocalTestFile(source, 'managed-malformed-pin.txt', withoutPath: true),
    ]);
    final managedFile = page.files.single;
    final managedPath = File(managedFile.path);
    final preferences = await SharedPreferences.getInstance();
    await controller.shutdown();
    controller.dispose();
    final savedPages =
        jsonDecode(preferences.getString('landrop.pages.v1')!) as List;
    final savedPage = Map<String, Object?>.from(savedPages.single as Map);
    final savedFiles = (savedPage['files'] as List)
        .map((raw) => Map<String, Object?>.from(raw as Map))
        .toList();
    savedFiles.single['managedLeafIdentity'] = 'malformed-pin';
    savedPage['files'] = savedFiles;
    await preferences.setString('landrop.pages.v1', jsonEncode([savedPage]));

    controller = LanDropController(receiveDirectory: directory);
    controller.mobileForTesting = false;
    controller.fileDirectoryForTesting = managedDirectory;
    await controller.initialize();
    page = controller.pages.single;
    await controller.start(page);
    port = controller.portFor(page)!;

    expect(page.files.single.managedPinBlocked, isTrue);
    expect((await request(port, 'GET', '/manifest')).json['files'], isEmpty);
    expect(await managedPath.readAsString(), 'preserve malformed pin target');
    await expectLater(controller.removeFile(page, page.files.single),
        throwsA(isA<FileSystemException>()));
    expect(await managedPath.readAsString(), 'preserve malformed pin target');
  });

  test('managed deletion intent preserves a replacement after restart',
      () async {
    controller.mobileForTesting = false;
    final managedDirectory = Directory(p.join(directory.path, 'managed-files'));
    controller.fileDirectoryForTesting = managedDirectory;
    final source = File(p.join(directory.path, 'managed-leaf-race.txt'));
    await source.writeAsString('original managed payload');
    await controller.addFiles(page, [
      LocalTestFile(source, 'managed-leaf-race.txt', withoutPath: true),
    ]);
    final importedFile = page.files.single;
    final legacyFileJson = Map<String, Object?>.from(importedFile.toJson())
      ..remove('managedLeafIdentity');
    final managedFile = SharedFile.fromJson(legacyFileJson)!;
    page.files[0] = managedFile;
    final managedPath = File(managedFile.path);
    late String identityAtStaging;
    controller.beforeManagedFileUnlink = (id) async {
      expect(id, managedFile.id);
      final preferences = await SharedPreferences.getInstance();
      final stagedJournal =
          jsonDecode(preferences.getString('landrop.managedFileDeletions.v1')!)
              as List;
      identityAtStaging = replaceMockReceiveLeafIdentity(managedFile.path);
      expect((stagedJournal.single as Map)['expectedLeafIdentity'],
          identityAtStaging,
          reason: 'the pin must be durable before native unlink begins');
    };

    await expectLater(
      controller.removeFile(page, managedFile),
      throwsA(isA<FileSystemException>()),
    );

    expect(page.files, isEmpty);
    expect(await managedPath.readAsString(), 'original managed payload');
    final preferences = await SharedPreferences.getInstance();
    final journal =
        jsonDecode(preferences.getString('landrop.managedFileDeletions.v1')!)
            as List;
    final intent = journal.single as Map;
    expect(intent['expectedLeafIdentity'], identityAtStaging);
    expect(controller.managedFileCleanupWarnings[managedFile.id], isNotNull);

    await controller.shutdown();
    controller.dispose();
    controller = LanDropController(receiveDirectory: directory);
    controller.mobileForTesting = false;
    controller.fileDirectoryForTesting = managedDirectory;
    await controller.initialize();

    expect(await managedPath.readAsString(), 'original managed payload');
    expect(
        (jsonDecode((await SharedPreferences.getInstance())
                .getString('landrop.managedFileDeletions.v1')!) as List)
            .single['expectedLeafIdentity'],
        identityAtStaging,
        reason: 'recovery must keep the original leaf pin, not recapture');
    expect(controller.managedFileCleanupWarnings[managedFile.id], isNotNull);
  });

  test('legacy managed deletion intent without leaf identity fails closed',
      () async {
    controller.mobileForTesting = false;
    final managedDirectory = Directory(p.join(directory.path, 'managed-files'));
    controller.fileDirectoryForTesting = managedDirectory;
    final source = File(p.join(directory.path, 'managed-legacy-intent.txt'));
    await source.writeAsString('keep legacy target');
    await controller.addFiles(page, [
      LocalTestFile(source, 'managed-legacy-intent.txt', withoutPath: true),
    ]);
    final managedFile = page.files.single;
    failNextManagedFileUnlinkForTest(managedFile.id);
    await expectLater(controller.removeFile(page, managedFile),
        throwsA(isA<FileSystemException>()));
    final preferences = await SharedPreferences.getInstance();
    await controller.shutdown();
    controller.dispose();
    final journal =
        jsonDecode(preferences.getString('landrop.managedFileDeletions.v1')!)
            as List;
    final legacyIntent = Map<String, Object?>.from(journal.single as Map)
      ..remove('expectedLeafIdentity');
    final legacyFile = Map<String, Object?>.from(legacyIntent['file'] as Map)
      ..remove('managedLeafIdentity');
    legacyIntent['file'] = legacyFile;
    await preferences.setString(
        'landrop.managedFileDeletions.v1', jsonEncode([legacyIntent]));

    controller = LanDropController(receiveDirectory: directory);
    controller.mobileForTesting = false;
    controller.fileDirectoryForTesting = managedDirectory;
    await controller.initialize();

    expect(await File(managedFile.path).readAsString(), 'keep legacy target');
    expect(controller.managedFileCleanupWarnings[managedFile.id], isNotNull);
    final persisted = jsonDecode((await SharedPreferences.getInstance())
        .getString('landrop.managedFileDeletions.v1')!) as List;
    expect(persisted, hasLength(1),
        reason:
            'legacy intent must be retained rather than freshly authorized');
  });

  test('managed files reject a replaced root before read or deletion',
      () async {
    final managedDirectory = Directory(p.join(directory.path, 'managed-files'));
    await managedDirectory.create();
    controller.fileDirectoryForTesting = managedDirectory;
    final source = File(p.join(directory.path, 'managed-source.txt'));
    await source.writeAsString('managed payload');
    await controller.addFiles(page, [
      LocalTestFile(source, 'managed.txt', withoutPath: true),
    ]);
    final managedFile = page.files.single;
    expect(
        (await request(port, 'GET', '/manifest')).json['files'], hasLength(1));
    final originalIdentity =
        replaceMockDirectoryIdentity(managedDirectory.path);
    expect((await request(port, 'GET', '/file/${managedFile.id}')).status, 404);
    await expectLater(controller.removeFile(page, managedFile),
        throwsA(isA<FileSystemException>()));
    restoreMockDirectoryIdentity(managedDirectory.path, originalIdentity);

    final movedDirectory = Directory(p.join(directory.path, 'managed-moved'));
    await managedDirectory.rename(movedDirectory.path);
    final outside = Directory(p.join(directory.path, 'managed-outside'));
    await outside.create();
    final sentinel = File(p.join(outside.path, managedFile.id));
    await sentinel.writeAsString('outside sentinel');
    await Link(managedDirectory.path).create(outside.path);

    expect((await request(port, 'GET', '/file/${managedFile.id}')).status, 404);
    await expectLater(controller.removeFile(page, managedFile),
        throwsA(isA<FileSystemException>()));
    expect(page.files.single.id, managedFile.id);
    expect(await sentinel.readAsString(), 'outside sentinel');

    await Link(managedDirectory.path).delete();
    await movedDirectory.rename(managedDirectory.path);
    await controller.removeFile(page, managedFile);
    expect(page.files, isEmpty);
    expect(await File(managedFile.path).exists(), isFalse);
    expect(await sentinel.readAsString(), 'outside sentinel');
  });

  test('malformed page metadata quarantine survives restart', () async {
    await controller.stop(page);
    controller.dispose();
    final managedDirectory = Directory(p.join(directory.path, 'managed-files'));
    await managedDirectory.create();
    final orphan = File(p.join(managedDirectory.path, newId()));
    await orphan.writeAsString('preserve after metadata corruption');
    SharedPreferences.setMockInitialValues({
      'landrop.pages.v1': jsonEncode([
        {'id': 'malformed-page', 'title': 'lost owner', 'files': []},
      ]),
    });
    controller = LanDropController(receiveDirectory: directory);
    controller.mobileForTesting = true;
    controller.fileDirectoryForTesting = managedDirectory;
    await controller.initialize();
    expect(await orphan.exists(), isTrue);
    final preferences = await SharedPreferences.getInstance();
    expect(
        preferences.getBool('landrop.managedFileCleanupQuarantine.v1'), true);

    controller.dispose();
    controller = LanDropController(receiveDirectory: directory);
    controller.mobileForTesting = true;
    controller.fileDirectoryForTesting = managedDirectory;
    await controller.initialize();
    expect(await orphan.exists(), isTrue);
    expect(controller.managedFileCleanupWarnings['quarantine'], isNotNull);
  });

  test('missing page metadata quarantines existing managed UUID files',
      () async {
    await controller.stop(page);
    controller.dispose();
    final managedDirectory = Directory(p.join(directory.path, 'managed-files'));
    await managedDirectory.create();
    final orphan = File(p.join(managedDirectory.path, newId()));
    await orphan.writeAsString('unowned after page-state loss');
    SharedPreferences.setMockInitialValues({});
    controller = LanDropController(receiveDirectory: directory);
    controller.mobileForTesting = true;
    controller.fileDirectoryForTesting = managedDirectory;
    await controller.initialize();

    expect(await orphan.exists(), isTrue);
    final preferences = await SharedPreferences.getInstance();
    expect(
        preferences.getBool('landrop.managedFileCleanupQuarantine.v1'), true);
    controller.dispose();
    controller = LanDropController(receiveDirectory: directory);
    controller.mobileForTesting = true;
    controller.fileDirectoryForTesting = managedDirectory;
    await controller.initialize();
    expect(await orphan.exists(), isTrue);
  });

  test('malformed managed cleanup journal preserves unknown files', () async {
    await controller.stop(page);
    controller.dispose();
    final managedDirectory = Directory(p.join(directory.path, 'managed-files'));
    await managedDirectory.create();
    final orphan = File(p.join(managedDirectory.path, newId()));
    await orphan.writeAsString('preserve on corrupt state');
    SharedPreferences.setMockInitialValues({
      'landrop.pages.v1': '[]',
      'landrop.managedFileDeletions.v1': '{broken',
    });
    controller = LanDropController(receiveDirectory: directory);
    controller.fileDirectoryForTesting = managedDirectory;
    await controller.initialize();

    expect(await orphan.exists(), isTrue);
    expect(controller.managedFileCleanupWarnings['journal'], isNotNull);
  });

  test('legacy managed share does not authorize a later occupant', () async {
    await controller.stop(page);
    controller.dispose();
    final managedDirectory = Directory(p.join(directory.path, 'managed-files'));
    await managedDirectory.create();
    final id = newId();
    final legacyPage = SharePage(
      id: newId(),
      title: 'Legacy managed share',
      files: [
        SharedFile(
          id: id,
          name: 'legacy.txt',
          path: p.join(managedDirectory.path, id),
          size: 5,
          managed: true,
        ),
      ],
    );
    SharedPreferences.setMockInitialValues({
      'landrop.pages.v1': jsonEncode([legacyPage.toJson()]),
    });
    controller = LanDropController(receiveDirectory: directory);
    controller.fileDirectoryForTesting = managedDirectory;
    await controller.initialize();
    page = controller.pages.single;
    expect(page.files.single.managedPinBlocked, isTrue);
    final path = page.files.single.path;
    await File(path).writeAsString('new occupant');
    await controller.start(page);
    port = controller.portFor(page)!;

    expect((await request(port, 'GET', '/file/$id')).status, 404);
    await expectLater(controller.removeFile(page, page.files.single),
        throwsA(isA<FileSystemException>()));
    expect(await File(path).readAsString(), 'new occupant');
    expect(controller.managedFileCleanupWarnings['pin:$id'], isNotNull);
  });

  test('persisted managed root cannot redirect cleanup outside app storage',
      () async {
    final managedDirectory = Directory(p.join(directory.path, 'managed-files'));
    await managedDirectory.create();
    controller.fileDirectoryForTesting = managedDirectory;
    final source = File(p.join(directory.path, 'managed-source.txt'));
    await source.writeAsString('managed payload');
    await controller.addFiles(page, [
      LocalTestFile(source, 'managed.txt', withoutPath: true),
    ]);
    final managedFile = page.files.single;
    final outside = Directory(p.join(directory.path, 'outside-root'));
    await outside.create();
    final sentinel = File(p.join(outside.path, managedFile.id));
    await sentinel.writeAsString('do not delete');
    final outsideIdentity =
        (await SecureReceiveFile.captureManagedFileDirectoryIdentity(
                outside.path))
            .rootIdentity;
    await controller.stop(page);

    final preferences = await SharedPreferences.getInstance();
    final savedPages =
        jsonDecode(preferences.getString('landrop.pages.v1')!) as List;
    final pageRecord = Map<String, Object?>.from(savedPages.single as Map);
    final savedFiles = pageRecord['files'] as List;
    final tamperedFile = Map<String, Object?>.from(savedFiles.single as Map)
      ..['path'] = sentinel.path
      ..['canonicalPath'] = sentinel.path
      ..['managedRoot'] = outside.path
      ..['managedRootIdentity'] = outsideIdentity;
    pageRecord['files'] = [tamperedFile];
    await preferences.setString('landrop.pages.v1', jsonEncode([pageRecord]));

    controller.dispose();
    controller = LanDropController(receiveDirectory: directory);
    controller.fileDirectoryForTesting = managedDirectory;
    await controller.initialize();
    page = controller.pages.single;
    await expectLater(
        controller.removePage(page), throwsA(isA<FileSystemException>()));
    expect(controller.pages.single.files.single.id, managedFile.id);
    expect(await File(managedFile.path).exists(), isTrue);
    expect(await sentinel.readAsString(), 'do not delete');
  });

  test('managed-file cleanup intent retries after restart', () async {
    final managedDirectory = Directory(p.join(directory.path, 'managed-files'));
    await managedDirectory.create();
    controller.fileDirectoryForTesting = managedDirectory;
    final source = File(p.join(directory.path, 'managed-source.txt'));
    await source.writeAsString('managed payload');
    await controller.addFiles(page, [
      LocalTestFile(source, 'managed.txt', withoutPath: true),
    ]);
    final managedFile = page.files.single;
    final managedPath = managedFile.path;
    expect(managedFile.managed, isTrue);
    expect(managedFile.managedRootIdentity, isNotNull);
    failNextManagedFileUnlinkForTest(managedFile.id);

    await expectLater(controller.removeFile(page, managedFile),
        throwsA(isA<FileSystemException>()));
    expect(page.files, isEmpty);
    expect(await File(managedPath).exists(), isTrue);
    expect(controller.managedFileCleanupWarnings[managedFile.id], isNotNull);
    final preferences = await SharedPreferences.getInstance();
    final journal =
        jsonDecode(preferences.getString('landrop.managedFileDeletions.v1')!)
            as List;
    expect(journal, hasLength(1));
    expect((journal.single as Map)['file']['id'], managedFile.id);

    await controller.stop(page);
    controller.dispose();
    controller = LanDropController(receiveDirectory: directory);
    controller.fileDirectoryForTesting = managedDirectory;
    await controller.initialize();
    page = controller.pages.single;
    expect(page.files, isEmpty);
    expect(await File(managedPath).exists(), isFalse);
    expect(
        jsonDecode(preferences.getString('landrop.managedFileDeletions.v1')!),
        isEmpty);
    expect(controller.managedFileCleanupWarnings, isEmpty);
  });

  test('page removal retains failed managed cleanup for restart', () async {
    final managedDirectory = Directory(p.join(directory.path, 'managed-files'));
    await managedDirectory.create();
    controller.fileDirectoryForTesting = managedDirectory;
    final source = File(p.join(directory.path, 'page-managed-source.txt'));
    await source.writeAsString('managed payload');
    await controller.addFiles(page, [
      LocalTestFile(source, 'managed.txt', withoutPath: true),
    ]);
    final managedFile = page.files.single;
    final managedPath = managedFile.path;
    failNextManagedFileUnlinkForTest(managedFile.id);

    await expectLater(
        controller.removePage(page), throwsA(isA<FileSystemException>()));
    expect(controller.pages, isEmpty);
    expect(await File(managedPath).exists(), isTrue);
    expect(controller.managedFileCleanupWarnings[managedFile.id], isNotNull);
    final preferences = await SharedPreferences.getInstance();
    final journal =
        jsonDecode(preferences.getString('landrop.managedFileDeletions.v1')!)
            as List;
    expect(journal, hasLength(1));

    controller.dispose();
    controller = LanDropController(receiveDirectory: directory);
    controller.fileDirectoryForTesting = managedDirectory;
    await controller.initialize();
    expect(controller.pages, isEmpty);
    expect(await File(managedPath).exists(), isFalse);
    expect(
        jsonDecode(preferences.getString('landrop.managedFileDeletions.v1')!),
        isEmpty);
    expect(controller.managedFileCleanupWarnings, isEmpty);
  });

  test('receive option persistence failure restores previous page settings',
      () async {
    final previousDirectory = Directory(p.join(directory.path, 'receive-old'));
    await controller.setReceiveOptions(page,
        directory: previousDirectory.path, organizeByDate: true);
    final previousReceiveDirectory = await controller.receiveDirectoryFor(page);
    final preferences = await SharedPreferences.getInstance();
    final persistedPagesBefore = preferences.getString('landrop.pages.v1')!;

    controller.beforePersistKey = (key) async {
      if (key == 'landrop.pages.v1') {
        throw const FileSystemException('injected receive-options failure');
      }
    };
    final nextDirectory = Directory(p.join(directory.path, 'receive-new'));
    await expectLater(
      controller.setReceiveOptions(page,
          directory: nextDirectory.path, organizeByDate: false),
      throwsA(isA<FileSystemException>()),
    );
    controller.beforePersistKey = null;

    expect(page.receiveDirectory, previousDirectory.path);
    expect(page.organizeByDate, isTrue);
    expect(
        await controller.receiveDirectoryFor(page), previousReceiveDirectory);
    final persistedPages =
        jsonDecode(preferences.getString('landrop.pages.v1')!) as List;
    final persistedPage = (persistedPages.single as Map);
    expect(persistedPage['receiveDirectory'], previousDirectory.path);
    expect(persistedPage['organizeByDate'], isTrue);
    expect(preferences.getString('landrop.pages.v1'), persistedPagesBefore);
  });

  test('receive options stay committed after later metadata write failure',
      () async {
    var failedLaterWrite = false;
    controller.beforePersistKey = (key) async {
      if (key == 'landrop.received.v1' && !failedLaterWrite) {
        failedLaterWrite = true;
        throw const FileSystemException('injected later metadata failure');
      }
    };
    final nextDirectory =
        Directory(p.join(directory.path, 'receive-committed'));

    await controller.setReceiveOptions(page,
        directory: nextDirectory.path, organizeByDate: true);

    expect(failedLaterWrite, isTrue);
    expect(page.receiveDirectory, nextDirectory.path);
    expect(page.organizeByDate, isTrue);
    final preferences = await SharedPreferences.getInstance();
    final savedPage =
        (jsonDecode(preferences.getString('landrop.pages.v1')!) as List).single
            as Map;
    expect(savedPage['receiveDirectory'], nextDirectory.path);
    expect(savedPage['organizeByDate'], isTrue);
    expect(jsonDecode(preferences.getString('landrop.received.v1')!), isEmpty);
  });

  test('page removal completes when a pinned date parent is missing', () async {
    final receiveBase = Directory(p.join(directory.path, 'dated-receives'));
    await controller.setReceiveOptions(page,
        directory: receiveBase.path, organizeByDate: true);
    final liveId = await create(fingerprint: 'live-session');
    final deferredId = await create(fingerprint: 'deferred-session');
    final dateDirectory = Directory(await controller.receiveDirectoryFor(page));
    final receiveRoot = Directory(p.dirname(dateDirectory.path));
    final quarantine = File(p.join(
        receiveRoot.path,
        SecureReceiveFile.quarantineDirectoryName,
        liveId,
        '.$liveId.quarantine'));
    failNextReceiveQuarantineAfterRenameForTest('.$liveId.part');
    await expectLater(
        controller.cancelTransfer(liveId), throwsA(isA<FileSystemException>()));
    expect(await quarantine.exists(), isTrue);

    final preferences = await SharedPreferences.getInstance();
    final beforeRestart =
        (jsonDecode(preferences.getString('landrop.sessions.v1')!) as List)
            .singleWhere((record) => record['id'] == liveId) as Map;
    expect(beforeRestart['deleting'], isTrue);
    expect(beforeRestart['receiveQuarantineIdentity'], isA<String>());
    final expectedLeafIdentity = beforeRestart['receiveLeafIdentity'] as String;
    expect(
        replaceMockReceiveLeafIdentity(quarantine.path), expectedLeafIdentity);
    await dateDirectory.delete(recursive: true);
    await controller.stop(page);
    controller.dispose();

    controller = LanDropController(receiveDirectory: directory);
    await controller.initialize();
    final restoredPage = controller.pages.single;
    expect(await quarantine.exists(), isTrue);
    expect(await File(p.join(receiveRoot.path, '.$liveId.part')).exists(),
        isFalse);
    final retained =
        (jsonDecode(preferences.getString('landrop.sessions.v1')!) as List)
            .singleWhere((record) => record['id'] == liveId) as Map;
    expect(retained['deleting'], isTrue);

    restoreMockReceiveLeafIdentity(quarantine.path, expectedLeafIdentity);
    await controller.removePage(restoredPage);

    expect(controller.pages, isEmpty);
    final sessions =
        jsonDecode(preferences.getString('landrop.sessions.v1')!) as List;
    expect(sessions.where((record) => record['id'] == liveId), isEmpty);
    expect(sessions.where((record) => record['id'] == deferredId), isEmpty);
    expect(await quarantine.exists(), isFalse);
    expect(await Directory(p.dirname(quarantine.path)).exists(), isFalse);
    expect(await FileSystemEntity.type(dateDirectory.path, followLinks: false),
        FileSystemEntityType.notFound);
  }, skip: Platform.isWindows ? 'POSIX receive-quarantine behavior' : false);

  test('page deletion completes after its durable page-list commit', () async {
    final id = await create(size: 0);
    expect((await request(port, 'POST', '/uploads/$id/complete')).status, 201);
    expect(controller.receivedFiles, hasLength(1));

    var failReceiptWrite = false;
    controller.beforePageRemoval = () async {
      failReceiptWrite = true;
    };
    controller.beforePersistKey = (key) async {
      if (failReceiptWrite && key == 'landrop.uploadReceipts.v1') {
        failReceiptWrite = false;
        throw const FileSystemException('simulated later-key failure');
      }
    };
    await controller.removePage(page);

    expect(controller.pages, isEmpty);
    final preferences = await SharedPreferences.getInstance();
    expect(jsonDecode(preferences.getString('landrop.pages.v1')!), isEmpty);
    expect(jsonDecode(preferences.getString('landrop.uploadReceipts.v1')!),
        isEmpty);
    expect(jsonDecode(preferences.getString('landrop.sessions.v1')!), isEmpty);
    expect(controller.receivedFiles, isEmpty);
  });

  test('page-list rollback preserves queued concurrent page writes', () async {
    final pageSessionId = await create(size: 0, name: 'page.txt');
    expect(
        (await request(port, 'POST', '/uploads/$pageSessionId/complete'))
            .status,
        201);
    final concurrentPage = await controller.createPage('Concurrent');
    await controller.start(concurrentPage);
    final concurrentPort = controller.portFor(concurrentPage)!;
    final concurrentCreate = await request(concurrentPort, 'POST',
        '/uploads?name=concurrent.txt&size=0&fingerprint=concurrent-page');
    expect(concurrentCreate.status, 201);
    final concurrentSessionId = concurrentCreate.json['id'] as String;

    var armFailure = false;
    var blockedOnce = false;
    final pageWriteStarted = Completer<void>();
    final releasePageWrite = Completer<void>();
    controller.beforePageRemoval = () async {
      armFailure = true;
    };
    controller.beforePersistKey = (key) async {
      if (armFailure && !blockedOnce && key == 'landrop.pages.v1') {
        blockedOnce = true;
        pageWriteStarted.complete();
        await releasePageWrite.future;
        throw const FileSystemException('simulated page-list failure');
      }
    };

    final removeFuture = controller.removePage(page);
    await pageWriteStarted.future;
    final concurrentCompletion = request(
        concurrentPort, 'POST', '/uploads/$concurrentSessionId/complete');
    await until(() => controller.receivedFiles.any((record) =>
        record.pageId == concurrentPage.id && record.name == 'concurrent.txt'));
    releasePageWrite.complete();

    await expectLater(removeFuture, throwsA(isA<FileSystemException>()));
    await until(() => page.running);
    expect((await concurrentCompletion).status, 201);
    expect(controller.pages.map((item) => item.id),
        containsAll([page.id, concurrentPage.id]));
    expect(controller.receivedFilesFor(page), hasLength(1));
    expect(controller.receivedFilesFor(concurrentPage), hasLength(1));

    final preferences = await SharedPreferences.getInstance();
    final persistedPages =
        jsonDecode(preferences.getString('landrop.pages.v1')!) as List;
    expect(persistedPages.map((item) => item['id']),
        containsAll([page.id, concurrentPage.id]));
    final persistedFiles =
        jsonDecode(preferences.getString('landrop.received.v1')!) as List;
    expect(persistedFiles.map((item) => item['pageId']),
        containsAll([page.id, concurrentPage.id]));
    final persistedReceipts =
        jsonDecode(preferences.getString('landrop.uploadReceipts.v1')!) as List;
    expect(persistedReceipts.map((item) => item['id']),
        containsAll([pageSessionId, concurrentSessionId]));
  });

  test('restored duplicate fingerprints reject retry without server error',
      () async {
    final firstId = await create(fingerprint: 'duplicate-first');
    final secondId = await create(fingerprint: 'duplicate-second');
    await request(port, 'PATCH', '/uploads/$firstId?offset=0',
        body: utf8.encode('abc'));
    await request(port, 'PATCH', '/uploads/$secondId?offset=0',
        body: utf8.encode('abc'));
    final savedPage = Map<String, Object>.from(page.toJson());
    expect(savedPage['running'], isTrue);
    await controller.stop(page);
    final preferences = await SharedPreferences.getInstance();
    expect(
        await preferences.setString(
            'landrop.pages.v1', jsonEncode([savedPage])),
        isTrue);
    final savedSessions =
        (jsonDecode(preferences.getString('landrop.sessions.v1')!) as List)
            .map((session) => Map<String, Object?>.from(session as Map))
            .toList();
    savedSessions[1]['fingerprint'] = 'duplicate-first';
    expect(
        await preferences.setString(
            'landrop.sessions.v1', jsonEncode(savedSessions)),
        isTrue);
    controller.dispose();

    controller = LanDropController(receiveDirectory: directory);
    await controller.initialize();
    page = controller.pages.single;
    expect(page.running, isTrue);
    port = controller.portFor(page)!;
    final retry = await request(
        port, 'POST', '/uploads?name=a.txt&size=6&fingerprint=duplicate-first');
    expect(retry.status, 409);
    expect(retry.json['error'], contains('Multiple upload sessions'));
  });

  test('failed session cleanup retains metadata until receive root returns',
      () async {
    final id = await create();
    await request(port, 'PATCH', '/uploads/$id?offset=0',
        body: utf8.encode('abc'));
    expect(controller.canAbandonTransfer(id), isTrue);
    final root = Directory('${directory.path}/LanDrop/${page.id}');
    final detachedRoot = Directory('${directory.path}/detached-${page.id}');
    await root.rename(detachedRoot.path);

    await expectLater(
        controller.cancelTransfer(id), throwsA(isA<FileSystemException>()));
    expect(controller.canAbandonTransfer(id), isTrue);
    expect(controller.pageRecoveryWarnings[page.id], contains('续传记录已保留'));
    expect((await request(port, 'GET', '/uploads/$id')).json,
        {'id': id, 'offset': 3, 'size': 6});
    final savedWhileUnavailable = jsonDecode(
        (await SharedPreferences.getInstance())
            .getString('landrop.sessions.v1')!) as List;
    final savedDeleteIntent = savedWhileUnavailable.single as Map;
    expect(savedDeleteIntent['id'], id);
    expect(savedDeleteIntent['deleting'], isTrue);

    await detachedRoot.rename(root.path);
    await controller.cancelTransfer(id);
    expect(controller.canAbandonTransfer(id), isFalse);
    expect((await request(port, 'GET', '/uploads/$id')).status, 404);
    expect(await File('${root.path}/.$id.part').exists(), isFalse);
    expect(controller.pageRecoveryWarnings.containsKey(page.id), isFalse);
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
    expect(controller.canAbandonTransfer(id), isTrue);
    expect((await request(port, 'DELETE', '/uploads/$id')).status, 204);
    expect(await part.exists(), false);
    expect(controller.transfers.single.status, 'cancelled');
    expect(controller.canAbandonTransfer(id), isFalse);
    final second = await create(fingerprint: 'next');
    await controller.removePage(page);
    expect(
        await File('${directory.path}/LanDrop/${page.id}/.$second.part')
            .exists(),
        false);
  });

  test('page removal cancels resumable tasks and bounds terminal history',
      () async {
    await controller.stop(page);
    controller.dispose();
    SharedPreferences.setMockInitialValues({});
    controller = LanDropController(
        receiveDirectory: directory, pendingSessionLimit: 200);
    await controller.initialize();
    page = await controller.createPage('Removal root');
    await controller.start(page);
    port = controller.portFor(page)!;
    final pages = <SharePage>[page];
    for (var i = 1; i < 9; i++) {
      final next = await controller.createPage('Remove $i');
      await controller.start(next);
      pages.add(next);
    }
    for (var pageIndex = 0; pageIndex < pages.length; pageIndex++) {
      final target = pages[pageIndex];
      final targetPort = controller.portFor(target)!;
      String? firstSessionId;
      for (var i = 0; i < 16; i++) {
        final result = await request(targetPort, 'POST',
            '/uploads?name=remove-$pageIndex-$i.txt&size=0&fingerprint=rm-$pageIndex-$i');
        expect(result.status, 201);
        if (i == 0) firstSessionId = result.json['id'] as String;
      }
      final emptyPatch = await request(
          targetPort, 'PATCH', '/uploads/$firstSessionId?offset=0',
          body: []);
      expect(emptyPatch.status, 200);
      expect(controller.uploadRegistryPageCountForTesting, 0);
    }
    expect(controller.transfers, hasLength(144));
    final removedPageIds = pages.map((target) => target.id).toSet();

    for (final target in pages) {
      await controller.removePage(target);
    }

    expect(controller.pages, isEmpty);
    expect(controller.uploadRegistryPageCountForTesting, 0);
    expect(controller.transfers, hasLength(128));
    expect(
        controller.transfers.any((task) =>
            removedPageIds.contains(task.pageId) && task.status == 'paused'),
        false);
    expect(
        controller.transfers.every((task) => task.status == 'cancelled'), true);
  });

  test(
      'received-file history is bounded and page removal preserves saved files',
      () async {
    final pages = <SharePage>[page];
    for (var i = 1; i < 6; i++) {
      pages.add(await controller.createPage('History $i'));
    }
    final savedFile = File(p.join(directory.path, 'already-received.txt'));
    await savedFile.writeAsString('keep');
    for (var pageIndex = pages.length - 1; pageIndex >= 0; pageIndex--) {
      for (var i = 200; i >= 0; i--) {
        final keepFile = pageIndex == pages.length - 1 && i == 200;
        controller.receivedFiles.add(ReceivedFile(
          name: keepFile ? 'already-received.txt' : 'record-$pageIndex-$i',
          path: keepFile
              ? savedFile.path
              : p.join(directory.path, 'missing-$pageIndex-$i'),
          size: 0,
          pageTitle: pages[pageIndex].title,
          pageId: pages[pageIndex].id,
          receivedAt:
              DateTime.utc(2025).add(Duration(minutes: pageIndex * 201 + i)),
        ));
      }
    }
    await controller.createPage('Prune trigger');

    expect(controller.receivedFiles, hasLength(1000));
    expect(controller.receivedFilesFor(pages.last), hasLength(200));
    expect(controller.receivedFilesFor(pages.first), isEmpty);
    expect(
        controller.receivedFiles.any((record) => record.name == 'record-5-1'),
        true);
    expect(
        controller.receivedFiles.any((record) => record.name == 'record-5-0'),
        false);

    final removedPageId = pages.last.id;
    await controller.removePage(pages.last);
    expect(controller.receivedFiles, hasLength(800));
    expect(
        controller.receivedFiles
            .any((record) => record.pageId == removedPageId),
        false);
    expect(await savedFile.exists(), isTrue);
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
      // The task can be marked paused before its handler releases the session
      // busy lock, especially on Windows while async cleanup is still running.
      await until(() => controller.uploadRegistryPageCountForTesting == 0);
      final resumed = await request(port, 'GET', '/uploads/$id');
      expect(resumed.json['offset'], 7);
      final appended =
          await request(port, 'PATCH', '/uploads/$id?offset=7', body: [1]);
      expect(appended.status, 200,
          reason: 'stop=$stop; response=${utf8.decode(appended.bytes)}');
      expect(appended.json['offset'], 8,
          reason: 'stop=$stop; response=${utf8.decode(appended.bytes)}');
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
    final canonicalTarget = await Directory(target).resolveSymbolicLinks();
    // A custom target must not materialize or require the unused default root.
    expect(controller.receiveDirectory, isNull);
    expect((await upload(port, 'photo.png', 'image')).$1, 201);
    expect(controller.receivedFiles.single.path,
        p.join(canonicalTarget, 'photo.png'));
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
    expect(controller.receivedFiles.single.path,
        p.join(canonicalTarget, 'photo.png'));
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

  test('restored sessions above the new cap remain recoverable', () async {
    final ids = <String>[
      await create(fingerprint: 'grandfather-one'),
      await create(fingerprint: 'grandfather-two'),
      await create(fingerprint: 'grandfather-three'),
    ];
    await controller.stop(page);
    controller.dispose();
    controller =
        LanDropController(receiveDirectory: directory, pendingSessionLimit: 2);
    await controller.initialize();
    page = controller.pages.single;
    await controller.start(page);
    port = controller.portFor(page)!;

    for (final id in ids) {
      expect((await request(port, 'GET', '/uploads/$id')).status, 200);
    }
    final repeated = await request(port, 'POST',
        '/uploads?name=grandfather-one.txt&size=6&fingerprint=grandfather-one');
    expect(repeated.status, 201);
    expect(repeated.json['id'], ids.first);
    expect(
        (await request(port, 'PATCH', '/uploads/${ids.first}?offset=0',
                body: [1]))
            .status,
        200);
    expect(
        (await request(
                port, 'POST', '/uploads?name=new.txt&size=1&fingerprint=new'))
            .status,
        429);

    await controller.cancelTransfer(ids[0]);
    await controller.cancelTransfer(ids[1]);
    final newSession = await create(fingerprint: 'after-grandfathered');
    await controller.cancelTransfer(ids[2]);
    await controller.cancelTransfer(newSession);
  });

  test('pending upload byte budget reserves, restores and frees capacity',
      () async {
    await controller.stop(page);
    controller.dispose();
    controller = LanDropController(
        receiveDirectory: directory, pendingUploadByteLimit: 20);
    await controller.initialize();
    page = controller.pages.single;
    await controller.start(page);
    port = controller.portFor(page)!;

    final first = await create(fingerprint: 'budget-first', size: 7);
    final second = await create(fingerprint: 'budget-second', size: 4);
    await controller.stop(page);
    controller.dispose();
    controller = LanDropController(
        receiveDirectory: directory, pendingUploadByteLimit: 10);
    await controller.initialize();
    page = controller.pages.single;
    await controller.start(page);
    port = controller.portFor(page)!;

    expect(
        (await request(port, 'PATCH', '/uploads/$first?offset=0', body: [1]))
            .status,
        HttpStatus.tooManyRequests);
    final receivePath = await controller.receiveDirectoryFor(page);
    Future<int> partCount() => Directory(receivePath)
        .list()
        .where((entry) => p.basename(entry.path).endsWith('.part'))
        .length;
    final beforeRejectedCreate = await partCount();
    final rejectedCreate = await request(port, 'POST',
        '/uploads?name=third.txt&size=4&fingerprint=budget-third');
    expect(rejectedCreate.status, HttpStatus.tooManyRequests);
    expect(await partCount(), beforeRejectedCreate);

    await controller.cancelTransfer(second);
    expect(
        (await request(port, 'PATCH', '/uploads/$first?offset=0', body: [1]))
            .status,
        HttpStatus.ok);
    expect(
        (await request(port, 'POST',
                '/uploads?name=third.txt&size=4&fingerprint=budget-third'))
            .status,
        HttpStatus.tooManyRequests);

    await controller.cancelTransfer(first);
    final acceptedCreate = await request(port, 'POST',
        '/uploads?name=third.txt&size=4&fingerprint=budget-third');
    expect(acceptedCreate.status, HttpStatus.created);
    final acceptedId = acceptedCreate.json['id'] as String;
    expect(
        (await request(port, 'PATCH', '/uploads/$acceptedId?offset=0',
                body: [1, 2, 3, 4]))
            .status,
        HttpStatus.ok);
    expect(
        (await request(port, 'POST', '/uploads/$acceptedId/complete')).status,
        HttpStatus.created);
    final afterCompletion = await request(port, 'POST',
        '/uploads?name=fourth.txt&size=4&fingerprint=budget-after-completion');
    expect(afterCompletion.status, HttpStatus.created);
    await controller.cancelTransfer(afterCompletion.json['id'] as String);
  });

  test('bodyless upload controls reject request bodies before side effects',
      () async {
    final id = await create();
    final part = File('${directory.path}/LanDrop/${page.id}/.$id.part');
    final taskCount = controller.transfers.length;
    expect(await part.exists(), isTrue);

    final createWithBody = await request(port, 'POST',
        '/uploads?name=unexpected.txt&size=1&fingerprint=unexpected',
        body: [1]);
    expect(createWithBody.status, 400);
    expect(controller.transfers, hasLength(taskCount));

    expect(
        (await request(port, 'POST', '/uploads/$id/complete', body: [1]))
            .status,
        400);
    expect(
        (await request(port, 'DELETE', '/uploads/$id', body: [1])).status, 400);
    expect((await chunkedRequest(port, 'DELETE', '/uploads/$id')).status, 400);

    final state = await request(port, 'GET', '/uploads/$id');
    expect(state.status, 200);
    expect(state.json['offset'], 0);
    expect(await part.exists(), isTrue);
    expect(controller.transfers, hasLength(taskCount));
    await controller.cancelTransfer(id);
  });

  test('pending upload sessions are bounded app-wide and resumable', () async {
    await controller.stop(page);
    controller.dispose();
    SharedPreferences.setMockInitialValues({});
    controller =
        LanDropController(receiveDirectory: directory, pendingSessionLimit: 2);
    await controller.initialize();
    page = await controller.createPage('Session cap one');
    await controller.start(page);
    port = controller.portFor(page)!;
    final otherPage = await controller.createPage('Session cap two');
    await controller.start(otherPage);
    final otherPort = controller.portFor(otherPage)!;

    final first = await request(
        port, 'POST', '/uploads?name=first.txt&size=10&fingerprint=first');
    final second = await request(otherPort, 'POST',
        '/uploads?name=second.txt&size=10&fingerprint=second');
    expect(first.status, 201);
    expect(second.status, 201);
    final firstId = first.json['id'] as String;
    final secondId = second.json['id'] as String;

    final repeated = await request(
        port, 'POST', '/uploads?name=first.txt&size=10&fingerprint=first');
    expect(repeated.status, 201,
        reason: 'an existing session remains resumable at the global cap');
    expect(repeated.json['id'], firstId);
    final rejected = await request(
        otherPort, 'POST', '/uploads?name=third.txt&size=10&fingerprint=third');
    expect(rejected.status, 429);
    expect(rejected.json['error'], contains('pending upload sessions'));

    await controller.cancelTransfer(firstId);
    final replacement = await request(
        otherPort, 'POST', '/uploads?name=third.txt&size=10&fingerprint=third');
    expect(replacement.status, 201,
        reason: 'cancelling a session releases its global slot');
    await controller.cancelTransfer(secondId);
    await controller.cancelTransfer(replacement.json['id'] as String);
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
        503);
    expect(controller.transfers.first.status, 'paused');
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

  test('ZIP generation is globally bounded and releases capacity', () async {
    await controller.stop(page);
    controller.dispose();
    SharedPreferences.setMockInitialValues({});
    final entered = Completer<void>();
    final release = Completer<void>();
    var buildsEntered = 0;
    controller = LanDropController(
        receiveDirectory: directory,
        beforeZipBuild: () async {
          buildsEntered++;
          if (buildsEntered == 2 && !entered.isCompleted) entered.complete();
          await release.future;
        });
    await controller.initialize();
    page = await controller.createPage('ZIP cap');
    await controller.start(page);
    port = controller.portFor(page)!;
    final otherPage = await controller.createPage('ZIP cap two');
    await controller.start(otherPage);
    final otherPort = controller.portFor(otherPage)!;
    final source = File(p.join(directory.path, 'zip-cap.txt'));
    await source.writeAsString('zip payload');
    await controller.addPaths(page, [source.path]);
    await controller.addPaths(otherPage, [source.path]);

    final first = request(port, 'GET', '/download.zip');
    final second = request(otherPort, 'GET', '/download.zip');
    try {
      await entered.future.timeout(const Duration(seconds: 5));
      expect(controller.activeZipJobsForTesting, 2);
      final rejected = await request(port, 'GET', '/download.zip');
      expect(rejected.status, 429);
      expect(buildsEntered, 2);
      expect(rejected.headers, contains('retry-after: 2'));
      expect(
          rejected.headers, contains('content-type: text/html; charset=utf-8'));
      expect(rejected.headers, contains("default-src 'none'"));
      final busyHtml = utf8.decode(rejected.bytes);
      expect(busyHtml, contains('ZIP 打包任务较多'));
      expect(busyHtml, contains('href="/"'));
      expect(busyHtml, contains('role="status"'));
      expect(busyHtml, contains('@media(prefers-color-scheme:dark)'));
      expect(busyHtml, isNot(contains('<script')));
    } finally {
      if (!release.isCompleted) release.complete();
    }

    final results = await Future.wait([first, second]);
    expect(results.every((result) => result.status == 200), isTrue);
    for (final result in results) {
      expect(result.bytes.take(2).toList(), [0x50, 0x4b]);
    }
    await until(() => controller.activeZipJobsForTesting == 0);
    final afterRelease = await request(otherPort, 'GET', '/download.zip');
    expect(afterRelease.status, 200);
    expect(afterRelease.bytes.take(2).toList(), [0x50, 0x4b]);
  });

  test('stopping a page cancels ZIP preparation before worker spawn', () async {
    await controller.stop(page);
    controller.dispose();
    SharedPreferences.setMockInitialValues({});
    final entered = Completer<void>();
    final release = Completer<void>();
    var buildsEntered = 0;
    controller = LanDropController(
        receiveDirectory: directory,
        beforeZipBuild: () async {
          buildsEntered++;
          if (buildsEntered == 1) {
            entered.complete();
            await release.future;
          }
        });
    await controller.initialize();
    page = await controller.createPage('ZIP cancellation');
    await controller.start(page);
    port = controller.portFor(page)!;
    final source = File(p.join(directory.path, 'zip-cancel.txt'));
    await source.writeAsString('do not build after stop');
    await controller.addPaths(page, [source.path]);

    final pending = request(port, 'GET', '/download.zip');
    await entered.future.timeout(const Duration(seconds: 5));
    final task = controller.transfers.single;
    final stopping = controller.stop(page);
    Future<void> expectNotAdmitted(String method, String path,
        {List<int> body = const []}) async {
      try {
        expect((await request(port, method, path, body: body)).status, 503);
      } on SocketException {
        // Graceful close stopped accepting before this connection arrived.
      }
    }

    try {
      await until(() => task.status == 'cancelled');
      await expectNotAdmitted('GET', '/download.zip');
      await expectNotAdmitted(
          'POST', '/uploads?name=late.txt&size=1&fingerprint=late',
          body: [1]);
      expect(controller.transfers, hasLength(1));
      expect(buildsEntered, 1);
      expect(controller.activeZipJobsForTesting, 1);
    } finally {
      if (!release.isCompleted) release.complete();
    }
    await stopping;

    expect((await pending).status, 400);
    expect(buildsEntered, 1);
    expect(controller.zipWorkerSpawnCountForTesting, 0);
    expect(controller.activeZipJobsForTesting, 0);
    expect(task.status, 'cancelled');
  });

  test('browser ZIP cancel token aborts preparation and is same-origin only',
      () async {
    await controller.stop(page);
    controller.dispose();
    SharedPreferences.setMockInitialValues({});
    final entered = Completer<void>();
    final release = Completer<void>();
    controller = LanDropController(
        receiveDirectory: directory,
        beforeZipBuild: () async {
          entered.complete();
          await release.future;
        });
    await controller.initialize();
    page = await controller.createPage('Cooperative ZIP cancellation');
    await controller.start(page);
    port = controller.portFor(page)!;
    final source = File(p.join(directory.path, 'zip-cancel-token.txt'));
    await source.writeAsString('cancelled from pagehide');
    await controller.addPaths(page, [source.path]);
    const token = '35bd1547-cae0-4b5e-9662-2f24b2ef6e89';
    const preCancelledToken = '45bd1547-cae0-4b5e-9662-2f24b2ef6e89';
    final origin = 'Origin: http://127.0.0.1:$port\r\n'
        'Sec-Fetch-Site: same-origin\r\n';

    expect(
        (await request(port, 'POST', '/download.zip/cancel?job=$token',
                extra: 'Origin: http://evil.example\r\n'
                    'Sec-Fetch-Site: cross-site\r\n'))
            .status,
        403);
    expect(
        (await request(port, 'POST', '/download.zip/cancel?job=$token')).status,
        403,
        reason: 'browser cancellation requires a same-origin POST');
    expect(
        (await request(port, 'POST', '/download.zip/cancel?job=not-a-uuid',
                extra: origin))
            .status,
        400);
    expect(
        (await request(
                port, 'POST', '/download.zip/cancel?job=$preCancelledToken',
                extra: origin))
            .status,
        204,
        reason: 'unknown tokens are idempotent and disclose no job state');
    expect(
        (await request(port, 'GET', '/download.zip?job=$preCancelledToken'))
            .status,
        400,
        reason: 'a cancellation beacon arriving before its GET must win');
    expect(
        (await request(port, 'GET', '/download.zip?job=$preCancelledToken'))
            .status,
        400,
        reason:
            'consumed tokens remain unavailable during tombstone retention');
    expect(
        (await request(port, 'POST', '/download.zip/cancel?job=$token',
                body: [1], extra: origin))
            .status,
        400);
    expect(
        (await request(port, 'GET', '/download.zip/cancel?job=$token')).status,
        405);

    final pending = request(port, 'GET', '/download.zip?job=$token');
    await entered.future.timeout(const Duration(seconds: 5));
    final task = controller.transfers.single;
    expect((await request(port, 'GET', '/download.zip?job=$token')).status, 409,
        reason: 'a client cancellation token cannot name two live jobs');
    final cancellation =
        request(port, 'POST', '/download.zip/cancel?job=$token', extra: origin);
    try {
      await until(() => task.status == 'cancelled');
      expect(controller.zipWorkerSpawnCountForTesting, 0);
      release.complete();
      expect((await cancellation).status, 204);
      expect((await pending).status, 400);
      expect(
          (await request(port, 'GET', '/download.zip?job=$token')).status, 400,
          reason: 'a completed cancellation token must not restart ZIP work');
      await until(() => controller.activeZipJobsForTesting == 0);
    } finally {
      if (!release.isCompleted) release.complete();
    }
  });

  test('browser ZIP cancel token interrupts an active response stream',
      () async {
    await controller.stop(page);
    controller.dispose();
    SharedPreferences.setMockInitialValues({});
    final entered = Completer<void>();
    final release = Completer<void>();
    controller = LanDropController(
        receiveDirectory: directory,
        beforeZipStream: () async {
          entered.complete();
          await release.future;
        });
    await controller.initialize();
    page = await controller.createPage('Cancel active ZIP stream');
    await controller.start(page);
    port = controller.portFor(page)!;
    final source = File(p.join(directory.path, 'zip-stream-cancel.txt'));
    await source.writeAsString('stop before response bytes are written');
    await controller.addPaths(page, [source.path]);
    const token = '55bd1547-cae0-4b5e-9662-2f24b2ef6e89';
    final origin = 'Origin: http://127.0.0.1:$port\r\n'
        'Sec-Fetch-Site: same-origin\r\n';
    final pending = request(port, 'GET', '/download.zip?job=$token');
    await entered.future.timeout(const Duration(seconds: 5));
    final task = controller.transfers.single;
    final cancellation =
        request(port, 'POST', '/download.zip/cancel?job=$token', extra: origin);
    try {
      await until(() => task.status == 'cancelled');
      expect(controller.zipWorkerSpawnCountForTesting, 1,
          reason:
              'archive generation has completed before stream cancellation');
      release.complete();
      expect((await cancellation).status, 204);
      try {
        await pending;
      } catch (_) {
        // The intentionally cancelled TCP response may end without an HTTP body.
      }
      await until(() => controller.activeZipJobsForTesting == 0);
      expect(
          (await request(port, 'GET', '/download.zip?job=$token')).status, 400,
          reason:
              'the token cannot restart after a streamed download is cancelled');
      expect(task.status, 'cancelled');
    } finally {
      if (!release.isCompleted) release.complete();
    }
  });

  test('stop closes idle persistent connections without hanging', () async {
    final socket = await Socket.connect(InternetAddress.loopbackIPv4, port);
    final closed = Completer<void>();
    try {
      final response = await keepAliveRequest(socket, port, 'GET', '/manifest',
          onClosed: closed);
      expect(response.status, 200);
      final stopping = controller.stop(page);
      await stopping.timeout(const Duration(seconds: 5));
      await closed.future.timeout(const Duration(seconds: 5));
      expect(controller.portFor(page), isNull);
      expect(page.running, isFalse);
    } finally {
      socket.destroy();
    }
  });

  test('stop and remove wait for in-flight server registration', () async {
    for (final removePageAfterBind in [false, true]) {
      await controller.stop(page);
      controller.dispose();
      SharedPreferences.setMockInitialValues({});
      final registrationEntered = Completer<void>();
      final releaseRegistration = Completer<void>();
      var registrationCount = 0;
      controller = LanDropController(
          receiveDirectory: directory,
          beforeServerRegistration: () async {
            registrationCount++;
            if (registrationCount == 1) {
              registrationEntered.complete();
              await releaseRegistration.future;
            }
          });
      await controller.initialize();
      page = await controller.createPage('Pending bind');

      final starting = controller.start(page);
      await registrationEntered.future.timeout(const Duration(seconds: 5));
      expect(controller.portFor(page), isNull);
      final teardownFinished = Completer<void>();
      final teardown = (removePageAfterBind
              ? controller.removePage(page)
              : controller.stop(page))
          .then((_) => teardownFinished.complete());
      try {
        await Future<void>.delayed(Duration.zero);
        expect(teardownFinished.isCompleted, isFalse);
      } finally {
        if (!releaseRegistration.isCompleted) {
          releaseRegistration.complete();
        }
      }
      await Future.wait([starting, teardown]);

      expect(controller.portFor(page), isNull);
      expect(page.running, isFalse);
      expect(registrationCount, 1);
      if (removePageAfterBind) {
        expect(controller.pages.any((candidate) => candidate.id == page.id),
            isFalse);
      } else {
        await controller.start(page);
        expect(controller.portFor(page), isNotNull);
        expect(registrationCount, 2);
        await controller.stop(page);
      }
    }
  });

  test('start cannot resurrect a page during removal cleanup', () async {
    await controller.stop(page);
    controller.dispose();
    SharedPreferences.setMockInitialValues({});
    final removalEntered = Completer<void>();
    final releaseRemoval = Completer<void>();
    controller = LanDropController(
        receiveDirectory: directory,
        beforePageRemoval: () async {
          removalEntered.complete();
          await releaseRemoval.future;
        });
    await controller.initialize();
    page = await controller.createPage('Removal barrier');
    await controller.start(page);
    port = controller.portFor(page)!;

    final removal = controller.removePage(page);
    await removalEntered.future.timeout(const Duration(seconds: 5));
    expect(controller.portFor(page), isNull);
    await controller.start(page);
    expect(controller.portFor(page), isNull);
    expect(page.running, isFalse);

    releaseRemoval.complete();
    await removal;
    expect(
        controller.pages.any((candidate) => candidate.id == page.id), isFalse);
    expect(controller.portFor(page), isNull);
    expect(page.running, isFalse);
    await controller.start(page);
    expect(controller.portFor(page), isNull);
    expect(page.running, isFalse);
  });

  test('canceling a ZIP response waits for archive cleanup', () async {
    await controller.stop(page);
    controller.dispose();
    SharedPreferences.setMockInitialValues({});
    final cleanupEntered = Completer<void>();
    final releaseCleanup = Completer<void>();
    controller = LanDropController(
        receiveDirectory: directory,
        beforeZipCleanup: () async {
          if (!cleanupEntered.isCompleted) cleanupEntered.complete();
          await releaseCleanup.future;
        });
    await controller.initialize();
    page = await controller.createPage('ZIP stream cancellation');
    await controller.start(page);
    port = controller.portFor(page)!;
    final source = File(p.join(directory.path, 'zip-stream.bin'));
    final payload = Uint8List(8 * 1024 * 1024);
    var state = 0x12345678;
    for (var i = 0; i < payload.length; i++) {
      state = (1664525 * state + 1013904223) & 0xffffffff;
      payload[i] = state >> 24;
    }
    await source.writeAsBytes(payload);
    await controller.addPaths(page, [source.path]);

    Socket? client;
    Future<void>? cancel;
    final cancelFinished = Completer<void>();
    try {
      client = await Socket.connect(InternetAddress.loopbackIPv4, port);
      client.write(
          'GET /download.zip HTTP/1.1\r\nHost: 127.0.0.1:$port\r\nConnection: close\r\n\r\n');
      await client.flush();
      await until(() => controller.transfers.any((task) =>
          task.direction == 'download' &&
          task.status == 'active' &&
          task.transferredBytes > 0));
      final task = controller.transfers.firstWhere(
          (task) => task.direction == 'download' && task.status == 'active');
      cancel = controller.cancelTransfer(task.id).then((_) {
        if (!cancelFinished.isCompleted) cancelFinished.complete();
      });
      await cleanupEntered.future.timeout(const Duration(seconds: 5));
      await Future<void>.delayed(Duration.zero);
      expect(cancelFinished.isCompleted, isFalse,
          reason: 'cancel waits until the ZIP temp directory is released');
      if (!releaseCleanup.isCompleted) releaseCleanup.complete();
      await cancel;
      expect(task.status, 'cancelled');
      expect(controller.activeZipJobsForTesting, 0);
    } finally {
      if (!releaseCleanup.isCompleted) releaseCleanup.complete();
      await cancel;
      client?.destroy();
    }
  });

  test('canceling a completed ZIP during cleanup preserves its status',
      () async {
    await controller.stop(page);
    controller.dispose();
    SharedPreferences.setMockInitialValues({});
    final cleanupEntered = Completer<void>();
    final releaseCleanup = Completer<void>();
    controller = LanDropController(
        receiveDirectory: directory,
        beforeZipCleanup: () async {
          if (!cleanupEntered.isCompleted) cleanupEntered.complete();
          await releaseCleanup.future;
        });
    await controller.initialize();
    page = await controller.createPage('ZIP completed cleanup');
    await controller.start(page);
    port = controller.portFor(page)!;
    final source = File(p.join(directory.path, 'zip-complete.txt'));
    await source.writeAsString('completed response');
    await controller.addPaths(page, [source.path]);

    final response = await request(port, 'GET', '/download.zip');
    expect(response.status, 200);
    await cleanupEntered.future.timeout(const Duration(seconds: 5));
    final task = controller.transfers.single;
    expect(task.status, 'completed');
    final cancelFinished = Completer<void>();
    final cancel = controller.cancelTransfer(task.id).then((_) {
      if (!cancelFinished.isCompleted) cancelFinished.complete();
    });
    try {
      await Future<void>.delayed(Duration.zero);
      expect(cancelFinished.isCompleted, isFalse);
      expect(task.status, 'completed');
    } finally {
      if (!releaseCleanup.isCompleted) releaseCleanup.complete();
    }
    await cancel;
    expect(task.status, 'completed');
    expect(controller.activeZipJobsForTesting, 0);
  });

  test('canceling a failed ZIP during cleanup preserves its status', () async {
    await controller.stop(page);
    controller.dispose();
    SharedPreferences.setMockInitialValues({});
    final cleanupEntered = Completer<void>();
    final releaseCleanup = Completer<void>();
    late File source;
    controller = LanDropController(
        receiveDirectory: directory,
        beforeZipBuild: () async {
          await source.delete();
        },
        beforeZipCleanup: () async {
          if (!cleanupEntered.isCompleted) cleanupEntered.complete();
          await releaseCleanup.future;
        });
    await controller.initialize();
    page = await controller.createPage('ZIP failed cleanup');
    await controller.start(page);
    port = controller.portFor(page)!;
    source = File(p.join(directory.path, 'zip-failed.txt'));
    await source.writeAsString('will be removed after validation');
    await controller.addPaths(page, [source.path]);

    final response = await request(port, 'GET', '/download.zip');
    expect(response.status, 500);
    await cleanupEntered.future.timeout(const Duration(seconds: 5));
    final task = controller.transfers.single;
    expect(task.status, 'failed');
    final cancelFinished = Completer<void>();
    final cancel = controller.cancelTransfer(task.id).then((_) {
      if (!cancelFinished.isCompleted) cancelFinished.complete();
    });
    try {
      await Future<void>.delayed(Duration.zero);
      expect(cancelFinished.isCompleted, isFalse);
      expect(task.status, 'failed');
    } finally {
      if (!releaseCleanup.isCompleted) releaseCleanup.complete();
    }
    await cancel;
    expect(task.status, 'failed');
    expect(controller.activeZipJobsForTesting, 0);
  });

  test('upload admitted before stop receives service unavailable', () async {
    await controller.stop(page);
    controller.dispose();
    SharedPreferences.setMockInitialValues({});
    final serveEntered = Completer<void>();
    final releaseServe = Completer<void>();
    controller = LanDropController(
        receiveDirectory: directory,
        beforeHttpServe: () async {
          serveEntered.complete();
          await releaseServe.future;
        });
    await controller.initialize();
    page = await controller.createPage('Stopping upload');
    await controller.start(page);
    port = controller.portFor(page)!;

    final pendingRequest =
        request(port, 'POST', '/upload?name=stopping.txt', body: [1, 2, 3]);
    await serveEntered.future.timeout(const Duration(seconds: 5));
    final stopping = controller.stop(page);
    try {
      await until(() => controller.portFor(page) == null);
      releaseServe.complete();
      final reply = await pendingRequest;
      expect(reply.status, HttpStatus.serviceUnavailable);
      expect(reply.json['error'], contains('停止'));
      await stopping;
    } finally {
      if (!releaseServe.isCompleted) releaseServe.complete();
    }
  });

  test('rejected HTTP responses have a separate concurrency budget', () async {
    await controller.stop(page);
    controller.dispose();
    SharedPreferences.setMockInitialValues({});
    final serveEntered = Completer<void>();
    final releaseServe = Completer<void>();
    final rejectEntered = Completer<void>();
    final releaseReject = Completer<void>();
    var serveCalls = 0;
    var rejectBodyCalls = 0;
    controller = LanDropController(
        receiveDirectory: directory,
        httpRequestLimit: 1,
        httpRejectionLimit: 1,
        beforeHttpServe: () async {
          serveCalls++;
          if (serveCalls == 1) {
            serveEntered.complete();
            await releaseServe.future;
          }
        },
        beforeHttpRejectBody: () async {
          rejectBodyCalls++;
          if (rejectBodyCalls == 1) {
            rejectEntered.complete();
            await releaseReject.future;
          }
        });
    await controller.initialize();
    page = await controller.createPage('HTTP rejection cap');
    await controller.start(page);
    port = controller.portFor(page)!;

    final active = request(port, 'GET', '/manifest');
    await serveEntered.future.timeout(const Duration(seconds: 5));
    final rejectedBody = request(
        port, 'POST', '/uploads?name=blocked.txt&size=1&fingerprint=blocked',
        body: [1]);
    try {
      await rejectEntered.future.timeout(const Duration(seconds: 5));
      expect(controller.activeHttpRejectionsForTesting, 1);
      final fastRejected = await request(port, 'GET', '/manifest');
      expect(fastRejected.status, 429);
      expect(fastRejected.bytes, isEmpty);
      try {
        final fastBodyRejected = await request(
            port, 'POST', '/uploads?name=fast.txt&size=1&fingerprint=fast',
            body: [1]);
        expect(fastBodyRejected.status, 429);
        expect(fastBodyRejected.bytes, isEmpty);
      } on SocketException {
        // The rejection budget is exhausted, so unread bodies may reset.
      }
      expect(controller.activeHttpRejectionsForTesting, 1);
      expect(rejectBodyCalls, 1);
    } finally {
      if (!releaseReject.isCompleted) releaseReject.complete();
      if (!releaseServe.isCompleted) releaseServe.complete();
    }

    final replies = await Future.wait([active, rejectedBody]);
    expect(replies[0].status, 200);
    expect(replies[1].status, 429);
    await until(() => controller.activeHttpRejectionsForTesting == 0);
    expect(controller.activeHttpRequestsForTesting, 0);
    expect(controller.activeHttpRejectionsForTesting, 0);
    expect(controller.transfers, isEmpty);
  });

  test('HTTP request handlers are bounded app-wide and release capacity',
      () async {
    await controller.stop(page);
    controller.dispose();
    SharedPreferences.setMockInitialValues({});
    final entered = Completer<void>();
    final release = Completer<void>();
    var calls = 0;
    controller = LanDropController(
        receiveDirectory: directory,
        httpRequestLimit: 2,
        beforeHttpServe: () async {
          calls++;
          if (calls <= 2) {
            if (calls == 2) entered.complete();
            await release.future;
          }
        });
    await controller.initialize();
    page = await controller.createPage('HTTP cap one');
    await controller.start(page);
    port = controller.portFor(page)!;
    final otherPage = await controller.createPage('HTTP cap two');
    await controller.start(otherPage);
    final otherPort = controller.portFor(otherPage)!;

    final first = request(port, 'GET', '/manifest');
    final second = request(otherPort, 'GET', '/manifest');
    try {
      await entered.future.timeout(const Duration(seconds: 5));
      expect(controller.activeHttpRequestsForTesting, 2);
      final rejected = await request(port, 'GET', '/manifest');
      expect(rejected.status, 429);
      expect(rejected.headers, contains('retry-after: 2'));
      expect(rejected.json['error'], contains('in-flight requests'));
      final headRejected = await request(port, 'HEAD', '/manifest');
      expect(headRejected.status, 429);
      expect(headRejected.headers, contains('retry-after: 2'));
      expect(headRejected.headers, contains('content-type: application/json'));
      expect(headRejected.bytes, isEmpty);
      final headBodyRejected =
          await request(port, 'HEAD', '/manifest', body: [1]);
      expect(headBodyRejected.status, 429);
      expect(headBodyRejected.bytes, isEmpty);
      expect(calls, 2);
    } finally {
      if (!release.isCompleted) release.complete();
    }

    final responses = await Future.wait([first, second]);
    expect(responses.every((response) => response.status == 200), isTrue);
    await until(() => controller.activeHttpRequestsForTesting == 0);
    final afterRelease = await request(otherPort, 'GET', '/manifest');
    expect(afterRelease.status, 200);
    expect(controller.activeHttpRequestsForTesting, 0);
  });

  test('single-file downloads are globally bounded across pages', () async {
    await controller.stop(page);
    controller.dispose();
    SharedPreferences.setMockInitialValues({});
    final entered = Completer<void>();
    final release = Completer<void>();
    var streamsEntered = 0;
    controller = LanDropController(
        receiveDirectory: directory,
        fileDownloadLimit: 2,
        beforeFileStream: () async {
          streamsEntered++;
          if (streamsEntered == 2 && !entered.isCompleted) entered.complete();
          await release.future;
        });
    await controller.initialize();
    page = await controller.createPage('File cap');
    await controller.start(page);
    port = controller.portFor(page)!;
    final otherPage = await controller.createPage('File cap two');
    await controller.start(otherPage);
    final otherPort = controller.portFor(otherPage)!;
    final source = File(p.join(directory.path, 'file-cap.txt'));
    await source.writeAsString('download payload');
    await controller.addPaths(page, [source.path]);
    await controller.addPaths(otherPage, [source.path]);

    final first = request(port, 'GET', '/file/${page.files.single.id}');
    final second =
        request(otherPort, 'GET', '/file/${otherPage.files.single.id}');
    try {
      await entered.future.timeout(const Duration(seconds: 5));
      expect(controller.activeFileDownloadsForTesting, 2);
      final rejected = request(port, 'GET', '/file/${page.files.single.id}');
      final reply = await rejected;
      expect(reply.status, 429);
      expect(reply.headers, contains('retry-after: 2'));
      expect(reply.json['error'], contains('下载'));
      expect(streamsEntered, 2);
    } finally {
      if (!release.isCompleted) release.complete();
    }

    final results = await Future.wait([first, second]);
    expect(results.every((result) => result.status == 200), isTrue);
    expect(
        results
            .every((result) => utf8.decode(result.bytes) == 'download payload'),
        isTrue);
    await until(() => controller.activeFileDownloadsForTesting == 0);
    final afterRelease =
        await request(otherPort, 'GET', '/file/${otherPage.files.single.id}');
    expect(afterRelease.status, 200);
    expect(utf8.decode(afterRelease.bytes), 'download payload');
  });

  test('ZIP worker rejects a path replaced after source validation', () async {
    final selectedRoot = Directory(p.join(directory.path, 'worker-selected'));
    final selectedSub = Directory(p.join(selectedRoot.path, 'sub'));
    await selectedSub.create(recursive: true);
    final source = File(p.join(selectedSub.path, 'a.txt'));
    await source.writeAsString('inside!!');
    final expectedSource = await source.resolveSymbolicLinks();
    final movedRoot = p.join(directory.path, 'worker-moved');
    final outsideRoot = Directory(p.join(directory.path, 'worker-outside'));
    await Directory(p.join(outsideRoot.path, 'sub')).create(recursive: true);
    final outsideSource = File(p.join(outsideRoot.path, 'sub', 'a.txt'));
    await outsideSource.writeAsString('secret!!');
    await selectedRoot.rename(movedRoot);
    await Link(selectedRoot.path).create(outsideRoot.path);

    final output = File(p.join(directory.path, 'worker-replaced.zip'));
    final cancellation = File(p.join(directory.path, 'worker-replaced-cancel'));
    final messages = ReceivePort();
    final exits = ReceivePort();
    final result = messages.first;
    final exited = exits.first;
    await Isolate.spawn(
        buildZipWorker,
        <Object>[
          messages.sendPort,
          output.path,
          [
            [source.path, 'a.txt', expectedSource]
          ],
          cancellation.path,
        ],
        onExit: exits.sendPort);
    try {
      final reply = await result.timeout(const Duration(seconds: 5)) as Map;
      expect(reply['error'], contains('Unsafe archive source'));
      await exited.timeout(const Duration(seconds: 5));
      expect(await output.length(), 0);
      expect(await File(p.join(movedRoot, 'sub', 'a.txt')).readAsString(),
          'inside!!');
      expect(await outsideSource.readAsString(), 'secret!!');
    } finally {
      messages.close();
      exits.close();
      if (await output.exists()) await output.delete();
    }
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
    await controller.addFiles(page, [
      LocalTestFile(source, 'validator.txt', withoutPath: true),
    ]);
    final managedSource = File(page.files.single.path);
    await managedSource.setLastModified(DateTime.utc(2025, 1, 2, 3, 4, 5));
    final path = '/file/${page.files.single.id}';
    final whole = await request(port, 'GET', path);
    final etag = RegExp(r'^etag: (.+)$', multiLine: true)
        .firstMatch(whole.headers)!
        .group(1)!
        .trim();
    final modified = HttpDate.format(await managedSource.lastModified());
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
    await managedSource.writeAsString('abcdefghij');
    await managedSource.setLastModified(DateTime.utc(2025, 1, 2, 3, 4, 6));
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

  test(
      'session completion retries with a suffix instead of replacing a late file',
      () async {
    final id = await create(size: 3, name: 'race.txt');
    final partials = await Directory(directory.path)
        .list(recursive: true, followLinks: false)
        .where((entity) => p.basename(entity.path) == '.$id.part')
        .toList();
    expect(partials, hasLength(1));
    final partial = partials.single as File;
    final chunk =
        await request(port, 'PATCH', '/uploads/$id?offset=0', body: [1, 2, 3]);
    expect(chunk.status, 200);

    final occupiedPath = p.join(partial.parent.path, 'race.txt');
    injectNextReceivePublishCollisionForTest(
        occupiedPath, 'preserve this occupant');
    final completed = await request(port, 'POST', '/uploads/$id/complete');
    expect(completed.status, 201);
    expect(completed.json['name'], 'race (1).txt');
    expect(await File(occupiedPath).readAsString(), 'preserve this occupant');
    expect(
        await File(p.join(partial.parent.path, 'race (1).txt')).readAsBytes(),
        [1, 2, 3]);
    expect(await partial.exists(), isFalse);
  });

  test('failed receipt persistence rolls back received records across restart',
      () async {
    final id = await create(size: 3);
    final partials = await Directory(directory.path)
        .list(recursive: true, followLinks: false)
        .where((entity) => p.basename(entity.path) == '.$id.part')
        .toList();
    expect(partials, hasLength(1));
    final partial = partials.single as File;
    final chunk =
        await request(port, 'PATCH', '/uploads/$id?offset=0', body: [1, 2, 3]);
    expect(chunk.status, 200);
    expect(await partial.readAsBytes(), [1, 2, 3]);
    controller.beforePersistKey = (key) async {
      if (key == 'landrop.uploadReceipts.v1') {
        throw const FileSystemException('injected receipt persistence failure');
      }
    };

    final failed = await request(port, 'POST', '/uploads/$id/complete');
    expect(failed.status, 500);
    expect(controller.receivedFiles, isEmpty);
    expect(await partial.exists(), isTrue);
    expect(await partial.readAsBytes(), [1, 2, 3],
        reason: 'rollback must restore the same resumable partial');
    final preferences = await SharedPreferences.getInstance();
    expect(jsonDecode(preferences.getString('landrop.received.v1') ?? '[]'),
        isEmpty,
        reason: 'compensation must remove the partially committed file record');

    final previousController = controller;
    previousController.beforePersistKey = null;
    await previousController.shutdown();
    previousController.dispose();
    controller = LanDropController(receiveDirectory: directory);
    controller.fileDirectoryForTesting =
        Directory(p.join(directory.path, 'managed-files'));
    await controller.initialize();
    page = controller.pages.single;
    port = controller.portFor(page)!;

    expect(controller.receivedFiles, isEmpty,
        reason: 'restart must not restore a record for the rolled-back file');
    final resumable = await request(port, 'GET', '/uploads/$id');
    expect(resumable.status, 200);
    expect(resumable.json['offset'], 3);
    final retry = await request(port, 'POST', '/uploads/$id/complete');
    expect(retry.status, 201);
    expect(controller.receivedFiles, hasLength(1));
    expect(await File(controller.receivedFiles.single.path).readAsBytes(),
        [1, 2, 3]);
  });

  test('lost session publish response restores the pinned partial', () async {
    final id = await create(size: 3, name: 'lost-session.txt');
    final partials = await Directory(directory.path)
        .list(recursive: true, followLinks: false)
        .where((entity) => p.basename(entity.path) == '.$id.part')
        .toList();
    expect(partials, hasLength(1));
    final partial = partials.single as File;
    final chunk =
        await request(port, 'PATCH', '/uploads/$id?offset=0', body: [1, 2, 3]);
    expect(chunk.status, 200);
    failNextReceivePublishAfterMoveForTest(
        p.join(partial.parent.path, 'lost-session.txt'));

    final failed = await request(port, 'POST', '/uploads/$id/complete');
    expect(failed.status, 500);
    expect(await partial.readAsBytes(), [1, 2, 3]);
    expect(await File(p.join(partial.parent.path, 'lost-session.txt')).exists(),
        isFalse);
    expect(controller.receivedFiles, isEmpty);
    final resumable = await request(port, 'GET', '/uploads/$id');
    expect(resumable.status, 200);
    expect(resumable.json['offset'], 3);
  });

  test('failed session rollback preserves partial-path occupants and data',
      () async {
    final id = await create(size: 3, name: 'restore-failure.bin');
    final partials = await Directory(directory.path)
        .list(recursive: true, followLinks: false)
        .where((entity) => p.basename(entity.path) == '.$id.part')
        .toList();
    expect(partials, hasLength(1));
    final partial = partials.single as File;
    final chunk =
        await request(port, 'PATCH', '/uploads/$id?offset=0', body: [1, 2, 3]);
    expect(chunk.status, 200);

    var injected = false;
    controller.beforePersistKey = (key) async {
      if (!injected && key == 'landrop.uploadReceipts.v1') {
        injected = true;
        await partial.writeAsString('preserve this partial-path occupant');
        replaceMockReceiveLeafIdentity(partial.path);
        throw const FileSystemException('injected receipt persistence failure');
      }
    };

    final failed = await request(port, 'POST', '/uploads/$id/complete');
    expect(failed.status, 500);
    expect(await partial.readAsString(), 'preserve this partial-path occupant');
    expect(
        await File(p.join(partial.parent.path, 'restore-failure.bin'))
            .readAsBytes(),
        [1, 2, 3],
        reason: 'the published data must survive failed no-replace rollback');
    expect(controller.receivedFiles, isEmpty);
    expect(controller.pageRecoveryWarnings[page.id], isNotNull);
    expect(controller.transfers.singleWhere((task) => task.id == id).status,
        'failed');
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

  test('stalled raw and resumable uploads time out without losing sessions',
      () async {
    await controller.stop(page);
    controller.dispose();
    SharedPreferences.setMockInitialValues({});
    controller = LanDropController(
        receiveDirectory: directory,
        uploadIdleTimeout: const Duration(milliseconds: 20));
    await controller.initialize();
    page = await controller.createPage('Idle timeout');
    await controller.start(page);
    port = controller.portFor(page)!;

    Future<String> stalledResponse(
        String requestLine, int contentLength) async {
      final socket = await Socket.connect(InternetAddress.loopbackIPv4, port);
      final response =
          socket.fold<List<int>>(<int>[], (out, chunk) => out..addAll(chunk));
      socket.write('$requestLine\r\n'
          'Host: 127.0.0.1:$port\r\n'
          'Content-Length: $contentLength\r\n'
          'Connection: close\r\n\r\n');
      return utf8.decode(await response.timeout(const Duration(seconds: 2)));
    }

    final raw =
        await stalledResponse('POST /upload?name=stalled.txt HTTP/1.1', 1024);
    expect(raw, contains('408 Request Time-out'));
    expect(raw, contains('上传长时间无数据'));
    expect((await upload(port, 'after-timeout.txt', 'ok')).$1, 201);

    final id = await create(fingerprint: 'stalled-session', size: 6);
    final patch =
        await stalledResponse('PATCH /uploads/$id?offset=0 HTTP/1.1', 6);
    expect(patch, contains('408 Request Time-out'));
    expect(patch, contains('上传长时间无数据'));
    // The 408 can reach the client before Windows finishes its async request
    // cleanup and releases the per-session busy lock.
    await until(() => controller.uploadRegistryPageCountForTesting == 0);
    expect((await request(port, 'GET', '/uploads/$id')).json['offset'], 0);
    final resumed = await request(port, 'PATCH', '/uploads/$id?offset=0',
        body: [97, 98, 99, 100, 101, 102]);
    expect(resumed.status, 200);
    expect((await request(port, 'POST', '/uploads/$id/complete')).status, 201);
  });

  test('terminal task history is bounded without dropping live sessions',
      () async {
    final retainedId = await create(fingerprint: 'retained-session', size: 4);
    final retainedTask =
        controller.transfers.firstWhere((task) => task.id == retainedId);
    final stalled = await Socket.connect(InternetAddress.loopbackIPv4, port);
    stalled.write('POST /upload?name=held.txt HTTP/1.1\r\n'
        'Host: 127.0.0.1:$port\r\n'
        'Content-Length: 1048576\r\n'
        'Connection: close\r\n\r\n');
    try {
      await until(() => controller.transfers
          .any((task) => task.name == 'held.txt' && task.status == 'active'));
      final activeTask =
          controller.transfers.firstWhere((task) => task.name == 'held.txt');
      final paths = <String>[];
      for (var i = 0; i < 140; i++) {
        final file = File(p.join(directory.path, 'bulk-$i.txt'));
        await file.writeAsString('x');
        paths.add(file.path);
      }
      await controller.addPaths(page, paths);
      for (final file in page.files.toList()) {
        expect((await request(port, 'GET', '/file/${file.id}')).status, 200);
      }

      expect(
          controller.transfers
              .where((task) => task.status == 'completed')
              .length,
          128);
      expect(controller.transfers, hasLength(130));
      expect(controller.transfers.contains(activeTask), true);
      expect(controller.transfers.contains(retainedTask), true);
      expect(retainedTask.status, 'paused');

      final cancelId = await create(fingerprint: 'cancel-session', size: 1);
      final cancelTask =
          controller.transfers.firstWhere((task) => task.id == cancelId);
      await controller.cancelTransfer(cancelId);
      expect(cancelTask.status, 'cancelled');
      expect((await request(port, 'GET', '/uploads/$cancelId')).status, 404);

      final resumed = await request(
          port, 'PATCH', '/uploads/$retainedId?offset=0',
          body: [100, 97, 116, 97]);
      expect(resumed.status, 200);
      expect(
          (await request(port, 'POST', '/uploads/$retainedId/complete')).status,
          201);
      expect(controller.transfers.contains(activeTask), true);
    } finally {
      stalled.destroy();
      await controller.stop(page).timeout(const Duration(seconds: 3));
    }
  });

  test('concurrent upload streams are globally bounded across pages', () async {
    final other = await controller.createPage('Other');
    await controller.start(other);
    final otherPort = controller.portFor(other)!;
    final created = await request(otherPort, 'POST',
        '/uploads?name=cap.txt&size=1&fingerprint=global-limit');
    expect(created.status, 201);
    final sessionId = created.json['id'] as String;
    final sockets = <Socket>[];
    Future<void> openStalledUpload(int targetPort, String name) async {
      final socket =
          await Socket.connect(InternetAddress.loopbackIPv4, targetPort);
      sockets.add(socket);
      socket.write('POST /upload?name=$name HTTP/1.1\r\n'
          'Host: 127.0.0.1:$targetPort\r\n'
          'Content-Length: 1048576\r\n'
          'Connection: close\r\n\r\n');
    }

    try {
      for (var i = 0; i < 4; i++) {
        await openStalledUpload(port, 'held-a-$i');
        await openStalledUpload(otherPort, 'held-b-$i');
      }
      await until(() =>
          controller.transfers
              .where((task) => task.status == 'active')
              .length ==
          8);
      final rejected = await request(
          otherPort, 'PATCH', '/uploads/$sessionId?offset=0',
          body: [65]);
      expect(rejected.status, 429);
      expect(rejected.json['error'], '当前上传任务较多，请稍后重试');
      expect(rejected.json['offset'], 0);
      expect(
          (await request(otherPort, 'GET', '/uploads/$sessionId'))
              .json['offset'],
          0);
      expect(controller.receivedFiles, isEmpty);
    } finally {
      for (final socket in sockets) {
        socket.destroy();
      }
      await Future.wait([controller.stop(page), controller.stop(other)])
          .timeout(const Duration(seconds: 3));
    }
  });

  test('rejected nonempty bodies receive complete HTTP errors without resets',
      () async {
    // Each independent request must succeed once; no network retries mask resets.
    final replies = await Future.wait(List.generate(
        48,
        (index) => request(port, 'POST', '/upload?name=rejected-$index.txt',
            body: List.filled(8192, 65),
            extra: 'Origin: https://evil.example\r\n')));
    for (final reply in replies) {
      expect(reply.status, 403);
      expect(reply.json['error'], 'Forbidden');
      expect(reply.headers, contains('connection: close'));
    }
    expect(controller.receivedFiles, isEmpty);
  });

  test('rejected stalled bodies do not delay the response or stop barrier',
      () async {
    final sockets = <Socket>[];
    try {
      for (final body in [
        'Content-Length: 1073741824\r\n\r\n',
        'Transfer-Encoding: chunked\r\n\r\n3\r\nbad\r\n',
      ]) {
        final socket = await Socket.connect(InternetAddress.loopbackIPv4, port);
        sockets.add(socket);
        final response =
            socket.fold<List<int>>([], (all, bytes) => all..addAll(bytes));
        socket.write('POST /upload?name=stalled HTTP/1.1\r\n'
            'Host: 127.0.0.1:$port\r\nOrigin: https://evil.example\r\n$body');
        final bytes = await response.timeout(const Duration(seconds: 2));
        expect(utf8.decode(bytes), contains('403 Forbidden'));
      }
      // Neither declared body is finished, and clients have not closed their
      // write sides. stop must still release all detached rejection sockets.
      await controller.stop(page).timeout(const Duration(seconds: 2));
    } finally {
      for (final socket in sockets) {
        socket.destroy();
      }
    }
  });

  test('ancestor replacement never exposes files outside the selected tree',
      () async {
    final selected = Directory(p.join(directory.path, 'selected', 'sub'));
    await selected.create(recursive: true);
    await File(p.join(selected.path, 'a.txt')).writeAsString('shared');
    final outside = Directory(p.join(directory.path, 'outside'));
    await outside.create();
    await File(p.join(outside.path, 'a.txt')).writeAsString('private sentinel');
    await controller.addPaths(page, [p.dirname(selected.path)]);
    final id = page.files.single.id;
    expect((await request(port, 'GET', '/file/$id')).status, 200);
    // Keep the selected content, but replace its former ancestor with a link.
    final moved = p.join(directory.path, 'moved-sub');
    expect(selected.path, p.join(directory.path, 'selected', 'sub'));
    await selected.rename(moved);
    await Link(selected.path).create(outside.path);
    expect((await request(port, 'GET', '/file/$id')).status, 404);
    expect((await request(port, 'GET', '/download.zip')).status, 400);
    expect((await request(port, 'GET', '/manifest')).json['files'], isEmpty);
    // The authorization pin must survive restart rather than trust the new link.
    await controller.stop(page);
    controller.dispose();
    controller = LanDropController(receiveDirectory: directory);
    await controller.initialize();
    page = controller.pages.single;
    await controller.start(page);
    port = controller.portFor(page)!;
    expect((await request(port, 'GET', '/file/$id')).status, 404);
    expect((await request(port, 'GET', '/download.zip')).status, 400);
  });

  test('legacy share and session records acquire persisted canonical pins',
      () async {
    final source = File(p.join(directory.path, 'legacy.txt'));
    await source.writeAsString('legacy');
    await controller.addPaths(page, [source.path]);
    final fileId = page.files.single.id;
    final id = await create();
    await request(port, 'PATCH', '/uploads/$id?offset=0', body: [1, 2, 3]);
    await controller.stop(page);
    final preferences = await SharedPreferences.getInstance();
    final savedPages =
        jsonDecode(preferences.getString('landrop.pages.v1')!) as List<dynamic>;
    (savedPages.single['files'].single as Map).remove('canonicalPath');
    final sessions = jsonDecode(preferences.getString('landrop.sessions.v1')!)
        as List<dynamic>;
    (sessions.single as Map)
      ..remove('receiveRoot')
      ..remove('canonicalRoot')
      ..remove('receiveRootIdentity')
      ..remove('receiveParentIdentity');
    await preferences.setString('landrop.pages.v1', jsonEncode(savedPages));
    await preferences.setString('landrop.sessions.v1', jsonEncode(sessions));
    controller.dispose();
    controller = LanDropController(receiveDirectory: directory);
    await controller.initialize();
    page = controller.pages.single;
    await controller.start(page);
    port = controller.portFor(page)!;
    expect((await request(port, 'GET', '/file/$fileId')).status, 200);
    expect((await request(port, 'GET', '/uploads/$id')).json['offset'], 3);
    expect(
        page.files.single.canonicalPath, await source.resolveSymbolicLinks());
    final restored = jsonDecode(preferences.getString('landrop.sessions.v1')!)
        as List<dynamic>;
    expect(restored.single['receiveRoot'], isNotNull);
    expect(restored.single['canonicalRoot'], isNotNull);
    expect(restored.single['receiveRootIdentity'], isA<String>());
    expect(restored.single['receiveParentIdentity'], isNull);
    expect(restored.single['receiveLeafIdentity'], isA<String>());
    await controller.cancelTransfer(id);
  });

  test('missing legacy share is not trusted when its path is later reused',
      () async {
    final source = File(p.join(directory.path, 'legacy-missing', 'saved.txt'));
    await source.parent.create(recursive: true);
    await source.writeAsString('original');
    await controller.addPaths(page, [source.path]);
    final id = page.files.single.id;
    await controller.stop(page);
    final preferences = await SharedPreferences.getInstance();
    final savedPages =
        jsonDecode(preferences.getString('landrop.pages.v1')!) as List<dynamic>;
    (savedPages.single['files'].single as Map).remove('canonicalPath');
    await preferences.setString('landrop.pages.v1', jsonEncode(savedPages));
    await source.delete();
    controller.dispose();

    controller = LanDropController(receiveDirectory: directory);
    await controller.initialize();
    page = controller.pages.single;
    expect(page.files.single.canonicalPath, '');
    // A new file at the old path must not inherit a legacy share's authority.
    await source.writeAsString('replacement');
    await controller.start(page);
    port = controller.portFor(page)!;
    expect((await request(port, 'GET', '/file/$id')).status, 404);
    expect((await request(port, 'GET', '/manifest')).json['files'], isEmpty);
  });

  test('session cancellation never deletes through a replaced ancestor',
      () async {
    final id = await create();
    final root = Directory(p.join(directory.path, 'LanDrop', page.id));
    final outside = Directory(p.join(directory.path, 'outside-parts'));
    await outside.create();
    final sentinel = File(p.join(outside.path, '.$id.part'));
    await sentinel.writeAsString('private');
    final moved = p.join(directory.path, 'moved-page');
    expect(root.path, p.join(directory.path, 'LanDrop', page.id));
    await root.rename(moved);
    await Link(root.path).create(outside.path);
    expect(
        (await request(port, 'PATCH', '/uploads/$id?offset=0', body: [1]))
            .status,
        503);
    expect((await request(port, 'POST', '/uploads/$id/complete')).status, 500);
    await expectLater(
        controller.cancelTransfer(id), throwsA(isA<FileSystemException>()));
    expect(await sentinel.readAsString(), 'private');
    expect(await File(p.join(moved, '.$id.part')).exists(), isTrue);
    expect((await request(port, 'GET', '/uploads/$id')).status, 200);
    expect(controller.pageRecoveryWarnings[page.id], contains('续传记录已保留'));
    final preferences = await SharedPreferences.getInstance();
    final retained =
        jsonDecode(preferences.getString('landrop.sessions.v1')!) as List;
    final retainedSession = retained.single as Map;
    expect(retainedSession['id'], id);
    expect(retainedSession['deleting'], isTrue);

    await Link(root.path).delete();
    await Directory(moved).rename(root.path);
    await controller.cancelTransfer(id);
    expect(await sentinel.readAsString(), 'private');
    expect((await request(port, 'GET', '/uploads/$id')).status, 404);
    expect(await File(p.join(root.path, '.$id.part')).exists(), isFalse);
    expect(jsonDecode(preferences.getString('landrop.sessions.v1')!), isEmpty);
  });

  test('post-validation ancestor swap cannot redirect session unlink',
      () async {
    await controller.stop(page);
    controller.dispose();
    late Directory root;
    late Directory outside;
    late String moved;
    late String id;
    var swapOnUnlink = false;
    var swapped = false;
    controller = LanDropController(
        receiveDirectory: directory,
        beforeSecureReceiveUnlink: () async {
          if (!swapOnUnlink || swapped) return;
          swapped = true;
          await root.rename(moved);
          await Link(root.path).create(outside.path);
        });
    await controller.initialize();
    page = controller.pages.single;
    await controller.start(page);
    port = controller.portFor(page)!;

    id = await create(fingerprint: 'post-validation-unlink');
    await request(port, 'PATCH', '/uploads/$id?offset=0',
        body: utf8.encode('abc'));
    root = Directory(p.join(directory.path, 'LanDrop', page.id));
    outside = Directory(p.join(directory.path, 'outside-after-check'));
    await outside.create();
    final sentinel = File(p.join(outside.path, '.$id.part'));
    await sentinel.writeAsString('private');
    moved = p.join(directory.path, 'moved-after-check');
    swapOnUnlink = true;

    await expectLater(
        controller.cancelTransfer(id), throwsA(isA<FileSystemException>()));
    expect(swapped, isTrue);
    expect(await sentinel.readAsString(), 'private');
    expect(await File(p.join(moved, '.$id.part')).readAsString(), 'abc');
    expect((await request(port, 'GET', '/uploads/$id')).status, 200);
    final pending = (jsonDecode((await SharedPreferences.getInstance())
            .getString('landrop.sessions.v1')!) as List)
        .single as Map;
    expect(pending['id'], id);
    expect(pending['deleting'], isTrue);

    await Link(root.path).delete();
    await Directory(moved).rename(root.path);
    await controller.cancelTransfer(id);
    expect(await sentinel.readAsString(), 'private');
    expect(await File(p.join(root.path, '.$id.part')).exists(), isFalse);
    expect(
        jsonDecode((await SharedPreferences.getInstance())
            .getString('landrop.sessions.v1')!),
        isEmpty);
  });

  test('legacy deletion marker never follows a replaced symlink ancestor',
      () async {
    final id = await create(fingerprint: 'legacy-symlink-root');
    await request(port, 'PATCH', '/uploads/$id?offset=0',
        body: utf8.encode('abc'));
    await controller.stop(page);
    final preferences = await SharedPreferences.getInstance();
    final records =
        jsonDecode(preferences.getString('landrop.sessions.v1')!) as List;
    (records.single as Map)
      ..remove('receiveRoot')
      ..remove('canonicalRoot')
      ..remove('receiveRootIdentity')
      ..remove('receiveParentIdentity')
      ..['deleting'] = true;
    await preferences.setString('landrop.sessions.v1', jsonEncode(records));

    final lexicalBase = Directory(p.join(directory.path, 'LanDrop'));
    final movedBase = Directory(p.join(directory.path, 'moved-legacy-root'));
    await lexicalBase.rename(movedBase.path);
    final outsideBase =
        Directory(p.join(directory.path, 'outside-legacy-root'));
    final outsidePage = Directory(p.join(outsideBase.path, page.id));
    await outsidePage.create(recursive: true);
    final sentinel = File(p.join(outsidePage.path, '.$id.part'));
    await sentinel.writeAsString('outside');
    await Link(lexicalBase.path).create(outsideBase.path);

    controller.dispose();
    controller = LanDropController(receiveDirectory: directory);
    await controller.initialize();
    page = controller.pages.single;
    final savedPart = File(p.join(movedBase.path, page.id, '.$id.part'));
    expect(await savedPart.readAsString(), 'abc');
    expect(await sentinel.readAsString(), 'outside');
    expect(controller.pageRecoveryWarnings[page.id], contains('续传记录已保留'));
    final retained =
        (jsonDecode(preferences.getString('landrop.sessions.v1')!) as List)
            .single as Map;
    expect(retained['deleting'], isTrue);
    expect(retained['receiveRootIdentity'], isNull);

    await Link(lexicalBase.path).delete();
    await movedBase.rename(lexicalBase.path);
    await controller.removePage(page);
    expect(await savedPart.exists(), isFalse);
    expect(await sentinel.readAsString(), 'outside');
    expect(jsonDecode(preferences.getString('landrop.sessions.v1')!), isEmpty);
  });

  test('post-validation ordinary root replacement preserves deleting marker',
      () async {
    await controller.stop(page);
    controller.dispose();
    late Directory root;
    late String moved;
    late String id;
    late String originalIdentity;
    var swapOnUnlink = false;
    var swapped = false;
    controller = LanDropController(
        receiveDirectory: directory,
        beforeSecureReceiveUnlink: () async {
          if (!swapOnUnlink || swapped) return;
          swapped = true;
          await root.rename(moved);
          await root.create();
          await File(p.join(root.path, '.$id.part'))
              .writeAsString('replacement');
          originalIdentity = replaceMockDirectoryIdentity(root.path);
        });
    await controller.initialize();
    page = controller.pages.single;
    await controller.start(page);
    port = controller.portFor(page)!;

    id = await create(fingerprint: 'post-validation-root-id');
    await request(port, 'PATCH', '/uploads/$id?offset=0',
        body: utf8.encode('abc'));
    root = Directory(p.join(directory.path, 'LanDrop', page.id));
    moved = p.join(directory.path, 'moved-root-id');
    swapOnUnlink = true;

    await expectLater(
        controller.cancelTransfer(id), throwsA(isA<FileSystemException>()));
    expect(swapped, isTrue);
    expect(await File(p.join(moved, '.$id.part')).readAsString(), 'abc');
    expect(await File(p.join(root.path, '.$id.part')).readAsString(),
        'replacement');
    expect((await request(port, 'GET', '/uploads/$id')).status, 200);
    final pending = (jsonDecode((await SharedPreferences.getInstance())
            .getString('landrop.sessions.v1')!) as List)
        .single as Map;
    expect(pending['deleting'], isTrue);

    await root.delete(recursive: true);
    await Directory(moved).rename(root.path);
    restoreMockDirectoryIdentity(root.path, originalIdentity);
    await controller.cancelTransfer(id);
    expect(await File(p.join(root.path, '.$id.part')).exists(), isFalse);
  });

  test('post-validation date-parent replacement preserves deleting marker',
      () async {
    await controller.stop(page);
    controller.dispose();
    late Directory dateDirectory;
    late String movedDate;
    late String id;
    late String originalIdentity;
    var swapOnUnlink = false;
    var swapped = false;
    controller = LanDropController(
        receiveDirectory: directory,
        beforeSecureReceiveUnlink: () async {
          if (!swapOnUnlink || swapped) return;
          swapped = true;
          await dateDirectory.rename(movedDate);
          await dateDirectory.create();
          await File(p.join(dateDirectory.path, '.$id.part'))
              .writeAsString('replacement');
          originalIdentity = replaceMockDirectoryIdentity(dateDirectory.path);
        });
    await controller.initialize();
    page = controller.pages.single;
    await controller.start(page);
    port = controller.portFor(page)!;
    final customRoot = p.join(directory.path, 'organized-receive');
    await controller.setReceiveOptions(page,
        directory: customRoot, organizeByDate: true);

    id = await create(fingerprint: 'post-validation-parent-id');
    await request(port, 'PATCH', '/uploads/$id?offset=0',
        body: utf8.encode('abc'));
    // Derive actual date from the session path to avoid a midnight boundary.
    final preferences = await SharedPreferences.getInstance();
    final saved =
        (jsonDecode(preferences.getString('landrop.sessions.v1')!) as List)
            .single as Map;
    final savedPath = saved['path'] as String;
    final expectedPart = File(savedPath);
    expect(await expectedPart.readAsString(), 'abc');
    dateDirectory = expectedPart.parent;
    movedDate = p.join(customRoot, 'moved-date-id');
    swapOnUnlink = true;

    await expectLater(
        controller.cancelTransfer(id), throwsA(isA<FileSystemException>()));
    expect(swapped, isTrue);
    expect(await File(p.join(movedDate, '.$id.part')).readAsString(), 'abc');
    expect(await expectedPart.readAsString(), 'replacement');
    final pending =
        (jsonDecode(preferences.getString('landrop.sessions.v1')!) as List)
            .single as Map;
    expect(pending['deleting'], isTrue);

    await dateDirectory.delete(recursive: true);
    await Directory(movedDate).rename(dateDirectory.path);
    restoreMockDirectoryIdentity(dateDirectory.path, originalIdentity);
    await controller.cancelTransfer(id);
    expect(await expectedPart.exists(), isFalse);
  });

  test('post-validation leaf symlink is rejected by secure unlink', () async {
    await controller.stop(page);
    controller.dispose();
    late File part;
    late File saved;
    late File sentinel;
    var swapOnUnlink = false;
    var swapped = false;
    controller = LanDropController(
        receiveDirectory: directory,
        beforeSecureReceiveUnlink: () async {
          if (!swapOnUnlink || swapped) return;
          swapped = true;
          await part.rename(saved.path);
          await Link(part.path).create(sentinel.path);
        });
    await controller.initialize();
    page = controller.pages.single;
    await controller.start(page);
    port = controller.portFor(page)!;

    final id = await create(fingerprint: 'post-validation-leaf');
    await request(port, 'PATCH', '/uploads/$id?offset=0',
        body: utf8.encode('abc'));
    final root = p.join(directory.path, 'LanDrop', page.id);
    part = File(p.join(root, '.$id.part'));
    saved = File(p.join(root, '.$id.saved'));
    final outside = Directory(p.join(directory.path, 'outside-leaf-swap'));
    await outside.create();
    sentinel = File(p.join(outside.path, 'private.txt'));
    await sentinel.writeAsString('private');
    swapOnUnlink = true;

    await expectLater(
        controller.cancelTransfer(id), throwsA(isA<FileSystemException>()));
    expect(swapped, isTrue);
    expect(await sentinel.readAsString(), 'private');
    expect(await saved.readAsString(), 'abc');
    expect(await FileSystemEntity.type(part.path, followLinks: false),
        FileSystemEntityType.link);
    final preferences = await SharedPreferences.getInstance();
    final pending =
        (jsonDecode(preferences.getString('landrop.sessions.v1')!) as List)
            .single as Map;
    expect(pending['deleting'], isTrue);

    await Link(part.path).delete();
    await saved.rename(part.path);
    await controller.cancelTransfer(id);
    expect(await sentinel.readAsString(), 'private');
    expect(await part.exists(), isFalse);
  });

  test('post-validation regular leaf replacement preserves the new file',
      () async {
    await controller.stop(page);
    controller.dispose();
    late File part;
    late File saved;
    late String originalLeafIdentity;
    var swapOnUnlink = false;
    var swapped = false;
    controller = LanDropController(
        receiveDirectory: directory,
        beforeSecureReceiveUnlink: () async {
          if (!swapOnUnlink || swapped) return;
          swapped = true;
          await part.rename(saved.path);
          await part.writeAsString('replacement');
          originalLeafIdentity = replaceMockReceiveLeafIdentity(part.path);
        });
    await controller.initialize();
    page = controller.pages.single;
    await controller.start(page);
    port = controller.portFor(page)!;

    final id = await create(
        fingerprint: 'post-validation-regular-leaf', size: 'original'.length);
    await request(port, 'PATCH', '/uploads/$id?offset=0',
        body: utf8.encode('original'));
    final root = p.join(directory.path, 'LanDrop', page.id);
    part = File(p.join(root, '.$id.part'));
    saved = File(p.join(root, '.$id.saved'));
    swapOnUnlink = true;

    await expectLater(
        controller.cancelTransfer(id), throwsA(isA<FileSystemException>()));
    expect(swapped, isTrue);
    expect(await saved.readAsString(), 'original');
    expect(await part.readAsString(), 'replacement');
    final preferences = await SharedPreferences.getInstance();
    final pending =
        (jsonDecode(preferences.getString('landrop.sessions.v1')!) as List)
            .single as Map;
    expect(pending['deleting'], isTrue);

    await part.delete();
    await saved.rename(part.path);
    restoreMockReceiveLeafIdentity(part.path, originalLeafIdentity);
    await controller.cancelTransfer(id);
    expect(await part.exists(), isFalse);
  });

  test('restored session retains a replaced partial instead of adopting it',
      () async {
    final id = await create(
        fingerprint: 'replaced-leaf-on-restore', size: 'abc'.length);
    await request(port, 'PATCH', '/uploads/$id?offset=0',
        body: utf8.encode('abc'));
    final preferences = await SharedPreferences.getInstance();
    final records =
        jsonDecode(preferences.getString('landrop.sessions.v1')!) as List;
    final savedIdentity = (records.single as Map)['receiveLeafIdentity'];
    expect(savedIdentity, isA<String>());
    final part = File((records.single as Map)['path'] as String);
    final moved = File('${part.path}.original');
    await controller.stop(page);
    controller.dispose();

    await part.rename(moved.path);
    await part.writeAsString('replacement');
    replaceMockReceiveLeafIdentity(part.path);

    controller = LanDropController(receiveDirectory: directory);
    await controller.initialize();
    page = controller.pages.single;
    expect(await part.readAsString(), 'replacement');
    expect(await moved.readAsString(), 'abc');
    expect(controller.pageRecoveryWarnings[page.id], contains('续传记录已保留'));
    final retained =
        (jsonDecode(preferences.getString('landrop.sessions.v1')!) as List)
            .single as Map;
    expect(retained['receiveLeafIdentity'], savedIdentity);

    await controller.start(page);
    port = controller.portFor(page)!;
    final retry = await request(port, 'POST',
        '/uploads?name=report.txt&size=3&fingerprint=replaced-leaf-on-restore');
    expect(retry.status, 409);
    expect(await part.readAsString(), 'replacement');
    expect(await moved.readAsString(), 'abc');
  });

  test('quarantined session deletion resumes after a restart', () async {
    final id = await create(
        fingerprint: 'quarantine-delete-recovery', size: 'abc'.length);
    await request(port, 'PATCH', '/uploads/$id?offset=0',
        body: utf8.encode('abc'));
    final preferences = await SharedPreferences.getInstance();
    final sessionRecords =
        jsonDecode(preferences.getString('landrop.sessions.v1')!) as List;
    final session = sessionRecords.single as Map;
    final part = File(session['path'] as String);
    final quarantine = File(p.join(part.parent.path,
        SecureReceiveFile.quarantineDirectoryName, id, '.$id.quarantine'));

    failNextReceiveQuarantineAfterRenameForTest('.$id.part');
    await expectLater(
        controller.cancelTransfer(id), throwsA(isA<FileSystemException>()));
    expect(await part.exists(), isFalse);
    expect(await quarantine.readAsString(), 'abc');
    final deletingRecord =
        (jsonDecode(preferences.getString('landrop.sessions.v1')!) as List)
            .single as Map;
    expect(deletingRecord['deleting'], isTrue);
    final savedQuarantineIdentity =
        deletingRecord['receiveQuarantineIdentity'] as String;
    final quarantineDirectory = Directory(p.dirname(quarantine.path));
    expect(replaceMockReceiveQuarantineIdentity(quarantineDirectory.path),
        savedQuarantineIdentity);

    await controller.stop(page);
    controller.dispose();
    controller = LanDropController(receiveDirectory: directory);
    await controller.initialize();
    page = controller.pages.single;

    expect(await quarantine.exists(), isTrue);
    final stillDeleting =
        (jsonDecode(preferences.getString('landrop.sessions.v1')!) as List)
            .single as Map;
    expect(stillDeleting['deleting'], isTrue);
    expect(stillDeleting['receiveQuarantineIdentity'], savedQuarantineIdentity);

    restoreMockReceiveQuarantineIdentity(
        quarantineDirectory.path, savedQuarantineIdentity);
    await controller.removePage(page);
    expect(await quarantine.exists(), isFalse);
    expect(await quarantineDirectory.exists(), isFalse);
    expect(await part.exists(), isFalse);
    expect(jsonDecode(preferences.getString('landrop.sessions.v1')!), isEmpty);
  }, skip: Platform.isWindows);

  test('receive root changes preserve old sessions across restart', () async {
    final id = await create();
    await request(port, 'PATCH', '/uploads/$id?offset=0',
        body: utf8.encode('abc'));
    final oldPart =
        File(p.join(directory.path, 'LanDrop', page.id, '.$id.part'));
    final custom = p.join(directory.path, 'custom-root');
    await controller.setReceiveOptions(page,
        directory: custom, organizeByDate: true);
    await controller.stop(page);
    // Pre-pin versions did not persist the receive root. This upload must
    // recover its original root from the part path, not use the changed page.
    final preferences = await SharedPreferences.getInstance();
    final legacySessions =
        jsonDecode(preferences.getString('landrop.sessions.v1')!)
            as List<dynamic>;
    (legacySessions.single as Map)
      ..remove('receiveRoot')
      ..remove('canonicalRoot');
    await preferences.setString(
        'landrop.sessions.v1', jsonEncode(legacySessions));
    controller.dispose();
    controller = LanDropController(receiveDirectory: directory);
    await controller.initialize();
    page = controller.pages.single;
    await controller.start(page);
    port = controller.portFor(page)!;
    expect((await request(port, 'GET', '/uploads/$id')).json['offset'], 3);
    await request(port, 'PATCH', '/uploads/$id?offset=3',
        body: utf8.encode('def'));
    expect((await request(port, 'POST', '/uploads/$id/complete')).status, 201);
    final saved = controller.receivedFiles.single;
    expect(p.dirname(saved.path), p.dirname(oldPart.path));
    expect(await File(saved.path).readAsString(), 'abcdef');
    expect(await oldPart.exists(), false);
    final next = await create(fingerprint: 'new-root');
    final target = await controller.receiveDirectoryFor(page);
    expect(p.isWithin(custom, target), true);
    final nextPart = File(p.join(target, '.$next.part'));
    expect(await nextPart.exists(), true);
    // A dated custom-root session must also survive switching back to default.
    await controller.setReceiveOptions(page);
    await controller.stop(page);
    controller.dispose();
    controller = LanDropController(receiveDirectory: directory);
    await controller.initialize();
    page = controller.pages.single;
    await controller.start(page);
    port = controller.portFor(page)!;
    expect((await request(port, 'GET', '/uploads/$next')).json['offset'], 0);
    await controller.cancelTransfer(next);
    expect(await nextPart.exists(), false);
  });

  test('session writes stay pinned if alias changes after validation',
      () async {
    await controller.stop(page);
    controller.dispose();
    final canonicalRoot = Directory(p.join(directory.path, 'pinned-receive'));
    final outsideRoot = Directory(p.join(directory.path, 'redirected-receive'));
    await canonicalRoot.create();
    await outsideRoot.create();
    final alias = Link(p.join(directory.path, 'receive-alias'));
    await alias.create(canonicalRoot.path);
    var redirected = false;
    controller = LanDropController(
        receiveDirectory: directory,
        afterSessionSourceResolved: () async {
          if (redirected) return;
          redirected = true;
          await alias.delete();
          await alias.create(outsideRoot.path);
        });
    await controller.initialize();
    page = controller.pages.single;
    await controller.start(page);
    port = controller.portFor(page)!;
    await controller.setReceiveOptions(page, directory: alias.path);
    final id = await create(fingerprint: 'swap-after-validation');
    final part = File(p.join(canonicalRoot.path, page.id, '.$id.part'));
    expect(await part.exists(), true);
    final outsidePage = Directory(p.join(outsideRoot.path, page.id));
    await outsidePage.create();
    final outsidePart = File(p.join(outsidePage.path, '.$id.part'));
    await outsidePart.writeAsString('keep');

    final reply = await request(port, 'PATCH', '/uploads/$id?offset=0',
        body: utf8.encode('abc'));
    expect(redirected, true);
    expect(reply.status, 503);
    expect(await part.readAsString(), 'abc');
    expect(await outsidePart.readAsString(), 'keep');
  });

  test('completion stays pinned when its lexical alias changes after check',
      () async {
    await controller.stop(page);
    controller.dispose();
    final canonicalRoot = Directory(p.join(directory.path, 'pinned-complete'));
    final outsideRoot =
        Directory(p.join(directory.path, 'redirected-complete'));
    await canonicalRoot.create();
    await outsideRoot.create();
    final alias = Link(p.join(directory.path, 'receive-alias'));
    await alias.create(canonicalRoot.path);
    var redirectNextResolution = false;
    controller = LanDropController(
        receiveDirectory: directory,
        afterSessionSourceResolved: () async {
          if (!redirectNextResolution) return;
          redirectNextResolution = false;
          await alias.delete();
          await alias.create(outsideRoot.path);
        });
    await controller.initialize();
    page = controller.pages.single;
    await controller.start(page);
    port = controller.portFor(page)!;
    await controller.setReceiveOptions(page, directory: alias.path);
    final id = await create(fingerprint: 'complete-after-swap');
    expect(
        (await request(port, 'PATCH', '/uploads/$id?offset=0',
                body: utf8.encode('abcdef')))
            .status,
        200);
    final outsidePage = Directory(p.join(outsideRoot.path, page.id));
    await outsidePage.create();
    final outsidePart = File(p.join(outsidePage.path, '.$id.part'));
    await outsidePart.writeAsString('secret');

    redirectNextResolution = true;
    expect((await request(port, 'POST', '/uploads/$id/complete')).status, 201);
    final canonicalReceiveRoot = await canonicalRoot.resolveSymbolicLinks();
    final pinnedTarget = File(p.join(canonicalReceiveRoot, page.id, 'a.txt'));
    expect(await pinnedTarget.readAsString(), 'abcdef');
    expect(await outsidePart.readAsString(), 'secret');
    expect(controller.receivedFiles.single.path, pinnedTarget.path);
    expect(await File(controller.receivedFiles.single.path).readAsString(),
        'abcdef');
  });

  test('resumable files operate through canonical custom-root aliases',
      () async {
    final canonicalRoot =
        Directory(p.join(directory.path, 'canonical-receive'));
    await canonicalRoot.create();
    final alias = Link(p.join(directory.path, 'receive-alias'));
    await alias.create(canonicalRoot.path);
    await controller.setReceiveOptions(page, directory: alias.path);
    final id = await create(fingerprint: 'root-alias');
    final part = File(p.join(canonicalRoot.path, page.id, '.$id.part'));
    expect(await part.exists(), true);
    await request(port, 'PATCH', '/uploads/$id?offset=0',
        body: utf8.encode('abcdef'));
    expect((await request(port, 'POST', '/uploads/$id/complete')).status, 201);
    final saved = controller.receivedFiles.single;
    final displayedPath = p.join(alias.path, page.id, 'a.txt');
    expect(saved.path, displayedPath);
    expect(await File(saved.path).readAsString(), 'abcdef');
    expect(
        await File(p.join(canonicalRoot.path, page.id, 'a.txt')).readAsString(),
        'abcdef');
  });

  test('custom receive root does not access a blocked default root', () async {
    await controller.stop(page);
    controller.dispose();
    final blocked = File(p.join(directory.path, 'blocked-default'));
    await blocked.writeAsString('not a directory');
    controller = LanDropController(receiveDirectory: Directory(blocked.path));
    await controller.initialize();
    page = controller.pages.single;
    final custom = p.join(directory.path, 'writable-custom');
    await controller.setReceiveOptions(page, directory: custom);
    await controller.start(page);
    port = controller.portFor(page)!;
    expect((await upload(port, 'raw.txt', 'safe')).$1, 201);
    final id = await create(size: 0);
    expect((await request(port, 'POST', '/uploads/$id/complete')).status, 201);
    expect(controller.receivedFiles, hasLength(2));
    final canonicalCustom = await Directory(custom).resolveSymbolicLinks();
    for (final file in controller.receivedFiles) {
      final canonicalFile = await File(file.path).resolveSymbolicLinks();
      expect(
        p.isWithin(canonicalCustom, canonicalFile),
        isTrue,
        reason: 'received file escaped the custom root: ${file.path}',
      );
    }
    expect(await blocked.readAsString(), 'not a directory');
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
    expect(controller.canCancelTransfer(task.id), isTrue);
    await controller
        .cancelTransfer(task.id)
        .timeout(const Duration(seconds: 5));
    expect(controller.canCancelTransfer(task.id), isFalse);
    expect(task.status, 'cancelled');
    expect(task.transferredBytes, lessThan(task.totalBytes));
    socket.destroy();
    await subscription.cancel();
  });
}
