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

/// Owns each page's independent listener, persisted state, and mobile file copies.
class LanDropController extends ChangeNotifier {
  static const _storageKey = 'landrop.pages.v1';
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
    if (isMobile) {
      final support = await getApplicationSupportDirectory();
      _fileDirectory = Directory(
        '${support.path}${Platform.pathSeparator}landrop_shared_files',
      );
      await _fileDirectory!.create(recursive: true);
    }
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

  Future<void> addFiles(SharePage page, List<PlatformFile> selections) async {
    for (final selection in selections) {
      final path = selection.path;
      if (path == null) throw const FileSystemException('所选文件没有可读取的路径');
      final original = File(path);
      final size = await original.length();
      final id = newId();
      String storedPath = path;
      if (isMobile) {
        final destination = File(
          '${_fileDirectory!.path}${Platform.pathSeparator}$id',
        );
        try {
          await original.copy(destination.path);
        } catch (_) {
          if (await destination.exists()) await destination.delete();
          rethrow;
        }
        storedPath = destination.path;
      }
      page.files.add(
        SharedFile(
          id: id,
          name: selection.name,
          path: storedPath,
          size: size,
          managed: isMobile,
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
    if (!file.managed ||
        _fileDirectory == null ||
        !_uuidPattern.hasMatch(file.id)) {
      return;
    }
    final expected =
        '${_fileDirectory!.path}${Platform.pathSeparator}${file.id}';
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
    if (server != null) await server.close(force: true);
  }

  Future<void> _serve(SharePage page, HttpRequest request) async {
    final response = request.response;
    response.headers.set('X-Content-Type-Options', 'nosniff');
    response.headers.set('Cache-Control', 'no-store');
    try {
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
