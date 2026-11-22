import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:isolate';

import 'package:characters/characters.dart';
import 'package:path/path.dart' as p;

import 'zip_service.dart';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'download_page.dart';
import 'secure_receive_file.dart';

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
    this.canonicalPath,
    this.managedRoot,
    this.managedRootIdentity,
    this.managedLeafIdentity,
    this.managedPinBlocked = false,
  });

  final String id;
  final String name;
  final String path;
  final int size;
  final bool managed;
  final String? relativePath;

  /// Canonical target authorized when the user selected this file.
  final String? canonicalPath;
  final String? managedRoot;
  final String? managedRootIdentity;
  final String? managedLeafIdentity;
  final bool managedPinBlocked;

  Map<String, Object> toJson() => {
        'id': id,
        'name': name,
        'path': path,
        'size': size,
        'managed': managed,
        if (relativePath != null) 'relativePath': relativePath!,
        if (canonicalPath != null) 'canonicalPath': canonicalPath!,
        if (managedRoot != null) 'managedRoot': managedRoot!,
        if (managedRootIdentity != null)
          'managedRootIdentity': managedRootIdentity!,
        if (managedLeafIdentity != null)
          'managedLeafIdentity': managedLeafIdentity!,
        if (managedPinBlocked) 'managedPinBlocked': true,
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
    final managedRootIdentity = value['managedRootIdentity'];
    final malformedManagedRootIdentity = managed &&
        value.containsKey('managedRootIdentity') &&
        !SecureReceiveFile.isValidLeafIdentity(
            managedRootIdentity is String ? managedRootIdentity : null);
    final managedLeafIdentity = value['managedLeafIdentity'];
    final malformedManagedLeafIdentity = managed &&
        value.containsKey('managedLeafIdentity') &&
        !SecureReceiveFile.isValidLeafIdentity(
            managedLeafIdentity is String ? managedLeafIdentity : null);
    return SharedFile(
      id: id,
      name: name,
      path: path,
      size: size,
      managed: managed,
      canonicalPath: value['canonicalPath'] is String
          ? value['canonicalPath'] as String
          : null,
      relativePath: value['relativePath'] is String
          ? value['relativePath'] as String
          : null,
      managedRoot: value['managedRoot'] is String
          ? value['managedRoot'] as String
          : null,
      managedRootIdentity:
          managedRootIdentity is String ? managedRootIdentity : null,
      managedLeafIdentity:
          managedLeafIdentity is String ? managedLeafIdentity : null,
      managedPinBlocked: value['managedPinBlocked'] == true ||
          malformedManagedRootIdentity ||
          malformedManagedLeafIdentity,
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
    this.pageId,
  });

  final String? pageId;
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
        if (pageId != null) 'pageId': pageId!,
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
        pageId: value['pageId'] is String ? value['pageId'] as String : null,
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
  double? get remainingSeconds => totalBytes > 0 && bytesPerSecond > 0
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

class _ZipClientTokenTombstone {
  _ZipClientTokenTombstone(this.pageId, this.expiresAt);
  final String pageId;
  final DateTime expiresAt;
}

class _ZipInput {
  const _ZipInput({
    required this.source,
    required this.name,
    this.managedFile,
  });

  final File source;
  final String name;
  final SharedFile? managedFile;
}

class _ZipJob {
  _ZipJob(this.task, {this.clientToken});
  final TransferTask task;
  final String? clientToken;
  final Completer<void> requestFinished = Completer<void>();
  bool cancelled = false;
  File? cancellationMarker;
  Completer<void>? cancelWorker;
  Completer<void>? workerFinished;
  Future<void> Function()? cancelResponse;
}

class _Session {
  _Session(
      {required this.id,
      required this.pageId,
      required this.name,
      required this.size,
      required this.fingerprint,
      required this.path,
      this.receiveRoot,
      this.canonicalRoot,
      this.receiveRootIdentity,
      this.receiveParentIdentity,
      this.receiveLeafIdentity,
      this.offset = 0});
  final String id, pageId, name, fingerprint, path;

  /// Authorized page directory, independent of future receive settings.
  final String? receiveRoot;
  final String? canonicalRoot;
  final String? receiveRootIdentity;
  final String? receiveParentIdentity;
  String? receiveLeafIdentity;
  String? receiveQuarantineIdentity;
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
        if (receiveRoot != null) 'receiveRoot': receiveRoot!,
        if (canonicalRoot != null) 'canonicalRoot': canonicalRoot!,
        if (receiveRootIdentity != null)
          'receiveRootIdentity': receiveRootIdentity!,
        if (receiveParentIdentity != null)
          'receiveParentIdentity': receiveParentIdentity!,
        if (receiveLeafIdentity != null)
          'receiveLeafIdentity': receiveLeafIdentity!,
        if (receiveQuarantineIdentity != null)
          'receiveQuarantineIdentity': receiveQuarantineIdentity!,
        'offset': offset
      };
  Map<String, Object> get state => {'id': id, 'offset': offset, 'size': size};
}

/// A bounded completion receipt intentionally contains no local path/fingerprint.
class _ReceiveQuarantineCleanup {
  const _ReceiveQuarantineCleanup({
    required this.root,
    required this.sessionId,
    required this.expectedRootIdentity,
    required this.expectedQuarantineIdentity,
  });

  final String root;
  final String sessionId;
  final String expectedRootIdentity;
  final String expectedQuarantineIdentity;
}

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

/// A path-free HTTP representation; concurrent polls share the same future.
class _ManifestSnapshot {
  _ManifestSnapshot(this.title, this.bytes);
  final String title;
  final Future<List<int>> bytes;
  DateTime? completedAt;
}

/// Owns each page's independent listener, persisted state, and mobile file copies.
class LanDropController extends ChangeNotifier {
  /// Tests can supply a base directory without invoking path_provider and
  /// inject deterministic path swaps, short timeouts, and held download builds.
  LanDropController({
    Directory? receiveDirectory,
    @visibleForTesting Future<void> Function()? afterSessionSourceResolved,
    @visibleForTesting Future<void> Function()? beforeSecureReceiveUnlink,
    @visibleForTesting Duration uploadIdleTimeout = const Duration(minutes: 2),
    @visibleForTesting Future<void> Function()? beforeZipBuild,
    @visibleForTesting Future<void> Function()? beforeZipStream,
    @visibleForTesting Future<void> Function()? beforeZipCleanup,
    @visibleForTesting int? fileDownloadLimit,
    @visibleForTesting Future<void> Function()? beforeFileStream,
    @visibleForTesting int? pendingSessionLimit,
    @visibleForTesting int? httpRequestLimit,
    @visibleForTesting int? httpRejectionLimit,
    @visibleForTesting Future<void> Function()? beforeHttpServe,
    @visibleForTesting Future<void> Function()? beforeHttpRejectBody,
    @visibleForTesting Future<void> Function()? beforeServerRegistration,
    @visibleForTesting
    Future<void> Function(String path)? beforeRestoredSessionFileCheck,
    @visibleForTesting Future<void> Function()? beforePageRemoval,
    @visibleForTesting Future<void> Function()? beforeAddFileCommit,
  })  : assert(fileDownloadLimit == null || fileDownloadLimit > 0),
        assert(pendingSessionLimit == null || pendingSessionLimit > 0),
        assert(httpRequestLimit == null || httpRequestLimit > 0),
        assert(httpRejectionLimit == null || httpRejectionLimit > 0),
        _receiveBaseDirectory = receiveDirectory,
        _afterSessionSourceResolved = afterSessionSourceResolved,
        _beforeSecureReceiveUnlink = beforeSecureReceiveUnlink,
        _uploadIdleTimeout = uploadIdleTimeout,
        _beforeZipBuild = beforeZipBuild,
        _beforeZipStream = beforeZipStream,
        _beforeZipCleanup = beforeZipCleanup,
        _fileDownloadLimit = fileDownloadLimit ?? _maxConcurrentFileDownloads,
        _beforeFileStream = beforeFileStream,
        _pendingSessionLimit = pendingSessionLimit ?? _maxPendingUploadSessions,
        _httpRequestLimit = httpRequestLimit ?? _maxConcurrentHttpRequests,
        _httpRejectionLimit =
            httpRejectionLimit ?? _maxConcurrentHttpRejections,
        _beforeHttpServe = beforeHttpServe,
        _beforeHttpRejectBody = beforeHttpRejectBody,
        _beforeServerRegistration = beforeServerRegistration,
        _beforeRestoredSessionFileCheck = beforeRestoredSessionFileCheck,
        _beforePageRemoval = beforePageRemoval,
        _beforeAddFileCommit = beforeAddFileCommit;

  static const _storageKey = 'landrop.pages.v1';
  static const _recordsKey = 'landrop.received.v1';
  static const _recordsMigratedKey = 'landrop.received.pageIdsMigrated.v1';
  // Unmatched/ambiguous legacy records remain history, never future ownership.
  final Set<ReceivedFile> _unassignedLegacyRecords = {};
  static const _sessionsKey = 'landrop.sessions.v1';
  static const _receiptsKey = 'landrop.uploadReceipts.v1';
  static const _rawReceiveCleanupKey = 'landrop.rawReceiveCleanup.v1';
  final Map<String, Map<String, Object?>> _rawReceiveCleanupRecords = {};
  bool _rawReceiveCleanupJournalValid = true;
  static const _receiptLifetime = Duration(hours: 24);
  static const _unavailableSessionMessage =
      '部分上传临时数据暂不可访问或写入失败，续传记录已保留。检查接收目录和磁盘空间后重启应用；若移除该传输，无法访问的临时文件可能仍需手动清理。';
  final Map<String, _CompletedReceipt> _receipts = {};
  final List<TransferTask> transfers = [];
  final ValueNotifier<int> _transferProgressRevision = ValueNotifier(0);
  ValueListenable<int> get transferProgressRevision =>
      _transferProgressRevision;
  final Map<String, Future<void> Function()> _cancelActions = {};
  final Map<String, _ZipJob> _zipJobsByClientToken = {};
  final Map<String, _ZipClientTokenTombstone> _consumedZipClientTokens = {};
  final Map<String, _Session> _sessions = {};
  final Set<String> _sessionDeletionMarkers = {};
  final Set<String> _unavailableSessionIds = {};
  final List<Map<String, Object?>> _unrestoredSessionRecords = [];
  final Map<String, Set<Future<void>>> _requests = {};
  final Map<String, Future<void>> _startingPages = {};
  final Map<String, Future<void>> _bindingPages = {};
  final Map<String, Future<void>> _unbindingPages = {};
  final Map<String, Future<void>> _removingPages = {};
  final Map<String, int> _activePageMutations = {};
  final Map<String, Completer<void>> _pageMutationWaiters = {};
  static const _manifestLifetime = Duration(seconds: 1);
  final Map<String, _ManifestSnapshot> _manifests = {};
  final Map<String, String> _canonicalSources = {};
  Future<void> _persistQueue = Future.value();
  static const _maxUploadBytes = 1024 * 1024 * 1024;
  static const _maxConcurrentUploads = 8;
  static const _maxConcurrentHttpRequests = 64;
  static const _maxConcurrentHttpRejections = 16;
  static const _maxPendingUploadSessions = 128;
  static const _maxConcurrentFileDownloads = 16;
  // Every ZIP job owns a full temp archive and an isolate; bound app-wide disk/CPU.
  static const _maxConcurrentZipJobs = 2;
  // Tombstones live for at most ten minutes; the count cap may evict earlier.
  static const _maxRememberedZipTokens = 128;
  static const _zipClientTokenRetention = Duration(minutes: 10);
  static const _maxReceivedFileRecords = 1000;
  static const _maxReceivedFileRecordsPerPage = 200;
  static const _maxTerminalTransferTasks = 128;
  final Directory? _receiveBaseDirectory;
  final Future<void> Function()? _afterSessionSourceResolved;
  final Future<void> Function()? _beforeSecureReceiveUnlink;
  final Duration _uploadIdleTimeout;
  final Future<void> Function()? _beforeZipBuild;
  final Future<void> Function()? _beforeZipStream;
  final Future<void> Function()? _beforeZipCleanup;
  final int _fileDownloadLimit;
  final Future<void> Function()? _beforeFileStream;
  final int _pendingSessionLimit;
  final int _httpRequestLimit;
  final int _httpRejectionLimit;
  final Future<void> Function()? _beforeHttpServe;
  final Future<void> Function()? _beforeHttpRejectBody;
  final Future<void> Function()? _beforeServerRegistration;
  final Future<void> Function(String path)? _beforeRestoredSessionFileCheck;
  Future<void> Function()? _beforePageRemoval;
  Future<void> Function()? _beforeAddFileCommit;
  Future<void> Function()? _beforeManagedFileReferenceCheck;
  Future<void> Function(String id)? _beforeOrphanManagedFileCheck;
  Future<void> Function(String id)? _beforeManagedFileUnlink;
  Future<void> Function(String key)? _beforePersistKey;

  @visibleForTesting
  set beforePersistKey(Future<void> Function(String key)? callback) {
    _beforePersistKey = callback;
  }

  @visibleForTesting
  set beforePageRemoval(Future<void> Function()? callback) {
    _beforePageRemoval = callback;
  }

  @visibleForTesting
  set beforeAddFileCommit(Future<void> Function()? callback) {
    _beforeAddFileCommit = callback;
  }

  @visibleForTesting
  set beforeManagedFileReferenceCheck(Future<void> Function()? callback) {
    _beforeManagedFileReferenceCheck = callback;
  }

  @visibleForTesting
  set beforeOrphanManagedFileCheck(Future<void> Function(String id)? callback) {
    _beforeOrphanManagedFileCheck = callback;
  }

  @visibleForTesting
  set beforeManagedFileUnlink(Future<void> Function(String id)? callback) {
    _beforeManagedFileUnlink = callback;
  }

  @visibleForTesting
  set fileDirectoryForTesting(Directory directory) {
    _fileDirectory = directory;
    _fileDirectoryCanonical = null;
    _fileDirectoryIdentity = null;
    _managedFileRootIdentity = null;
    _managedFileRootIdentityPersisted = false;
    _managedRootIdentityConflict = false;
  }

  int _activeZipJobs = 0;
  int _activeHttpRequests = 0;
  int _activeHttpRejections = 0;
  int _activeFileDownloads = 0;
  int _zipWorkerSpawnCount = 0;
  final List<ReceivedFile> receivedFiles = [];
  String? receiveDirectory;
  final Map<String, Set<_Upload>> _uploads = {};
  int get _activeUploadCount =>
      _uploads.values.fold<int>(0, (count, uploads) => count + uploads.length);
  int get _pendingSessionCount =>
      _sessions.length + _unrestoredSessionRecords.length;
  int _sessionCountForPage(String pageId) =>
      _sessions.values.where((session) => session.pageId == pageId).length +
      _unrestoredSessionRecords
          .where((record) => record['pageId'] == pageId)
          .length;

  Future<void> _runPageMutation(
      SharePage page, Future<void> Function() operation) async {
    if (_conflictingPageIds.contains(page.id) ||
        _removingPages.containsKey(page.id) ||
        !pages.any((candidate) => candidate.id == page.id)) {
      throw StateError('Cannot modify a page while it is being removed.');
    }
    _activePageMutations.update(page.id, (count) => count + 1,
        ifAbsent: () => 1);
    try {
      await operation();
    } finally {
      final remaining = (_activePageMutations[page.id] ?? 1) - 1;
      if (remaining > 0) {
        _activePageMutations[page.id] = remaining;
      } else {
        _activePageMutations.remove(page.id);
        final waiter = _pageMutationWaiters.remove(page.id);
        if (waiter != null && !waiter.isCompleted) waiter.complete();
      }
    }
  }

  Future<void> _waitForPageMutations(String pageId) {
    if ((_activePageMutations[pageId] ?? 0) == 0) {
      return Future<void>.value();
    }
    return (_pageMutationWaiters[pageId] ??= Completer<void>()).future;
  }

  bool _hasUnavailableSessionForPage(String pageId) =>
      _unrestoredSessionRecords.any((record) => record['pageId'] == pageId) ||
      _sessions.values.any((session) =>
          session.pageId == pageId &&
          _unavailableSessionIds.contains(session.id));

  void _refreshPageRecoveryWarning(String pageId) {
    if (_hasUnavailableSessionForPage(pageId)) {
      pageRecoveryWarnings[pageId] = _unavailableSessionMessage;
    } else {
      pageRecoveryWarnings.remove(pageId);
    }
  }

  void _markSessionUnavailable(_Session session) {
    _unavailableSessionIds.add(session.id);
    _refreshPageRecoveryWarning(session.pageId);
  }

  Future<bool> _receiveRootMissingOrInaccessible(_Session session) async {
    final root = session.receiveRoot;
    final canonicalRoot = session.canonicalRoot;
    final expectedRootIdentity = session.receiveRootIdentity;
    if (root == null || canonicalRoot == null || expectedRootIdentity == null) {
      return true;
    }
    try {
      if (await FileSystemEntity.type(root, followLinks: false) !=
          FileSystemEntityType.directory) {
        return true;
      }
      if (!p.equals(
          await Directory(root).resolveSymbolicLinks(), canonicalRoot)) {
        return true;
      }
      final relativeParent = _relativeReceiveParent(root, session.path);
      final identity = await SecureReceiveFile.captureDirectoryIdentity(
          root: canonicalRoot, relativeParent: relativeParent);
      if (identity.rootIdentity != expectedRootIdentity ||
          identity.parentIdentity != session.receiveParentIdentity) {
        return true;
      }
      return await FileSystemEntity.type(session.path, followLinks: false) !=
          FileSystemEntityType.file;
    } on FileSystemException {
      return true;
    } on ArgumentError {
      return true;
    }
  }

  void _retainUnrestoredSession(Map raw, String pageId) {
    final id = raw['id'] as String;
    if (!_unrestoredSessionRecords.any((record) => record['id'] == id)) {
      _unrestoredSessionRecords.add(Map<String, Object?>.from(raw));
    }
    _unavailableSessionIds.add(id);
    if (raw['deleting'] == true) _sessionDeletionMarkers.add(id);
    _refreshPageRecoveryWarning(pageId);
  }

  @visibleForTesting
  int get uploadRegistryPageCountForTesting => _uploads.length;
  @visibleForTesting
  int get activeZipJobsForTesting => _activeZipJobs;
  @visibleForTesting
  int get zipWorkerSpawnCountForTesting => _zipWorkerSpawnCount;
  @visibleForTesting
  int get activeFileDownloadsForTesting => _activeFileDownloads;
  @visibleForTesting
  int get activeHttpRequestsForTesting => _activeHttpRequests;
  @visibleForTesting
  int get activeHttpRejectionsForTesting => _activeHttpRejections;
  @visibleForTesting
  int receiptCountForPageForTesting(String pageId) =>
      _receipts.values.where((receipt) => receipt.pageId == pageId).length;

  final List<SharePage> pages = [];
  final Map<String, HttpServer> _servers = {};
  final Map<String, String> pageErrors = {};
  final Set<String> _conflictingPageIds = {};
  final Map<String, List<Object?>> _conflictingPageRecords = {};
  final Map<String, String> pageRecoveryWarnings = {};
  List<String> addresses = [];
  SharedPreferences? _preferences;
  Directory? _fileDirectory;
  String? _fileDirectoryCanonical;
  String? _fileDirectoryIdentity;
  String? _managedFileRootIdentity;
  bool _managedFileRootIdentityPersisted = false;
  bool _managedRootIdentityConflict = false;
  static const _managedFileRootIdentityKey =
      'landrop.managedFileRootIdentity.v1';
  static const _managedFileDeletionKey = 'landrop.managedFileDeletions.v1';
  static const _managedFileCleanupQuarantineKey =
      'landrop.managedFileCleanupQuarantine.v1';
  final List<Map<String, Object?>> _managedFileDeletionJournal = [];
  Future<void> _managedFileReferenceQueue = Future<void>.value();
  final Map<String, String> managedFileCleanupWarnings = {};
  final Map<String, Future<String>> _managedRootIdentityCaptures = {};
  bool _managedFileCleanupBlocked = false;
  bool _managedFileQuarantineRequired = false;
  bool _managedFileQuarantinePersisted = false;
  @visibleForTesting
  bool? mobileForTesting;

  bool get isMobile =>
      mobileForTesting ?? (Platform.isAndroid || Platform.isIOS);
  int? portFor(SharePage page) => _servers[page.id]?.port;

  bool hasConflictingPageId(SharePage page) =>
      _conflictingPageIds.contains(page.id);

  /// ID ownership wins even after renames. A legacy title is safe only when
  /// exactly one current page has it, and migration has not left it unassigned.
  List<ReceivedFile> receivedFilesFor(SharePage page) {
    if (_conflictingPageIds.contains(page.id) ||
        !pages.any((candidate) => candidate.id == page.id)) {
      return [];
    }
    final uniqueTitle =
        pages.where((candidate) => candidate.title == page.title).length == 1;
    return receivedFiles.where((file) {
      if (file.pageId != null) return file.pageId == page.id;
      return uniqueTitle &&
          file.pageTitle == page.title &&
          !_unassignedLegacyRecords.contains(file);
    }).toList();
  }

  void _migrateLegacyRecords({required bool alreadyMigrated}) {
    for (var index = 0; index < receivedFiles.length; index++) {
      final record = receivedFiles[index];
      if (record.pageId != null || _unassignedLegacyRecords.contains(record)) {
        continue;
      }
      final matches = pages
          .where((page) =>
              !_conflictingPageIds.contains(page.id) &&
              page.title == record.pageTitle)
          .toList();
      if (!alreadyMigrated && matches.length == 1) {
        receivedFiles[index] = ReceivedFile(
          name: record.name,
          path: record.path,
          size: record.size,
          pageTitle: record.pageTitle,
          pageId: matches.single.id,
          receivedAt: record.receivedAt,
        );
      } else {
        _unassignedLegacyRecords.add(record);
      }
    }
  }

  Future<bool> _managedRootHasUuidEntries() async {
    final root = await _managedFileDirectoryPath();
    final type = await FileSystemEntity.type(root, followLinks: false);
    if (type == FileSystemEntityType.notFound) return false;
    if (type != FileSystemEntityType.directory) return true;
    await for (final entity in Directory(root).list(followLinks: false)) {
      if (_uuidPattern.hasMatch(p.basename(entity.path))) return true;
    }
    return false;
  }

  void _quarantineDuplicatePageRecord(
      String pageId, Map<String, Object?> rawRecord,
      {String? title}) {
    final warning = '发现重复的传输 ID（$pageId），已停用该分享并保留原始记录；自动文件清理已隔离。';
    _requireManagedFileCleanupQuarantine('metadata', warning);
    managedFileCleanupWarnings['duplicate-page:$pageId'] = warning;
    _conflictingPageRecords.putIfAbsent(pageId, () => []).add(rawRecord);
    if (!_conflictingPageIds.add(pageId)) return;

    final existingIndex = pages.indexWhere((page) => page.id == pageId);
    final existing = existingIndex < 0 ? null : pages.removeAt(existingIndex);
    pages.add(SharePage(
      id: pageId,
      title: '${existing?.title ?? title ?? '重复 ID 的传输记录'}（ID 冲突）',
      files: <SharedFile>[],
      running: false,
    ));
    pageErrors[pageId] = '检测到重复的传输 ID，已停止恢复服务并隐藏有歧义的文件列表。删除此冲突记录后可重新创建分享。';
  }

  bool _isValidRawCleanupIdentity(Object? value) =>
      value is String &&
      value.isNotEmpty &&
      value.length <= 512 &&
      !value.runes.any((rune) => rune < 0x20 || (rune >= 0x7f && rune <= 0x9f));

  bool _isSafeRawCleanupLeaf(Object? value) =>
      value is String &&
      value.isNotEmpty &&
      value != '.' &&
      value != '..' &&
      !value.contains('/') &&
      !value.contains('\\') &&
      !value.contains('\u0000') &&
      !value.runes.any((rune) => rune < 0x20 || (rune >= 0x7f && rune <= 0x9f));

  bool _isValidRawCleanupRecord(Map<String, Object?> record, String id) {
    final root = record['root'];
    final relativeParent = record['relativeParent'];
    final leaf = record['leaf'];
    final expectedRootIdentity = record['expectedRootIdentity'];
    final expectedParentIdentity = record['expectedParentIdentity'];
    final expectedLeafIdentity = record['expectedLeafIdentity'];
    final expectedQuarantineIdentity = record['expectedQuarantineIdentity'];
    final pageId = record['pageId'];
    return record['id'] == id &&
        _uuidPattern.hasMatch(id) &&
        root is String &&
        p.isAbsolute(root) &&
        root == p.normalize(root) &&
        relativeParent is String &&
        (relativeParent.isEmpty ||
            _isValidReceiveDateComponent(relativeParent)) &&
        _isSafeRawCleanupLeaf(leaf) &&
        _isValidRawCleanupIdentity(expectedRootIdentity) &&
        ((relativeParent.isEmpty && expectedParentIdentity == null) ||
            (relativeParent.isNotEmpty &&
                _isValidRawCleanupIdentity(expectedParentIdentity))) &&
        _isValidRawCleanupIdentity(expectedLeafIdentity) &&
        _isValidRawCleanupIdentity(expectedQuarantineIdentity) &&
        (pageId == null || pageId is String && _uuidPattern.hasMatch(pageId));
  }

  void _loadRawReceiveCleanupJournal() {
    final saved = _preferences!.getString(_rawReceiveCleanupKey);
    if (saved == null) return;
    try {
      final decoded = jsonDecode(saved);
      if (decoded is! List) throw const FormatException('Expected a list');
      final restored = <String, Map<String, Object?>>{};
      for (final raw in decoded) {
        if (raw is! Map) throw const FormatException('Invalid raw cleanup row');
        final record = Map<String, Object?>.from(raw);
        final id = record['id'];
        if (id is! String ||
            !_isValidRawCleanupRecord(record, id) ||
            restored.containsKey(id)) {
          throw const FormatException('Invalid or duplicate raw cleanup id');
        }
        restored[id] = record;
      }
      _rawReceiveCleanupRecords.addAll(restored);
    } catch (_) {
      _rawReceiveCleanupRecords.clear();
      _rawReceiveCleanupJournalValid = false;
      managedFileCleanupWarnings['rawQuarantineJournal'] =
          '原始上传清理日志无法验证，隔离文件已保留且不会自动删除。';
    }
  }

  /// Coalesces concurrent calls and restores controller state only once.
  Future<void> initialize() {
    if (_shuttingDown || _disposed) return Future<void>.value();
    final existing = _initializationFuture;
    if (existing != null) return existing;
    final initialization = _initialize();
    _initializationFuture = initialization;
    return initialization;
  }

  Future<void> _initialize() async {
    if (_shuttingDown || _disposed) return;
    _preferences = await SharedPreferences.getInstance();
    if (_shuttingDown || _disposed) return;
    _loadRawReceiveCleanupJournal();
    if (_preferences!.getBool(_managedFileCleanupQuarantineKey) == true) {
      _managedFileCleanupBlocked = true;
      _managedFileQuarantineRequired = true;
      _managedFileQuarantinePersisted = true;
      managedFileCleanupWarnings['quarantine'] =
          '受管文件状态曾出现无法确认的数据，自动孤儿清理已永久暂停。';
    }
    final saved = _preferences!.getString(_storageKey);
    if (saved == null) {
      _managedFileCleanupBlocked = true;
      final managedStateWasPersisted =
          _preferences!.getString(_managedFileRootIdentityKey) != null ||
              _preferences!.getString(_managedFileDeletionKey) != null;
      var hasUnknownManagedEntries = managedStateWasPersisted;
      if (!hasUnknownManagedEntries) {
        try {
          hasUnknownManagedEntries = await _managedRootHasUuidEntries();
        } catch (_) {
          // An unreadable/unsafe root is ambiguous; do not forget this state.
          hasUnknownManagedEntries = true;
        }
      }
      if (hasUnknownManagedEntries) {
        _requireManagedFileCleanupQuarantine(
            'metadata', '共享清单缺失但受管目录可能仍有文件，自动清理已持久隔离。');
      }
    }
    if (saved != null) {
      try {
        final decoded = jsonDecode(saved);
        if (decoded is List) {
          final pageIdCounts = <String, int>{};
          for (final rawPage in decoded) {
            if (rawPage is! Map) continue;
            final id = rawPage['id'];
            if (id is String && _uuidPattern.hasMatch(id)) {
              pageIdCounts.update(id, (count) => count + 1, ifAbsent: () => 1);
            }
          }
          final duplicatePageIds = pageIdCounts.entries
              .where((entry) => entry.value > 1)
              .map((entry) => entry.key)
              .toSet();

          for (final rawPage in decoded) {
            final rawRecord =
                rawPage is Map ? Map<String, Object?>.from(rawPage) : null;
            final rawId = rawRecord?['id'];
            final page = SharePage.fromJson(rawPage);
            if (page == null) {
              _requireManagedFileCleanupQuarantine(
                  'metadata', '传输记录损坏，自动孤儿清理已暂停以保护未知文件。');
              if (rawRecord != null &&
                  rawId is String &&
                  duplicatePageIds.contains(rawId)) {
                _quarantineDuplicatePageRecord(rawId, rawRecord);
              }
              continue;
            }
            final rawFiles = rawRecord?['files'];
            if (rawFiles is! List || rawFiles.length != page.files.length) {
              _requireManagedFileCleanupQuarantine(
                  'metadata', '共享文件记录损坏，自动孤儿清理已暂停以保护未知文件。');
            }
            if (duplicatePageIds.contains(page.id)) {
              _quarantineDuplicatePageRecord(page.id, rawRecord!,
                  title: page.title);
              continue;
            }
            pages.add(page);
          }
        } else {
          _requireManagedFileCleanupQuarantine(
              'metadata', '传输记录格式无效，自动孤儿清理已暂停以保护未知文件。');
        }
      } on FormatException {
        // A malformed preference must not prevent the app from opening; it
        // also disables orphan cleanup because ownership is unknown.
        _requireManagedFileCleanupQuarantine(
            'metadata', '传输记录损坏，自动孤儿清理已暂停以保护未知文件。');
      }
    }
    _loadManagedFileDeletionJournal();
    try {
      await _loadManagedFileRootIdentity();
    } catch (error) {
      _managedFileCleanupBlocked = true;
      managedFileCleanupWarnings['rootIdentity'] =
          '受管文件目录身份记录无法读取，已暂停自动清理：$error';
    }
    // Legacy records predate canonical, root, and leaf pins. Establish a
    // one-time baseline only for an existing regular file beneath the current
    // verified managed root, then persist it. This cannot prove the object was
    // never replaced before upgrade; missing/unsafe leaves remain blocked so a
    // later occupant cannot inherit authorization.
    for (final page in pages) {
      for (var i = 0; i < page.files.length; i++) {
        final file = page.files[i];
        if (file.managed && file.managedPinBlocked) {
          managedFileCleanupWarnings['pin:${file.id}'] =
              '受管共享文件的目录或叶子身份无法确认，文件已保留且不会分享或自动删除。';
          continue;
        }
        final needsCanonical = file.canonicalPath == null;
        final needsManagedPin = file.managed &&
            !file.managedPinBlocked &&
            (file.managedRoot == null || file.managedRootIdentity == null);
        final needsManagedLeafPin = file.managed &&
            !file.managedPinBlocked &&
            file.managedLeafIdentity == null;
        if (!needsCanonical && !needsManagedPin && !needsManagedLeafPin) {
          continue;
        }
        var canonicalPath = file.canonicalPath ?? '';
        String? managedRoot = file.managedRoot;
        String? managedRootIdentity = file.managedRootIdentity;
        var managedLeafIdentity = file.managedLeafIdentity;
        var managedPinBlocked = file.managedPinBlocked;
        try {
          if (file.managed && !managedPinBlocked) {
            final directory = await _ensureFileDirectory();
            if ((file.managedRoot != null &&
                    !p.equals(file.managedRoot!, directory.path)) ||
                (file.managedRootIdentity != null &&
                    file.managedRootIdentity != _fileDirectoryIdentity)) {
              throw FileSystemException(
                  'Managed-file root identity changed', file.path);
            }
            final expected = p.join(directory.path, file.id);
            if (p.isAbsolute(file.path) &&
                p.equals(file.path, expected) &&
                await FileSystemEntity.type(file.path, followLinks: false) ==
                    FileSystemEntityType.file) {
              final resolved = await File(file.path).resolveSymbolicLinks();
              if (p.equals(resolved, expected)) {
                canonicalPath = expected;
                managedRoot = directory.path;
                managedRootIdentity = _fileDirectoryIdentity;
                final currentLeafIdentity =
                    await SecureReceiveFile.captureManagedFileLeafIdentity(
                  root: directory.path,
                  leaf: file.id,
                  expectedRootIdentity: _fileDirectoryIdentity!,
                );
                if (managedLeafIdentity != null &&
                    (!SecureReceiveFile.isValidLeafIdentity(
                            managedLeafIdentity) ||
                        currentLeafIdentity.value != managedLeafIdentity)) {
                  throw FileSystemException(
                      'Managed-file leaf identity changed', file.path);
                }
                managedLeafIdentity ??= currentLeafIdentity.value;
                managedPinBlocked = false;
              } else {
                canonicalPath = '';
                managedPinBlocked = true;
              }
            } else {
              canonicalPath = '';
              managedPinBlocked = true;
            }
          } else if (needsCanonical &&
              p.isAbsolute(file.path) &&
              await FileSystemEntity.type(file.path, followLinks: false) ==
                  FileSystemEntityType.file) {
            canonicalPath = await File(file.path).resolveSymbolicLinks();
          }
        } on FileSystemException {
          // Keep missing shares visible, but do not authorize a future occupant.
          canonicalPath = '';
          managedRoot = null;
          managedRootIdentity = null;
          managedPinBlocked = file.managed;
        } on ArgumentError {
          canonicalPath = '';
          managedRoot = null;
          managedRootIdentity = null;
          managedPinBlocked = file.managed;
        }
        page.files[i] = SharedFile(
          id: file.id,
          name: file.name,
          path: file.path,
          size: file.size,
          managed: file.managed,
          relativePath: file.relativePath,
          canonicalPath: canonicalPath,
          managedRoot: managedRoot,
          managedRootIdentity: managedRootIdentity,
          managedLeafIdentity: managedLeafIdentity,
          managedPinBlocked: managedPinBlocked,
        );
        if (file.managed && managedPinBlocked) {
          managedFileCleanupWarnings['pin:${file.id}'] =
              '受管共享文件的目录或叶子身份无法确认，文件已保留且不会分享或自动删除。';
        }
      }
    }
    if (isMobile ||
        pages.any((page) => page.files.any((file) => file.managed)) ||
        _managedFileDeletionJournal.isNotEmpty) {
      try {
        await _recoverManagedFileDeletionJournal();
      } catch (error) {
        managedFileCleanupWarnings['journal'] = '受管文件清理状态暂未保存：$error';
      }
      await _cleanupOrphanManagedFiles();
    }
    if (_shuttingDown || _disposed) return;
    await _recoverRawReceiveCleanupJournal();
    if (_shuttingDown || _disposed) return;
    await _restoreTransfers();
    if (_shuttingDown || _disposed) return;
    await refreshAddresses();
    if (_shuttingDown || _disposed) return;
    for (final page in pages) {
      if (_shuttingDown || _disposed) return;
      if (!page.running) continue;
      try {
        await _bind(page);
        if (_shuttingDown || _disposed) return;
      } catch (error) {
        page.running = false;
        pageErrors[page.id] = '恢复服务失败：$error';
      }
    }
    if (_shuttingDown || _disposed) return;
    try {
      await _persist();
    } catch (error) {
      if (!_managedFileQuarantineRequired) rethrow;
      managedFileCleanupWarnings['quarantinePersist'] =
          '无法保存受管文件安全隔离标记，已保留原始传输记录且暂停清理：$error';
    }
    notifyListeners();
  }

  Future<void> refreshAddresses() async {
    if (_shuttingDown || _disposed) return;
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
    if (_shuttingDown || _disposed) return;
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
    if (_shuttingDown || _disposed) {
      throw StateError('Controller is shutting down');
    }
    final page = SharePage(id: newId(), title: title.trim(), files: []);
    pages.add(page);
    await _persist();
    notifyListeners();
    return page;
  }

  Future<String> _captureManagedRootIdentity(String root) {
    final pending = _managedRootIdentityCaptures[root];
    if (pending != null) return pending;
    final capture = SecureReceiveFile.captureManagedFileDirectoryIdentity(root)
        .then((identity) => identity.rootIdentity);
    _managedRootIdentityCaptures[root] = capture;
    unawaited(capture.then<void>(
      (_) {
        if (identical(_managedRootIdentityCaptures[root], capture)) {
          _managedRootIdentityCaptures.remove(root);
        }
      },
      onError: (Object _, StackTrace __) {
        if (identical(_managedRootIdentityCaptures[root], capture)) {
          _managedRootIdentityCaptures.remove(root);
        }
      },
    ));
    return capture;
  }

  Future<String> _managedFileDirectoryPath() async {
    if (_fileDirectory == null) {
      final support = await getApplicationSupportDirectory();
      _fileDirectory = Directory(
        p.join(support.path, 'landrop_shared_files'),
      );
    }
    final requestedPath = p.normalize(p.absolute(_fileDirectory!.path));
    if (await _hasSymbolicLinkComponent(requestedPath)) {
      throw FileSystemException(
          'Managed-file directory contains a symbolic link', requestedPath);
    }
    return requestedPath;
  }

  bool _canRebindManagedFileRoot() =>
      _managedFileDeletionJournal.isEmpty &&
      !pages.any((page) => page.files.any((file) => file.managed));

  Future<Directory> _ensureFileDirectory() async {
    if (_managedRootIdentityConflict && !_canRebindManagedFileRoot()) {
      throw const FileSystemException(
          'Managed-file root identity is inconsistent');
    }
    final requestedPath = await _managedFileDirectoryPath();
    if (await _hasSymbolicLinkComponent(requestedPath)) {
      throw FileSystemException(
          'Managed-file directory contains a symbolic link', requestedPath);
    }
    var type = await FileSystemEntity.type(requestedPath, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      await Directory(requestedPath).create(recursive: true);
      type = await FileSystemEntity.type(requestedPath, followLinks: false);
    }
    if (type != FileSystemEntityType.directory) {
      throw FileSystemException(
          'Managed-file directory is not a real directory', requestedPath);
    }
    final canonical = await Directory(requestedPath).resolveSymbolicLinks();
    if (!p.equals(canonical, requestedPath)) {
      throw FileSystemException(
          'Managed-file directory is not canonical', requestedPath);
    }
    final identity = await _captureManagedRootIdentity(canonical);
    final directoryChanged = _managedRootIdentityConflict ||
        (_fileDirectoryCanonical != null &&
            !p.equals(canonical, _fileDirectoryCanonical!)) ||
        (_fileDirectoryIdentity != null &&
            identity != _fileDirectoryIdentity) ||
        (_managedFileRootIdentity != null &&
            identity != _managedFileRootIdentity);
    if (directoryChanged) {
      if (!_canRebindManagedFileRoot()) {
        if (_managedFileRootIdentity != null &&
            identity != _managedFileRootIdentity) {
          _managedRootIdentityConflict = true;
          _managedFileCleanupBlocked = true;
          managedFileCleanupWarnings['rootIdentity'] = '受管文件目录身份已改变，已暂停自动清理。';
        }
        throw FileSystemException(
            'Managed-file directory identity changed', canonical);
      }
      // With no live references or deletion intents, the new directory can
      // safely receive future imports. Quarantine orphan scanning permanently
      // so pre-existing UUID entries in the replacement are never deleted.
      _requireManagedFileCleanupQuarantine(
          'rootIdentity', '受管文件目录已重建；新文件可继续使用，但孤儿自动清理已隔离。');
      _managedRootIdentityConflict = false;
      _managedFileRootIdentity = identity;
      _managedFileRootIdentityPersisted = false;
      _fileDirectoryCanonical = null;
      _fileDirectoryIdentity = null;
      try {
        await _persistManagedFileRootIdentity(identity);
        _managedFileRootIdentityPersisted = true;
      } catch (_) {
        _managedRootIdentityConflict = true;
        rethrow;
      }
    }
    _managedFileRootIdentity ??= identity;
    if (!_managedFileRootIdentityPersisted) {
      await _persistManagedFileRootIdentity(identity);
      _managedFileRootIdentityPersisted = true;
    }
    _fileDirectory = Directory(canonical);
    _fileDirectoryCanonical = canonical;
    _fileDirectoryIdentity = identity;
    return _fileDirectory!;
  }

  Future<void> _tryUnlinkManagedFileLeaf(
      String root, String id, String rootIdentity, String leafIdentity) async {
    try {
      await SecureReceiveFile.unlinkManagedFile(
        root: root,
        leaf: id,
        expectedRootIdentity: rootIdentity,
        expectedLeafIdentity: leafIdentity,
      );
      managedFileCleanupWarnings.remove(id);
    } catch (error) {
      // Cleanup must not replace the original import error. The startup orphan
      // scan will retry after revalidating the directory identity.
      managedFileCleanupWarnings[id] = '导入残留文件暂未清理：$error';
    }
    notifyListeners();
  }

  void _requireManagedFileCleanupQuarantine(String key, String message) {
    _managedFileCleanupBlocked = true;
    _managedFileQuarantineRequired = true;
    managedFileCleanupWarnings[key] = message;
  }

  Future<void> _persistManagedFileCleanupQuarantineIfNeeded() async {
    if (!_managedFileQuarantineRequired || _managedFileQuarantinePersisted) {
      return;
    }
    final beforeWrite = _beforePersistKey;
    if (beforeWrite != null) {
      await beforeWrite(_managedFileCleanupQuarantineKey);
    }
    if (!await _preferences!.setBool(_managedFileCleanupQuarantineKey, true)) {
      throw const FileSystemException(
          'Could not persist managed-file cleanup quarantine');
    }
    _managedFileQuarantinePersisted = true;
  }

  void _loadManagedFileDeletionJournal() {
    _managedFileDeletionJournal.clear();
    final saved = _preferences!.getString(_managedFileDeletionKey);
    if (saved == null) return;
    try {
      final decoded = jsonDecode(saved);
      if (decoded is List) {
        for (final entry in decoded) {
          if (entry is Map) {
            _managedFileDeletionJournal.add(Map<String, Object?>.from(entry));
          } else {
            _requireManagedFileCleanupQuarantine(
                'journal', '受管文件清理记录格式无效，已保留原文件以避免误删。');
          }
        }
      } else {
        _requireManagedFileCleanupQuarantine(
            'journal', '受管文件清理记录格式无效，已保留原文件以避免误删。');
      }
    } on FormatException {
      _requireManagedFileCleanupQuarantine(
          'journal', '受管文件清理记录损坏，已保留原文件以避免误删。');
    }
  }

  Future<void> _loadManagedFileRootIdentity() async {
    final saved = _preferences!.getString(_managedFileRootIdentityKey);
    if (saved != null) {
      if (saved.isEmpty) {
        _managedRootIdentityConflict = true;
        _requireManagedFileCleanupQuarantine(
            'rootIdentity', '受管文件目录身份记录无效，已暂停自动清理。');
        return;
      }
      _managedFileRootIdentity = saved;
      _managedFileRootIdentityPersisted = true;
    }
    final hasManagedRecord =
        pages.any((page) => page.files.any((file) => file.managed)) ||
            _managedFileDeletionJournal.any((entry) {
              final raw = entry['file'];
              final file = raw is Map ? SharedFile.fromJson(raw) : null;
              return file?.managed == true;
            });
    if (saved == null && !hasManagedRecord && !isMobile) return;
    final root = await _managedFileDirectoryPath();
    final pinnedIdentities = <String>{};
    void collect(SharedFile? file) {
      if (file == null ||
          !file.managed ||
          file.managedPinBlocked ||
          file.managedRoot == null ||
          file.managedRootIdentity == null ||
          !p.equals(file.managedRoot!, root)) {
        return;
      }
      pinnedIdentities.add(file.managedRootIdentity!);
    }

    for (final page in pages) {
      for (final file in page.files) {
        collect(file);
      }
    }
    for (final entry in _managedFileDeletionJournal) {
      final raw = entry['file'];
      collect(raw is Map ? SharedFile.fromJson(raw) : null);
    }

    if (saved != null) {
      if (pinnedIdentities.any((id) => id != saved)) {
        _managedRootIdentityConflict = true;
        _requireManagedFileCleanupQuarantine(
            'rootIdentity', '受管文件目录身份记录与现有文件不一致，已暂停自动清理。');
      }
      return;
    }
    if (pinnedIdentities.length > 1) {
      _managedRootIdentityConflict = true;
      _requireManagedFileCleanupQuarantine(
          'rootIdentity', '受管文件目录身份记录不一致，已暂停自动清理。');
      return;
    }
    if (pinnedIdentities.isNotEmpty) {
      _managedFileRootIdentity = pinnedIdentities.single;
    }
  }

  Future<void> _persistManagedFileRootIdentity(String identity) {
    final result = _persistQueue.then((_) async {
      await _persistManagedFileCleanupQuarantineIfNeeded();
      final beforeWrite = _beforePersistKey;
      if (beforeWrite != null) await beforeWrite(_managedFileRootIdentityKey);
      if (!await _preferences!
          .setString(_managedFileRootIdentityKey, identity)) {
        throw const FileSystemException(
            'Could not persist managed-file root identity');
      }
    });
    _persistQueue = result.catchError((Object _) {});
    return result;
  }

  Future<void> _persistManagedFileDeletionJournal() {
    final value = jsonEncode(_managedFileDeletionJournal);
    final result = _persistQueue.then((_) async {
      await _persistManagedFileCleanupQuarantineIfNeeded();
      final beforeWrite = _beforePersistKey;
      if (beforeWrite != null) await beforeWrite(_managedFileDeletionKey);
      if (!await _preferences!.setString(_managedFileDeletionKey, value)) {
        throw const FileSystemException(
            'Could not persist managed-file cleanup journal');
      }
    });
    _persistQueue = result.catchError((Object _) {});
    return result;
  }

  String? _journalFileId(Map<String, Object?> entry) {
    final rawFile = entry['file'];
    if (rawFile is! Map) return null;
    final file = SharedFile.fromJson(rawFile);
    return file?.managed == true ? file!.id : null;
  }

  bool _managedPathsMatch(String left, String right) =>
      p.equals(p.normalize(p.absolute(left)), p.normalize(p.absolute(right)));

  Future<bool> _sameExistingFileEntity(String left, String right) async {
    try {
      if (await FileSystemEntity.type(left, followLinks: false) ==
              FileSystemEntityType.notFound ||
          await FileSystemEntity.type(right, followLinks: false) ==
              FileSystemEntityType.notFound) {
        return false;
      }
      return await FileSystemEntity.identical(left, right);
    } catch (_) {
      return true;
    }
  }

  Future<bool> _legacyPathResolvesToManagedFile(
      String path, List<String> managedPaths) async {
    try {
      if (!await _hasSymbolicLinkComponent(path)) return false;
      final resolved = await File(path).resolveSymbolicLinks();
      return managedPaths.any((target) => _managedPathsMatch(resolved, target));
    } catch (_) {
      return true;
    }
  }

  bool _sameManagedFileLocation(SharedFile candidate, SharedFile file) {
    final candidatePaths = [
      candidate.path,
      if (candidate.canonicalPath != null) candidate.canonicalPath!,
    ];
    final filePaths = [
      file.path,
      if (file.canonicalPath != null) file.canonicalPath!,
    ];
    return candidatePaths.any(
        (left) => filePaths.any((right) => _managedPathsMatch(left, right)));
  }

  Future<bool> _managedFileIsReferenced(SharedFile file) async {
    final filePaths = [
      file.path,
      if (file.canonicalPath != null) file.canonicalPath!,
    ];
    for (final page in pages) {
      for (final candidate in page.files) {
        final beforeCheck = _beforeManagedFileReferenceCheck;
        if (beforeCheck != null) await beforeCheck();
        if (candidate.managed && candidate.id == file.id ||
            _sameManagedFileLocation(candidate, file)) {
          return true;
        }
        final candidatePaths = [
          candidate.path,
          if (candidate.canonicalPath != null) candidate.canonicalPath!,
        ];
        for (final candidatePath in candidatePaths) {
          for (final targetPath in filePaths) {
            if (await _sameExistingFileEntity(candidatePath, targetPath)) {
              return true;
            }
          }
        }
        if (candidate.canonicalPath == null ||
            candidate.canonicalPath!.isEmpty) {
          if (await _legacyPathResolvesToManagedFile(
              candidate.path, filePaths)) {
            return true;
          }
        }
      }
    }
    // Duplicate-page records are intentionally hidden in a placeholder, but
    // still own their original metadata until the user removes that conflict.
    // Treat matching IDs and paths as references, and conservatively block
    // cleanup if a preserved file record is too malformed to identify safely.
    for (final records in _conflictingPageRecords.values) {
      for (final rawPage in records) {
        if (rawPage is! Map) return true;
        final rawFiles = rawPage['files'];
        if (rawFiles == null && !rawPage.containsKey('files')) continue;
        if (rawFiles is! List) return true;
        for (final rawFile in rawFiles) {
          if (rawFile is! Map) return true;
          final id = rawFile['id'];
          final path = rawFile['path'];
          final canonicalPath = rawFile['canonicalPath'];
          final rawPaths = [
            if (path is String) path,
            if (canonicalPath is String) canonicalPath,
          ];
          if (id == file.id ||
              rawPaths.any((rawPath) => filePaths.any(
                  (targetPath) => _managedPathsMatch(rawPath, targetPath)))) {
            return true;
          }
          if (id is! String ||
              !_uuidPattern.hasMatch(id) ||
              path is! String ||
              rawFile.containsKey('canonicalPath') &&
                  canonicalPath is! String) {
            return true;
          }
          for (final rawPath in rawPaths) {
            for (final targetPath in filePaths) {
              if (await _sameExistingFileEntity(rawPath, targetPath)) {
                return true;
              }
            }
          }
          if (await _legacyPathResolvesToManagedFile(path, filePaths)) {
            return true;
          }
        }
      }
    }
    return false;
  }

  Future<T> _withManagedFileReferenceLock<T>(
      Future<T> Function() operation) async {
    final previous = _managedFileReferenceQueue;
    final gate = Completer<void>();
    _managedFileReferenceQueue = gate.future;
    try {
      await previous;
      return await operation();
    } finally {
      gate.complete();
    }
  }

  Map<String, Object?>? _managedFileDeletionIntentFor(SharedFile file) {
    for (final entry in _managedFileDeletionJournal) {
      final raw = entry['file'];
      if (raw is! Map) continue;
      final saved = SharedFile.fromJson(raw);
      if (saved?.id == file.id &&
          saved?.managedRootIdentity == file.managedRootIdentity &&
          saved?.managedRoot != null &&
          file.managedRoot != null &&
          p.equals(saved!.managedRoot!, file.managedRoot!)) {
        return entry;
      }
    }
    return null;
  }

  Future<void> _addManagedFileDeletionIntents(
      Iterable<SharedFile> files, String pageId) async {
    var changed = false;
    final additions = <Map<String, Object?>>[];
    try {
      for (final file in files.where((candidate) => candidate.managed)) {
        await _validateManagedFileAuthorization(file);
        final root = file.managedRoot;
        final identity = file.managedRootIdentity;
        if (root == null || identity == null || !p.isAbsolute(root)) {
          throw FileSystemException(
              'Managed file has no trusted directory identity', file.path);
        }
        final expectedPath = p.join(root, file.id);
        if (!p.equals(file.path, expectedPath) ||
            file.canonicalPath == null ||
            !p.equals(file.canonicalPath!, expectedPath)) {
          throw FileSystemException(
              'Managed file path does not match its pinned root', file.path);
        }
        final existingIntent = _managedFileDeletionIntentFor(file);
        final targetType =
            await FileSystemEntity.type(expectedPath, followLinks: false);
        if (existingIntent != null) {
          final savedIdentity = existingIntent['expectedLeafIdentity'];
          final savedIdentityIsValid = SecureReceiveFile.isValidLeafIdentity(
              savedIdentity is String ? savedIdentity : null);
          if (file.managedLeafIdentity != null &&
              savedIdentityIsValid &&
              savedIdentity != file.managedLeafIdentity) {
            _requireManagedFileCleanupQuarantine(
                file.id, '受管文件清理记录与创建时的叶子身份不一致，已保留原文件。');
            throw FileSystemException(
                'Managed-file deletion intent changed its leaf identity',
                file.path);
          }
          if (!savedIdentityIsValid &&
              (existingIntent.containsKey('expectedLeafIdentity') ||
                  file.managedLeafIdentity == null) &&
              targetType != FileSystemEntityType.notFound) {
            _requireManagedFileCleanupQuarantine(
                file.id, '旧版受管文件清理记录缺少叶子身份，已保留原文件。');
            throw FileSystemException(
                'Managed-file deletion intent has no leaf identity', file.path);
          }
          continue;
        }
        final leafIdentity = file.managedLeafIdentity == null
            ? targetType == FileSystemEntityType.notFound
                ? null
                : await SecureReceiveFile.captureManagedFileLeafIdentity(
                    root: root,
                    leaf: file.id,
                    expectedRootIdentity: identity,
                  )
            : ReceiveLeafIdentity(file.managedLeafIdentity!);
        final intent = <String, Object?>{
          'file': file.toJson(),
          'pageId': pageId,
          if (leafIdentity != null) 'expectedLeafIdentity': leafIdentity.value,
        };
        _managedFileDeletionJournal.add(intent);
        additions.add(intent);
        changed = true;
      }
      if (changed) await _persistManagedFileDeletionJournal();
    } catch (_) {
      // Roll back all staged entries for validation and persistence failures.
      // Otherwise a retry could mistake an in-memory-only intent for a durable one.
      for (final intent in additions) {
        _managedFileDeletionJournal.remove(intent);
      }
      rethrow;
    }
  }

  Future<void> _removeManagedFileDeletionIntent(SharedFile file) async {
    final originalLength = _managedFileDeletionJournal.length;
    _managedFileDeletionJournal.removeWhere((entry) {
      final raw = entry['file'];
      if (raw is! Map) return false;
      final saved = SharedFile.fromJson(raw);
      return saved?.id == file.id &&
          saved?.managedRootIdentity == file.managedRootIdentity &&
          saved?.managedRoot != null &&
          file.managedRoot != null &&
          p.equals(saved!.managedRoot!, file.managedRoot!);
    });
    if (_managedFileDeletionJournal.length < originalLength) {
      await _persistManagedFileDeletionJournal();
    }
  }

  Future<void> _recoverManagedFileDeletionJournal() async {
    var changed = false;
    for (final entry in _managedFileDeletionJournal.toList()) {
      final raw = entry['file'];
      final file = raw is Map ? SharedFile.fromJson(raw) : null;
      final rawExpectedLeafIdentity = entry['expectedLeafIdentity'];
      var expectedLeafIdentity =
          rawExpectedLeafIdentity is String ? rawExpectedLeafIdentity : null;
      if (!entry.containsKey('expectedLeafIdentity') &&
          SecureReceiveFile.isValidLeafIdentity(file?.managedLeafIdentity)) {
        expectedLeafIdentity = file!.managedLeafIdentity;
      }
      if (file == null ||
          !file.managed ||
          file.managedRoot == null ||
          file.managedRootIdentity == null) {
        final id = _journalFileId(entry) ?? 'journal';
        _requireManagedFileCleanupQuarantine(id, '受管文件清理记录无效，已保留原文件以避免误删。');
        continue;
      }
      await _withManagedFileReferenceLock(() async {
        if (await _managedFileIsReferenced(file)) {
          _managedFileDeletionJournal.remove(entry);
          changed = true;
          managedFileCleanupWarnings.remove(file.id);
          return;
        }
        if (!SecureReceiveFile.isValidLeafIdentity(
            expectedLeafIdentity is String ? expectedLeafIdentity : null)) {
          try {
            final root = await _validateManagedFileAuthorization(file);
            final type = await FileSystemEntity.type(p.join(root, file.id),
                followLinks: false);
            if (type == FileSystemEntityType.notFound) {
              _managedFileDeletionJournal.remove(entry);
              changed = true;
              managedFileCleanupWarnings.remove(file.id);
            } else {
              _requireManagedFileCleanupQuarantine(
                  file.id, '受管文件清理记录缺少叶子身份，已保留原文件。');
            }
          } catch (error) {
            managedFileCleanupWarnings[file.id] = '受管文件暂未清理：$error';
          }
          return;
        }
        try {
          await _deleteManagedFile(
            file,
            expectedLeafIdentity: expectedLeafIdentity as String,
          );
          _managedFileDeletionJournal.remove(entry);
          changed = true;
          managedFileCleanupWarnings.remove(file.id);
        } catch (error) {
          managedFileCleanupWarnings[file.id] = '受管文件暂未清理：$error';
        }
      });
    }
    if (changed) await _persistManagedFileDeletionJournal();
  }

  Future<void> _cleanupOrphanManagedFiles() =>
      _withManagedFileReferenceLock(() async {
        if (_managedFileCleanupBlocked) return;
        Directory directory;
        try {
          directory = await _ensureFileDirectory();
        } catch (error) {
          managedFileCleanupWarnings['root'] = '受管文件目录不可安全访问：$error';
          return;
        }
        if (_managedFileCleanupBlocked) return;
        final rootIdentity = _fileDirectoryIdentity;
        if (rootIdentity == null) {
          managedFileCleanupWarnings['root'] = '受管文件目录身份不可确认，已保留孤立文件。';
          return;
        }
        final referenced = <String>{};
        for (final page in pages) {
          for (final file in page.files) {
            if (file.managed) referenced.add(file.id);
          }
        }
        for (final entry in _managedFileDeletionJournal) {
          final raw = entry['file'];
          final file = raw is Map ? SharedFile.fromJson(raw) : null;
          if (file != null && file.managed) referenced.add(file.id);
        }
        try {
          await for (final entity in directory.list(followLinks: false)) {
            final id = p.basename(entity.path);
            if (!_uuidPattern.hasMatch(id) || referenced.contains(id)) continue;
            if (await FileSystemEntity.type(entity.path, followLinks: false) !=
                FileSystemEntityType.file) {
              continue;
            }
            final beforeCheck = _beforeOrphanManagedFileCheck;
            if (beforeCheck != null) await beforeCheck(id);
            final managedPath = p.join(directory.path, id);
            final candidate = SharedFile(
              id: id,
              name: id,
              path: managedPath,
              canonicalPath: managedPath,
              size: 0,
              managed: true,
              managedRoot: directory.path,
              managedRootIdentity: rootIdentity,
            );
            if (await _managedFileIsReferenced(candidate)) continue;
            try {
              final leafIdentity =
                  await SecureReceiveFile.captureManagedFileLeafIdentity(
                root: directory.path,
                leaf: id,
                expectedRootIdentity: rootIdentity,
              );
              await SecureReceiveFile.unlinkManagedFile(
                root: directory.path,
                leaf: id,
                expectedRootIdentity: rootIdentity,
                expectedLeafIdentity: leafIdentity.value,
              );
            } catch (error) {
              managedFileCleanupWarnings[id] = '孤立受管文件暂未清理：$error';
            }
          }
        } catch (error) {
          managedFileCleanupWarnings['root'] = '受管文件目录扫描失败：$error';
        }
      });

  Future<void> addFiles(SharePage page, List<PlatformFile> selections) =>
      _runPageMutation(
          page,
          () => _withManagedFileReferenceLock(() async {
                for (final selection in selections) {
                  final path = selection.path;
                  final managed = isMobile || path == null;
                  final id = newId();
                  Directory? managedDirectory;
                  String? managedRootIdentity;
                  String? managedLeafIdentity;
                  File? destination;
                  IOSink? sink;
                  var createdDestination = false;
                  var pageListCommitted = false;
                  var safeToDelete = true;
                  SharedFile? imported;
                  try {
                    var storedPath = path;
                    late int size;
                    if (managed) {
                      managedDirectory = await _ensureFileDirectory();
                      managedRootIdentity = _fileDirectoryIdentity!;
                      destination = File(p.join(managedDirectory.path, id));
                      await destination.create(exclusive: true);
                      createdDestination = true;
                      sink = destination.openWrite(mode: FileMode.append);
                      await sink.addStream(selection.readAsByteStream());
                      await sink.close();
                      sink = null;
                      size = await destination.length();
                      await _ensureFileDirectory();
                      if (await FileSystemEntity.type(destination.path,
                              followLinks: false) !=
                          FileSystemEntityType.file) {
                        throw FileSystemException(
                            'Imported managed entry is not a regular file',
                            destination.path);
                      }
                      final resolved = await destination.resolveSymbolicLinks();
                      final expectedPath = p.join(managedDirectory.path, id);
                      if (!p.equals(resolved, expectedPath)) {
                        throw FileSystemException(
                            'Imported managed entry escaped its pinned directory',
                            destination.path);
                      }
                      managedLeafIdentity = (await SecureReceiveFile
                              .captureManagedFileLeafIdentity(
                        root: managedDirectory.path,
                        leaf: id,
                        expectedRootIdentity: managedRootIdentity,
                      ))
                          .value;
                      storedPath = expectedPath;
                    } else {
                      size = await File(path).length();
                    }

                    final beforeCommit = _beforeAddFileCommit;
                    if (beforeCommit != null) await beforeCommit();
                    if (managed) {
                      await _ensureFileDirectory();
                      final currentLeafIdentity = await SecureReceiveFile
                          .captureManagedFileLeafIdentity(
                        root: managedDirectory!.path,
                        leaf: id,
                        expectedRootIdentity: managedRootIdentity!,
                      );
                      if (currentLeafIdentity.value != managedLeafIdentity) {
                        throw FileSystemException(
                            'Managed file changed before page commit',
                            destination!.path);
                      }
                    }
                    final canonicalPath =
                        await File(storedPath!).resolveSymbolicLinks();
                    if (managed &&
                        !p.equals(canonicalPath,
                            p.join(managedDirectory!.path, id))) {
                      throw FileSystemException(
                          'Managed source changed before it was committed',
                          storedPath);
                    }
                    if (managed) await _ensureFileDirectory();
                    imported = SharedFile(
                      id: id,
                      name: selection.name,
                      path: storedPath,
                      canonicalPath: canonicalPath,
                      size: size,
                      managed: managed,
                      managedRoot: managed ? managedDirectory!.path : null,
                      managedRootIdentity: managed ? managedRootIdentity : null,
                      managedLeafIdentity: managed ? managedLeafIdentity : null,
                    );
                    page.files.add(imported);
                    _manifests.remove(page.id);
                    await _persist(
                        onPageListStored: () => pageListCommitted = true);
                    managedFileCleanupWarnings.remove(id);
                    notifyListeners();
                  } catch (error) {
                    final openSink = sink;
                    if (openSink != null) {
                      try {
                        await openSink.close();
                      } catch (_) {
                        // Preserve the original import error.
                      }
                    }
                    if (imported != null && pageListCommitted) {
                      // The page-list key is the share commit point. Retain the file
                      // and finish best-effort metadata writes rather than reporting
                      // failure for a share that is already durably visible.
                      try {
                        await _persist();
                      } catch (retryError) {
                        pageErrors[page.id] = '共享文件已保存，但其他状态暂未保存：$retryError';
                      }
                      notifyListeners();
                      continue;
                    }
                    if (imported != null && !pageListCommitted) {
                      page.files.removeWhere((candidate) => candidate.id == id);
                      _manifests.remove(page.id);
                      var rollbackCommitted = false;
                      try {
                        await _persist(
                            onPageListStored: () => rollbackCommitted = true);
                      } catch (_) {
                        // Do not unlink while another queued snapshot may still own it.
                      }
                      safeToDelete = rollbackCommitted;
                    }
                    if (createdDestination &&
                        safeToDelete &&
                        managedDirectory != null &&
                        managedRootIdentity != null &&
                        managedLeafIdentity != null) {
                      await _tryUnlinkManagedFileLeaf(
                        managedDirectory.path,
                        id,
                        managedRootIdentity,
                        managedLeafIdentity,
                      );
                    }
                    rethrow;
                  }
                }
              }));

  Future<void> removeFile(SharePage page, SharedFile file) =>
      _runPageMutation(page, () async {
        if (!file.managed) {
          await _withManagedFileReferenceLock(() async {
            final originalFiles = List<SharedFile>.of(page.files);
            page.files.removeWhere((candidate) => candidate.id == file.id);
            _manifests.remove(page.id);
            var pageListCommitted = false;
            try {
              await _persist(onPageListStored: () => pageListCommitted = true);
            } catch (_) {
              if (!pageListCommitted) {
                page.files
                  ..clear()
                  ..addAll(originalFiles);
                _manifests.remove(page.id);
                try {
                  await _persist();
                } catch (_) {
                  // The failed page-list commit still has the old reference.
                }
                rethrow;
              }
              try {
                await _persist();
              } catch (_) {
                // The removed page-list entry is already durable.
              }
            }
            notifyListeners();
          });
          return;
        }

        await _withManagedFileReferenceLock(() async {
          await _validateManagedFileAuthorization(file);
          await _addManagedFileDeletionIntents([file], page.id);
          final originalIndex =
              page.files.indexWhere((candidate) => candidate.id == file.id);
          if (originalIndex >= 0) page.files.removeAt(originalIndex);
          _manifests.remove(page.id);
          var pageListCommitted = false;
          try {
            await _persist(onPageListStored: () => pageListCommitted = true);
          } catch (_) {
            if (!pageListCommitted) {
              if (originalIndex >= 0 &&
                  !page.files.any((candidate) => candidate.id == file.id)) {
                page.files.insert(min(originalIndex, page.files.length), file);
              }
              try {
                await _removeManagedFileDeletionIntent(file);
              } catch (_) {
                // The surviving page reference makes any stale intent harmless.
              }
              await _persist();
              rethrow;
            }
            // The page-list key is the deletion commit point. Retry other
            // metadata best-effort, then report success if secure cleanup works.
            try {
              await _persist();
            } catch (_) {
              // The durable page list and deletion journal still authorize this
              // cleanup; a later startup will recover any pending intent.
            }
          }
          notifyListeners();
          try {
            await _deleteManagedFile(file);
          } catch (error) {
            managedFileCleanupWarnings[file.id] = '受管文件暂未清理：$error';
            notifyListeners();
            rethrow;
          }
          try {
            await _removeManagedFileDeletionIntent(file);
            managedFileCleanupWarnings.remove(file.id);
          } catch (error) {
            // The file is already gone. Keep the durable intent for restart
            // recovery, but do not report the completed deletion as a failure.
            managedFileCleanupWarnings[file.id] = '文件已删除，清理记录将在启动时重试：$error';
            notifyListeners();
          }
        });
      });

  Future<void> removePage(SharePage page) {
    final existing = _removingPages[page.id];
    if (existing != null) return existing;
    final shouldResumeAfterFailure = page.running;
    final completion = Completer<void>();
    _removingPages[page.id] = completion.future;
    final operation = _performRemovePage(page);
    unawaited(operation.then<void>(
      (_) {
        if (identical(_removingPages[page.id], completion.future)) {
          _removingPages.remove(page.id);
        }
        completion.complete();
      },
      onError: (Object error, StackTrace stackTrace) {
        if (identical(_removingPages[page.id], completion.future)) {
          _removingPages.remove(page.id);
        }
        if (shouldResumeAfterFailure &&
            pages.any((candidate) => candidate.id == page.id) &&
            !_servers.containsKey(page.id)) {
          unawaited(start(page).catchError((_) {}));
        }
        completion.completeError(error, stackTrace);
      },
    ));
    return completion.future;
  }

  Future<void> _performRemovePage(SharePage page) async {
    await _unbind(page);
    await _waitForPageMutations(page.id);
    final beforePageRemoval = _beforePageRemoval;
    if (beforePageRemoval != null) await beforePageRemoval();
    for (final session
        in _sessions.values.where((s) => s.pageId == page.id).toList()) {
      await _deleteSession(session);
    }
    for (final task in transfers.where((t) => t.pageId == page.id)) {
      if (task.status != 'completed') task.status = 'cancelled';
    }
    _pruneTransferTasks();
    final deferred = _unrestoredSessionRecords
        .where((record) => record['pageId'] == page.id)
        .toList();
    for (final record in deferred) {
      final id = record['id'] as String;
      final index = _unrestoredSessionRecords.indexOf(record);
      if (index < 0) continue;
      final alreadyMarked = _sessionDeletionMarkers.contains(id);
      final deletingRecord = <String, Object?>{...record, 'deleting': true};
      _unrestoredSessionRecords[index] = deletingRecord;
      _sessionDeletionMarkers.add(id);
      _unavailableSessionIds.add(id);
      _refreshPageRecoveryWarning(page.id);
      try {
        await _persist();
      } catch (_) {
        _unrestoredSessionRecords[index] = record;
        if (!alreadyMarked) _sessionDeletionMarkers.remove(id);
        _refreshPageRecoveryWarning(page.id);
        rethrow;
      }

      // The durable marker lets startup finish this unlink after a crash.
      final quarantineCleanup =
          await _deleteUnrestoredSessionRecord(deletingRecord, page);
      _unrestoredSessionRecords.remove(deletingRecord);
      _sessionDeletionMarkers.remove(id);
      if (!_unrestoredSessionRecords.any((item) => item['id'] == id)) {
        _unavailableSessionIds.remove(id);
      }
      _refreshPageRecoveryWarning(page.id);
      try {
        await _persist();
      } catch (_) {
        _unrestoredSessionRecords.add(deletingRecord);
        _sessionDeletionMarkers.add(id);
        _unavailableSessionIds.add(id);
        _refreshPageRecoveryWarning(page.id);
        rethrow;
      }
      if (quarantineCleanup != null) {
        await _removeReceiveQuarantineBestEffort(quarantineCleanup);
      }
    }
    await _withManagedFileReferenceLock(() => _commitPageRemoval(page));
  }

  Future<void> _commitPageRemoval(SharePage page) async {
    final pageIndexBeforeRemoval =
        pages.indexWhere((candidate) => candidate.id == page.id);
    final hadPageBeforeRemoval = pageIndexBeforeRemoval >= 0;
    final receiptsBeforeRemoval = _receipts.entries
        .where((entry) => entry.value.pageId == page.id)
        .toList();
    final recordsBeforeRemoval = List<ReceivedFile>.from(receivedFiles);
    final unassignedBeforeRemoval =
        Set<ReceivedFile>.from(_unassignedLegacyRecords);
    final hadPageError = pageErrors.containsKey(page.id);
    final pageErrorBeforeRemoval = pageErrors[page.id];
    final conflictingPageRecordsBeforeRemoval =
        _conflictingPageRecords[page.id];
    final wasIdentityConflicted = _conflictingPageIds.contains(page.id);
    final duplicateWarningKey = 'duplicate-page:${page.id}';
    final duplicateWarningBeforeRemoval =
        managedFileCleanupWarnings[duplicateWarningKey];
    final managedFiles = List<SharedFile>.from(page.files);
    // Commit cleanup intent before page metadata can forget managed files.
    await _addManagedFileDeletionIntents(managedFiles, page.id);

    // Keep idempotent completion receipts until every cleanup marker commits.
    _receipts.removeWhere((_, receipt) => receipt.pageId == page.id);
    _unavailableSessionIds.removeAll(_sessions.values
        .where((session) => session.pageId == page.id)
        .map((session) => session.id));
    pageRecoveryWarnings.remove(page.id);
    // Resolve any in-memory legacy entries before removing their only owner.
    _migrateLegacyRecords(alreadyMigrated: false);
    pages.removeWhere((candidate) => candidate.id == page.id);
    _manifests.remove(page.id);
    pageErrors.remove(page.id);
    _conflictingPageIds.remove(page.id);
    _conflictingPageRecords.remove(page.id);
    managedFileCleanupWarnings.remove(duplicateWarningKey);
    var pageListCommitted = false;
    try {
      await _persist(onPageListStored: () => pageListCommitted = true);
    } catch (_) {
      if (!pageListCommitted) {
        if (hadPageBeforeRemoval &&
            !pages.any((candidate) => candidate.id == page.id)) {
          pages.insert(min(pageIndexBeforeRemoval, pages.length), page);
        }
        if (wasIdentityConflicted) {
          _conflictingPageIds.add(page.id);
          if (conflictingPageRecordsBeforeRemoval != null) {
            _conflictingPageRecords[page.id] =
                conflictingPageRecordsBeforeRemoval;
          }
        }
        if (duplicateWarningBeforeRemoval != null) {
          managedFileCleanupWarnings[duplicateWarningKey] =
              duplicateWarningBeforeRemoval;
        }
        for (final receipt in receiptsBeforeRemoval) {
          _receipts.putIfAbsent(receipt.key, () => receipt.value);
        }
        // Restore this page's pruned history without replacing records that
        // another page may have received while this commit was queued.
        final concurrentRecords = receivedFiles
            .where((record) =>
                record.pageId != null &&
                record.pageId != page.id &&
                !recordsBeforeRemoval.contains(record))
            .toList();
        receivedFiles
          ..clear()
          ..addAll(recordsBeforeRemoval)
          ..addAll(concurrentRecords)
          ..sort((a, b) => b.receivedAt.compareTo(a.receivedAt));
        _unassignedLegacyRecords.addAll(unassignedBeforeRemoval);
        _pruneReceivedFiles();
        _pruneReceipts();
        if (hadPageError) {
          pageErrors[page.id] = pageErrorBeforeRemoval!;
        }
        _refreshPageRecoveryWarning(page.id);
        // Earlier queued persistence calls may have captured the page-less
        // snapshot. Enqueue a fresh authoritative snapshot after rollback.
        try {
          await _persist();
        } catch (_) {
          // Keep the in-memory page; the failed operation still reports error.
        }
        for (final file in managedFiles.where((file) => file.managed)) {
          try {
            await _removeManagedFileDeletionIntent(file);
          } catch (_) {
            // A surviving page reference prevents a stale intent from deleting.
          }
        }
        notifyListeners();
        rethrow;
      }
      // The page list is the durable page-removal commit point. Finish a best-
      // effort write of the remaining keys, but do not report failure after the
      // page has already disappeared from persistent state.
      try {
        await _persist();
      } catch (_) {
        // The persisted page key is already committed; stale history/receipts
        // are harmless and are pruned against page IDs during restore.
      }
    }
    notifyListeners();
    Object? firstCleanupError;
    StackTrace? cleanupStack;
    for (final file in managedFiles.where((file) => file.managed)) {
      try {
        await _deleteManagedFile(file);
        await _removeManagedFileDeletionIntent(file);
        managedFileCleanupWarnings.remove(file.id);
      } catch (error, stack) {
        managedFileCleanupWarnings[file.id] = '页面已移除，受管文件清理将在重启后重试：$error';
        firstCleanupError ??= error;
        cleanupStack ??= stack;
      }
    }
    if (firstCleanupError != null) {
      notifyListeners();
      Error.throwWithStackTrace(firstCleanupError, cleanupStack!);
    }
  }

  Future<void> _deleteManagedFile(
    SharedFile file, {
    String? expectedLeafIdentity,
  }) async {
    if (!file.managed) return;
    // Callers hold the ownership lock across reference mutation, rollback and
    // cleanup, so no restored page can begin referencing this ID mid-unlink.
    if (await _managedFileIsReferenced(file)) return;
    final root = await _validateManagedFileAuthorization(file);
    final target = p.join(root, file.id);
    if (await FileSystemEntity.type(target, followLinks: false) ==
        FileSystemEntityType.notFound) {
      return;
    }
    final intent = _managedFileDeletionIntentFor(file);
    final intentLeafIdentity = intent?['expectedLeafIdentity'];
    final pinnedLeafIdentity = expectedLeafIdentity ??
        (intent != null && intent.containsKey('expectedLeafIdentity')
            ? intentLeafIdentity
            : file.managedLeafIdentity);
    if (!SecureReceiveFile.isValidLeafIdentity(
        pinnedLeafIdentity is String ? pinnedLeafIdentity : null)) {
      _requireManagedFileCleanupQuarantine(file.id, '受管文件清理记录缺少有效叶子身份，已保留原文件。');
      throw FileSystemException(
          'Managed-file deletion has no valid leaf identity', file.path);
    }
    final beforeUnlink = _beforeManagedFileUnlink;
    if (beforeUnlink != null) await beforeUnlink(file.id);
    await SecureReceiveFile.unlinkManagedFile(
      root: root,
      leaf: file.id,
      expectedRootIdentity: file.managedRootIdentity!,
      expectedLeafIdentity: pinnedLeafIdentity as String,
    );
  }

  Future<void> start(SharePage page) {
    if (_shuttingDown || _disposed) return Future<void>.value();
    if (_conflictingPageIds.contains(page.id)) {
      return Future<void>.error(
          StateError('Cannot start a page with a duplicate persisted ID.'));
    }
    if (_removingPages.containsKey(page.id) ||
        _unbindingPages.containsKey(page.id) ||
        !pages.any((candidate) => candidate.id == page.id)) {
      return Future<void>.value();
    }
    final existing = _startingPages[page.id];
    if (existing != null) return existing;
    if (_servers.containsKey(page.id)) return Future<void>.value();

    final completion = Completer<void>();
    _startingPages[page.id] = completion.future;
    final operation = _startPage(page);
    unawaited(operation.then<void>(
      (_) {
        if (identical(_startingPages[page.id], completion.future)) {
          _startingPages.remove(page.id);
        }
        completion.complete();
      },
      onError: (Object error, StackTrace stackTrace) {
        if (identical(_startingPages[page.id], completion.future)) {
          _startingPages.remove(page.id);
        }
        completion.completeError(error, stackTrace);
      },
    ));
    return completion.future;
  }

  Future<void> _startPage(SharePage page) async {
    await _bind(page);
    if (_shuttingDown ||
        _disposed ||
        !_servers.containsKey(page.id) ||
        _unbindingPages.containsKey(page.id) ||
        _removingPages.containsKey(page.id) ||
        !pages.any((candidate) => candidate.id == page.id)) {
      return;
    }
    page.running = true;
    pageErrors.remove(page.id);
    await _persist();
    notifyListeners();
  }

  Future<void> stop(SharePage page) => _unbind(page);

  Future<void> restart(SharePage page) async {
    await _unbind(page);
    await start(page);
  }

  Future<void> _rejectHttpRequest(HttpRequest request, int status, String error,
      {String? retryAfter}) async {
    final response = request.response;
    if (retryAfter != null) response.headers.set('Retry-After', retryAfter);
    response.headers.set('X-Content-Type-Options', 'nosniff');
    response.headers.set('Cache-Control', 'no-store');
    response.persistentConnection = false;
    final hasBody = _requestHasBody(request);
    if (_activeHttpRejections >= _httpRejectionLimit) {
      // Beyond the bounded drain budget, close promptly rather than retain an
      // unbounded number of rejected request bodies.
      response.statusCode = status;
      response.headers.contentType = ContentType.json;
      if (request.method != 'HEAD') response.contentLength = 0;
      await response.close();
      return;
    }
    _activeHttpRejections++;
    try {
      if (request.method == 'HEAD' && !hasBody) {
        response.statusCode = status;
        response.headers.contentType = ContentType.json;
        await response.close();
      } else if (hasBody) {
        final beforeRejectBody = _beforeHttpRejectBody;
        if (beforeRejectBody != null) await beforeRejectBody();
        await _rejectUpload(request, status, error,
            suppressBody: request.method == 'HEAD');
      } else {
        await _uploadJson(response, status, {'error': error});
      }
    } finally {
      _activeHttpRejections--;
    }
  }

  Future<void> _rejectHttpRequestLimit(HttpRequest request) =>
      _rejectHttpRequest(
          request, HttpStatus.tooManyRequests, 'Too many in-flight requests',
          retryAfter: '2');

  void _trackPageRequest(String pageId, Future<void> operation) {
    late final Future<void> tracked;
    tracked = operation
        .then<void>((_) {}, onError: (Object _, StackTrace __) {})
        .whenComplete(() {
      final pending = _requests[pageId];
      pending?.remove(tracked);
      if (pending != null && pending.isEmpty) _requests.remove(pageId);
    });
    (_requests[pageId] ??= {}).add(tracked);
    unawaited(tracked);
  }

  Future<void> _bind(SharePage page) {
    if (_shuttingDown || _disposed) return Future<void>.value();
    if (_conflictingPageIds.contains(page.id)) {
      return Future<void>.error(
          StateError('Cannot bind a page with a duplicate persisted ID.'));
    }
    final existing = _bindingPages[page.id];
    if (existing != null) return existing;
    late final Future<void> binding;
    binding = _bindPage(page).whenComplete(() {
      if (identical(_bindingPages[page.id], binding)) {
        _bindingPages.remove(page.id);
      }
    });
    _bindingPages[page.id] = binding;
    return binding;
  }

  Future<void> _bindPage(SharePage page) async {
    if (_shuttingDown || _disposed) return;
    final server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    try {
      final beforeServerRegistration = _beforeServerRegistration;
      if (beforeServerRegistration != null) {
        await beforeServerRegistration();
      }
    } catch (_) {
      await server.close(force: true);
      rethrow;
    }
    if (_shuttingDown ||
        _disposed ||
        _conflictingPageIds.contains(page.id) ||
        _unbindingPages.containsKey(page.id) ||
        _removingPages.containsKey(page.id) ||
        !pages.any((candidate) => candidate.id == page.id) ||
        _servers.containsKey(page.id)) {
      await server.close(force: true);
      return;
    }
    _servers[page.id] = server;
    server.listen(
      (request) {
        if (_shuttingDown ||
            _disposed ||
            !identical(_servers[page.id], server) ||
            _unbindingPages.containsKey(page.id) ||
            _removingPages.containsKey(page.id)) {
          _trackPageRequest(
              page.id,
              _rejectHttpRequest(request, HttpStatus.serviceUnavailable,
                  'Transfer is stopping',
                  retryAfter: '2'));
          return;
        }
        if (_activeHttpRequests >= _httpRequestLimit) {
          _trackPageRequest(page.id, _rejectHttpRequestLimit(request));
          return;
        }
        _activeHttpRequests++;
        final operation = _serve(page, request).whenComplete(() {
          _activeHttpRequests--;
        });
        _trackPageRequest(page.id, operation);
      },
      onError: (Object error) {
        if (_shuttingDown ||
            _disposed ||
            !identical(_servers[page.id], server) ||
            _unbindingPages.containsKey(page.id) ||
            _removingPages.containsKey(page.id)) {
          return;
        }
        pageErrors[page.id] = '服务错误：$error';
        notifyListeners();
      },
    );
  }

  Future<void> _unbind(SharePage page, {bool preserveRunning = false}) {
    final existing = _unbindingPages[page.id];
    if (existing != null) return existing;
    final completion = Completer<void>();
    // Close admission synchronously before any cancellation barrier can await.
    _unbindingPages[page.id] = completion.future;
    final pendingStart = _startingPages[page.id];
    final pendingBinding = _bindingPages[page.id];
    final operation = _performUnbind(page,
        pendingStart: pendingStart,
        pendingBinding: pendingBinding,
        preserveRunning: preserveRunning);
    unawaited(operation.then<void>(
      (_) {
        if (identical(_unbindingPages[page.id], completion.future)) {
          _unbindingPages.remove(page.id);
        }
        completion.complete();
      },
      onError: (Object error, StackTrace stackTrace) {
        if (identical(_unbindingPages[page.id], completion.future)) {
          _unbindingPages.remove(page.id);
        }
        completion.completeError(error, stackTrace);
      },
    ));
    return completion.future;
  }

  Future<void> _performUnbind(SharePage page,
      {Future<void>? pendingStart,
      Future<void>? pendingBinding,
      bool preserveRunning = false}) async {
    if (pendingStart != null) {
      try {
        await pendingStart;
      } catch (_) {
        // A failed bind must not prevent stop from cleaning existing state.
      }
    }
    if (pendingBinding != null) {
      try {
        await pendingBinding;
      } catch (_) {
        // A failed bind must not prevent shutdown from cleaning existing state.
      }
    }
    final server = _servers.remove(page.id);
    final listenerClosed = server?.close();
    final pending = _uploads[page.id]?.toList() ?? <_Upload>[];
    for (final upload in pending) {
      upload.cancel();
    }
    for (final task in transfers
        .where((t) => t.pageId == page.id && t.status == 'active')
        .toList()) {
      try {
        await _cancelActions[task.id]?.call();
      } catch (_) {
        // Continue closing the listener even if one worker cannot stop cleanly.
      }
      if (task.status == 'active') {
        task.status = _sessions.containsKey(task.id) ? 'paused' : 'cancelled';
      }
    }
    await Future.wait(pending.map((upload) => upload.done.future));
    await Future.wait(_requests[page.id]?.toList() ?? <Future<void>>[]);
    if (server != null) {
      await server.close(force: true);
      if (listenerClosed != null) await listenerClosed;
    }
    _requests.remove(page.id);
    if (_uploads[page.id]?.isEmpty ?? false) _uploads.remove(page.id);
    _pruneTransferTasks();
    if (!preserveRunning) {
      page.running = false;
      await _persist();
    }
    notifyListeners();
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
    final reservedDeviceName = RegExp(
        r'^(con|prn|aux|nul|com[1-9¹²³]|lpt[1-9¹²³])$',
        caseSensitive: false);
    bool isReservedDeviceName(String value) =>
        reservedDeviceName.hasMatch(value.split('.').first.trim());
    if (isReservedDeviceName(name)) name = '_$name';
    // Reserve internal quarantine paths on case-insensitive filesystems too.
    if (name.toLowerCase() ==
            SecureReceiveFile.quarantineDirectoryName.toLowerCase() ||
        RegExp(r'^\.[0-9a-f-]{36}\.part$', caseSensitive: false)
            .hasMatch(name)) {
      name = '_$name';
    }
    final shortened = StringBuffer();
    var bytes = 0;
    for (final grapheme in name.characters) {
      final graphemeBytes = utf8.encode(grapheme).length;
      if (bytes + graphemeBytes > 180) break;
      shortened.write(grapheme);
      bytes += graphemeBytes;
    }
    name = shortened.toString().replaceAll(RegExp(r'[. ]+$'), '');
    // Truncation can itself turn a longer stem into a Windows device name.
    if (isReservedDeviceName(name)) name = '_$name';
    return name.isEmpty || name == '.' || name == '..' ? 'upload' : name;
  }

  bool _requestHasBody(HttpRequest request) =>
      request.contentLength > 0 ||
      (request.headers['transfer-encoding']?.isNotEmpty ?? false);

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
      {Map<String, Object>? state, bool suppressBody = false}) async {
    final response = request.response;
    final data = utf8.encode(jsonEncode({'error': error, ...?state}));
    response.statusCode = status;
    response.headers.contentType = ContentType.json;
    response.contentLength = data.length;
    response.persistentConnection = false;
    // Closing HttpResponse with unread input makes dart:io destroy the socket,
    // which can reset TCP before the peer receives even this small error body.
    // Detach before writing headers, send the error, and half-close gracefully.
    // Drain only for a bounded grace period: a stalled/infinite rejected body
    // must never retain the request (or block stop) indefinitely.
    final socket = await response.detachSocket();
    final drained = Completer<void>();
    void finishDrain() {
      if (!drained.isCompleted) drained.complete();
    }

    final input = socket.listen((_) {},
        onError: (Object _) => finishDrain(), onDone: finishDrain);
    try {
      if (!suppressBody) socket.add(data);
      await socket.flush();
      await socket.close();
      await drained.future
          .timeout(const Duration(milliseconds: 250), onTimeout: () {});
    } finally {
      socket.destroy();
      await input.cancel();
    }
  }

  Future<void> _rejectSubscribedUpload(
      HttpRequest request,
      StreamIterator<List<int>> input,
      Future<bool> pending,
      int status,
      Map<String, Object?> body) async {
    final response = request.response;
    final data = utf8.encode(jsonEncode(body));
    response.statusCode = status;
    response.headers.contentType = ContentType.json;
    response.contentLength = data.length;
    response.persistentConnection = false;
    // The request already has a StreamIterator subscription, so drain through
    // that iterator rather than trying to listen to the detached socket twice.
    final socket = await response.detachSocket();
    final drainGrace = Stopwatch()..start();
    try {
      socket.add(data);
      await socket.flush();
      await socket.close();
      var next = pending;
      while (true) {
        final remaining =
            const Duration(milliseconds: 250) - drainGrace.elapsed;
        if (remaining <= Duration.zero) break;
        try {
          if (!await next.timeout(remaining)) break;
          next = input.moveNext();
        } on TimeoutException {
          break;
        } catch (_) {
          break;
        }
      }
    } finally {
      socket.destroy();
    }
  }

  Future<void> _rejectStalledUpload(HttpRequest request,
          StreamIterator<List<int>> input, Future<bool> pending,
          {Map<String, Object>? state}) =>
      _rejectSubscribedUpload(
          request, input, pending, HttpStatus.requestTimeout, {
        'error': '上传长时间无数据，已暂停，请检查连接后重试',
        ...?state,
      });

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
    if (server == null) {
      await _rejectUpload(
          request, HttpStatus.serviceUnavailable, '上传服务正在停止，请稍后重试');
      return;
    }
    if (_activeUploadCount >= _maxConcurrentUploads) {
      await _rejectUpload(
          request, HttpStatus.tooManyRequests, '当前上传任务较多，请稍后重试');
      return;
    }
    final upload = _Upload();
    (_uploads[page.id] ??= {}).add(upload);
    final task = _newTask(page, _receivedName(names.single), 'upload',
        max(0, request.contentLength));
    _cancelActions[task.id] = () async {
      upload.cancel();
      await upload.done.future;
    };
    final input = StreamIterator<List<int>>(request);
    // Subscribe before filesystem setup so stop can cancel even before the first
    // body chunk arrives; creating the temporary file must not precede listening.
    var pendingBody = input.moveNext();
    // Observe setup-time disconnects now; keep the original future so the normal
    // request loop still handles its result and error in order.
    unawaited(pendingBody.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    ));
    Future<void>? inputCancellation;
    Future<void> cancelInput() => inputCancellation ??= input.cancel();
    // A single cancellation listener avoids retaining a Future per body chunk.
    unawaited(upload.cancelled.future.then((_) async {
      try {
        await cancelInput();
      } catch (_) {
        // The request may already have failed or disconnected.
      }
    }));
    RandomAccessFile? output;
    File? temporary;
    String? temporarySessionId;
    File? destination;
    String? secureRoot;
    String? secureRelativeParent;
    String? secureRootIdentity;
    String? secureParentIdentity;
    String? secureLeafIdentity;
    String? secureDestinationLeafIdentity;
    var temporaryCreated = false;
    var destinationCreated = false;
    var committed = false;
    var recordPersistenceAttempted = false;
    ReceivedFile? pendingRecord;
    var bodyStarted = false;
    var deferUncommittedErrorResponse = false;
    int? deferredErrorStatus;
    void checkActive() {
      if (upload.cancelled.isCompleted || _servers[page.id] != server) {
        throw _UploadCancelled();
      }
    }

    try {
      final configuredDirectory = await receiveDirectoryFor(page);
      checkActive();
      final pageRoot = p.basename(configuredDirectory) == page.id
          ? configuredDirectory
          : p.dirname(configuredDirectory);
      final resolvedRoot = await Directory(pageRoot).resolveSymbolicLinks();
      secureRoot = resolvedRoot;
      final relativeParent = p.equals(configuredDirectory, pageRoot)
          ? ''
          : p.basename(configuredDirectory);
      secureRelativeParent = relativeParent;
      if (relativeParent.isNotEmpty &&
          !_isValidReceiveDateComponent(relativeParent)) {
        throw const FileSystemException('Unsafe receive-file directory');
      }
      final directory = Directory(p.join(resolvedRoot, relativeParent));
      if (await FileSystemEntity.type(directory.path, followLinks: false) !=
          FileSystemEntityType.directory) {
        throw FileSystemException('Receive directory changed', directory.path);
      }
      final directoryIdentity =
          await SecureReceiveFile.captureDirectoryIdentity(
        root: resolvedRoot,
        relativeParent: relativeParent,
      );
      if ((relativeParent.isEmpty &&
              directoryIdentity.parentIdentity != null) ||
          (relativeParent.isNotEmpty &&
              directoryIdentity.parentIdentity == null)) {
        throw FileSystemException(
            'Invalid receive directory identity', directory.path);
      }
      secureRootIdentity = directoryIdentity.rootIdentity;
      secureParentIdentity = directoryIdentity.parentIdentity;
      Future<void> verifyReceiveDirectoryIdentity() async {
        final current = await SecureReceiveFile.captureDirectoryIdentity(
          root: resolvedRoot,
          relativeParent: relativeParent,
        );
        if (current.rootIdentity != directoryIdentity.rootIdentity ||
            current.parentIdentity != directoryIdentity.parentIdentity) {
          throw FileSystemException(
              'Receive directory changed during upload', directory.path);
        }
      }

      checkActive();
      final uploadSessionId = newId();
      temporarySessionId = uploadSessionId;
      temporary = File(
          '${directory.path}${Platform.pathSeparator}.$uploadSessionId.part');
      final createdIdentity = await SecureReceiveFile.createReceiveEntry(
        root: resolvedRoot,
        relativeParent: relativeParent,
        leaf: p.basename(temporary.path),
        expectedRootIdentity: directoryIdentity.rootIdentity,
        expectedParentIdentity: directoryIdentity.parentIdentity,
      );
      secureLeafIdentity = createdIdentity.value;
      temporaryCreated = true;
      await verifyReceiveDirectoryIdentity();
      final currentLeafIdentity =
          await SecureReceiveFile.captureReceiveEntryIdentity(
        root: resolvedRoot,
        relativeParent: relativeParent,
        leaf: p.basename(temporary.path),
        expectedRootIdentity: directoryIdentity.rootIdentity,
        expectedParentIdentity: directoryIdentity.parentIdentity,
        expectedLeafIdentity: createdIdentity.value,
      );
      if (currentLeafIdentity.value != secureLeafIdentity) {
        throw FileSystemException(
            'Receive partial changed before writing', temporary.path);
      }
      output = await temporary.open(mode: FileMode.write);
      var size = 0;
      while (true) {
        checkActive();
        bodyStarted = true;
        final pending = pendingBody;
        final available =
            await pending.timeout(_uploadIdleTimeout, onTimeout: () async {
          checkActive();
          task.status = 'failed';
          await _rejectStalledUpload(request, input, pending);
          return false;
        });
        if (!available) {
          if (task.status == 'failed') return;
          break;
        }
        checkActive();
        size += input.current.length;
        if (size > _maxUploadBytes) throw _UploadTooLarge();
        await output.writeFrom(input.current);
        task.update(size);
        if (task.totalBytes > 0 && task.totalBytes < size) {
          task.totalBytes = size;
        }
        _notifyProgress();
        checkActive();
        pendingBody = input.moveNext();
      }
      task.totalBytes = size;
      await output.close();
      output = null;
      checkActive();
      await verifyReceiveDirectoryIdentity();
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
        // Mark the intended destination before native publication: if the
        // channel response is lost after the atomic move, pinned cleanup can
        // still remove this exact inode. Errors after this point are reported
        // only after the rollback attempt in finally.
        destination = candidate;
        secureDestinationLeafIdentity = secureLeafIdentity;
        destinationCreated = true;
        deferUncommittedErrorResponse = true;
        final published = await SecureReceiveFile.publishReceiveEntry(
          root: resolvedRoot,
          relativeParent: relativeParent,
          leaf: p.basename(temporary.path),
          destinationLeaf: p.basename(candidate.path),
          expectedRootIdentity: directoryIdentity.rootIdentity,
          expectedParentIdentity: directoryIdentity.parentIdentity,
          expectedLeafIdentity: secureLeafIdentity,
        );
        if (!published) {
          destinationCreated = false;
          secureDestinationLeafIdentity = null;
          continue;
        }
        temporaryCreated = false;
        break;
      }
      checkActive();
      await verifyReceiveDirectoryIdentity();
      pendingRecord = ReceivedFile(
        name: savedName,
        path: destination.path,
        size: size,
        pageTitle: page.title,
        pageId: page.id,
        receivedAt: DateTime.now(),
      );
      receivedFiles.insert(0, pendingRecord);
      recordPersistenceAttempted = true;
      await _persist();
      committed = true;
      task.status = 'completed';
      notifyListeners();
      await _uploadJson(
          response, HttpStatus.created, {'name': savedName, 'size': size});
    } on _UploadCancelled {
      if (deferUncommittedErrorResponse && !committed) {
        deferredErrorStatus = HttpStatus.badRequest;
      } else {
        await _closeAfterError(response, HttpStatus.badRequest);
      }
    } on _UploadTooLarge {
      await _uploadJson(response, HttpStatus.requestEntityTooLarge,
          {'error': 'File exceeds 1 GiB'});
    } on HttpException {
      if (deferUncommittedErrorResponse && !committed) {
        deferredErrorStatus = HttpStatus.badRequest;
      } else {
        await _closeAfterError(response, HttpStatus.badRequest);
      }
    } on SocketException {
      // Disconnected request: finally removes partial files.
    } catch (_) {
      if (!bodyStarted) {
        await _rejectSubscribedUpload(request, input, pendingBody,
            HttpStatus.internalServerError, {'error': 'Cannot save file'});
      } else if (deferUncommittedErrorResponse && !committed) {
        deferredErrorStatus = HttpStatus.internalServerError;
      } else {
        await _closeAfterError(response, HttpStatus.internalServerError);
      }
    } finally {
      try {
        await cancelInput();
      } catch (_) {
        // A disconnected client may fail cancellation too.
      }
      try {
        await output?.close();
      } finally {
        try {
          if (temporaryCreated &&
              temporary != null &&
              temporarySessionId != null &&
              secureRoot != null &&
              secureRelativeParent != null &&
              secureRootIdentity != null) {
            try {
              await _secureUnlinkRawEntry(
                  sessionId: temporarySessionId,
                  root: secureRoot,
                  relativeParent: secureRelativeParent,
                  leaf: p.basename(temporary.path),
                  expectedRootIdentity: secureRootIdentity,
                  expectedParentIdentity: secureParentIdentity,
                  expectedLeafIdentity: secureLeafIdentity!);
            } catch (_) {
              // Never fall back to a path-based unlink if the root changed.
            }
          }
          if (!committed && pendingRecord != null) {
            receivedFiles.remove(pendingRecord);
            if (recordPersistenceAttempted) {
              // Like session completion, raw-upload persistence may commit the
              // received list before a later metadata key fails. Persist the
              // rollback before deleting the uncommitted destination.
              try {
                await _persist();
              } catch (_) {
                // Earlier keys in the compensating snapshot may still commit.
              }
            }
          }
          if (!committed &&
              destinationCreated &&
              destination != null &&
              temporarySessionId != null &&
              secureRoot != null &&
              secureRelativeParent != null &&
              secureRootIdentity != null) {
            try {
              await _secureUnlinkRawEntry(
                  sessionId: temporarySessionId,
                  root: secureRoot,
                  relativeParent: secureRelativeParent,
                  leaf: p.basename(destination.path),
                  expectedRootIdentity: secureRootIdentity,
                  expectedParentIdentity: secureParentIdentity,
                  expectedLeafIdentity: secureDestinationLeafIdentity!);
            } catch (_) {
              // Preserve the destination rather than risk unlinking elsewhere.
            }
          }
        } finally {
          final pending = _uploads[page.id];
          pending?.remove(upload);
          if (pending != null && pending.isEmpty) _uploads.remove(page.id);
          if (task.status == 'active') {
            task.status = upload.cancelled.isCompleted ? 'cancelled' : 'failed';
          }
          _cancelActions.remove(task.id);
          _pruneTransferTasks();
          notifyListeners();
          final status = deferredErrorStatus;
          if (status != null) await _closeAfterError(response, status);
          upload.done.complete();
        }
      }
    }
  }

  Future<List<int>> _manifestFor(SharePage page) async {
    while (true) {
      var snapshot = _manifests[page.id];
      final now = DateTime.now();
      if (snapshot == null ||
          snapshot.title != page.title ||
          (snapshot.completedAt != null &&
              now.difference(snapshot.completedAt!) >= _manifestLifetime)) {
        snapshot = _ManifestSnapshot(
            page.title, _scanManifest(page.title, page.files.toList()));
        _manifests[page.id] = snapshot;
      }
      try {
        final bytes = await snapshot.bytes;
        snapshot.completedAt ??= DateTime.now();
        // Mutations invalidate even an in-flight scan: never publish its stale
        // result over a newer revision. Concurrent readers join the new scan.
        if (!identical(_manifests[page.id], snapshot) ||
            snapshot.title != page.title) {
          continue;
        }
        return bytes;
      } catch (_) {
        if (identical(_manifests[page.id], snapshot)) {
          _manifests.remove(page.id);
        }
        rethrow;
      }
    }
  }

  Future<String> _validateManagedFileAuthorization(SharedFile file) async {
    try {
      final root = await _validateManagedFileAuthorizationUnchecked(file);
      if (managedFileCleanupWarnings.remove('pin:${file.id}') != null) {
        notifyListeners();
      }
      return root;
    } catch (error) {
      final key = 'pin:${file.id}';
      final message = '受管共享文件身份校验失败，已禁止访问或删除：$error';
      if (managedFileCleanupWarnings[key] != message) {
        managedFileCleanupWarnings[key] = message;
        notifyListeners();
      }
      rethrow;
    }
  }

  Future<String> _validateManagedFileAuthorizationUnchecked(
      SharedFile file) async {
    final savedRoot = file.managedRoot;
    final expectedIdentity = file.managedRootIdentity;
    if (!file.managed ||
        file.managedPinBlocked ||
        savedRoot == null ||
        expectedIdentity == null ||
        !_uuidPattern.hasMatch(file.id)) {
      throw FileSystemException(
          'Managed file is missing a trusted directory identity', file.path);
    }
    final root = await _managedFileDirectoryPath();
    if (!p.equals(savedRoot, root)) {
      throw FileSystemException(
          'Managed file root is not the current app-private directory',
          savedRoot);
    }
    if (await FileSystemEntity.type(root, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw FileSystemException('Managed-file directory is unsafe', root);
    }
    final canonicalRoot = await Directory(root).resolveSymbolicLinks();
    if (!p.equals(canonicalRoot, root)) {
      throw FileSystemException(
          'Managed-file directory is not canonical', root);
    }
    final actualIdentity = await _captureManagedRootIdentity(root);
    if (actualIdentity != expectedIdentity) {
      throw FileSystemException(
          'Managed-file directory identity changed', root);
    }
    final expectedPath = p.join(root, file.id);
    if (!p.equals(file.path, expectedPath) ||
        file.canonicalPath == null ||
        !p.equals(file.canonicalPath!, expectedPath)) {
      throw FileSystemException(
          'Managed-file path does not match its pinned root', file.path);
    }
    final leafType = await FileSystemEntity.type(file.path, followLinks: false);
    if (leafType != FileSystemEntityType.notFound &&
        leafType != FileSystemEntityType.file) {
      throw FileSystemException(
          'Managed-file entry is not a regular file', file.path);
    }
    final expectedLeafIdentity = file.managedLeafIdentity;
    if (expectedLeafIdentity != null) {
      if (!SecureReceiveFile.isValidLeafIdentity(expectedLeafIdentity)) {
        throw FileSystemException(
            'Managed-file leaf identity is invalid', file.path);
      }
      if (leafType == FileSystemEntityType.file) {
        final actualLeafIdentity =
            await SecureReceiveFile.captureManagedFileLeafIdentity(
          root: root,
          leaf: file.id,
          expectedRootIdentity: expectedIdentity,
        );
        if (actualLeafIdentity.value != expectedLeafIdentity) {
          throw FileSystemException(
              'Managed-file leaf identity changed', file.path);
        }
      }
    }
    return root;
  }

  /// Preserve the model's canonical root/leaf binding, then delegate the
  /// actual no-follow open, identity check, and read to the native layer.
  Future<ManagedFileChunk> _readManagedFileChunk(
      SharedFile file, int offset, int maxBytes) async {
    final root = file.managedRoot;
    final rootIdentity = file.managedRootIdentity;
    final leafIdentity = file.managedLeafIdentity;
    if (!file.managed ||
        file.managedPinBlocked ||
        root == null ||
        rootIdentity == null ||
        leafIdentity == null ||
        !SecureReceiveFile.isValidLeafIdentity(leafIdentity)) {
      throw FileSystemException(
          'Managed file has no trusted root and leaf identity', file.path);
    }
    final expectedPath = p.join(root, file.id);
    if (!p.isAbsolute(root) ||
        !p.equals(file.path, expectedPath) ||
        file.canonicalPath == null ||
        !p.equals(file.canonicalPath!, expectedPath)) {
      throw FileSystemException(
          'Managed file path does not match its pinned root', file.path);
    }
    return SecureReceiveFile.readManagedFileChunk(
      root: root,
      leaf: file.id,
      expectedRootIdentity: rootIdentity,
      expectedLeafIdentity: leafIdentity,
      offset: offset,
      maxBytes: maxBytes,
    );
  }

  Future<File?> _safeSharedSource(SharedFile file) async {
    String? managedRoot;
    if (file.managed) {
      if (file.managedLeafIdentity == null) return null;
      try {
        managedRoot = await _validateManagedFileAuthorization(file);
      } on FileSystemException {
        return null;
      }
    }
    if (await FileSystemEntity.type(file.path, followLinks: false) !=
        FileSystemEntityType.file) {
      return null;
    }
    final resolved = await File(file.path).resolveSymbolicLinks();
    if (file.managed) {
      if (!p.equals(resolved, p.join(managedRoot!, file.id))) return null;
      try {
        if (await _captureManagedRootIdentity(managedRoot) !=
            file.managedRootIdentity) {
          return null;
        }
      } on FileSystemException {
        return null;
      }
    }
    // Directly constructed (non-persisted) entries are trusted on first access.
    final expected = file.canonicalPath ??
        _canonicalSources.putIfAbsent(file.id, () => resolved);
    return p.equals(resolved, expected) ? File(resolved) : null;
  }

  Future<List<int>> _scanManifest(
      String title, List<SharedFile> snapshot) async {
    final ids = <String>{};
    final files = snapshot
        .where((file) => _uuidPattern.hasMatch(file.id) && ids.add(file.id))
        .toList();
    final entries = List<Map<String, Object?>?>.filled(files.length, null);
    var next = 0;
    // Bound async FS concurrency, keeping the original list order. A scan is
    // O(n), shared by all phones for one second; only JSON bytes are cached.
    await Future.wait(List.generate(min(16, files.length), (_) async {
      while (next < files.length) {
        final index = next++;
        final file = files[index];
        try {
          int size;
          if (file.managed) {
            await _validateManagedFileAuthorization(file);
            final metadata = await _readManagedFileChunk(file, 0, 1);
            size = metadata.fileLength;
          } else {
            final source = await _safeSharedSource(file);
            if (source == null) continue;
            final stat = await source.stat();
            if (stat.type != FileSystemEntityType.file) continue;
            size = stat.size;
          }
          final mime = _previewMime(_downloadName(file.name));
          entries[index] = {
            'id': file.id,
            'name': file.name,
            'size': size,
            if (file.relativePath != null && _zipName(file) != null)
              'relativePath': file.relativePath,
            'previewKind': mime?.split('/').first,
          };
        } on FileSystemException {
          // Missing/unreadable shares are not part of this snapshot.
        }
      }
    }));
    return utf8.encode(jsonEncode({
      'title': title,
      'files': entries.whereType<Map<String, Object?>>().toList(),
    }));
  }

  Future<void> _serve(SharePage page, HttpRequest request) async {
    final response = request.response;
    response.headers.set('X-Content-Type-Options', 'nosniff');
    response.headers.set('Cache-Control', 'no-store');
    try {
      final beforeHttpServe = _beforeHttpServe;
      if (beforeHttpServe != null) await beforeHttpServe();
      if (request.uri.path == '/uploads' ||
          request.uri.path.startsWith('/uploads/')) {
        await _serveSession(page, request);
        return;
      }
      if (request.uri.path == '/download.zip/cancel') {
        await _serveZipCancellation(page, request);
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
      if (request.uri.path == '/manifest') {
        final data = await _manifestFor(page);
        response.headers.contentType = ContentType.json;
        response.contentLength = data.length;
        if (request.method == 'GET') response.add(data);
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
      final isFileDownload = request.method == 'GET';
      if (isFileDownload) {
        if (_activeFileDownloads >= _fileDownloadLimit) {
          response.headers.set('Retry-After', '2');
          await _uploadJson(response, HttpStatus.tooManyRequests,
              {'error': '当前文件下载任务较多，请稍后重试'});
          return;
        }
        _activeFileDownloads++;
      }
      try {
        final source = await _safeSharedSource(selected);
        if (source == null) {
          response.statusCode = HttpStatus.notFound;
          await response.close();
          return;
        }
        final managedMetadata = selected.managed
            ? await _readManagedFileChunk(selected, 0, 1)
            : null;
        final stat = managedMetadata == null ? await source.stat() : null;
        final length = managedMetadata?.fileLength ?? stat!.size;
        final modified = managedMetadata == null
            ? stat!.modified.toUtc()
            : DateTime.fromMicrosecondsSinceEpoch(
                managedMetadata.modifiedTimeMicros,
                isUtc: true,
              );
        final etag =
            '"${selected.id}-${length.toRadixString(16)}-${modified.microsecondsSinceEpoch.toRadixString(16)}"';
        response.headers.set(HttpHeaders.etagHeader, etag);
        response.headers
            .set(HttpHeaders.lastModifiedHeader, HttpDate.format(modified));
        final name = _downloadName(selected.name);
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
            if (parsedEnd != null) {
              endExclusive = min(parsedEnd, length - 1) + 1;
            }
          }
          response.statusCode = HttpStatus.partialContent;
          response.headers.set(
            'Content-Range',
            'bytes $start-${endExclusive - 1}/$length',
          );
        }
        response.contentLength = endExclusive - start;
        if (request.method == 'GET') {
          await _beforeFileStream?.call();
          if (!_servers.containsKey(page.id)) return;
          if (selected.managed) {
            final firstChunk = await _readManagedFileChunk(
              selected,
              start,
              max(
                  1,
                  min(SecureReceiveFile.managedFileReadChunkLimit,
                      endExclusive - start)),
            );
            if (firstChunk.fileLength != length ||
                firstChunk.modifiedTimeMicros !=
                    managedMetadata!.modifiedTimeMicros ||
                (start < endExclusive && firstChunk.bytes.isEmpty)) {
              throw FileSystemException(
                  'Managed file changed before streaming began', selected.path);
            }
            await _streamDownload(
              page,
              response,
              source,
              name,
              start,
              endExclusive,
              sourceStream: () => _managedFileRangeStream(
                file: selected!,
                start: start,
                end: endExclusive,
                firstChunk: firstChunk,
                expectedLength: length,
                expectedModifiedTimeMicros: managedMetadata.modifiedTimeMicros,
              ),
            );
          } else {
            await _streamDownload(
                page, response, source, name, start, endExclusive);
          }
        }
        await response.close();
      } finally {
        if (isFileDownload) _activeFileDownloads--;
      }
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
      response.contentLength = 0;
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
  bool _disposed = false;
  bool _shuttingDown = false;
  Future<void>? _initializationFuture;
  Future<void>? _shutdownFuture;

  void _notifyProgress() {
    if (_disposed) return;
    final now = DateTime.now();
    if (now.difference(_lastProgress).inMilliseconds < 80) return;
    _lastProgress = now;
    _transferProgressRevision.value++;
  }

  @visibleForTesting
  void notifyTransferProgressForTesting({bool force = false}) {
    if (force) {
      if (_disposed) return;
      _transferProgressRevision.value++;
      return;
    }
    _notifyProgress();
  }

  @visibleForTesting
  void notifyModelForTesting() => notifyListeners();

  bool canCancelTransfer(String id) =>
      transfers.any((task) => task.id == id && task.status == 'active') &&
      (_cancelActions.containsKey(id) || _sessions.containsKey(id));

  bool canAbandonTransfer(String id) =>
      transfers.any((task) => task.id == id && task.status == 'paused') &&
      _sessions.containsKey(id);

  @override
  void notifyListeners() {
    if (_disposed) return;
    super.notifyListeners();
  }

  /// Stops all listeners and workers. Safe to await before an owning host exits.
  /// Running-page preferences are preserved so a later controller can restore them.
  Future<void> shutdown() {
    final existing = _shutdownFuture;
    if (existing != null) return existing;
    _shuttingDown = true;
    final future = _shutdownPages();
    _shutdownFuture = future;
    return future;
  }

  Future<void> _shutdownPages() async {
    final currentPages = List<SharePage>.of(pages);
    await Future.wait(currentPages.map((page) async {
      try {
        await _unbind(page, preserveRunning: true);
      } catch (_) {
        // Continue shutting down every other page after one failure.
      }
    }));
    for (final page in currentPages) {
      page.running = false;
    }
    notifyListeners();
    for (final removal in _removingPages.values.toList()) {
      try {
        await removal;
      } catch (_) {
        // A failed page removal must not keep other pages listening.
      }
    }
    for (final cancel in _cancelActions.values.toList()) {
      try {
        await cancel();
      } catch (_) {
        // Keep shutting down other workers and listeners after one failure.
      }
    }
    for (final binding in _bindingPages.values.toList()) {
      try {
        await binding;
      } catch (_) {
        // Binding failure is already handled by its caller.
      }
    }
    final leftoverServers = _servers.values.toList();
    _servers.clear();
    for (final server in leftoverServers) {
      try {
        await server.close(force: true);
      } catch (_) {
        // Keep disposing other listeners if one socket fails to close.
      }
    }
    final pendingRequests =
        _requests.values.expand((requests) => requests).toList();
    await Future.wait(pendingRequests);
    await _persistQueue;
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    unawaited(shutdown().catchError((Object _, StackTrace __) {}));
    _transferProgressRevision.dispose();
    super.dispose();
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
    _pruneTransferTasks();
    notifyListeners();
    return task;
  }

  void _pruneTransferTasks() {
    final retainedIds = <String>{..._sessions.keys, ..._cancelActions.keys};
    final terminal = transfers
        .where(
            (task) => task.status != 'active' && !retainedIds.contains(task.id))
        .toList();
    if (terminal.length <= _maxTerminalTransferTasks) return;
    final expired = terminal.skip(_maxTerminalTransferTasks).toSet();
    transfers.removeWhere(expired.contains);
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
      if (task.status == 'active' ||
          session != null && task.status != 'completed') {
        task.status = 'cancelled';
      }
    }
    _pruneTransferTasks();
    notifyListeners();
  }

  bool _isWindowsNetworkPath(String path) {
    if (!Platform.isWindows) return false;
    final normalized = p.normalize(path);
    return normalized.startsWith(r'\\') || normalized.startsWith('//');
  }

  Future<void> setReceiveOptions(SharePage page,
          {String? directory, bool organizeByDate = false}) =>
      _runPageMutation(page, () async {
        final selectedDirectory = directory?.trim();
        if (selectedDirectory != null && selectedDirectory.isNotEmpty) {
          if (!p.isAbsolute(selectedDirectory)) {
            throw ArgumentError('Receive directory must be absolute');
          }
          if (_isWindowsNetworkPath(selectedDirectory)) {
            throw ArgumentError(
                'Windows receive directories must be on a local drive');
          }
        }
        final previousDirectory = page.receiveDirectory;
        final previousOrganizeByDate = page.organizeByDate;
        page.receiveDirectory =
            selectedDirectory == null || selectedDirectory.isEmpty
                ? null
                : p.normalize(selectedDirectory);
        page.organizeByDate = organizeByDate;
        var pageListCommitted = false;
        try {
          await _persist(onPageListStored: () => pageListCommitted = true);
        } catch (_) {
          if (!pageListCommitted) {
            page.receiveDirectory = previousDirectory;
            page.organizeByDate = previousOrganizeByDate;
            // Queue a fresh authoritative snapshot in case later writes had
            // captured the failed setting change before rollback.
            try {
              await _persist();
            } catch (_) {
              // Preserve the original persistence error and restored model.
            }
            rethrow;
          }
          // The page-list commit is authoritative; complete the other keys
          // best-effort rather than reverting to stale in-memory options.
          try {
            await _persist();
          } catch (_) {
            // The committed receive options remain usable in this process.
          }
        }
        notifyListeners();
      });

  Future<String> receiveDirectoryFor(SharePage page) async {
    if (_conflictingPageIds.contains(page.id)) {
      throw StateError(
          'Cannot resolve a receive directory for a duplicate page ID.');
    }
    if (!_uuidPattern.hasMatch(page.id)) throw const FormatException('Page ID');
    final base = page.receiveDirectory == null
        ? (await _receiveRoot()).path
        : p.normalize(p.absolute(page.receiveDirectory!));
    if (_isWindowsNetworkPath(base)) {
      throw const FileSystemException(
          'Windows receive directories must be on a local drive', '');
    }
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

  Future<void> addPaths(SharePage page, List<String> paths) => _runPageMutation(
      page,
      () => _withManagedFileReferenceLock(() async {
            final addedFiles = <SharedFile>[];
            final addedManagedLeafIdentities = <String, String>{};
            var pageListCommitted = false;
            Future<void> add(String path, String? relative, String root) async {
              final components = p.split(p.normalize(p.absolute(path)));
              if (components
                  .contains(SecureReceiveFile.quarantineDirectoryName)) {
                return;
              }
              final type =
                  await FileSystemEntity.type(path, followLinks: false);
              if (type == FileSystemEntityType.link) return;
              if (type == FileSystemEntityType.directory) {
                await for (final child
                    in Directory(path).list(followLinks: false)) {
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
                Directory? managedDirectory;
                String? managedRootIdentity;
                String? managedLeafIdentity;
                var createdManaged = false;
                try {
                  if (isMobile) {
                    managedDirectory = await _ensureFileDirectory();
                    managedRootIdentity = _fileDirectoryIdentity!;
                    stored = p.join(managedDirectory.path, id);
                    final destination = File(stored);
                    await destination.create(exclusive: true);
                    createdManaged = true;
                    final sink = destination.openWrite(mode: FileMode.append);
                    try {
                      await sink.addStream(File(path).openRead());
                      await sink.close();
                    } catch (_) {
                      try {
                        await sink.close();
                      } catch (_) {
                        // Preserve the original copy error.
                      }
                      rethrow;
                    }
                    await _ensureFileDirectory();
                    if (await FileSystemEntity.type(stored,
                            followLinks: false) !=
                        FileSystemEntityType.file) {
                      throw FileSystemException(
                          'Imported managed entry is not a regular file',
                          stored);
                    }
                    managedLeafIdentity =
                        (await SecureReceiveFile.captureManagedFileLeafIdentity(
                      root: managedDirectory.path,
                      leaf: id,
                      expectedRootIdentity: managedRootIdentity,
                    ))
                            .value;
                  }
                  final canonicalPath = isMobile
                      ? await File(stored).resolveSymbolicLinks()
                      : resolved;
                  if (isMobile &&
                      !p.equals(
                          canonicalPath, p.join(managedDirectory!.path, id))) {
                    throw FileSystemException(
                        'Imported managed entry escaped its pinned directory',
                        stored);
                  }
                  if (isMobile) {
                    await _ensureFileDirectory();
                    final currentLeafIdentity =
                        await SecureReceiveFile.captureManagedFileLeafIdentity(
                      root: managedDirectory!.path,
                      leaf: id,
                      expectedRootIdentity: managedRootIdentity!,
                    );
                    if (currentLeafIdentity.value != managedLeafIdentity) {
                      throw FileSystemException(
                          'Managed file changed before page commit', stored);
                    }
                  }
                  final file = SharedFile(
                      id: id,
                      name: p.basename(path),
                      path: stored,
                      canonicalPath: canonicalPath,
                      size: await File(stored).length(),
                      managed: isMobile,
                      managedRoot: isMobile ? managedDirectory!.path : null,
                      managedRootIdentity:
                          isMobile ? managedRootIdentity : null,
                      managedLeafIdentity:
                          isMobile ? managedLeafIdentity : null,
                      relativePath: relative);
                  page.files.add(file);
                  addedFiles.add(file);
                  if (managedLeafIdentity != null) {
                    addedManagedLeafIdentities[id] = managedLeafIdentity;
                  }
                  _manifests.remove(page.id);
                } catch (_) {
                  if (createdManaged &&
                      managedDirectory != null &&
                      managedRootIdentity != null &&
                      managedLeafIdentity != null) {
                    await _tryUnlinkManagedFileLeaf(
                      managedDirectory.path,
                      id,
                      managedRootIdentity,
                      managedLeafIdentity,
                    );
                  }
                  rethrow;
                }
              }
            }

            try {
              for (final path in paths) {
                final absolute = p.normalize(p.absolute(path));
                final type =
                    await FileSystemEntity.type(absolute, followLinks: false);
                if (type == FileSystemEntityType.link ||
                    type == FileSystemEntityType.notFound) {
                  continue;
                }
                late final String root;
                try {
                  root = await File(absolute).resolveSymbolicLinks();
                } on FileSystemException {
                  if (await FileSystemEntity.type(absolute,
                          followLinks: false) ==
                      FileSystemEntityType.notFound) {
                    continue;
                  }
                  rethrow;
                }
                await add(
                    absolute,
                    type == FileSystemEntityType.directory
                        ? p.basename(absolute)
                        : null,
                    root);
              }
              await _persist(onPageListStored: () => pageListCommitted = true);
              notifyListeners();
            } catch (_) {
              if (pageListCommitted) {
                // The page-list key is the import commit point. Keep the copied
                // entries and make remaining metadata writes best-effort.
                try {
                  await _persist();
                } catch (retryError) {
                  pageErrors[page.id] = '共享文件已保存，但其他状态暂未保存：$retryError';
                }
                notifyListeners();
                return;
              }
              if (!pageListCommitted) {
                final addedIds = addedFiles.map((file) => file.id).toSet();
                page.files.removeWhere((file) => addedIds.contains(file.id));
                _manifests.remove(page.id);
                var rollbackCommitted = false;
                try {
                  await _persist(
                      onPageListStored: () => rollbackCommitted = true);
                } catch (_) {
                  // Retain copies if ownership could still be present in preferences.
                }
                if (rollbackCommitted) {
                  for (final file in addedFiles.where((file) => file.managed)) {
                    final leafIdentity = addedManagedLeafIdentities[file.id];
                    if (leafIdentity == null) continue;
                    await _tryUnlinkManagedFileLeaf(
                      file.managedRoot!,
                      file.id,
                      file.managedRootIdentity!,
                      leafIdentity,
                    );
                  }
                } else {
                  for (final file in addedFiles.where((file) => file.managed)) {
                    managedFileCleanupWarnings[file.id] =
                        '导入状态无法回滚，残留文件会在启动扫描时重试清理。';
                  }
                }
              }
              notifyListeners();
              rethrow;
            }
          }));

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

  /// Retain newest-first metadata only; saved files remain untouched.
  void _pruneReceivedFiles() {
    final activePageIds = pages.map((page) => page.id).toSet();
    receivedFiles.removeWhere((record) =>
        record.pageId != null && !activePageIds.contains(record.pageId));
    final perPageCounts = <String, int>{};
    receivedFiles.removeWhere((record) {
      final pageId = record.pageId;
      if (pageId == null) return false;
      final count = (perPageCounts[pageId] ?? 0) + 1;
      perPageCounts[pageId] = count;
      return count > _maxReceivedFileRecordsPerPage;
    });
    if (receivedFiles.length > _maxReceivedFileRecords) {
      receivedFiles.removeRange(_maxReceivedFileRecords, receivedFiles.length);
    }
    _unassignedLegacyRecords
        .removeWhere((record) => !receivedFiles.contains(record));
  }

  Future<void> _recoverRawReceiveCleanupJournal() async {
    if (!_rawReceiveCleanupJournalValid || _rawReceiveCleanupRecords.isEmpty) {
      return;
    }
    for (final record in _rawReceiveCleanupRecords.values.toList()) {
      final id = record['id'] as String;
      try {
        await SecureReceiveFile.unlinkEntry(
          root: record['root'] as String,
          relativeParent: record['relativeParent'] as String,
          leaf: record['leaf'] as String,
          expectedRootIdentity: record['expectedRootIdentity'] as String,
          expectedParentIdentity: record['expectedParentIdentity'] as String?,
          expectedLeafIdentity: record['expectedLeafIdentity'] as String,
          quarantineSessionId: id,
          quarantineLeaf: '.$id.quarantine',
          expectedQuarantineIdentity:
              record['expectedQuarantineIdentity'] as String,
        );
      } catch (error) {
        managedFileCleanupWarnings['rawQuarantine:$id'] =
            '原始上传残留暂未安全清理，已保留并将在下次启动重试：$error';
        continue;
      }

      _rawReceiveCleanupRecords.remove(id);
      try {
        await _persist();
      } catch (error) {
        _rawReceiveCleanupRecords[id] = record;
        managedFileCleanupWarnings['rawQuarantine:$id'] =
            '文件已隔离删除，清理日志暂未提交，将在启动时重试：$error';
        continue;
      }
      managedFileCleanupWarnings.remove('rawQuarantine:$id');
      await _removeReceiveQuarantineBestEffort(_ReceiveQuarantineCleanup(
        root: record['root'] as String,
        sessionId: id,
        expectedRootIdentity: record['expectedRootIdentity'] as String,
        expectedQuarantineIdentity:
            record['expectedQuarantineIdentity'] as String,
      ));
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
    _migrateLegacyRecords(
        alreadyMigrated: _preferences!.getBool(_recordsMigratedKey) == true);
    try {
      final sessions =
          jsonDecode(_preferences!.getString(_sessionsKey) ?? '[]');
      if (sessions is! List) return;
      // Grandfather valid existing sessions even if their total exceeds the
      // current creation cap; never discard resumable user data to enforce it.
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
        final pageId = raw['pageId'] as String;
        final matches = pages.where((page) => page.id == pageId).toList();
        final deleting = raw['deleting'] == true;
        // Keep ordinary sessions quarantined, but still honor a durable,
        // identity-pinned deletion marker when its original root returns.
        if (_conflictingPageIds.contains(pageId) && !deleting) {
          _retainUnrestoredSession(raw, pageId);
          continue;
        }
        if (matches.length != 1) {
          if (deleting) _retainUnrestoredSession(raw, pageId);
          continue;
        }
        if (!deleting && _sessionCountForPage(pageId) >= 16) continue;
        if (!deleting && raw['receiveQuarantineIdentity'] != null) {
          // A quarantine pin without its deletion marker is inconsistent; do
          // not resume the source or adopt the quarantine as a new upload.
          _retainUnrestoredSession(raw, pageId);
          continue;
        }
        if (deleting) {
          if (raw['receiveRootIdentity'] is! String ||
              raw['receiveLeafIdentity'] is! String) {
            // A legacy deletion marker without directory/leaf identity cannot authorize an unlink
            // after a possible directory replacement. Keep it for explicit
            // recovery rather than inferring authority from the current path.
            _retainUnrestoredSession(raw, pageId);
            continue;
          }
          _retainUnrestoredSession(raw, pageId);
          final deletingRecord = _unrestoredSessionRecords
              .firstWhere((record) => record['id'] == raw['id']);
          try {
            final quarantineCleanup = await _deleteUnrestoredSessionRecord(
                deletingRecord, matches.single);
            _unrestoredSessionRecords.remove(deletingRecord);
            _sessionDeletionMarkers.remove(deletingRecord['id']);
            _unavailableSessionIds.remove(deletingRecord['id']);
            _refreshPageRecoveryWarning(pageId);
            await _persist();
            if (quarantineCleanup != null) {
              await _removeReceiveQuarantineBestEffort(quarantineCleanup);
            }
          } on FileSystemException {
            _retainUnrestoredSession(deletingRecord, pageId);
          }
          continue;
        }
        final path = raw['path'] as String;
        final String pageRoot;
        if (raw['receiveRoot'] is String) {
          pageRoot = raw['receiveRoot'] as String;
        } else {
          // Older sessions did not persist the receive root separately. Infer
          // the original root from their strictly validated page/date path,
          // rather than rebinding a paused upload to today's page setting.
          final parent = p.dirname(path);
          final direct = p.basename(parent) == matches.single.id;
          final dated = _isValidReceiveDateComponent(p.basename(parent)) &&
              p.basename(p.dirname(parent)) == matches.single.id;
          if (!p.isAbsolute(path) || path != p.normalize(path)) continue;
          if (direct) {
            pageRoot = parent;
          } else if (dated) {
            pageRoot = p.dirname(parent);
          } else {
            continue;
          }
        }
        if (!p.isAbsolute(pageRoot) ||
            pageRoot != p.normalize(pageRoot) ||
            p.basename(pageRoot) != matches.single.id) {
          continue;
        }
        try {
          final beforeFileCheck = _beforeRestoredSessionFileCheck;
          if (beforeFileCheck != null) await beforeFileCheck(path);
          final parent = p.dirname(path);
          final direct = p.equals(parent, pageRoot);
          final dated = p.equals(p.dirname(parent), pageRoot) &&
              _isValidReceiveDateComponent(p.basename(parent));
          final rootType =
              await FileSystemEntity.type(pageRoot, followLinks: false);
          if (rootType == FileSystemEntityType.notFound ||
              rootType == FileSystemEntityType.link) {
            _retainUnrestoredSession(raw, pageId);
            continue;
          }
          if (rootType != FileSystemEntityType.directory) continue;
          // Older records lack a pinned canonical root. Do not infer authority
          // through a symlinked ancestor, which may now target an unrelated
          // directory after the original path was saved.
          if (raw['canonicalRoot'] is! String &&
              await _hasSymbolicLinkComponent(pageRoot)) {
            _retainUnrestoredSession(raw, pageId);
            continue;
          }
          if ((!direct && !dated) ||
              !p.isAbsolute(path) ||
              path != p.normalize(path)) {
            continue;
          }
          final parentType =
              await FileSystemEntity.type(parent, followLinks: false);
          if (parentType == FileSystemEntityType.notFound ||
              parentType == FileSystemEntityType.link) {
            _retainUnrestoredSession(raw, pageId);
            continue;
          }
          if (parentType != FileSystemEntityType.directory) continue;
          final canonicalRoot =
              await Directory(pageRoot).resolveSymbolicLinks();
          if (raw['canonicalRoot'] is String &&
              !p.equals(raw['canonicalRoot'] as String, canonicalRoot)) {
            _retainUnrestoredSession(raw, pageId);
            continue;
          }
          final canonicalParent =
              await Directory(parent).resolveSymbolicLinks();
          if (!p.equals(canonicalParent, canonicalRoot) &&
              !(dated && p.equals(p.dirname(canonicalParent), canonicalRoot))) {
            _retainUnrestoredSession(raw, pageId);
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
          final relativeParent = _relativeReceiveParent(pageRoot, path);
          final currentIdentity =
              await SecureReceiveFile.captureDirectoryIdentity(
            root: canonicalRoot,
            relativeParent: relativeParent,
          );
          final savedRootIdentity = raw['receiveRootIdentity'];
          final savedParentIdentity = raw['receiveParentIdentity'];
          final savedLeafIdentity = raw['receiveLeafIdentity'];
          if (savedLeafIdentity is! String || savedLeafIdentity.isEmpty) {
            // Do not adopt a legacy path's current leaf as the identity of an
            // existing upload; retain it for explicit recovery.
            _retainUnrestoredSession(raw, pageId);
            continue;
          }
          final hasSavedIdentity = savedRootIdentity is String;
          if ((savedRootIdentity != null && !hasSavedIdentity) ||
              (savedParentIdentity != null && savedParentIdentity is! String) ||
              (!hasSavedIdentity && savedParentIdentity != null) ||
              (hasSavedIdentity &&
                  (savedRootIdentity != currentIdentity.rootIdentity ||
                      savedParentIdentity != currentIdentity.parentIdentity))) {
            _retainUnrestoredSession(raw, pageId);
            continue;
          }
          final leafType =
              await FileSystemEntity.type(path, followLinks: false);
          if (leafType == FileSystemEntityType.notFound) {
            if (!hasSavedIdentity) _retainUnrestoredSession(raw, pageId);
            continue;
          }
          if (leafType != FileSystemEntityType.file) {
            _retainUnrestoredSession(raw, pageId);
            continue;
          }
          final canonicalPath =
              p.join(canonicalRoot, p.relative(path, from: pageRoot));
          final resolvedPath = await File(path).resolveSymbolicLinks();
          if (!p.equals(resolvedPath, canonicalPath)) {
            _retainUnrestoredSession(raw, pageId);
            continue;
          }
          final currentLeafIdentity =
              await SecureReceiveFile.captureReceiveEntryIdentity(
            root: canonicalRoot,
            relativeParent: relativeParent,
            leaf: p.basename(path),
            expectedRootIdentity: currentIdentity.rootIdentity,
            expectedParentIdentity: currentIdentity.parentIdentity,
            expectedLeafIdentity: savedLeafIdentity,
          );
          if (currentLeafIdentity.value != savedLeafIdentity) {
            _retainUnrestoredSession(raw, pageId);
            continue;
          }
          final length = await File(resolvedPath).length();
          if (length > (raw['size'] as int)) {
            _retainUnrestoredSession(raw, pageId);
            continue;
          }
          final session = _Session(
              id: raw['id'] as String,
              pageId: pageId,
              name: _receivedName(raw['name'] as String),
              size: raw['size'] as int,
              fingerprint: raw['fingerprint'] as String,
              path: path,
              receiveRoot: pageRoot,
              canonicalRoot: canonicalRoot,
              receiveRootIdentity: currentIdentity.rootIdentity,
              receiveParentIdentity: currentIdentity.parentIdentity,
              receiveLeafIdentity: savedLeafIdentity,
              offset: length);
          _sessions[session.id] = session;
          _newTask(matches.single, session.name, 'upload', session.size,
              id: session.id, offset: length, status: 'paused');
        } on FileSystemException {
          _retainUnrestoredSession(raw, pageId);
        } on ArgumentError {
          // A malformed OS path is an invalid record, not an app startup failure.
        }
      }
    } on FormatException {/* Invalid preferences must not break startup. */}
  }

  Future<File?> _safeSessionSource(_Session session) async {
    final root = session.receiveRoot;
    final canonicalRoot = session.canonicalRoot;
    final expectedRootIdentity = session.receiveRootIdentity;
    final expectedLeafIdentity = session.receiveLeafIdentity;
    if (root == null ||
        canonicalRoot == null ||
        expectedRootIdentity == null ||
        expectedLeafIdentity == null) {
      return null;
    }
    final relativeParent = _relativeReceiveParent(root, session.path);
    final currentIdentity = await SecureReceiveFile.captureDirectoryIdentity(
        root: canonicalRoot, relativeParent: relativeParent);
    if (currentIdentity.rootIdentity != expectedRootIdentity ||
        currentIdentity.parentIdentity != session.receiveParentIdentity) {
      throw FileSystemException(
          'Upload receive directory identity changed', session.path);
    }
    if (await FileSystemEntity.type(session.path, followLinks: false) !=
        FileSystemEntityType.file) {
      return null;
    }
    final currentLeafIdentity =
        await SecureReceiveFile.captureReceiveEntryIdentity(
      root: canonicalRoot,
      relativeParent: relativeParent,
      leaf: p.basename(session.path),
      expectedRootIdentity: expectedRootIdentity,
      expectedParentIdentity: session.receiveParentIdentity,
      expectedLeafIdentity: expectedLeafIdentity,
    );
    if (currentLeafIdentity.value != expectedLeafIdentity) {
      throw FileSystemException(
          'Upload partial identity changed', session.path);
    }
    final expected =
        p.join(canonicalRoot, p.relative(session.path, from: root));
    final resolved = await File(session.path).resolveSymbolicLinks();
    if (!p.equals(resolved, expected)) return null;
    if (_unavailableSessionIds.remove(session.id)) {
      _refreshPageRecoveryWarning(session.pageId);
    }
    // This hook makes the check/use boundary deterministic in security tests.
    final afterResolve = _afterSessionSourceResolved;
    if (afterResolve != null) await afterResolve();
    // Read/write callers use this resolved path, not the lexical alias. Deletion
    // callers use the handle-relative secure unlink primitive below.
    return File(resolved);
  }

  Future<bool> _hasSymbolicLinkComponent(String path) async {
    if (!p.isAbsolute(path) || path != p.normalize(path)) return true;
    final rootPrefix = p.rootPrefix(path);
    var current = rootPrefix;
    for (final component in p.split(p.relative(path, from: rootPrefix))) {
      if (component.isEmpty || component == '.' || component == '..') {
        return true;
      }
      current = p.join(current, component);
      if (await FileSystemEntity.type(current, followLinks: false) ==
          FileSystemEntityType.link) {
        return true;
      }
    }
    return false;
  }

  String _relativeReceiveParent(String root, String path) {
    final parent = p.dirname(path);
    if (p.equals(parent, root)) return '';
    final date = p.basename(parent);
    if (_isValidReceiveDateComponent(date) &&
        p.equals(p.dirname(parent), root)) {
      return date;
    }
    throw FileSystemException('Unsafe receive-file parent', path);
  }

  bool _isValidReceiveDateComponent(String value) {
    if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) return false;
    final year = int.parse(value.substring(0, 4));
    final month = int.parse(value.substring(5, 7));
    final day = int.parse(value.substring(8, 10));
    final date = DateTime.utc(year, month, day);
    return year > 0 &&
        date.year == year &&
        date.month == month &&
        date.day == day;
  }

  Future<bool> _completeMissingDatedReceiveParent({
    required String root,
    required String relativeParent,
    required String expectedRootIdentity,
    required String? expectedParentIdentity,
  }) async {
    if (!_isValidReceiveDateComponent(relativeParent) ||
        expectedParentIdentity == null) {
      return false;
    }
    final parent = p.join(root, relativeParent);
    if (await FileSystemEntity.type(parent, followLinks: false) !=
        FileSystemEntityType.notFound) {
      return false;
    }
    final current = await SecureReceiveFile.captureDirectoryIdentity(
        root: root, relativeParent: '');
    if (current.rootIdentity != expectedRootIdentity ||
        current.parentIdentity != null) {
      throw FileSystemException(
          'Receive root identity changed while checking a missing date parent',
          root);
    }
    if (await FileSystemEntity.type(parent, followLinks: false) !=
        FileSystemEntityType.notFound) {
      return false;
    }
    return true;
  }

  String? _receiveQuarantineLeaf(String id) =>
      Platform.isWindows ? null : '.$id.quarantine';

  Future<void> _verifyPinnedReceiveDirectory({
    required String root,
    required String relativeParent,
    required String expectedRootIdentity,
    required String? expectedParentIdentity,
  }) async {
    final actual = await SecureReceiveFile.captureDirectoryIdentity(
        root: root, relativeParent: relativeParent);
    if (actual.rootIdentity != expectedRootIdentity ||
        actual.parentIdentity != expectedParentIdentity) {
      throw FileSystemException(
          'Upload receive directory identity changed', root);
    }
  }

  bool get _supportsPosixReceiveQuarantine =>
      Platform.isAndroid || Platform.isIOS || Platform.isMacOS;

  Future<void> _removeReceiveQuarantineBestEffort(
      _ReceiveQuarantineCleanup cleanup) async {
    if (!_supportsPosixReceiveQuarantine) return;
    try {
      await SecureReceiveFile.removeReceiveQuarantine(
        root: cleanup.root,
        sessionId: cleanup.sessionId,
        expectedRootIdentity: cleanup.expectedRootIdentity,
        expectedQuarantineIdentity: cleanup.expectedQuarantineIdentity,
      );
    } catch (_) {
      // Cleanup is post-commit and only removes an empty, identity-matched dir.
    }
  }

  Future<void> _secureUnlinkRawEntry({
    required String sessionId,
    required String root,
    required String relativeParent,
    required String leaf,
    required String expectedRootIdentity,
    required String? expectedParentIdentity,
    required String expectedLeafIdentity,
  }) async {
    final match = RegExp(r'^\.([0-9a-f-]{36})\.part$').firstMatch(leaf);
    if (!_supportsPosixReceiveQuarantine) {
      await _secureUnlinkReceiveEntry(
        root: root,
        relativeParent: relativeParent,
        leaf: leaf,
        expectedRootIdentity: expectedRootIdentity,
        expectedParentIdentity: expectedParentIdentity,
        expectedLeafIdentity: expectedLeafIdentity,
      );
      return;
    }
    if (!_rawReceiveCleanupJournalValid) {
      throw FileSystemException(
          'Raw receive cleanup journal is invalid; preserving source', root);
    }
    if (!_uuidPattern.hasMatch(sessionId) ||
        (match != null && match[1] != sessionId)) {
      throw FileSystemException('Mismatched raw-upload quarantine UUID', leaf);
    }
    final quarantineLeaf = '.$sessionId.quarantine';
    final quarantineIdentity =
        (await SecureReceiveFile.prepareReceiveQuarantine(
      root: root,
      relativeParent: relativeParent,
      leaf: leaf,
      sessionId: sessionId,
      quarantineLeaf: quarantineLeaf,
      expectedRootIdentity: expectedRootIdentity,
      expectedParentIdentity: expectedParentIdentity,
      expectedLeafIdentity: expectedLeafIdentity,
    ))
            .value;
    final cleanupRecord = <String, Object?>{
      'id': sessionId,
      'root': root,
      'relativeParent': relativeParent,
      'leaf': leaf,
      'expectedRootIdentity': expectedRootIdentity,
      'expectedParentIdentity': expectedParentIdentity,
      'expectedLeafIdentity': expectedLeafIdentity,
      'expectedQuarantineIdentity': quarantineIdentity,
    };
    _rawReceiveCleanupRecords[sessionId] = cleanupRecord;
    try {
      await _persist();
    } catch (_) {
      _rawReceiveCleanupRecords.remove(sessionId);
      await _removeReceiveQuarantineBestEffort(_ReceiveQuarantineCleanup(
        root: root,
        sessionId: sessionId,
        expectedRootIdentity: expectedRootIdentity,
        expectedQuarantineIdentity: quarantineIdentity,
      ));
      rethrow;
    }

    try {
      await _secureUnlinkReceiveEntry(
        root: root,
        relativeParent: relativeParent,
        leaf: leaf,
        expectedRootIdentity: expectedRootIdentity,
        expectedParentIdentity: expectedParentIdentity,
        expectedLeafIdentity: expectedLeafIdentity,
        quarantineSessionId: sessionId,
        quarantineLeaf: quarantineLeaf,
        expectedQuarantineIdentity: quarantineIdentity,
      );
      _rawReceiveCleanupRecords.remove(sessionId);
      try {
        await _persist();
      } catch (error) {
        _rawReceiveCleanupRecords[sessionId] = cleanupRecord;
        managedFileCleanupWarnings['rawQuarantine:$sessionId'] =
            '文件已清理，隔离日志暂未提交，将在启动时重试：$error';
        rethrow;
      }
      managedFileCleanupWarnings.remove('rawQuarantine:$sessionId');
      await _removeReceiveQuarantineBestEffort(_ReceiveQuarantineCleanup(
        root: root,
        sessionId: sessionId,
        expectedRootIdentity: expectedRootIdentity,
        expectedQuarantineIdentity: quarantineIdentity,
      ));
    } catch (error) {
      if (_rawReceiveCleanupRecords.containsKey(sessionId)) {
        managedFileCleanupWarnings['rawQuarantine:$sessionId'] =
            '原始上传残留暂未安全清理，已保留并将在下次启动重试：$error';
      }
      rethrow;
    }
  }

  Future<void> _secureUnlinkReceiveEntry({
    required String root,
    required String relativeParent,
    required String leaf,
    required String expectedRootIdentity,
    required String? expectedParentIdentity,
    required String expectedLeafIdentity,
    String? quarantineSessionId,
    String? quarantineLeaf,
    String? expectedQuarantineIdentity,
  }) async {
    final beforeUnlink = _beforeSecureReceiveUnlink;
    if (beforeUnlink != null) await beforeUnlink();
    await SecureReceiveFile.unlinkEntry(
        root: root,
        relativeParent: relativeParent,
        leaf: leaf,
        expectedRootIdentity: expectedRootIdentity,
        expectedParentIdentity: expectedParentIdentity,
        expectedLeafIdentity: expectedLeafIdentity,
        quarantineSessionId: quarantineSessionId,
        quarantineLeaf: quarantineLeaf,
        expectedQuarantineIdentity: expectedQuarantineIdentity);
  }

  Future<_ReceiveQuarantineCleanup?> _deleteUnrestoredSessionRecord(
      Map<String, Object?> record, SharePage page) async {
    final id = record['id'];
    final path = record['path'];
    final expectedLeafIdentity = record['receiveLeafIdentity'];
    final savedQuarantineIdentity = record['receiveQuarantineIdentity'];
    if (id is! String ||
        !_uuidPattern.hasMatch(id) ||
        path is! String ||
        expectedLeafIdentity is! String ||
        expectedLeafIdentity.isEmpty ||
        (savedQuarantineIdentity != null &&
            savedQuarantineIdentity is! String)) {
      throw const FileSystemException('Invalid deferred upload record');
    }

    final String root;
    if (record['receiveRoot'] is String) {
      root = record['receiveRoot'] as String;
    } else {
      final parent = p.dirname(path);
      final direct = p.basename(parent) == page.id;
      final dated = _isValidReceiveDateComponent(p.basename(parent)) &&
          p.basename(p.dirname(parent)) == page.id;
      if (direct) {
        root = parent;
      } else if (dated) {
        root = p.dirname(parent);
      } else {
        throw const FileSystemException('Invalid deferred upload path');
      }
    }
    if (!p.isAbsolute(root) ||
        root != p.normalize(root) ||
        p.basename(root) != page.id ||
        !p.isAbsolute(path) ||
        path != p.normalize(path) ||
        p.basename(path) != '.$id.part') {
      throw const FileSystemException('Invalid deferred upload path');
    }

    final parent = p.dirname(path);
    final direct = p.equals(parent, root);
    final dated = p.equals(p.dirname(parent), root) &&
        _isValidReceiveDateComponent(p.basename(parent));
    if (!direct && !dated) {
      throw const FileSystemException('Invalid deferred upload path');
    }
    if (await FileSystemEntity.type(root, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw FileSystemException(
          'Deferred upload directory is unavailable', root);
    }
    final parentType = await FileSystemEntity.type(parent, followLinks: false);
    final canonicalRoot = await Directory(root).resolveSymbolicLinks();
    final savedCanonicalRoot = record['canonicalRoot'];
    if (savedCanonicalRoot is String) {
      if (!p.equals(savedCanonicalRoot, canonicalRoot)) {
        throw FileSystemException('Deferred upload root changed', root);
      }
    } else if (await _hasSymbolicLinkComponent(root)) {
      // Do not grant an old path-only record authority through a symlink that
      // could have been redirected since the record was created.
      throw FileSystemException(
          'Cannot verify legacy upload root without symlinks', root);
    }
    final relativeParent = dated ? p.basename(parent) : '';
    if (parentType == FileSystemEntityType.directory) {
      final canonicalParent = await Directory(parent).resolveSymbolicLinks();
      if (!p.equals(canonicalParent, canonicalRoot) &&
          !(dated && p.equals(p.dirname(canonicalParent), canonicalRoot))) {
        throw FileSystemException('Deferred upload parent changed', parent);
      }
    } else if (parentType != FileSystemEntityType.notFound || !dated) {
      throw FileSystemException(
          'Deferred upload directory is unavailable', parent);
    }
    final type = await FileSystemEntity.type(path, followLinks: false);
    final expected = p.join(canonicalRoot, p.relative(path, from: root));
    if (type != FileSystemEntityType.notFound) {
      if (type != FileSystemEntityType.file) {
        throw FileSystemException('Unsafe deferred upload file', path);
      }
      final resolved = await File(path).resolveSymbolicLinks();
      if (!p.equals(resolved, expected)) {
        throw FileSystemException('Deferred upload file changed', path);
      }
    }

    final savedRootIdentity = record['receiveRootIdentity'];
    final savedParentIdentity = record['receiveParentIdentity'];
    final ReceiveDirectoryIdentity identity;
    if (savedRootIdentity is String) {
      if ((relativeParent.isEmpty && savedParentIdentity != null) ||
          (relativeParent.isNotEmpty && savedParentIdentity is! String)) {
        throw FileSystemException(
            'Deferred upload directory identity is incomplete', root);
      }
      identity = ReceiveDirectoryIdentity(
          rootIdentity: savedRootIdentity,
          parentIdentity: savedParentIdentity as String?);
    } else {
      if (savedRootIdentity != null ||
          savedParentIdentity != null ||
          type != FileSystemEntityType.file) {
        throw FileSystemException(
            'Cannot securely bind legacy upload directory identity', path);
      }
      // A legacy record can be upgraded only while its expected regular .part
      // still exists below the validated, non-symlinked receive root.
      final captured = await SecureReceiveFile.captureDirectoryIdentity(
          root: canonicalRoot, relativeParent: relativeParent);
      if ((relativeParent.isEmpty && captured.parentIdentity != null) ||
          (relativeParent.isNotEmpty && captured.parentIdentity == null)) {
        throw FileSystemException(
            'Invalid deferred upload directory identity', path);
      }
      record['receiveRootIdentity'] = captured.rootIdentity;
      if (captured.parentIdentity != null) {
        record['receiveParentIdentity'] = captured.parentIdentity;
      }
      // Commit the upgraded identity together with deleting:true before unlink.
      await _persist();
      identity = captured;
    }
    final quarantineLeaf = _receiveQuarantineLeaf(id);
    final missingDatedParent = dated &&
        await _completeMissingDatedReceiveParent(
          root: canonicalRoot,
          relativeParent: relativeParent,
          expectedRootIdentity: identity.rootIdentity,
          expectedParentIdentity: identity.parentIdentity,
        );
    if (missingDatedParent) {
      if (quarantineLeaf == null || savedQuarantineIdentity == null) {
        return null;
      }
      await _secureUnlinkReceiveEntry(
          root: canonicalRoot,
          relativeParent: relativeParent,
          leaf: p.basename(path),
          expectedRootIdentity: identity.rootIdentity,
          expectedParentIdentity: identity.parentIdentity,
          expectedLeafIdentity: expectedLeafIdentity,
          quarantineSessionId: id,
          quarantineLeaf: quarantineLeaf,
          expectedQuarantineIdentity: savedQuarantineIdentity as String);
      return _ReceiveQuarantineCleanup(
        root: canonicalRoot,
        sessionId: id,
        expectedRootIdentity: identity.rootIdentity,
        expectedQuarantineIdentity: savedQuarantineIdentity,
      );
    }
    if (parentType != FileSystemEntityType.directory) {
      throw FileSystemException(
          'Deferred upload directory is unavailable', parent);
    }
    if (quarantineLeaf != null) {
      if (type == FileSystemEntityType.notFound &&
          savedQuarantineIdentity == null) {
        await _verifyPinnedReceiveDirectory(
          root: canonicalRoot,
          relativeParent: relativeParent,
          expectedRootIdentity: identity.rootIdentity,
          expectedParentIdentity: identity.parentIdentity,
        );
        return null;
      }
      var quarantineIdentity = savedQuarantineIdentity as String?;
      if (quarantineIdentity == null) {
        quarantineIdentity = (await SecureReceiveFile.prepareReceiveQuarantine(
          root: canonicalRoot,
          relativeParent: relativeParent,
          leaf: p.basename(path),
          expectedRootIdentity: identity.rootIdentity,
          expectedParentIdentity: identity.parentIdentity,
          expectedLeafIdentity: expectedLeafIdentity,
          sessionId: id,
          quarantineLeaf: quarantineLeaf,
        ))
            .value;
        record['receiveQuarantineIdentity'] = quarantineIdentity;
        try {
          await _persist();
        } catch (_) {
          record.remove('receiveQuarantineIdentity');
          rethrow;
        }
      }
      await _secureUnlinkReceiveEntry(
          root: canonicalRoot,
          relativeParent: relativeParent,
          leaf: p.basename(path),
          expectedRootIdentity: identity.rootIdentity,
          expectedParentIdentity: identity.parentIdentity,
          expectedLeafIdentity: expectedLeafIdentity,
          quarantineSessionId: id,
          quarantineLeaf: quarantineLeaf,
          expectedQuarantineIdentity: quarantineIdentity);
      return _ReceiveQuarantineCleanup(
        root: canonicalRoot,
        sessionId: id,
        expectedRootIdentity: identity.rootIdentity,
        expectedQuarantineIdentity: quarantineIdentity,
      );
    }
    await _secureUnlinkReceiveEntry(
        root: canonicalRoot,
        relativeParent: relativeParent,
        leaf: p.basename(path),
        expectedRootIdentity: identity.rootIdentity,
        expectedParentIdentity: identity.parentIdentity,
        expectedLeafIdentity: expectedLeafIdentity);
    return null;
  }

  Future<void> _deleteSession(_Session session) async {
    // Commit intent before unlinking so a crash cannot restore this as resumable.
    final alreadyMarked = _sessionDeletionMarkers.contains(session.id);
    _sessionDeletionMarkers.add(session.id);
    try {
      await _persist();
    } catch (_) {
      if (!alreadyMarked) _sessionDeletionMarkers.remove(session.id);
      rethrow;
    }

    try {
      final root = session.receiveRoot;
      final canonicalRoot = session.canonicalRoot;
      final expectedRootIdentity = session.receiveRootIdentity;
      final expectedLeafIdentity = session.receiveLeafIdentity;
      if (root == null ||
          canonicalRoot == null ||
          expectedRootIdentity == null ||
          expectedLeafIdentity == null) {
        throw FileSystemException(
            'Upload receive directory is unavailable or unpinned',
            session.path);
      }
      final rootType = await FileSystemEntity.type(root, followLinks: false);
      if (rootType != FileSystemEntityType.directory) {
        throw FileSystemException(
            'Upload receive directory is unavailable or changed', root);
      }
      if (!p.equals(
          await Directory(root).resolveSymbolicLinks(), canonicalRoot)) {
        throw FileSystemException('Upload receive directory changed', root);
      }
      // Never derive the unlink target from client metadata.
      if (p.basename(session.path) != '.${session.id}.part') {
        throw FileSystemException('Unsafe upload partial path', session.path);
      }
      final relativeParent = _relativeReceiveParent(root, session.path);
      if ((relativeParent.isEmpty && session.receiveParentIdentity != null) ||
          (relativeParent.isNotEmpty &&
              session.receiveParentIdentity == null)) {
        throw FileSystemException(
            'Upload receive directory identity is incomplete', session.path);
      }
      final missingDatedParent = await _completeMissingDatedReceiveParent(
        root: canonicalRoot,
        relativeParent: relativeParent,
        expectedRootIdentity: expectedRootIdentity,
        expectedParentIdentity: session.receiveParentIdentity,
      );
      final quarantineLeaf = _receiveQuarantineLeaf(session.id);
      final savedQuarantineIdentity = session.receiveQuarantineIdentity;
      FileSystemEntityType? partialType;
      if (!missingDatedParent) {
        partialType =
            await FileSystemEntity.type(session.path, followLinks: false);
        if (partialType != FileSystemEntityType.notFound &&
            partialType != FileSystemEntityType.file) {
          throw FileSystemException('Unsafe upload partial', session.path);
        }
        final file = await _safeSessionSource(session);
        if (partialType == FileSystemEntityType.file && file == null) {
          throw FileSystemException(
              'Upload partial path changed', session.path);
        }
      }

      if (quarantineLeaf != null) {
        if (missingDatedParent) {
          // Without a persisted quarantine-directory identity, no atomic move
          // could have begun; do not create authority for a vanished parent.
          if (savedQuarantineIdentity != null) {
            await _secureUnlinkReceiveEntry(
              root: canonicalRoot,
              relativeParent: relativeParent,
              leaf: p.basename(session.path),
              expectedRootIdentity: expectedRootIdentity,
              expectedParentIdentity: session.receiveParentIdentity,
              expectedLeafIdentity: expectedLeafIdentity,
              quarantineSessionId: session.id,
              quarantineLeaf: quarantineLeaf,
              expectedQuarantineIdentity: savedQuarantineIdentity,
            );
          }
        } else if (partialType == FileSystemEntityType.file ||
            savedQuarantineIdentity != null) {
          var quarantineIdentity = savedQuarantineIdentity;
          if (quarantineIdentity == null) {
            quarantineIdentity =
                (await SecureReceiveFile.prepareReceiveQuarantine(
              root: canonicalRoot,
              relativeParent: relativeParent,
              leaf: p.basename(session.path),
              expectedRootIdentity: expectedRootIdentity,
              expectedParentIdentity: session.receiveParentIdentity,
              expectedLeafIdentity: expectedLeafIdentity,
              sessionId: session.id,
              quarantineLeaf: quarantineLeaf,
            ))
                    .value;
            session.receiveQuarantineIdentity = quarantineIdentity;
            try {
              await _persist();
            } catch (_) {
              session.receiveQuarantineIdentity = null;
              rethrow;
            }
          }
          await _secureUnlinkReceiveEntry(
            root: canonicalRoot,
            relativeParent: relativeParent,
            leaf: p.basename(session.path),
            expectedRootIdentity: expectedRootIdentity,
            expectedParentIdentity: session.receiveParentIdentity,
            expectedLeafIdentity: expectedLeafIdentity,
            quarantineSessionId: session.id,
            quarantineLeaf: quarantineLeaf,
            expectedQuarantineIdentity: quarantineIdentity,
          );
        }
      } else {
        await _secureUnlinkReceiveEntry(
            root: canonicalRoot,
            relativeParent: relativeParent,
            leaf: p.basename(session.path),
            expectedRootIdentity: expectedRootIdentity,
            expectedParentIdentity: session.receiveParentIdentity,
            expectedLeafIdentity: expectedLeafIdentity);
      }
    } on FileSystemException {
      // Preserve the slot and deletion intent until the original root is usable.
      _markSessionUnavailable(session);
      notifyListeners();
      rethrow;
    }
    _sessions.remove(session.id);
    _unavailableSessionIds.remove(session.id);
    _sessionDeletionMarkers.remove(session.id);
    _unrestoredSessionRecords
        .removeWhere((record) => record['id'] == session.id);
    _refreshPageRecoveryWarning(session.pageId);
    try {
      await _persist();
    } catch (_) {
      // The last committed sessions key still contains deleting:true.
      _sessions[session.id] = session;
      _sessionDeletionMarkers.add(session.id);
      _markSessionUnavailable(session);
      notifyListeners();
      rethrow;
    }
    final quarantineIdentity = session.receiveQuarantineIdentity;
    if (quarantineIdentity != null) {
      await _removeReceiveQuarantineBestEffort(_ReceiveQuarantineCleanup(
        root: session.canonicalRoot!,
        sessionId: session.id,
        expectedRootIdentity: session.receiveRootIdentity!,
        expectedQuarantineIdentity: quarantineIdentity,
      ));
    }
  }

  Future<void> _serveSession(SharePage page, HttpRequest request) async {
    final segments = request.uri.pathSegments;
    final response = request.response;
    if (request.method != 'GET' && !_uploadAllowed(request)) {
      await _rejectUpload(request, 403, 'Forbidden');
      return;
    }
    final bodylessControl = request.method == 'POST' &&
            (segments.length == 1 ||
                segments.length == 3 && segments[2] == 'complete') ||
        request.method == 'DELETE' && segments.length == 2;
    if (bodylessControl && _requestHasBody(request)) {
      await _rejectUpload(request, HttpStatus.badRequest,
          'Control request must not include a body');
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
      final unavailable = _unrestoredSessionRecords.any((record) =>
          record['pageId'] == page.id &&
          record['fingerprint'] == fingerprint.single);
      if (unavailable) {
        await _rejectUpload(request, 409,
            'A previous upload session is unavailable; restore its receive folder before retrying.');
        return;
      }
      final existing = _sessions.values
          .where(
              (s) => s.pageId == page.id && s.fingerprint == fingerprint.single)
          .toList();
      if (existing.length > 1) {
        await _rejectUpload(request, 409,
            'Multiple upload sessions match this file; remove the transfer before retrying.');
        return;
      }
      if (existing.isNotEmpty) {
        final session = existing.single;
        if (_unavailableSessionIds.contains(session.id) ||
            _sessionDeletionMarkers.contains(session.id)) {
          await _rejectUpload(request, 409,
              'A previous upload session is unavailable; restore its receive folder before retrying.');
          return;
        }
        if (session.size != size) {
          await _rejectUpload(request, 409, 'Fingerprint metadata mismatch');
          return;
        }
        if (session.path.isEmpty ||
            session.initialization?.isCompleted == false) {
          await session.initialization?.future;
          final initialized = _sessions[session.id];
          if (initialized == null ||
              initialized.path.isEmpty ||
              _sessionDeletionMarkers.contains(session.id)) {
            await _rejectUpload(request, 500, 'Cannot create session');
            return;
          }
          await _uploadJson(response, 201, initialized.state);
          return;
        }
        await _uploadJson(response, 201, session.state);
        return;
      }
      final pageSessionCount = _sessionCountForPage(page.id);
      if (pageSessionCount >= 16 ||
          _pendingSessionCount >= _pendingSessionLimit) {
        await _rejectUpload(
            request,
            HttpStatus.tooManyRequests,
            _pendingSessionCount >= _pendingSessionLimit
                ? 'Too many pending upload sessions'
                : 'Too many upload sessions');
        return;
      }
      // Reserve the global slot synchronously before the first filesystem await.
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
      var createdPart = false;
      try {
        final directory = await receiveDirectoryFor(page);
        if (!_servers.containsKey(page.id)) throw _UploadCancelled();
        final pageRoot =
            p.basename(directory) == page.id ? directory : p.dirname(directory);
        final canonicalRoot = await Directory(pageRoot).resolveSymbolicLinks();
        final path = p.join(directory, '.$id.part');
        final canonicalPath =
            p.join(canonicalRoot, p.relative(path, from: pageRoot));
        final relativeParent = _relativeReceiveParent(pageRoot, path);
        final directoryIdentity =
            await SecureReceiveFile.captureDirectoryIdentity(
          root: canonicalRoot,
          relativeParent: relativeParent,
        );
        if ((relativeParent.isEmpty &&
                directoryIdentity.parentIdentity != null) ||
            (relativeParent.isNotEmpty &&
                directoryIdentity.parentIdentity == null)) {
          throw FileSystemException(
              'Invalid receive directory identity', directory);
        }
        final stored = _Session(
            id: id,
            pageId: page.id,
            name: session.name,
            size: size,
            fingerprint: session.fingerprint,
            path: path,
            receiveRoot: pageRoot,
            canonicalRoot: canonicalRoot,
            receiveRootIdentity: directoryIdentity.rootIdentity,
            receiveParentIdentity: directoryIdentity.parentIdentity)
          ..busy = true
          ..initialization = session.initialization;
        _sessions[id] = stored;
        // Persist a cleanup intent before creating the partial. A crash during
        // creation is recoverable and can never revive an untracked .part.
        _sessionDeletionMarkers.add(id);
        await _persist();
        final createdIdentity = await SecureReceiveFile.createReceiveEntry(
          root: canonicalRoot,
          relativeParent: relativeParent,
          leaf: p.basename(canonicalPath),
          expectedRootIdentity: directoryIdentity.rootIdentity,
          expectedParentIdentity: directoryIdentity.parentIdentity,
        );
        stored.receiveLeafIdentity = createdIdentity.value;
        createdPart = true;
        // Persist the identity while the deleting marker is still durable.
        await _persist();
        final identityAfterCreate =
            await SecureReceiveFile.captureDirectoryIdentity(
          root: canonicalRoot,
          relativeParent: relativeParent,
        );
        if (identityAfterCreate.rootIdentity !=
                directoryIdentity.rootIdentity ||
            identityAfterCreate.parentIdentity !=
                directoryIdentity.parentIdentity) {
          throw FileSystemException(
              'Receive directory changed while creating upload', directory);
        }
        final leafIdentityAfterCreate =
            await SecureReceiveFile.captureReceiveEntryIdentity(
          root: canonicalRoot,
          relativeParent: relativeParent,
          leaf: p.basename(canonicalPath),
          expectedRootIdentity: directoryIdentity.rootIdentity,
          expectedParentIdentity: directoryIdentity.parentIdentity,
          expectedLeafIdentity: createdIdentity.value,
        );
        if (leafIdentityAfterCreate.value != stored.receiveLeafIdentity) {
          throw FileSystemException(
              'Receive partial changed after creation', canonicalPath);
        }
        _sessionDeletionMarkers.remove(id);
        await _persist();
        stored.busy = false;
        _newTask(page, stored.name, 'upload', size, id: id, status: 'paused');
      } catch (_) {
        final failed = _sessions[id];
        if (failed == null || !createdPart) {
          _sessions.remove(id);
          _sessionDeletionMarkers.remove(id);
          try {
            await _persist();
          } catch (_) {
            // If the prepared record reached disk, its marker is safe to retry.
          }
        } else {
          _sessionDeletionMarkers.add(id);
          try {
            await _persist();
          } catch (_) {
            // The earlier prepared marker remains the durable recovery point.
          }
          try {
            await _deleteSession(failed);
          } catch (_) {
            _sessionDeletionMarkers.add(id);
            _markSessionUnavailable(failed);
            try {
              await _persist();
            } catch (_) {
              // Keep the in-memory marker and warning until the root returns.
            }
          }
        }
        await _rejectUpload(request, 500, 'Cannot create session');
        return;
      } finally {
        final current = _sessions[id];
        if (current != null) current.busy = false;
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
          if (request.uri.queryParameters['cancel'] == '1') {
            await _rejectUpload(request, 409, 'Upload already completed',
                state: receipt.state);
            return;
          }
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
    if (_sessionDeletionMarkers.contains(session.id) &&
        request.method != 'DELETE' &&
        request.method != 'GET') {
      await _rejectUpload(request, 409, 'Upload session is being cleaned');
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
      if (_activeUploadCount >= _maxConcurrentUploads) {
        await _rejectUpload(request, 429, '当前上传任务较多，请稍后重试',
            state: session.state);
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
      var moveMayHaveCommitted = false;
      ReceivedFile? record;
      try {
        final source = await _safeSessionSource(session);
        if (source == null) {
          throw const FileSystemException('Missing upload part');
        }
        if (session.offset != session.size ||
            await source.length() != session.size) {
          await _uploadJson(
              response, 409, {...session.state, 'error': 'Upload incomplete'});
          return;
        }
        final receiveRoot = session.receiveRoot;
        final canonicalRoot = session.canonicalRoot;
        final rootIdentity = session.receiveRootIdentity;
        final expectedLeafIdentity = session.receiveLeafIdentity;
        if (receiveRoot == null ||
            canonicalRoot == null ||
            rootIdentity == null ||
            expectedLeafIdentity == null) {
          throw FileSystemException(
              'Upload session has no pinned receive identity', session.path);
        }
        final relativeParent =
            _relativeReceiveParent(receiveRoot, session.path);
        final extension = p.extension(session.name);
        final stem = p.basenameWithoutExtension(session.name);
        for (var index = 0;; index++) {
          final candidate = File(p.join(source.parent.path,
              index == 0 ? session.name : '$stem ($index)$extension'));
          destination = candidate;
          moveMayHaveCommitted = true;
          final moved = await SecureReceiveFile.publishReceiveEntry(
            root: canonicalRoot,
            relativeParent: relativeParent,
            leaf: p.basename(source.path),
            destinationLeaf: p.basename(candidate.path),
            expectedRootIdentity: rootIdentity,
            expectedParentIdentity: session.receiveParentIdentity,
            expectedLeafIdentity: expectedLeafIdentity,
          );
          if (moved) break;
          destination = null;
          moveMayHaveCommitted = false;
        }
        final publishedDestination = destination;
        var displayedPath = publishedDestination.path;
        try {
          final originalParent = p.dirname(session.path);
          final resolvedParent =
              await Directory(originalParent).resolveSymbolicLinks();
          if (p.equals(resolvedParent, publishedDestination.parent.path)) {
            displayedPath =
                p.join(originalParent, p.basename(publishedDestination.path));
          }
        } on FileSystemException {
          // The pinned canonical path is the fallback if its alias disappeared.
        }
        record = ReceivedFile(
            name: p.basename(publishedDestination.path),
            path: displayedPath,
            size: session.size,
            pageTitle: page.title,
            pageId: page.id,
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
          final restored = await _restoreSessionPartial(
              session, p.basename(publishedDestination.path));
          moveMayHaveCommitted = false;
          if (restored) {
            destination = null;
          } else {
            // Do not overwrite an unexpected occupant at the partial path. The
            // final file stays intact and this session is no longer resumable.
            _markSessionUnavailable(session);
          }
          // _persist writes received-file records before receipts. If that
          // later key failed, the failed snapshot may already have committed
          // this record; persist the rolled-back model as compensation so a
          // restart cannot resurrect a ghost entry for the restored .part.
          try {
            await _persist();
          } catch (_) {
            // The failing key may still be unavailable; earlier keys in this
            // compensating snapshot are nevertheless written in order.
          }
          rethrow;
        }
        receipt.pending = null;
        _pruneReceipts();
        _sessionTask(session).status = 'completed';
        _pruneTransferTasks();
        notifyListeners();
        await _uploadJson(
            response, 201, {'name': record.name, 'size': record.size});
      } catch (error) {
        if (_sessions.containsKey(session.id) &&
            moveMayHaveCommitted &&
            destination != null) {
          final restored = await _restoreSessionPartial(
              session, p.basename(destination.path));
          moveMayHaveCommitted = false;
          if (restored) {
            destination = null;
          } else {
            _markSessionUnavailable(session);
          }
        }
        if (_sessions.containsKey(session.id)) {
          _sessionTask(session).status = 'failed';
          if (error is FileSystemException &&
              await _receiveRootMissingOrInaccessible(session)) {
            _markSessionUnavailable(session);
          }
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

  Future<bool> _restoreSessionPartial(
      _Session session, String publishedLeaf) async {
    final receiveRoot = session.receiveRoot;
    final canonicalRoot = session.canonicalRoot;
    final rootIdentity = session.receiveRootIdentity;
    final expectedLeafIdentity = session.receiveLeafIdentity;
    final partialLeaf = p.basename(session.path);
    if (receiveRoot == null ||
        canonicalRoot == null ||
        rootIdentity == null ||
        expectedLeafIdentity == null ||
        partialLeaf != '.${session.id}.part') {
      return false;
    }
    final String relativeParent;
    try {
      relativeParent = _relativeReceiveParent(receiveRoot, session.path);
    } on FileSystemException {
      return false;
    }

    Future<bool> partialHasExpectedIdentity() async {
      try {
        final identity = await SecureReceiveFile.captureReceiveEntryIdentity(
          root: canonicalRoot,
          relativeParent: relativeParent,
          leaf: partialLeaf,
          expectedRootIdentity: rootIdentity,
          expectedParentIdentity: session.receiveParentIdentity,
          expectedLeafIdentity: expectedLeafIdentity,
        );
        return identity.value == expectedLeafIdentity;
      } catch (_) {
        return false;
      }
    }

    if (await partialHasExpectedIdentity()) return true;
    try {
      final restored = await SecureReceiveFile.publishReceiveEntry(
        root: canonicalRoot,
        relativeParent: relativeParent,
        leaf: publishedLeaf,
        destinationLeaf: partialLeaf,
        expectedRootIdentity: rootIdentity,
        expectedParentIdentity: session.receiveParentIdentity,
        expectedLeafIdentity: expectedLeafIdentity,
      );
      if (restored && await partialHasExpectedIdentity()) return true;
    } catch (_) {
      // A lost response is reconciled by verifying the original partial below.
    }
    return partialHasExpectedIdentity();
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
    File? source;
    var chunkSize = 0;
    var status = 200;
    final initialOffset = session.offset;
    try {
      source = await _safeSessionSource(session);
      if (source == null) {
        throw const FileSystemException('Missing upload part');
      }
      output = await source.open(mode: FileMode.append);
      while (true) {
        final pending = input.moveNext();
        final available =
            await pending.timeout(_uploadIdleTimeout, onTimeout: () async {
          if (upload.cancelled.isCompleted || !_servers.containsKey(page.id)) {
            throw _UploadCancelled();
          }
          task.status = 'paused';
          await _rejectStalledUpload(request, input, pending,
              state: session.state);
          return false;
        });
        if (!available) {
          if (task.status == 'paused') return;
          break;
        }
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
    } on FileSystemException {
      if (await _receiveRootMissingOrInaccessible(session)) {
        _markSessionUnavailable(session);
        task.status = 'paused';
        status = 503;
      } else {
        task.status = 'failed';
        status = 500;
      }
    } catch (_) {
      task.status = 'failed';
      status = 500;
    } finally {
      try {
        await input.cancel();
      } catch (_) {}
      try {
        await output?.close();
        if (source == null || await _safeSessionSource(session) == null) {
          throw const FileSystemException('Unsafe upload part');
        }
        session.offset = await source.length();
        task.update(session.offset);
      } on FileSystemException {
        if (await _receiveRootMissingOrInaccessible(session)) {
          _markSessionUnavailable(session);
          task.status = 'paused';
          status = 503;
        } else {
          task.status = 'failed';
          status = 500;
        }
      } catch (_) {
        task.status = 'failed';
        status = 500;
      }
      try {
        await _persist();
      } catch (_) {
        task.status = 'failed';
        status = 500;
      } finally {
        // Release the lock before acknowledgement: the next chunk may arrive immediately.
        session.busy = false;
        _cancelActions.remove(task.id);
        final activeUploads = _uploads[page.id];
        activeUploads?.remove(upload);
        if (activeUploads != null && activeUploads.isEmpty) {
          _uploads.remove(page.id);
        }
        upload.done.complete();
        _pruneTransferTasks();
        notifyListeners();
      }
    }
    if (status == 200) {
      await _uploadJson(request.response, 200, session.state);
    } else {
      await _closeAfterError(request.response, status);
    }
  }

  String _downloadName(String name) {
    final safe = name.replaceAll(RegExp(r'[\x00-\x1f\x7f/\\]'), '_').trim();
    return safe.isEmpty ? 'download' : safe;
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

  Stream<List<int>> _managedFileRangeStream({
    required SharedFile file,
    required int start,
    required int end,
    required ManagedFileChunk firstChunk,
    required int expectedLength,
    required int expectedModifiedTimeMicros,
  }) async* {
    var offset = start;
    ManagedFileChunk? pending = firstChunk;
    while (offset < end) {
      final chunk = pending ??
          await _readManagedFileChunk(
            file,
            offset,
            min(SecureReceiveFile.managedFileReadChunkLimit, end - offset),
          );
      pending = null;
      if (chunk.fileLength != expectedLength ||
          chunk.modifiedTimeMicros != expectedModifiedTimeMicros) {
        throw FileSystemException(
            'Managed file changed while its content was being served',
            file.path);
      }
      if (chunk.bytes.isEmpty) {
        throw FileSystemException(
            'Managed file ended before the pinned range completed', file.path);
      }
      final count = min(chunk.bytes.length, end - offset);
      yield count == chunk.bytes.length
          ? chunk.bytes
          : chunk.bytes.sublist(0, count);
      offset += count;
    }
  }

  Future<void> _streamDownload(SharePage page, HttpResponse response,
      File source, String name, int start, int end,
      {Stream<List<int>> Function()? sourceStream,
      TransferTask? existing,
      Future<void>? cancellationBarrier,
      void Function(Future<void> Function())? onCancellationReady,
      Future<void> Function()? beforeStreamStart}) async {
    final task = existing ?? _newTask(page, name, 'download', end - start);
    task.totalBytes = end - start;
    var cancelled = false;
    StreamSubscription<List<int>>? subscription;
    final done = Completer<void>();
    final finished = Completer<void>();
    final stream = StreamController<List<int>>();
    Future<void> cancelDownload() async {
      if (finished.isCompleted) {
        if (cancellationBarrier != null) await cancellationBarrier;
        return;
      }
      if (!cancelled) {
        cancelled = true;
        if (task.status == 'active') task.status = 'cancelled';
        try {
          await subscription?.cancel();
        } catch (_) {}
        unawaited(stream.close());
        try {
          final socket = await response.detachSocket();
          socket.destroy();
        } catch (_) {}
        if (!done.isCompleted) done.complete();
      }
      await finished.future;
      if (cancellationBarrier != null) await cancellationBarrier;
    }

    _cancelActions[task.id] = cancelDownload;
    onCancellationReady?.call(cancelDownload);
    stream.onListen = () {
      final sourceBytes = sourceStream?.call() ?? source.openRead(start, end);
      subscription = sourceBytes.listen((bytes) {
        task.update(task.transferredBytes + bytes.length);
        _notifyProgress();
        stream.add(bytes);
      }, onError: stream.addError, onDone: stream.close);
    };
    stream.onPause = () => subscription?.pause();
    stream.onResume = () => subscription?.resume();
    stream.onCancel = () => subscription?.cancel();
    try {
      await beforeStreamStart?.call();
      if (cancelled) {
        await done.future;
      } else {
        await Future.any([response.addStream(stream.stream), done.future]);
      }
      if (!cancelled) {
        await response.close();
        task.status = 'completed';
      }
    } catch (_) {
      if (!cancelled) task.status = 'failed';
      rethrow;
    } finally {
      try {
        await subscription?.cancel();
        if (cancellationBarrier == null) _cancelActions.remove(task.id);
        _pruneTransferTasks();
        notifyListeners();
      } finally {
        if (!finished.isCompleted) finished.complete();
      }
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

  // sendBeacon and the GET use separate connections; cancellation can win the
  // race. Tombstones reject late/replayed GETs while retained; the count cap
  // intentionally permits earlier eviction under high churn.
  void _rememberConsumedZipClientToken(String token, String pageId) {
    final now = DateTime.now();
    _consumedZipClientTokens
        .removeWhere((_, tombstone) => !tombstone.expiresAt.isAfter(now));
    _consumedZipClientTokens.remove(token);
    _consumedZipClientTokens[token] =
        _ZipClientTokenTombstone(pageId, now.add(_zipClientTokenRetention));
    while (_consumedZipClientTokens.length > _maxRememberedZipTokens) {
      _consumedZipClientTokens.remove(_consumedZipClientTokens.keys.first);
    }
  }

  Future<void> _serveZipCancellation(
      SharePage page, HttpRequest request) async {
    if (request.method != 'POST') {
      request.response.headers.set('Allow', 'POST');
      await _closeAfterError(request.response, HttpStatus.methodNotAllowed);
      return;
    }
    if (request.headers['origin'] == null || !_uploadAllowed(request)) {
      await _rejectUpload(request, HttpStatus.forbidden, 'Forbidden');
      return;
    }
    if (_requestHasBody(request)) {
      await _rejectUpload(request, HttpStatus.badRequest,
          'Control request must not include a body');
      return;
    }
    final query = request.uri.queryParametersAll;
    final tokens = query['job'];
    if (query.length != 1 ||
        tokens?.length != 1 ||
        !_uuidPattern.hasMatch(tokens!.single)) {
      await _rejectUpload(request, HttpStatus.badRequest, 'Invalid ZIP job');
      return;
    }
    final token = tokens.single.toLowerCase();
    final job = _zipJobsByClientToken[token];
    if (job != null) {
      if (job.task.pageId == page.id) await _cancelZipJob(job);
    } else {
      _rememberConsumedZipClientToken(token, page.id);
    }
    request.response.statusCode = HttpStatus.noContent;
    await request.response.close();
  }

  Future<void> _zipBusyResponse(HttpResponse response) async {
    response.statusCode = HttpStatus.tooManyRequests;
    response.headers.set('Retry-After', '2');
    response.headers.set('Content-Type', 'text/html; charset=utf-8');
    response.headers.set('Content-Security-Policy',
        "default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'");
    response.write('''<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>ZIP 打包任务较多</title>
<style>:root{color-scheme:light dark}body{font:16px/1.6 system-ui,sans-serif;margin:0;padding:10vh 24px;background:#f5f7fb;color:#172033}main{max-width:560px;margin:auto;padding:32px;border:1px solid #d9e0ec;border-radius:16px;background:white}h1{font-size:1.4rem}a{color:#2457c5}@media(prefers-color-scheme:dark){body{background:#111827;color:#f3f4f6}main{background:#1f2937;border-color:#374151}a{color:#9ab7ff}}</style></head>
<body><main aria-labelledby="busy-title"><h1 id="busy-title">ZIP 打包任务较多</h1><p role="status">同时进行的 ZIP 打包已达上限（2 个），请稍后重试。</p><a href="/">返回下载页</a></main></body></html>''');
    await response.close();
  }

  /// ZIPs are regenerated for every request and are not resumable artifacts.
  /// Range/If-Range are intentionally ignored: each download receives a full ZIP.
  Future<void> _serveZip(SharePage page, HttpRequest request) async {
    final rawIds = request.uri.queryParametersAll['ids'];
    final ids = rawIds?.length == 1 ? rawIds!.single.split(',') : null;
    final rawJobTokens = request.uri.queryParametersAll['job'];
    String? clientToken;
    if (rawJobTokens != null) {
      if (rawJobTokens.length != 1 ||
          !_uuidPattern.hasMatch(rawJobTokens.single)) {
        await _closeAfterError(request.response, HttpStatus.badRequest);
        return;
      }
      clientToken = rawJobTokens.single;
      final tombstone = _consumedZipClientTokens[clientToken];
      if (tombstone != null && !tombstone.expiresAt.isAfter(DateTime.now())) {
        _consumedZipClientTokens.remove(clientToken);
      } else if (tombstone != null) {
        await _closeAfterError(
            request.response,
            tombstone.pageId == page.id
                ? HttpStatus.badRequest
                : HttpStatus.conflict);
        return;
      }
      if (_zipJobsByClientToken.containsKey(clientToken)) {
        await _closeAfterError(request.response, HttpStatus.conflict);
        return;
      }
    }
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
    if (_activeZipJobs >= _maxConcurrentZipJobs) {
      if (clientToken != null) {
        _rememberConsumedZipClientToken(clientToken, page.id);
      }
      await _zipBusyResponse(request.response);
      return;
    }
    _activeZipJobs++;
    final task = _newTask(page, '${page.title}.zip', 'download', 0);
    final job = _ZipJob(task, clientToken: clientToken);
    if (clientToken != null) _zipJobsByClientToken[clientToken] = job;
    _cancelActions[task.id] = () => _cancelZipJob(job);
    try {
      final entries = <_ZipInput>[];
      final used = <String>{};
      for (final file in selected) {
        if (job.cancelled) {
          await _closeAfterError(request.response, HttpStatus.badRequest);
          return;
        }
        final original = _zipName(file);
        if (original == null) {
          task.status = 'failed';
          await _closeAfterError(request.response, HttpStatus.badRequest);
          return;
        }
        final source = await _safeSharedSource(file);
        if (job.cancelled) {
          await _closeAfterError(request.response, HttpStatus.badRequest);
          return;
        }
        if (source == null) {
          task.status = 'failed';
          await _closeAfterError(request.response, HttpStatus.badRequest);
          return;
        }
        var name = original;
        for (var n = 1; !used.add(name.toLowerCase()); n++) {
          final extension = p.posix.extension(original);
          name =
              '${original.substring(0, original.length - extension.length)} ($n)$extension';
        }
        entries.add(_ZipInput(
          source: source,
          name: name,
          managedFile: file.managed ? file : null,
        ));
      }
      if (job.cancelled) {
        await _closeAfterError(request.response, HttpStatus.badRequest);
        return;
      }
      await _buildAndSendZip(page, request, entries, job);
    } finally {
      if (task.status == 'active') task.status = 'failed';
      _cancelActions.remove(task.id);
      if (clientToken != null &&
          identical(_zipJobsByClientToken[clientToken], job)) {
        _zipJobsByClientToken.remove(clientToken);
        _rememberConsumedZipClientToken(clientToken, page.id);
      }
      _pruneTransferTasks();
      _activeZipJobs--;
      if (!job.requestFinished.isCompleted) job.requestFinished.complete();
      notifyListeners();
    }
  }

  Future<void> _cancelZipJob(_ZipJob job) async {
    if (job.task.status != 'active') {
      if (job.workerFinished != null) await job.workerFinished!.future;
      await job.requestFinished.future;
      return;
    }
    job.cancelled = true;
    job.task.status = 'cancelled';
    final marker = job.cancellationMarker;
    final cancelWorker = job.cancelWorker;
    final workerFinished = job.workerFinished;
    if (marker != null && cancelWorker != null) {
      try {
        await marker.create();
      } catch (_) {}
      if (!cancelWorker.isCompleted) cancelWorker.complete();
    }
    final cancelResponse = job.cancelResponse;
    if (cancelResponse != null) await cancelResponse();
    if (workerFinished != null) await workerFinished.future;
    await job.requestFinished.future;
  }

  Future<void> _stageManagedFileForZip(
      SharedFile file, File snapshot, _ZipJob job) async {
    if (file.managedLeafIdentity == null) {
      throw FileSystemException(
          'Managed ZIP source has no leaf identity', file.path);
    }
    await _validateManagedFileAuthorization(file);
    await snapshot.create(exclusive: true);
    final output = await snapshot.open(mode: FileMode.write);
    var offset = 0;
    int? expectedLength;
    int? expectedModifiedTimeMicros;
    try {
      while (expectedLength == null || offset < expectedLength) {
        if (job.cancelled) {
          throw FileSystemException('Managed ZIP staging was cancelled');
        }
        final chunk = await _readManagedFileChunk(
          file,
          offset,
          SecureReceiveFile.managedFileReadChunkLimit,
        );
        expectedLength ??= chunk.fileLength;
        expectedModifiedTimeMicros ??= chunk.modifiedTimeMicros;
        if (chunk.fileLength != expectedLength ||
            chunk.modifiedTimeMicros != expectedModifiedTimeMicros) {
          throw FileSystemException(
              'Managed ZIP source changed while staging', file.path);
        }
        if (chunk.bytes.isEmpty) {
          if (offset < expectedLength) {
            throw FileSystemException(
                'Managed ZIP source ended before staging completed', file.path);
          }
          break;
        }
        await output.writeFrom(chunk.bytes);
        offset += chunk.bytes.length;
      }
      if (offset != expectedLength) {
        throw FileSystemException(
            'Managed ZIP source length changed while staging', file.path);
      }
      final finalCheck = await _readManagedFileChunk(file, offset, 1);
      if (finalCheck.fileLength != expectedLength ||
          finalCheck.modifiedTimeMicros != expectedModifiedTimeMicros ||
          finalCheck.bytes.isNotEmpty) {
        throw FileSystemException(
            'Managed ZIP source changed after staging', file.path);
      }
    } finally {
      await output.close();
    }
  }

  Future<void> _buildAndSendZip(SharePage page, HttpRequest request,
      List<_ZipInput> entries, _ZipJob job) async {
    await _beforeZipBuild?.call();
    if (job.cancelled) {
      await _closeAfterError(request.response, HttpStatus.badRequest);
      return;
    }
    final temporary = await Directory.systemTemp.createTemp('landrop-zip-');
    Future<void> cleanupTemporary() async {
      try {
        if (p.basename(temporary.path).startsWith('landrop-zip-') &&
            p.isWithin(Directory.systemTemp.path, temporary.path)) {
          await temporary.delete(recursive: true);
        }
      } catch (_) {}
    }

    if (job.cancelled) {
      try {
        await _beforeZipCleanup?.call();
      } finally {
        await cleanupTemporary();
      }
      await _closeAfterError(request.response, HttpStatus.badRequest);
      return;
    }
    final archive = File(p.join(temporary.path, 'download.zip'));
    final workerEntries = <List<String>>[];
    try {
      for (var index = 0; index < entries.length; index++) {
        if (job.cancelled) {
          throw FileSystemException('ZIP staging was cancelled');
        }
        final entry = entries[index];
        final managedFile = entry.managedFile;
        if (managedFile == null) {
          workerEntries.add([entry.source.path, entry.name]);
          continue;
        }
        final snapshot =
            File(p.join(temporary.path, 'managed-$index-${newId()}'));
        await _stageManagedFileForZip(managedFile, snapshot, job);
        workerEntries.add([snapshot.path, entry.name]);
      }
    } catch (_) {
      try {
        await _beforeZipCleanup?.call();
      } finally {
        await cleanupTemporary();
      }
      await _closeAfterError(
          request.response,
          job.cancelled
              ? HttpStatus.badRequest
              : HttpStatus.internalServerError);
      return;
    }
    final task = job.task;
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
    final cancel = Completer<void>();
    job.cancellationMarker = cancellation;
    job.cancelWorker = cancel;
    job.workerFinished = finished;
    try {
      if (job.cancelled) {
        await _closeAfterError(request.response, HttpStatus.badRequest);
        return;
      }
      _zipWorkerSpawnCount++;
      await Isolate.spawn(
          buildZipWorker,
          <Object>[
            port.sendPort,
            archive.path,
            workerEntries,
            cancellation.path,
          ],
          onExit: port.sendPort,
          onError: port.sendPort,
          errorsAreFatal: true);
      spawned = true;
      final failure = await Future.any<Object?>([result.future, cancel.future]);
      if (job.cancelled) {
        await _closeAfterError(request.response, HttpStatus.badRequest);
        return;
      }
      if (failure != null) throw FileSystemException('$failure');
      // The result confirms explicit close; onExit additionally confirms the
      // isolate cannot reopen a file while the owner streams/deletes the ZIP.
      await exited.future;
      if (job.cancelled) {
        await _closeAfterError(request.response, HttpStatus.badRequest);
        return;
      }
      final length = await archive.length();
      if (job.cancelled) {
        await _closeAfterError(request.response, HttpStatus.badRequest);
        return;
      }
      request.response.headers.set('Content-Type', 'application/zip');
      request.response.headers.set(HttpHeaders.acceptRangesHeader, 'none');
      request.response.headers
          .set('Content-Disposition', 'attachment; filename="download.zip"');
      request.response.contentLength = length;
      await _streamDownload(
          page, request.response, archive, task.name, 0, length,
          existing: task,
          cancellationBarrier: job.requestFinished.future,
          onCancellationReady: (cancel) => job.cancelResponse = cancel,
          beforeStreamStart: _beforeZipStream);
    } catch (_) {
      if (!job.cancelled) task.status = 'failed';
      await _closeAfterError(
          request.response,
          job.cancelled
              ? HttpStatus.badRequest
              : HttpStatus.internalServerError);
    } finally {
      try {
        if (spawned) await exited.future;
        await messages.cancel();
        port.close();
      } finally {
        try {
          await _beforeZipCleanup?.call();
        } finally {
          try {
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
    }
  }

  Future<void> _persist({void Function()? onPageListStored}) {
    _pruneReceipts();
    _pruneReceivedFiles();
    final receiptsJson = jsonEncode(
        _receipts.values.map((receipt) => receipt.toJson()).toList());
    final pagesJson = jsonEncode([
      ...pages
          .where((page) => !_conflictingPageIds.contains(page.id))
          .map((page) => page.toJson()),
      for (final records in _conflictingPageRecords.values) ...records,
    ]);
    final recordsJson =
        jsonEncode(receivedFiles.map((file) => file.toJson()).toList());
    final sessionsJson = jsonEncode([
      ..._unrestoredSessionRecords,
      ..._sessions.values.map((session) => <String, Object?>{
            ...session.toJson(),
            if (_sessionDeletionMarkers.contains(session.id)) 'deleting': true,
          }),
    ]);
    final rawReceiveCleanupJson =
        jsonEncode(_rawReceiveCleanupRecords.values.toList());
    Future<bool> setString(String key, String value) async {
      final beforeWrite = _beforePersistKey;
      if (beforeWrite != null) await beforeWrite(key);
      return _preferences!.setString(key, value);
    }

    Future<bool> setBool(String key, bool value) async {
      final beforeWrite = _beforePersistKey;
      if (beforeWrite != null) await beforeWrite(key);
      return _preferences!.setBool(key, value);
    }

    final result = _persistQueue.then((_) async {
      await _persistManagedFileCleanupQuarantineIfNeeded();
      if (!await setString(_storageKey, pagesJson)) {
        throw const FileSystemException('Could not persist page state');
      }
      onPageListStored?.call();
      if (!await setString(_recordsKey, recordsJson) ||
          !await setString(_receiptsKey, receiptsJson) ||
          !await setBool(_recordsMigratedKey, true) ||
          // Session state is the deletion/recovery commit record; keep it last so
          // a failed earlier metadata write cannot commit a partial session list.
          !await setString(_sessionsKey, sessionsJson)) {
        throw const FileSystemException('Could not persist transfer state');
      }
      if (_rawReceiveCleanupJournalValid &&
          !await setString(_rawReceiveCleanupKey, rawReceiveCleanupJson)) {
        throw const FileSystemException(
            'Could not persist raw receive cleanup journal');
      }
    });
    _persistQueue = result.catchError((Object _) {});
    return result;
  }
}
