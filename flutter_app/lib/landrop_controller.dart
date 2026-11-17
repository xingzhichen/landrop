import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

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
  });

  final String id;
  final String name;
  final String path;
  final int size;
  final bool managed;

  Map<String, Object> toJson() => {
        'id': id,
        'name': name,
        'path': path,
        'size': size,
        'managed': managed,
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
    );
  }
}

class SharePage {
  SharePage({
    required this.id,
    required this.title,
    required this.files,
    this.running = false,
  });

  final String id;
  String title;
  final List<SharedFile> files;
  bool running;

  Map<String, Object> toJson() => {
        'id': id,
        'title': title,
        'running': running,
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
        unawaited(_serve(page, request));
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
    if (server != null) await server.close(force: true);
    await Future.wait(pending.map((upload) => upload.done.future));
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

  Future<void> _rejectUpload(
      HttpRequest request, int status, String error) async {
    // dart:io otherwise drains an unlistened body before sending its response.
    // Never wait for a rejected (possibly infinite) body to finish uploading.
    final input = request.listen(null, onError: (Object _) {})..pause();
    request.response.persistentConnection = false;
    try {
      await _uploadJson(request.response, status, {'error': error});
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
    var bodyStarted = false;
    void checkActive() {
      if (upload.cancelled.isCompleted || _servers[page.id] != server) {
        throw _UploadCancelled();
      }
    }

    try {
      final root = await _receiveRoot();
      checkActive();
      // Page IDs originate here or pass strict UUID validation on restore.
      if (!_uuidPattern.hasMatch(page.id)) {
        throw const FormatException('Page ID');
      }
      final directory =
          Directory('${root.path}${Platform.pathSeparator}${page.id}');
      await directory.create(recursive: true);
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
      }
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
      receivedFiles.insert(
          0,
          ReceivedFile(
            name: savedName,
            path: destination.path,
            size: size,
            pageTitle: page.title,
            receivedAt: DateTime.now(),
          ));
      committed = true;
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
          if (!committed && destination != null && await destination.exists()) {
            await destination.delete();
          }
        } finally {
          final pending = _uploads[page.id];
          pending?.remove(upload);
          if (pending != null && pending.isEmpty) _uploads.remove(page.id);
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
                (file) =>
                    DownloadItem(id: file.id, name: file.name, size: file.size),
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
      if (!await source.exists()) {
        response.statusCode = HttpStatus.notFound;
        await response.close();
        return;
      }
      final length = await source.length();
      final safeName =
          selected.name.replaceAll(RegExp(r'[\x00-\x1f\x7f/\\]'), '_').trim();
      final name = safeName.isEmpty ? 'download' : safeName;
      final fallback = name
          .replaceAll(RegExp(r'[^\x20-\x7e]'), '_')
          .replaceAll(RegExp(r'["\\;]'), '_');
      response.headers.set('Content-Type', 'application/octet-stream');
      response.headers.set('Accept-Ranges', 'bytes');
      final encodedName = Uri.encodeComponent(name).replaceAll("'", '%27');
      response.headers.set(
        'Content-Disposition',
        'attachment; filename="$fallback"; filename*=UTF-8\'\'$encodedName',
      );
      var start = 0;
      var endExclusive = length;
      final range = request.headers.value(HttpHeaders.rangeHeader);
      if (range != null) {
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
        await response.addStream(source.openRead(start, endExclusive));
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

  Future<void> _rangeNotSatisfiable(HttpResponse response, int length) async {
    response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
    response.headers.set('Content-Range', 'bytes */$length');
    response.contentLength = 0;
    await response.close();
  }

  Future<void> _persist() async {
    await _preferences!.setString(
      _storageKey,
      jsonEncode(pages.map((page) => page.toJson()).toList()),
    );
  }
}
