import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:isolate';

import 'package:path/path.dart' as p;

import 'zip_service.dart';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'download_page.dart';

final RegExp _uuidPattern = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
);

String newId() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex =
      bytes.map((value) => value.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

class SharedFile {
  const SharedFile({
    required this.id,
    required this.name,
    required this.path,
    required this.size,
    required this.managed,
    this.relativePath,
  });

  final String id;
  final String name;
  final String path;
  final int size;
  final bool managed;
  final String? relativePath;

  Map<String, Object> toJson() => {
        'id': id,
        'name': name,
        'path': path,
        'size': size,
        'managed': managed,
        if (relativePath != null) 'relativePath': relativePath!,
      };

  static SharedFile? fromJson(Object? value) {
    if (value is! Map) return null;
    final id = value['id'];
    final name = value['name'];
    final path = value['path'];
    final size = value['size'];
    final managed = value['managed'];
    if (id is! String ||
        !_uuidPattern.hasMatch(id) ||
        name is! String ||
        path is! String ||
        size is! int ||
        size < 0 ||
        managed is! bool) {
      return null;
    }
    return SharedFile(
      id: id,
      name: name,
      path: path,
      size: size,
      managed: managed,
      relativePath: value['relativePath'] is String
          ? value['relativePath'] as String
          : null,
    );
  }
}

class SharePage {
  SharePage({
    required this.id,
    required this.title,
    required this.files,
    this.running = false,
    this.receiveDirectory,
    this.organizeByDate = false,
  });

  final String id;
  String title;
  final List<SharedFile> files;
  bool running;
  String? receiveDirectory;
  bool organizeByDate;

  Map<String, Object> toJson() => {
        'id': id,
        'title': title,
        'running': running,
        if (receiveDirectory != null) 'receiveDirectory': receiveDirectory!,
        'organizeByDate': organizeByDate,
        'files': files.map((file) => file.toJson()).toList(),
      };

  static SharePage? fromJson(Object? value) {
    if (value is! Map) return null;
    final id = value['id'];
    final title = value['title'];
    if (id is! String || !_uuidPattern.hasMatch(id) || title is! String) {
      return null;
    }
    final rawFiles = value['files'];
    final files = rawFiles is List
        ? rawFiles.map(SharedFile.fromJson).whereType<SharedFile>().toList()
        : <SharedFile>[];
    return SharePage(
      id: id,
      title: title,
      files: files,
      running: value['running'] == true,
      receiveDirectory: value['receiveDirectory'] is String
          ? value['receiveDirectory'] as String
          : null,
      organizeByDate: value['organizeByDate'] == true,
    );
  }
}

class ReceivedFile {
  const ReceivedFile({
    required this.name,
    required this.path,
    required this.size,
    required this.pageTitle,
    required this.receivedAt,
  });

  final String name;
  final String path;
  final int size;
  final String pageTitle;
  final DateTime receivedAt;
  Map<String, Object> toJson() => {
        'name': name,
        'path': path,
        'size': size,
        'pageTitle': pageTitle,
        'receivedAt': receivedAt.toIso8601String()
      };
  static ReceivedFile? fromJson(Object? value) {
    if (value is! Map ||
        value['name'] is! String ||
        value['path'] is! String ||
        value['size'] is! int ||
        (value['size'] as int) < 0 ||
        value['pageTitle'] is! String ||
        value['receivedAt'] is! String) {
      return null;
    }
    final date = DateTime.tryParse(value['receivedAt'] as String);
    if (date == null) return null;
    return ReceivedFile(
        name: value['name'] as String,
        path: value['path'] as String,
        size: value['size'] as int,
        pageTitle: value['pageTitle'] as String,
        receivedAt: date);
  }
}

class TransferTask {
  TransferTask(
      {required this.id,
      required this.pageId,
      required this.pageTitle,
      required this.name,
      required this.direction,
      required this.totalBytes,
      this.transferredBytes = 0,
      this.status = 'active'});
  final String id, pageId, pageTitle, name, direction;
  String status;
  int totalBytes, transferredBytes;
  double bytesPerSecond = 0;
  double? get remainingSeconds => bytesPerSecond > 0
      ? max(0, totalBytes - transferredBytes) / bytesPerSecond
      : null;
  double get progress => totalBytes <= 0
      ? (status == 'completed' ? 1 : 0)
      : (transferredBytes / totalBytes).clamp(0.0, 1.0);
  final Stopwatch _clock = Stopwatch()..start();
  int _initialBytes = 0;
  void update(int bytes) {
    transferredBytes = bytes;
    if (_clock.elapsedMicroseconds > 0) {
      bytesPerSecond =
          max(0, bytes - _initialBytes) * 1000000 / _clock.elapsedMicroseconds;
    }
  }
}

class _Session {
  _Session(
      {required this.id,
      required this.pageId,
      required this.name,
      required this.size,
      required this.fingerprint,
      required this.path,
      this.offset = 0});
  final String id, pageId, name, fingerprint, path;
  final int size;
  int offset;
  bool busy = false;
  Completer<void>? completion;
  Completer<void>? initialization;
  Map<String, Object> toJson() => {
        'id': id,
        'pageId': pageId,
        'name': name,
        'size': size,
        'fingerprint': fingerprint,
        'path': path,
        'offset': offset
      };
  Map<String, Object> get state => {'id': id, 'offset': offset, 'size': size};
}

/// A bounded completion receipt intentionally contains no local path/fingerprint.
class _CompletedReceipt {
  _CompletedReceipt(
      {required this.id,
      required this.pageId,
      required this.name,
      required this.size,
      required this.completedAt,
      this.pending});
  final String id, pageId, name;
  final int size;
  final DateTime completedAt;
  Future<void>? pending;
  Map<String, Object> get state => {'id': id, 'offset': size, 'size': size};
  Map<String, Object> get result => {'name': name, 'size': size};
  Map<String, Object> toJson() => {
        'id': id,
        'pageId': pageId,
        'name': name,
        'size': size,
        'completedAt': completedAt.toIso8601String()
      };
}

class _Upload {
  final cancelled = Completer<void>();
  final done = Completer<void>();

  void cancel() {
    if (!cancelled.isCompleted) cancelled.complete();
  }
}

class _UploadCancelled implements Exception {}

class _UploadTooLarge implements Exception {}

/// Owns each page's independent listener, persisted state, and mobile file copies.
class LanDropController extends ChangeNotifier {
  /// Tests can supply a base directory without invoking path_provider.
  LanDropController({Directory? receiveDirectory})
      : _receiveBaseDirectory = receiveDirectory;

  static const _storageKey = 'landrop.pages.v1';
  static const _recordsKey = 'landrop.received.v1';
  static const _sessionsKey = 'landrop.sessions.v1';
  static const _receiptsKey = 'landrop.uploadReceipts.v1';
  static const _receiptLifetime = Duration(hours: 24);
  final Map<String, _CompletedReceipt> _receipts = {};
  final List<TransferTask> transfers = [];
  final Map<String, Future<void> Function()> _cancelActions = {};
  final Map<String, _Session> _sessions = {};
  final Map<String, Set<Future<void>>> _requests = {};
  Future<void> _persistQueue = Future.value();
  static const _maxUploadBytes = 1024 * 1024 * 1024;
  final Directory? _receiveBaseDirectory;
  final List<ReceivedFile> receivedFiles = [];
  String? receiveDirectory;
  final Map<String, Set<_Upload>> _uploads = {};
  final List<SharePage> pages = [];
  final Map<String, HttpServer> _servers = {};
  final Map<String, String> pageErrors = {};
  List<String> addresses = [];
  SharedPreferences? _preferences;
  Directory? _fileDirectory;

  bool get isMobile => Platform.isAndroid || Platform.isIOS;
  int? portFor(SharePage page) => _servers[page.id]?.port;

  Future<void> initialize() async {
    _preferences = await SharedPreferences.getInstance();
    if (isMobile) await _ensureFileDirectory();
    final saved = _preferences!.getString(_storageKey);
    if (saved != null) {
      try {
        final decoded = jsonDecode(saved);
        if (decoded is List) {
          pages.addAll(decoded.map(SharePage.fromJson).whereType<SharePage>());
        }
      } on FormatException {
        // A malformed preference must not prevent the app from opening.
      }
    }
    await _restoreTransfers();
    await refreshAddresses();
    for (final page in pages) {
      if (!page.running) continue;
      try {
        await _bind(page);
      } catch (error) {
        page.running = false;
        pageErrors[page.id] = '恢复服务失败：$error';
      }
    }
    await _persist();
    notifyListeners();
  }

  Future<void> refreshAddresses() async {
    final found = <String>{};
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
        includeLinkLocal: false,
      );
      for (final interface in interfaces) {
        for (final address in interface.addresses) {
          if (address.type == InternetAddressType.IPv4) {
            found.add(address.address);
          }
        }
      }
    } on SocketException {
      // A page can still be created offline and shared after reconnecting.
    }
    addresses = found.toList()
      ..sort((a, b) {
        final aLocal = _privateAddress(a) ? 0 : 1;
        final bLocal = _privateAddress(b) ? 0 : 1;
        return aLocal != bLocal ? aLocal.compareTo(bLocal) : a.compareTo(b);
      });
    notifyListeners();
  }

  bool _privateAddress(String address) {
    final parts = address.split('.').map(int.tryParse).toList();
    if (parts.length != 4 || parts.any((value) => value == null)) return false;
    final first = parts[0]!;
    final second = parts[1]!;
    return first == 10 ||
        first == 192 && second == 168 ||
        first == 172 && second >= 16 && second <= 31;
  }

  Future<SharePage> createPage(String title) async {
    final page = SharePage(id: newId(), title: title.trim(), files: []);
    pages.add(page);
    await _persist();
    notifyListeners();
    return page;
  }

  Future<Directory> _ensureFileDirectory() async {
    if (_fileDirectory != null) return _fileDirectory!;
    final support = await getApplicationSupportDirectory();
    _fileDirectory = Directory(
      '${support.path}${Platform.pathSeparator}landrop_shared_files',
    );
    await _fileDirectory!.create(recursive: true);
    return _fileDirectory!;
  }

  Future<void> addFiles(SharePage page, List<PlatformFile> selections) async {
    for (final selection in selections) {
      final path = selection.path;
      final managed = isMobile || path == null;
      final id = newId();
      var storedPath = path;
      int size;
      if (managed) {
        final directory = await _ensureFileDirectory();
        final destination =
            File('${directory.path}${Platform.pathSeparator}$id');
        final sink = destination.openWrite();
        try {
          await sink.addStream(selection.readAsByteStream());
          await sink.close();
          size = await destination.length();
        } catch (_) {
          try {
            await sink.close();
          } catch (_) {
            // Preserve the original copy error; remove any partial output.
          }
          if (await destination.exists()) await destination.delete();
          rethrow;
        }
        storedPath = destination.path;
      } else {
        size = await File(path).length();
      }
      page.files.add(
        SharedFile(
          id: id,
          name: selection.name,
          path: storedPath!,
          size: size,
          managed: managed,
        ),
      );
      await _persist();
      notifyListeners();
    }
  }

  Future<void> removeFile(SharePage page, SharedFile file) async {
    page.files.removeWhere((candidate) => candidate.id == file.id);
    await _persist();
    notifyListeners();
    await _deleteManagedFile(file);
  }

  Future<void> removePage(SharePage page) async {
    await _unbind(page);
    for (final session
        in _sessions.values.where((s) => s.pageId == page.id).toList()) {
      await _deleteSession(session);
    }
    _receipts.removeWhere((_, receipt) => receipt.pageId == page.id);
    pages.removeWhere((candidate) => candidate.id == page.id);
    pageErrors.remove(page.id);
    await _persist();
    notifyListeners();
    for (final file in page.files) {
      await _deleteManagedFile(file);
    }
  }

  Future<void> _deleteManagedFile(SharedFile file) async {
    if (!file.managed || !_uuidPattern.hasMatch(file.id)) return;
    final directory = await _ensureFileDirectory();
    final expected = '${directory.path}${Platform.pathSeparator}${file.id}';
    if (file.path != expected) return;
    final stored = File(expected);
    if (await stored.exists()) await stored.delete();
  }

  Future<void> start(SharePage page) async {
    if (_servers.containsKey(page.id)) return;
    await _bind(page);
    page.running = true;
    pageErrors.remove(page.id);
    await _persist();
    notifyListeners();
  }

  Future<void> stop(SharePage page) async {
    await _unbind(page);
    page.running = false;
    await _persist();
    notifyListeners();
  }

  Future<void> restart(SharePage page) async {
    await _unbind(page);
    page.running = false;
    await _persist();
    notifyListeners();
    await start(page);
  }

  Future<void> _bind(SharePage page) async {
    final server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    _servers[page.id] = server;
    server.listen(
      (request) {
        final operation = _serve(page, request);
        (_requests[page.id] ??= {}).add(operation);
        unawaited(operation
            .whenComplete(() => _requests[page.id]?.remove(operation)));
      },
      onError: (Object error) {
        pageErrors[page.id] = '服务错误：$error';
        notifyListeners();
      },
    );
  }

  Future<void> _unbind(SharePage page) async {
    final server = _servers.remove(page.id);
    final pending = _uploads[page.id]?.toList() ?? <_Upload>[];
    for (final upload in pending) {
      upload.cancel();
    }
    for (final task in transfers
        .where((t) => t.pageId == page.id && t.status == 'active')
        .toList()) {
      await _cancelActions[task.id]?.call();
      if (task.status == 'active') {
        task.status = _sessions.containsKey(task.id) ? 'paused' : 'cancelled';
      }
    }
    if (server != null) await server.close(force: true);
    await Future.wait(pending.map((upload) => upload.done.future));
    await Future.wait(_requests[page.id]?.toList() ?? <Future<void>>[]);
  }

  Future<Directory> _receiveRoot() async {
    Directory? base = _receiveBaseDirectory;
    if (base == null) {
      try {
        base = await getDownloadsDirectory();
      } catch (_) {
        // Downloads is unavailable on some platforms.
      }
      base ??= await getApplicationDocumentsDirectory();
    }
    final root = Directory('${base.path}${Platform.pathSeparator}LanDrop');
    await root.create(recursive: true);
    receiveDirectory = root.path;
    return root;
  }

  String _receivedName(String input) {
    // Treat both Windows and Unix separators as paths, on every platform.
    var name = input
        .split(RegExp(r'[/\\]'))
        .last
        .replaceAll(RegExp(r'[\x00-\x1f\x7f-\x9f<>:"|?*]'), '_')
        .trim()
        .replaceAll(RegExp(r'[. ]+$'), '');
    if (RegExp(r'^(con|prn|aux|nul|com[1-9¹²³]|lpt[1-9¹²³])$',
            caseSensitive: false)
        .hasMatch(name.split('.').first.trim())) {
      name = '_$name';
    }
    final shortened = StringBuffer();
    var bytes = 0;
    for (final rune in name.runes) {
      final character = String.fromCharCode(rune);
      bytes += utf8.encode(character).length;
      if (bytes > 180) break;
      shortened.write(character);
    }
    name = shortened.toString().replaceAll(RegExp(r'[. ]+$'), '');
    return name.isEmpty || name == '.' || name == '..' ? 'upload' : name;
  }

  bool _uploadAllowed(HttpRequest request) {
    final hostHeaders = request.headers[HttpHeaders.hostHeader];
    if (hostHeaders == null || hostHeaders.length != 1) return false;
    final authority = Uri.tryParse('http://${hostHeaders.single}');
    if (authority == null ||
        authority.userInfo.isNotEmpty ||
        authority.path.isNotEmpty ||
        authority.hasQuery ||
        authority.hasFragment ||
        authority.port != request.connectionInfo?.localPort) {
      return false;
    }
    // Only numeric local interface addresses (and localhost) are advertised.
    // Reject attacker-controlled DNS names even when Origin matches Host.
    final host = authority.host.toLowerCase();
    if (host != 'localhost' &&
        host != '127.0.0.1' &&
        host != '::1' &&
        !addresses.contains(host)) {
      return false;
    }
    final sites = request.headers['sec-fetch-site'];
    if (sites != null &&
        (sites.length != 1 ||
            !const ['same-origin', 'none'].contains(sites.single))) {
      return false;
    }
    final origins = request.headers['origin'];
    if (origins == null) return true;
    if (origins.length != 1) return false;
    final origin = Uri.tryParse(origins.single);
    return origin != null &&
        origin.scheme == 'http' &&
        origin.userInfo.isEmpty &&
        origin.path.isEmpty &&
        !origin.hasQuery &&
        !origin.hasFragment &&
        origin.host.toLowerCase() == host &&
        origin.port == authority.port;
  }

  Future<void> _uploadJson(
      HttpResponse response, int status, Object body) async {
    final data = utf8.encode(jsonEncode(body));
    response.statusCode = status;
    response.headers.contentType = ContentType.json;
    response.contentLength = data.length;
    response.add(data);
    await response.close();
  }

  Future<void> _rejectUpload(HttpRequest request, int status, String error,
      {Map<String, Object>? state}) async {
    // dart:io otherwise drains an unlistened body before sending its response.
    // Never wait for a rejected (possibly infinite) body to finish uploading.
    final input = request.listen(null, onError: (Object _) {})..pause();
    request.response.persistentConnection = false;
    try {
      await _uploadJson(request.response, status, {'error': error, ...?state});
    } finally {
      await input.cancel();
    }
  }

  Future<void> _receive(SharePage page, HttpRequest request) async {
    final response = request.response;
    if (!_uploadAllowed(request)) {
      await _rejectUpload(request, HttpStatus.forbidden, 'Forbidden');
      return;
    }
    final names = request.uri.queryParametersAll['name'];
    if (names == null || names.length != 1 || names.single.isEmpty) {
      await _rejectUpload(request, HttpStatus.badRequest, 'Missing name');
      return;
    }
    if (request.contentLength > _maxUploadBytes) {
      await _rejectUpload(
          request, HttpStatus.requestEntityTooLarge, 'File exceeds 1 GiB');
      return;
    }
    final server = _servers[page.id];
    if (server == null) return;
    final upload = _Upload();
    (_uploads[page.id] ??= {}).add(upload);
    final task = _newTask(page, _receivedName(names.single), 'upload',
        max(0, request.contentLength));
    _cancelActions[task.id] = () async {
      upload.cancel();
      await upload.done.future;
    };
    final input = StreamIterator<List<int>>(request);
    // A single cancellation listener avoids retaining a Future per body chunk.
    unawaited(upload.cancelled.future.then((_) async {
      try {
        await input.cancel();
      } catch (_) {
        // The request may already have failed or disconnected.
      }
    }));
    RandomAccessFile? output;
    File? temporary;
    File? destination;
    var committed = false;
    ReceivedFile? pendingRecord;
    var bodyStarted = false;
    void checkActive() {
      if (upload.cancelled.isCompleted || _servers[page.id] != server) {
        throw _UploadCancelled();
      }
    }

    try {
      final directory = Directory(await receiveDirectoryFor(page));
      checkActive();
      temporary =
          File('${directory.path}${Platform.pathSeparator}.${newId()}.part');
      await temporary.create(exclusive: true);
      output = await temporary.open(mode: FileMode.write);
      var size = 0;
      while (true) {
        bodyStarted = true;
        final available = await input.moveNext();
        checkActive();
        if (!available) break;
        size += input.current.length;
        if (size > _maxUploadBytes) throw _UploadTooLarge();
        await output.writeFrom(input.current);
        task.update(size);
        if (task.totalBytes < size) task.totalBytes = size;
        _notifyProgress();
      }
      task.totalBytes = size;
      await output.close();
      output = null;
      checkActive();
      final name = _receivedName(names.single);
      var savedName = name;
      final dot = name.lastIndexOf('.');
      final stem = dot > 0 ? name.substring(0, dot) : name;
      final extension = dot > 0 ? name.substring(dot) : '';
      for (var index = 0;; index++) {
        checkActive();
        savedName = index == 0 ? name : '$stem ($index)$extension';
        final candidate =
            File('${directory.path}${Platform.pathSeparator}$savedName');
        try {
          // Reserve exclusively: simultaneous uploads cannot replace each other.
          await candidate.create(exclusive: true);
          destination = candidate;
          break;
        } on FileSystemException {
          if (!await FileSystemEntity.isFile(candidate.path) &&
              !await FileSystemEntity.isDirectory(candidate.path) &&
              !await FileSystemEntity.isLink(candidate.path)) {
            rethrow;
          }
        }
      }
      checkActive();
      await temporary.rename(destination.path);
      checkActive();
      pendingRecord = ReceivedFile(
        name: savedName,
        path: destination.path,
        size: size,
        pageTitle: page.title,
        receivedAt: DateTime.now(),
      );
      receivedFiles.insert(0, pendingRecord);
      await _persist();
      committed = true;
      task.status = 'completed';
      notifyListeners();
      await _uploadJson(
          response, HttpStatus.created, {'name': savedName, 'size': size});
    } on _UploadCancelled {
      await _closeAfterError(response, HttpStatus.badRequest);
    } on _UploadTooLarge {
      await _uploadJson(response, HttpStatus.requestEntityTooLarge,
          {'error': 'File exceeds 1 GiB'});
    } on HttpException {
      await _closeAfterError(response, HttpStatus.badRequest);
    } on SocketException {
      // Disconnected request: finally removes partial files.
    } catch (_) {
      if (!bodyStarted) {
        await _rejectUpload(
            request, HttpStatus.internalServerError, 'Cannot save file');
      } else {
        await _closeAfterError(response, HttpStatus.internalServerError);
      }
    } finally {
      try {
        await input.cancel();
      } catch (_) {
        // A disconnected client may fail cancellation too.
      }
      try {
        await output?.close();
      } finally {
        try {
          if (temporary != null && await temporary.exists()) {
            await temporary.delete();
          }
          if (!committed && pendingRecord != null) {
            receivedFiles.remove(pendingRecord);
          }
          if (!committed && destination != null && await destination.exists()) {
            await destination.delete();
          }
        } finally {
          final pending = _uploads[page.id];
          pending?.remove(upload);
          if (pending != null && pending.isEmpty) _uploads.remove(page.id);
          if (task.status == 'active') {
            task.status = upload.cancelled.isCompleted ? 'cancelled' : 'failed';
          }
          _cancelActions.remove(task.id);
          notifyListeners();
          upload.done.complete();
        }
      }
    }
  }

  Future<void> _serve(SharePage page, HttpRequest request) async {
    final response = request.response;
    response.headers.set('X-Content-Type-Options', 'nosniff');
    response.headers.set('Cache-Control', 'no-store');
    try {
      if (request.uri.path == '/uploads' ||
          request.uri.path.startsWith('/uploads/')) {
        await _serveSession(page, request);
        return;
      }
      if (request.uri.path == '/download.zip' && request.method == 'GET') {
        await _serveZip(page, request);
        return;
      }
      if (request.uri.path == '/upload') {
        if (request.method == 'POST') {
          await _receive(page, request);
        } else {
          response.headers.set('Allow', 'POST');
          await _closeAfterError(response, HttpStatus.methodNotAllowed);
        }
        return;
      }
      if (request.method != 'GET' && request.method != 'HEAD') {
        response.statusCode = HttpStatus.methodNotAllowed;
        response.headers.set('Allow', 'GET, HEAD');
        await response.close();
        return;
      }
      if (request.uri.path == '/') {
        final html = renderDownloadPage(
          page.title,
          page.files
              .map(
                (file) => DownloadItem(
                    id: file.id,
                    name: file.name,
                    size: file.size,
                    relativePath: file.relativePath),
              )
              .toList(),
        );
        final data = utf8.encode(html);
        response.headers.set('Content-Type', 'text/html; charset=utf-8');
        response.contentLength = data.length;
        if (request.method == 'GET') response.add(data);
        await response.close();
        return;
      }
      final segments = request.uri.pathSegments;
      if (segments.length != 2 ||
          segments[0] != 'file' ||
          !_uuidPattern.hasMatch(segments[1])) {
        response.statusCode = HttpStatus.notFound;
        await response.close();
        return;
      }
      SharedFile? selected;
      for (final file in page.files) {
        if (file.id == segments[1]) {
          selected = file;
          break;
        }
      }
      if (selected == null) {
        response.statusCode = HttpStatus.notFound;
        await response.close();
        return;
      }
      final source = File(selected.path);
      if (await FileSystemEntity.type(source.path, followLinks: false) !=
          FileSystemEntityType.file) {
        response.statusCode = HttpStatus.notFound;
        await response.close();
        return;
      }
      final stat = await source.stat();
      final length = stat.size;
      final modified = stat.modified.toUtc();
      final etag =
          '"${selected.id}-${length.toRadixString(16)}-${modified.microsecondsSinceEpoch.toRadixString(16)}"';
      response.headers.set(HttpHeaders.etagHeader, etag);
      response.headers
          .set(HttpHeaders.lastModifiedHeader, HttpDate.format(modified));
      final safeName =
          selected.name.replaceAll(RegExp(r'[\x00-\x1f\x7f/\\]'), '_').trim();
      final name = safeName.isEmpty ? 'download' : safeName;
      final fallback = name
          .replaceAll(RegExp(r'[^\x20-\x7e]'), '_')
          .replaceAll(RegExp(r'["\\;]'), '_');
      final inlineMime = request.uri.queryParameters['inline'] == '1'
          ? _previewMime(name)
          : null;
      response.headers
          .set('Content-Type', inlineMime ?? 'application/octet-stream');
      response.headers.set('Accept-Ranges', 'bytes');
      final encodedName = Uri.encodeComponent(name).replaceAll("'", '%27');
      response.headers.set(
        'Content-Disposition',
        '${inlineMime == null ? 'attachment' : 'inline'}; filename="$fallback"; filename*=UTF-8\'\'$encodedName',
      );
      var start = 0;
      var endExclusive = length;
      final range = request.headers.value(HttpHeaders.rangeHeader);
      final ifRange = request.headers.value(HttpHeaders.ifRangeHeader);
      if (range != null &&
          (ifRange == null || _ifRangeMatches(ifRange, etag, modified))) {
        final match = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(range.trim());
        if (match == null ||
            length == 0 ||
            (match.group(1)!.isEmpty && match.group(2)!.isEmpty)) {
          await _rangeNotSatisfiable(response, length);
          return;
        }
        final first = match.group(1)!;
        final last = match.group(2)!;
        if (first.isEmpty) {
          final suffix = int.tryParse(last);
          if (suffix == null || suffix <= 0) {
            await _rangeNotSatisfiable(response, length);
            return;
          }
          start = suffix >= length ? 0 : length - suffix;
        } else {
          final parsedStart = int.tryParse(first);
          final parsedEnd = last.isEmpty ? null : int.tryParse(last);
          if (parsedStart == null ||
              parsedStart >= length ||
              (last.isNotEmpty &&
                  (parsedEnd == null || parsedEnd < parsedStart))) {
            await _rangeNotSatisfiable(response, length);
            return;
          }
          start = parsedStart;
          if (parsedEnd != null) endExclusive = min(parsedEnd, length - 1) + 1;
        }
        response.statusCode = HttpStatus.partialContent;
        response.headers.set(
          'Content-Range',
          'bytes $start-${endExclusive - 1}/$length',
        );
      }
      response.contentLength = endExclusive - start;
      if (request.method == 'GET') {
        await _streamDownload(
            page, response, source, name, start, endExclusive);
      }
      await response.close();
    } on SocketException {
      // A client disconnect during a download is not a server failure.
    } on FileSystemException {
      await _closeAfterError(response, HttpStatus.notFound);
    } catch (error) {
      await _closeAfterError(response, HttpStatus.internalServerError);
      pageErrors[page.id] = '请求失败：$error';
      notifyListeners();
    }
  }

  Future<void> _closeAfterError(HttpResponse response, int status) async {
    try {
      response.statusCode = status;
    } catch (_) {
      // Headers may have already been sent while streaming.
    }
    try {
      await response.close();
    } catch (_) {
      // The peer may have disconnected.
    }
  }

  bool _ifRangeMatches(String validator, String etag, DateTime modified) {
    // If-Range requires a strong ETag. Weak, invalid, or stale validators must
    // fall back to a whole representation, never splice a changed file.
    final value = validator.trim();
    if (value == etag) return true;
    if (value.startsWith('"') || value.startsWith('W/')) return false;
    try {
      final date = HttpDate.parse(value);
      return date.millisecondsSinceEpoch ~/ 1000 ==
          modified.millisecondsSinceEpoch ~/ 1000;
    } on HttpException {
      return false;
    }
  }

  Future<void> _rangeNotSatisfiable(HttpResponse response, int length) async {
    response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
    response.headers.set('Content-Range', 'bytes */$length');
    response.contentLength = 0;
    await response.close();
  }

  DateTime _lastProgress = DateTime.fromMillisecondsSinceEpoch(0);
  void _notifyProgress() {
    final now = DateTime.now();
    if (now.difference(_lastProgress).inMilliseconds < 80) return;
    _lastProgress = now;
    notifyListeners();
  }

  TransferTask _newTask(SharePage page, String name, String direction, int size,
      {String? id, int offset = 0, String status = 'active'}) {
    final task = TransferTask(
        id: id ?? newId(),
        pageId: page.id,
        pageTitle: page.title,
        name: name,
        direction: direction,
        totalBytes: size,
        transferredBytes: offset,
        status: status);
    task._initialBytes = offset;
    transfers.insert(0, task);
    notifyListeners();
    return task;
  }

  TransferTask _sessionTask(_Session session) =>
      transfers.firstWhere((t) => t.id == session.id);

  Future<void> cancelTransfer(String id) async {
    final session = _sessions[id];
    if (session != null) {
      if (session.completion != null) await session.completion!.future;
      if (!_sessions.containsKey(id)) return;
      await _cancelActions[id]?.call();
      await _deleteSession(session);
    } else {
      await _cancelActions[id]?.call();
    }
    for (final task in transfers.where((t) => t.id == id)) {
      if (task.status != 'completed') task.status = 'cancelled';
    }
    notifyListeners();
  }

  Future<void> setReceiveOptions(SharePage page,
      {String? directory, bool organizeByDate = false}) async {
    if (directory != null &&
        directory.trim().isNotEmpty &&
        !p.isAbsolute(directory)) {
      throw ArgumentError('Receive directory must be absolute');
    }
    page.receiveDirectory = directory == null || directory.trim().isEmpty
        ? null
        : p.normalize(directory);
    page.organizeByDate = organizeByDate;
    await _persist();
    notifyListeners();
  }

  Future<String> receiveDirectoryFor(SharePage page) async {
    if (!_uuidPattern.hasMatch(page.id)) throw const FormatException('Page ID');
    final root = await _receiveRoot();
    final base = page.receiveDirectory == null
        ? root.path
        : p.normalize(p.absolute(page.receiveDirectory!));
    final now = DateTime.now();
    final date =
        '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    var directory = Directory(base);
    await directory.create(recursive: true);
    // Reject symlinked children, rather than letting a pre-existing page/date link escape.
    for (final component in [page.id, if (page.organizeByDate) date]) {
      directory = Directory(p.join(directory.path, component));
      final type =
          await FileSystemEntity.type(directory.path, followLinks: false);
      if (type != FileSystemEntityType.notFound &&
          type != FileSystemEntityType.directory) {
        throw const FileSystemException('Unsafe receive directory');
      }
      await directory.create();
    }
    return directory.path;
  }

  Future<void> addPaths(SharePage page, List<String> paths) async {
    Future<void> add(String path, String? relative, String root) async {
      final type = await FileSystemEntity.type(path, followLinks: false);
      if (type == FileSystemEntityType.link) return;
      if (type == FileSystemEntityType.directory) {
        await for (final child in Directory(path).list(followLinks: false)) {
          final rel = relative == null
              ? p.basename(child.path)
              : p.posix.join(relative, p.basename(child.path));
          await add(child.path, rel, root);
        }
      } else if (type == FileSystemEntityType.file) {
        final resolved = await File(path).resolveSymbolicLinks();
        if (resolved != root && !p.isWithin(root, resolved)) return;
        final id = newId();
        var stored = path;
        if (isMobile) {
          final directory = await _ensureFileDirectory();
          stored = p.join(directory.path, id);
          await File(path).copy(stored);
        }
        page.files.add(SharedFile(
            id: id,
            name: p.basename(path),
            path: stored,
            size: await File(stored).length(),
            managed: isMobile,
            relativePath: relative));
      }
    }

    for (final path in paths) {
      final absolute = p.normalize(p.absolute(path));
      if (await FileSystemEntity.type(absolute, followLinks: false) ==
          FileSystemEntityType.link) {
        continue;
      }
      final root = await File(absolute).resolveSymbolicLinks();
      await add(
          absolute,
          await FileSystemEntity.isDirectory(absolute)
              ? p.basename(absolute)
              : null,
          root);
    }
    await _persist();
    notifyListeners();
  }

  void _pruneReceipts() {
    final cutoff = DateTime.now().subtract(_receiptLifetime);
    final sorted = _receipts.values.toList()
      ..sort((a, b) => b.completedAt.compareTo(a.completedAt));
    final counts = <String, int>{};
    var retained = 0;
    for (final receipt in sorted) {
      if (receipt.pending != null) {
        counts[receipt.pageId] = (counts[receipt.pageId] ?? 0) + 1;
        retained++;
        continue;
      }
      final count = counts[receipt.pageId] ?? 0;
      if (receipt.completedAt.isBefore(cutoff) ||
          count >= 64 ||
          retained >= 256 ||
          !pages.any((page) => page.id == receipt.pageId)) {
        _receipts.remove(receipt.id);
      } else {
        counts[receipt.pageId] = count + 1;
        retained++;
      }
    }
  }

  Future<void> _restoreTransfers() async {
    try {
      final receipts =
          jsonDecode(_preferences!.getString(_receiptsKey) ?? '[]');
      if (receipts is List) {
        for (final raw in receipts) {
          if (raw is! Map ||
              raw['id'] is! String ||
              !_uuidPattern.hasMatch(raw['id'] as String) ||
              raw['pageId'] is! String ||
              !_uuidPattern.hasMatch(raw['pageId'] as String) ||
              raw['name'] is! String ||
              raw['size'] is! int ||
              (raw['size'] as int) < 0 ||
              (raw['size'] as int) > _maxUploadBytes ||
              raw['completedAt'] is! String) {
            continue;
          }
          final completedAt = DateTime.tryParse(raw['completedAt'] as String);
          if (completedAt == null ||
              completedAt
                  .isAfter(DateTime.now().add(const Duration(minutes: 5)))) {
            continue;
          }
          final receipt = _CompletedReceipt(
              id: raw['id'] as String,
              pageId: raw['pageId'] as String,
              name: _receivedName(raw['name'] as String),
              size: raw['size'] as int,
              completedAt: completedAt);
          _receipts[receipt.id] = receipt;
        }
      }
      _pruneReceipts();
    } on FormatException {
      /* A malformed receipt must not affect saved files. */
    }

    try {
      final records = jsonDecode(_preferences!.getString(_recordsKey) ?? '[]');
      if (records is List) {
        receivedFiles.addAll(
            records.map(ReceivedFile.fromJson).whereType<ReceivedFile>());
      }
    } on FormatException {
      /* Ignore malformed records, not the rest of startup. */
    }
    try {
      final sessions =
          jsonDecode(_preferences!.getString(_sessionsKey) ?? '[]');
      if (sessions is! List) return;
      for (final raw in sessions) {
        if (raw is! Map ||
            raw['id'] is! String ||
            !_uuidPattern.hasMatch(raw['id'] as String) ||
            raw['pageId'] is! String ||
            raw['name'] is! String ||
            raw['size'] is! int ||
            (raw['size'] as int) < 0 ||
            (raw['size'] as int) > _maxUploadBytes ||
            raw['fingerprint'] is! String ||
            raw['path'] is! String) {
          continue;
        }
        final matches =
            pages.where((page) => page.id == raw['pageId']).toList();
        if (matches.isEmpty ||
            _sessions.values.where((s) => s.pageId == raw['pageId']).length >=
                16) {
          continue;
        }
        final path = raw['path'] as String;
        final expectedRoot =
            matches.single.receiveDirectory ?? (await _receiveRoot()).path;
        final pageRoot =
            p.join(p.normalize(p.absolute(expectedRoot)), matches.single.id);
        final parent = p.dirname(path);
        final direct = p.equals(parent, pageRoot);
        final dated = p.equals(p.dirname(parent), pageRoot) &&
            RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(p.basename(parent));
        if ((!direct && !dated) ||
            !p.isAbsolute(path) ||
            path != p.normalize(path) ||
            await FileSystemEntity.type(pageRoot, followLinks: false) !=
                FileSystemEntityType.directory ||
            await FileSystemEntity.type(parent, followLinks: false) !=
                FileSystemEntityType.directory) {
          continue;
        }
        // Persisted paths are accepted only as the canonical .UUID.part child of this page.
        if (p.basename(path) != '.${raw['id']}.part' ||
            p.basename(p.dirname(path)) != matches.single.id &&
                !(RegExp(r'^\d{4}-\d{2}-\d{2}$')
                        .hasMatch(p.basename(p.dirname(path))) &&
                    p.basename(p.dirname(p.dirname(path))) ==
                        matches.single.id)) {
          continue;
        }
        if (await FileSystemEntity.type(path, followLinks: false) !=
            FileSystemEntityType.file) {
          continue;
        }
        final length = await File(path).length();
        if (length > (raw['size'] as int)) continue;
        final session = _Session(
            id: raw['id'] as String,
            pageId: raw['pageId'] as String,
            name: _receivedName(raw['name'] as String),
            size: raw['size'] as int,
            fingerprint: raw['fingerprint'] as String,
            path: path,
            offset: length);
        _sessions[session.id] = session;
        _newTask(matches.single, session.name, 'upload', session.size,
            id: session.id, offset: length, status: 'paused');
      }
    } on FormatException {/* Invalid preferences must not break startup. */}
  }

  Future<void> _deleteSession(_Session session) async {
    _sessions.remove(session.id);
    // Path is created here or validated during restore; never derived from client fingerprint/name.
    final file = File(session.path);
    if (p.basename(file.path) == '.${session.id}.part' &&
        await FileSystemEntity.type(file.path, followLinks: false) ==
            FileSystemEntityType.file) {
      await file.delete();
    }
    await _persist();
  }

  Future<void> _serveSession(SharePage page, HttpRequest request) async {
    final segments = request.uri.pathSegments;
    final response = request.response;
    if (request.method != 'GET' && !_uploadAllowed(request)) {
      await _rejectUpload(request, 403, 'Forbidden');
      return;
    }
    if (segments.length == 1 && request.method == 'POST') {
      final q = request.uri.queryParametersAll;
      final name = q['name'];
      final sizes = q['size'];
      final fingerprint = q['fingerprint'];
      final size = sizes?.length == 1 ? int.tryParse(sizes!.single) : null;
      if (name?.length != 1 ||
          name!.single.isEmpty ||
          size == null ||
          size < 0 ||
          fingerprint?.length != 1 ||
          fingerprint!.single.isEmpty ||
          fingerprint.single.length > 256) {
        await _rejectUpload(request, 400, 'Invalid session metadata');
        return;
      }
      if (size > _maxUploadBytes) {
        await _rejectUpload(request, 413, 'File exceeds 1 GiB');
        return;
      }
      final existing = _sessions.values
          .where(
              (s) => s.pageId == page.id && s.fingerprint == fingerprint.single)
          .toList();
      if (existing.isNotEmpty) {
        final session = existing.single;
        if (session.size != size) {
          await _rejectUpload(request, 409, 'Fingerprint metadata mismatch');
          return;
        }
        if (session.path.isEmpty) {
          await session.initialization?.future;
          final initialized = _sessions[session.id];
          if (initialized == null || initialized.path.isEmpty) {
            await _rejectUpload(request, 500, 'Cannot create session');
            return;
          }
          await _uploadJson(response, 201, initialized.state);
          return;
        }
        await _uploadJson(response, 201, session.state);
        return;
      }
      if (_sessions.values.where((s) => s.pageId == page.id).length >= 16) {
        await _rejectUpload(request, 429, 'Too many upload sessions');
        return;
      }
      // Reserve the slot synchronously before the first filesystem await.
      final id = newId();
      final session = _Session(
          id: id,
          pageId: page.id,
          name: _receivedName(name.single),
          size: size,
          fingerprint: fingerprint.single,
          path: '')
        ..busy = true
        ..initialization = Completer<void>();
      _sessions[id] = session;
      try {
        final directory = await receiveDirectoryFor(page);
        if (!_servers.containsKey(page.id)) throw _UploadCancelled();
        final stored = _Session(
            id: id,
            pageId: page.id,
            name: session.name,
            size: size,
            fingerprint: session.fingerprint,
            path: p.join(directory, '.$id.part'));
        await File(stored.path).create(exclusive: true);
        _sessions[id] = stored;
        _newTask(page, stored.name, 'upload', size, id: id, status: 'paused');
        await _persist();
      } catch (_) {
        final failed = _sessions.remove(id);
        if (failed != null &&
            failed.path.isNotEmpty &&
            await File(failed.path).exists()) {
          await File(failed.path).delete();
        }
        await _rejectUpload(request, 500, 'Cannot create session');
        return;
      } finally {
        session.initialization!.complete();
      }
      // A lost response must not destroy a successfully persisted resumable session.
      await _uploadJson(response, 201, _sessions[id]!.state);
      return;
    }
    if (segments.length < 2 || !_uuidPattern.hasMatch(segments[1])) {
      await _rejectUpload(request, 404, 'Unknown upload');
      return;
    }
    _pruneReceipts();
    final receipt = _receipts[segments[1]];
    if (receipt != null && receipt.pageId == page.id) {
      await receipt.pending;
      if (_receipts[receipt.id] == receipt) {
        if (segments.length == 2 && request.method == 'GET') {
          await _uploadJson(response, 200, receipt.state);
          return;
        }
        if (segments.length == 3 &&
            segments[2] == 'complete' &&
            request.method == 'POST') {
          await _uploadJson(response, 201, receipt.result);
          return;
        }
        if (segments.length == 2 && request.method == 'PATCH') {
          await _rejectUpload(request, 409, 'Upload already completed',
              state: receipt.state);
          return;
        }
        if (segments.length == 2 && request.method == 'DELETE') {
          _receipts.remove(receipt.id);
          await _persist();
          response.statusCode = 204;
          await response.close();
          return;
        }
        await _rejectUpload(request, 405, 'Method not allowed');
        return;
      }
    }
    final session = _sessions[segments[1]];
    if (session == null || session.pageId != page.id) {
      await _rejectUpload(request, 404, 'Unknown upload');
      return;
    }
    if (segments.length == 2 && request.method == 'GET') {
      await _uploadJson(response, 200, session.state);
      return;
    }
    if (segments.length == 2 &&
        request.method == 'DELETE' &&
        (!session.busy || _cancelActions.containsKey(session.id))) {
      await cancelTransfer(session.id);
      response.statusCode = 204;
      await response.close();
      return;
    }
    if (session.busy) {
      await _rejectUpload(request, 409, 'Session busy', state: session.state);
      return;
    }
    if (segments.length == 2 && request.method == 'PATCH') {
      final offsets = request.uri.queryParametersAll['offset'];
      final offset =
          offsets?.length == 1 ? int.tryParse(offsets!.single) : null;
      if (offset != session.offset) {
        await _rejectUpload(request, 409, 'Offset conflict',
            state: session.state);
        return;
      }
      if (request.contentLength > 4 * 1024 * 1024 ||
          request.contentLength >= 0 &&
              session.offset + request.contentLength > session.size) {
        await _rejectUpload(request, 413, 'Chunk exceeds limit');
        return;
      }
      session.busy = true;
      await _patchSession(page, session, request);
      return;
    }
    if (segments.length == 3 &&
        segments[2] == 'complete' &&
        request.method == 'POST') {
      session.busy = true;
      session.completion = Completer<void>();
      File? destination;
      ReceivedFile? record;
      try {
        if (await FileSystemEntity.type(session.path, followLinks: false) !=
            FileSystemEntityType.file) {
          throw const FileSystemException('Missing upload part');
        }
        if (session.offset != session.size ||
            await File(session.path).length() != session.size) {
          await _uploadJson(
              response, 409, {...session.state, 'error': 'Upload incomplete'});
          return;
        }
        destination = await _reserveName(
            Directory(p.dirname(session.path)), session.name);
        await File(session.path).rename(destination.path);
        record = ReceivedFile(
            name: p.basename(destination.path),
            path: destination.path,
            size: session.size,
            pageTitle: page.title,
            receivedAt: DateTime.now());
        receivedFiles.insert(0, record);
        _sessions.remove(session.id);
        final receipt = _CompletedReceipt(
            id: session.id,
            pageId: session.pageId,
            name: record.name,
            size: record.size,
            completedAt: record.receivedAt,
            pending: session.completion!.future);
        _receipts[receipt.id] = receipt;
        try {
          await _persist();
        } catch (_) {
          _receipts.remove(receipt.id);
          _sessions[session.id] = session;
          receivedFiles.remove(record);
          await destination.rename(session.path);
          destination = null;
          rethrow;
        }
        receipt.pending = null;
        _pruneReceipts();
        _sessionTask(session).status = 'completed';
        notifyListeners();
        await _uploadJson(
            response, 201, {'name': record.name, 'size': record.size});
      } catch (_) {
        if (_sessions.containsKey(session.id)) {
          _sessionTask(session).status = 'failed';
        }
        await _closeAfterError(response, 500);
      } finally {
        session.busy = false;
        session.completion!.complete();
        session.completion = null;
      }
      return;
    }
    await _rejectUpload(request, 405, 'Method not allowed');
  }

  Future<File> _reserveName(Directory directory, String name) async {
    final extension = p.extension(name);
    final stem = p.basenameWithoutExtension(name);
    for (var index = 0;; index++) {
      final candidate = File(p.join(
          directory.path, index == 0 ? name : '$stem ($index)$extension'));
      try {
        await candidate.create(exclusive: true);
        return candidate;
      } on FileSystemException {
        if (await FileSystemEntity.type(candidate.path, followLinks: false) ==
            FileSystemEntityType.notFound) {
          rethrow;
        }
      }
    }
  }

  Future<void> _patchSession(
      SharePage page, _Session session, HttpRequest request) async {
    final upload = _Upload();
    (_uploads[page.id] ??= {}).add(upload);
    final task = _sessionTask(session)..status = 'active';
    task._initialBytes = session.offset;
    task._clock.reset();
    final input = StreamIterator<List<int>>(request);
    _cancelActions[task.id] = () async {
      upload.cancel();
      await upload.done.future;
    };
    unawaited(upload.cancelled.future.then((_) async {
      try {
        await input.cancel();
      } catch (_) {}
    }));
    RandomAccessFile? output;
    var chunkSize = 0;
    var status = 200;
    final initialOffset = session.offset;
    try {
      if (await FileSystemEntity.type(session.path, followLinks: false) !=
          FileSystemEntityType.file) {
        throw const FileSystemException('Missing upload part');
      }
      output = await File(session.path).open(mode: FileMode.append);
      while (await input.moveNext()) {
        if (upload.cancelled.isCompleted || !_servers.containsKey(page.id)) {
          throw _UploadCancelled();
        }
        chunkSize += input.current.length;
        if (chunkSize > 4 * 1024 * 1024 ||
            initialOffset + chunkSize > session.size) {
          throw _UploadTooLarge();
        }
        await output.writeFrom(input.current);
        session.offset += input.current.length;
        task.update(session.offset);
        _notifyProgress();
      }
      if (upload.cancelled.isCompleted) throw _UploadCancelled();
      await output.flush();
      task.status = 'paused';
    } on _UploadTooLarge {
      await output?.truncate(initialOffset);
      session.offset = initialOffset;
      task.update(initialOffset);
      task.status = 'failed';
      status = 413;
    } on _UploadCancelled {
      task.status = 'paused';
      status = 400;
    } on SocketException {
      task.status = 'paused';
      status = 400;
    } on HttpException {
      task.status = 'paused';
      status = 400;
    } catch (_) {
      task.status = 'failed';
      status = 500;
    } finally {
      try {
        await input.cancel();
      } catch (_) {}
      try {
        await output?.close();
        session.offset = await File(session.path).length();
        task.update(session.offset);
        await _persist();
      } catch (_) {
        task.status = 'failed';
        status = 500;
      } finally {
        // Release the lock before acknowledgement: the next chunk may arrive immediately.
        session.busy = false;
        _cancelActions.remove(task.id);
        _uploads[page.id]?.remove(upload);
        upload.done.complete();
        notifyListeners();
      }
    }
    if (status == 200) {
      await _uploadJson(request.response, 200, session.state);
    } else {
      await _closeAfterError(request.response, status);
    }
  }

  String? _previewMime(String name) {
    return const {
      '.jpg': 'image/jpeg',
      '.jpeg': 'image/jpeg',
      '.png': 'image/png',
      '.gif': 'image/gif',
      '.webp': 'image/webp',
      '.avif': 'image/avif',
      '.bmp': 'image/bmp',
      '.mp4': 'video/mp4',
      '.webm': 'video/webm',
      '.mov': 'video/quicktime',
      '.mp3': 'audio/mpeg',
      '.m4a': 'audio/mp4',
      '.aac': 'audio/aac',
      '.wav': 'audio/wav',
      '.ogg': 'audio/ogg',
      '.flac': 'audio/flac'
    }[p.extension(name).toLowerCase()];
  }

  Future<void> _streamDownload(SharePage page, HttpResponse response,
      File source, String name, int start, int end,
      {TransferTask? existing}) async {
    final task = existing ?? _newTask(page, name, 'download', end - start);
    task.totalBytes = end - start;
    var cancelled = false;
    StreamSubscription<List<int>>? subscription;
    final done = Completer<void>();
    final stream = StreamController<List<int>>();
    _cancelActions[task.id] = () async {
      cancelled = true;
      task.status = 'cancelled';
      await subscription?.cancel();
      unawaited(stream.close());
      try {
        final socket = await response.detachSocket();
        socket.destroy();
      } catch (_) {}
      if (!done.isCompleted) done.complete();
    };
    stream.onListen = () {
      subscription = source.openRead(start, end).listen((bytes) {
        task.update(task.transferredBytes + bytes.length);
        _notifyProgress();
        stream.add(bytes);
      }, onError: stream.addError, onDone: stream.close);
    };
    stream.onPause = () => subscription?.pause();
    stream.onResume = () => subscription?.resume();
    stream.onCancel = () => subscription?.cancel();
    try {
      await Future.any([response.addStream(stream.stream), done.future]);
      if (!cancelled) {
        await response.close();
        task.status = 'completed';
      }
    } catch (_) {
      if (!cancelled) task.status = 'failed';
      rethrow;
    } finally {
      await subscription?.cancel();
      _cancelActions.remove(task.id);
      notifyListeners();
    }
  }

  String? _zipName(SharedFile file) {
    final name = (file.relativePath ?? file.name).replaceAll('\\', '/');
    final parts = name.split('/');
    if (name.isEmpty ||
        name.startsWith('/') ||
        RegExp(r'^[a-zA-Z]:').hasMatch(name) ||
        parts.any((part) =>
            part.isEmpty ||
            part == '.' ||
            part == '..' ||
            RegExp(r'[\x00-\x1f\x7f:]').hasMatch(part))) {
      return null;
    }
    return name;
  }

  /// ZIPs are regenerated for every request and are not resumable artifacts.
  /// Range/If-Range are intentionally ignored: each download receives a full ZIP.
  Future<void> _serveZip(SharePage page, HttpRequest request) async {
    final rawIds = request.uri.queryParametersAll['ids'];
    final ids = rawIds?.length == 1 ? rawIds!.single.split(',') : null;
    if (rawIds != null &&
        (rawIds.length != 1 ||
            ids == null ||
            ids.isEmpty ||
            ids.any((id) => !_uuidPattern.hasMatch(id)))) {
      await _closeAfterError(request.response, 400);
      return;
    }
    final selected = ids == null
        ? page.files
        : page.files.where((f) => ids.contains(f.id)).toList();
    if (ids != null &&
        selected.map((f) => f.id).toSet().length != ids.toSet().length) {
      await _closeAfterError(request.response, 404);
      return;
    }
    final entries = <List<String>>[];
    final used = <String>{};
    for (final file in selected) {
      final original = _zipName(file);
      if (original == null ||
          await FileSystemEntity.type(file.path, followLinks: false) !=
              FileSystemEntityType.file) {
        await _closeAfterError(request.response, 400);
        return;
      }
      var name = original;
      for (var n = 1; !used.add(name.toLowerCase()); n++) {
        final extension = p.posix.extension(original);
        name =
            '${original.substring(0, original.length - extension.length)} ($n)$extension';
      }
      entries.add([file.path, name]);
    }
    final temporary = await Directory.systemTemp.createTemp('landrop-zip-');
    final archive = File(p.join(temporary.path, 'download.zip'));
    final task = _newTask(page, '${page.title}.zip', 'download', 0);
    final port = ReceivePort();
    final exited = Completer<void>();
    final result = Completer<Object?>();
    final finished = Completer<void>();
    final cancellation = File(p.join(temporary.path, 'cancel'));
    var spawned = false;
    final messages = port.listen((message) {
      if (message == null) {
        if (!exited.isCompleted) exited.complete();
        if (!result.isCompleted) {
          result.complete('ZIP worker exited without a result');
        }
      } else if (message is Map) {
        if (!result.isCompleted) result.complete(message['error']);
      } else {
        // Uncaught worker errors are delivered as [error, stack].
        if (!result.isCompleted) result.complete(message.toString());
      }
    });
    var cancelled = false;
    final cancel = Completer<void>();
    _cancelActions[task.id] = () async {
      cancelled = true;
      task.status = 'cancelled';
      // Cooperative cancellation preserves the worker's finally blocks. Waiting
      // for request cleanup makes cancelTransfer a real resource-release barrier.
      await cancellation.create();
      if (!cancel.isCompleted) cancel.complete();
      await finished.future;
    };
    try {
      await Isolate.spawn(buildZipWorker,
          <Object>[port.sendPort, archive.path, entries, cancellation.path],
          onExit: port.sendPort, onError: port.sendPort, errorsAreFatal: true);
      spawned = true;
      final failure = await Future.any<Object?>([result.future, cancel.future]);
      if (cancelled) {
        await _closeAfterError(request.response, 400);
        return;
      }
      if (failure != null) throw FileSystemException('$failure');
      // The result confirms explicit close; onExit additionally confirms the
      // isolate cannot reopen a file while the owner streams/deletes the ZIP.
      await exited.future;
      final length = await archive.length();
      request.response.headers.set('Content-Type', 'application/zip');
      request.response.headers.set(HttpHeaders.acceptRangesHeader, 'none');
      request.response.headers
          .set('Content-Disposition', 'attachment; filename="download.zip"');
      request.response.contentLength = length;
      await _streamDownload(
          page, request.response, archive, task.name, 0, length,
          existing: task);
    } catch (_) {
      if (!cancelled) task.status = 'failed';
      await _closeAfterError(request.response, 500);
    } finally {
      try {
        if (spawned) await exited.future;
        await messages.cancel();
        port.close();
        _cancelActions.remove(task.id);
        // Fixed system-generated temp directory, never a request-derived path.
        if (p.basename(temporary.path).startsWith('landrop-zip-') &&
            p.isWithin(Directory.systemTemp.path, temporary.path)) {
          await temporary.delete(recursive: true);
        }
        notifyListeners();
      } finally {
        if (!finished.isCompleted) finished.complete();
      }
    }
  }

  Future<void> _persist() {
    _pruneReceipts();
    final receiptsJson = jsonEncode(
        _receipts.values.map((receipt) => receipt.toJson()).toList());
    final pagesJson = jsonEncode(pages.map((page) => page.toJson()).toList());
    final recordsJson =
        jsonEncode(receivedFiles.map((file) => file.toJson()).toList());
    final sessionsJson = jsonEncode(
        _sessions.values.map((session) => session.toJson()).toList());
    final result = _persistQueue.then((_) async {
      if (!await _preferences!.setString(_storageKey, pagesJson) ||
          !await _preferences!.setString(_recordsKey, recordsJson) ||
          !await _preferences!.setString(_sessionsKey, sessionsJson) ||
          !await _preferences!.setString(_receiptsKey, receiptsJson)) {
        throw const FileSystemException('Could not persist transfer state');
      }
    });
    _persistQueue = result.catchError((Object _) {});
    return result;
  }
}
