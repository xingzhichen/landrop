import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:landrop/secure_receive_file.dart';
import 'package:path/path.dart' as p;

final Map<String, String> _directoryIdentities = {};
final Map<String, String> _leafIdentities = {};
final Map<String, String> _quarantineIdentities = {};
final Set<String> _managedUnlinkFailures = {};
final Set<String> _receiveQuarantineFailures = {};
final Map<String, String> _receivePublishCollisions = {};
final Set<String> _receivePublishFailuresAfterMove = {};
Completer<void>? _receivePublishFailureCleanup;
String? _receivePublishFailureCleanupPath;
Future<void> _receivePublishTail = Future<void>.value();
var _nextDirectoryIdentity = 0;
var _nextLeafIdentity = 0;

void failNextManagedFileUnlinkForTest(String leaf) {
  _managedUnlinkFailures.add(leaf);
}

/// Simulate a process interruption after moving a partial into quarantine.
void failNextReceiveQuarantineAfterRenameForTest(String sourceLeaf) {
  _receiveQuarantineFailures.add(sourceLeaf);
}

/// Simulate an unrelated file appearing after a raw upload chooses its name.
void injectNextReceivePublishCollisionForTest(String path, String contents) {
  _receivePublishCollisions[_directoryKey(path)] = contents;
}

/// Simulate a lost method-channel response after the native move commits.
void failNextReceivePublishAfterMoveForTest(String destinationPath) {
  final key = _directoryKey(destinationPath);
  _receivePublishFailuresAfterMove.add(key);
  _receivePublishFailureCleanupPath = key;
  _receivePublishFailureCleanup = Completer<void>();
}

bool receivePublishFailureCleanupCompletedForTest() =>
    _receivePublishFailureCleanup?.isCompleted ?? false;

Future<T> _serializeReceivePublish<T>(Future<T> Function() action) async {
  final previous = _receivePublishTail;
  final completion = Completer<void>();
  _receivePublishTail = completion.future;
  await previous;
  try {
    return await action();
  } finally {
    completion.complete();
  }
}

bool _isValidReceiveDate(String value) {
  final match = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(value);
  if (match == null) return false;
  final year = int.parse(match[1]!);
  final month = int.parse(match[2]!);
  final day = int.parse(match[3]!);
  if (year == 0) return false;
  final date = DateTime.utc(year, month, day);
  return date.year == year && date.month == month && date.day == day;
}

final RegExp _uuidPattern = RegExp(
    r'^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$');
final RegExp _receivePartLeafPattern = RegExp(
    r'^\.[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.part$');

bool _isSafeReceiveLeaf(String value) =>
    value.isNotEmpty &&
    value != '.' &&
    value != '..' &&
    !value.contains('/') &&
    !value.contains('\\') &&
    !value.contains('\u0000');

String _directoryKey(String path) {
  final absolute = p.normalize(p.absolute(path));
  if (!Platform.isWindows) return absolute;

  // The Windows runner's temp path may use an 8.3 alias (RUNNER~1), while
  // controller paths are resolved to their long form before native calls.
  // Canonicalize the existing prefix so test identities follow the same leaf.
  var existingPrefix = absolute;
  final suffix = <String>[];
  try {
    while (FileSystemEntity.typeSync(existingPrefix, followLinks: false) ==
        FileSystemEntityType.notFound) {
      final parent = p.dirname(existingPrefix);
      if (parent == existingPrefix) return absolute;
      suffix.insert(0, p.basename(existingPrefix));
      existingPrefix = parent;
    }
    final existingType =
        FileSystemEntity.typeSync(existingPrefix, followLinks: false);
    if (existingType == FileSystemEntityType.link ||
        (suffix.isNotEmpty && existingType != FileSystemEntityType.directory)) {
      return absolute;
    }
    final canonical = File(existingPrefix).resolveSymbolicLinksSync();
    return p.normalize(p.joinAll([canonical, ...suffix]));
  } on FileSystemException {
    return absolute;
  }
}

String _identityForDirectory(String path) {
  final key = _directoryKey(path);
  return _directoryIdentities.putIfAbsent(
      key, () => 'dev=1;ino=${++_nextDirectoryIdentity}');
}

/// Change the mock file ID after a test replaces a directory object in-place.
/// Returns the prior identity so the test can restore it with the original dir.
String replaceMockDirectoryIdentity(String path) {
  final key = _directoryKey(path);
  final previous = _identityForDirectory(key);
  _directoryIdentities[key] = 'dev=1;ino=${++_nextDirectoryIdentity}';
  return previous;
}

void restoreMockDirectoryIdentity(String path, String identity) {
  _directoryIdentities[_directoryKey(path)] = identity;
}

String _nextLeafId() => 'dev=0;ino=${++_nextLeafIdentity}';

String _leafIdentityForPath(String path) {
  final key = _directoryKey(path);
  return _leafIdentities.putIfAbsent(key, _nextLeafId);
}

String replaceMockReceiveQuarantineIdentity(String path) {
  final key = _directoryKey(path);
  final previous = _quarantineIdentities.putIfAbsent(key, _nextLeafId);
  _quarantineIdentities[key] = _nextLeafId();
  return previous;
}

void restoreMockReceiveQuarantineIdentity(String path, String identity) {
  _quarantineIdentities[_directoryKey(path)] = identity;
}

/// Model a regular-file replacement at a path for race regression tests.
String replaceMockReceiveLeafIdentity(String path) {
  final key = _directoryKey(path);
  final previous = _leafIdentityForPath(key);
  _leafIdentities[key] = _nextLeafId();
  return previous;
}

void restoreMockReceiveLeafIdentity(String path, String identity) {
  _leafIdentities[_directoryKey(path)] = identity;
}

Future<void> _verifyNoFollowRootWalk(String root) async {
  final rootPrefix = p.rootPrefix(root);
  var current = rootPrefix;
  final components = p.split(p.relative(root, from: rootPrefix));
  for (final component in components) {
    if (component.isEmpty || component == '.' || component == '..') {
      throw PlatformException(
          code: 'invalid_path', message: 'Unsafe root component');
    }
    current = p.join(current, component);
    if (await FileSystemEntity.type(current, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw PlatformException(
          code: 'unsafe_root', message: 'Receive root changed');
    }
  }
}

Future<String> _mockPrepareReceiveQuarantine({
  required String root,
  required String target,
  required String sourceLeaf,
  required String sessionId,
  required String quarantineLeaf,
  required String expectedLeafIdentity,
}) async {
  final sourceMatch =
      RegExp(r'^\.([0-9a-f-]{36})\.part$').firstMatch(sourceLeaf);
  if (!_uuidPattern.hasMatch(sessionId) ||
      quarantineLeaf != '.$sessionId.quarantine' ||
      sourceMatch != null && sourceMatch[1] != sessionId) {
    throw PlatformException(
        code: 'invalid_path', message: 'Invalid receive quarantine source');
  }
  final sourceType = await FileSystemEntity.type(target, followLinks: false);
  if (sourceType != FileSystemEntityType.file) {
    throw PlatformException(
        code: 'identity_mismatch', message: 'Receive source identity changed');
  }
  final targetKey = _directoryKey(target);
  final targetIdentity = _leafIdentityForPath(targetKey);
  if (targetIdentity != expectedLeafIdentity) {
    throw PlatformException(
        code: 'identity_mismatch', message: 'Receive source identity changed');
  }

  final rootDirectory =
      Directory(p.join(root, SecureReceiveFile.quarantineDirectoryName));
  final rootType =
      await FileSystemEntity.type(rootDirectory.path, followLinks: false);
  if (rootType == FileSystemEntityType.notFound) {
    await rootDirectory.create();
  } else if (rootType != FileSystemEntityType.directory) {
    throw PlatformException(
        code: 'unsafe_quarantine',
        message: 'Quarantine root is not a directory');
  }
  final sessionDirectory = Directory(p.join(rootDirectory.path, sessionId));
  final sessionType =
      await FileSystemEntity.type(sessionDirectory.path, followLinks: false);
  if (sessionType == FileSystemEntityType.notFound) {
    await sessionDirectory.create();
  } else if (sessionType != FileSystemEntityType.directory) {
    throw PlatformException(
        code: 'unsafe_quarantine',
        message: 'Session quarantine is not a directory');
  }
  final entries = await sessionDirectory.list(followLinks: false).toList();
  if (entries.isNotEmpty) {
    throw PlatformException(
        code: 'unsafe_quarantine', message: 'Unpinned quarantine is not empty');
  }
  return _quarantineIdentities.putIfAbsent(
      _directoryKey(sessionDirectory.path), _nextLeafId);
}

Future<void> _mockQuarantinedUnlink({
  required String root,
  required String target,
  required String sourceLeaf,
  required String sessionId,
  required String quarantineLeaf,
  required String expectedLeafIdentity,
  required String expectedQuarantineIdentity,
  required bool sourceParentMissing,
}) async {
  final sourceMatch =
      RegExp(r'^\.([0-9a-f-]{36})\.part$').firstMatch(sourceLeaf);
  if (!_uuidPattern.hasMatch(sessionId) ||
      quarantineLeaf != '.$sessionId.quarantine' ||
      sourceMatch != null && sourceMatch[1] != sessionId) {
    throw PlatformException(
        code: 'invalid_path', message: 'Invalid receive quarantine entry');
  }

  final quarantineDirectory = Directory(
      p.join(root, SecureReceiveFile.quarantineDirectoryName, sessionId));
  if (await FileSystemEntity.type(quarantineDirectory.path,
          followLinks: false) !=
      FileSystemEntityType.directory) {
    throw PlatformException(
        code: 'unsafe_quarantine', message: 'Pinned quarantine is missing');
  }
  final quarantineDirectoryKey = _directoryKey(quarantineDirectory.path);
  if (_quarantineIdentities[quarantineDirectoryKey] !=
      expectedQuarantineIdentity) {
    throw PlatformException(
        code: 'identity_mismatch', message: 'Quarantine directory changed');
  }
  final quarantine = File(p.join(quarantineDirectory.path, quarantineLeaf));
  final quarantineKey = _directoryKey(quarantine.path);
  final sourceKey = _directoryKey(target);

  Future<String?> identityAt(String path) async {
    if (await FileSystemEntity.type(path, followLinks: false) !=
        FileSystemEntityType.file) {
      return null;
    }
    return _leafIdentities[_directoryKey(path)] ?? _leafIdentityForPath(path);
  }

  Future<void> restoreMismatch(String identity) async {
    if (sourceParentMissing) {
      throw PlatformException(
          code: 'identity_mismatch',
          message:
              'Mismatched quarantine preserved because its parent is missing');
    }
    if (await FileSystemEntity.type(target, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw PlatformException(
          code: 'identity_mismatch',
          message: 'Mismatched quarantine and occupied source preserved');
    }
    await quarantine.rename(target);
    _leafIdentities.remove(quarantineKey);
    _leafIdentities[sourceKey] = identity;
    throw PlatformException(
        code: 'identity_mismatch', message: 'Mismatched quarantine restored');
  }

  final quarantineType =
      await FileSystemEntity.type(quarantine.path, followLinks: false);
  if (quarantineType == FileSystemEntityType.file) {
    final identity = await identityAt(quarantine.path);
    if (identity == expectedLeafIdentity) {
      await quarantine.delete();
      _leafIdentities.remove(quarantineKey);
      return;
    }
    if (identity == null) {
      throw PlatformException(
          code: 'unsafe_quarantine',
          message: 'Quarantine identity unavailable');
    }
    await restoreMismatch(identity);
  }
  if (quarantineType != FileSystemEntityType.notFound) {
    throw PlatformException(
        code: 'unsafe_quarantine', message: 'Quarantine entry is not regular');
  }

  final sourceType = sourceParentMissing
      ? FileSystemEntityType.notFound
      : await FileSystemEntity.type(target, followLinks: false);
  if (sourceType == FileSystemEntityType.notFound) return;
  if (sourceType != FileSystemEntityType.file) {
    throw PlatformException(
        code: 'unsafe_leaf', message: 'Receive entry is not a regular file');
  }
  final sourceIdentity = await identityAt(target);
  if (sourceIdentity == null) {
    throw PlatformException(
        code: 'identity_mismatch',
        message: 'Receive entry identity unavailable');
  }
  await File(target).rename(quarantine.path);
  _leafIdentities.remove(sourceKey);
  _leafIdentities[quarantineKey] = sourceIdentity;
  if (_receiveQuarantineFailures.remove(sourceLeaf)) {
    throw PlatformException(
        code: 'simulated_crash',
        message: 'Interrupted after quarantine rename');
  }
  if (sourceIdentity != expectedLeafIdentity) {
    await restoreMismatch(sourceIdentity);
  }
  await quarantine.delete();
  _leafIdentities.remove(quarantineKey);
}

/// Unit-test stand-in for the native, directory-handle-relative unlink method.
/// The production implementation is exercised by native app builds/tests.
void installSecureReceiveFileMock() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('landrop/secure_fs'),
    (call) async {
      if (call.arguments is! Map) {
        throw MissingPluginException('Unexpected secure filesystem call');
      }
      final args = call.arguments as Map;
      final root = args['root'];
      if (root is! String || !p.isAbsolute(root)) {
        throw PlatformException(
            code: 'invalid_path', message: 'Invalid secure directory');
      }
      if (call.method == 'captureManagedFileDirectoryIdentity') {
        if (root != p.normalize(root)) {
          throw PlatformException(
              code: 'invalid_path', message: 'Invalid managed-file root');
        }
        await _verifyNoFollowRootWalk(root);
        return <String, Object?>{
          'rootIdentity': _identityForDirectory(root),
        };
      }
      if (call.method == 'captureManagedFileLeafIdentity' ||
          call.method == 'readManagedFileChunk' ||
          call.method == 'unlinkManagedFile') {
        final leaf = args['leaf'];
        final expectedRootIdentity = args['expectedRootIdentity'];
        final expectedLeafIdentity = args['expectedLeafIdentity'];
        if (root != p.normalize(root) ||
            leaf is! String ||
            !_uuidPattern.hasMatch(leaf) ||
            expectedRootIdentity is! String ||
            (call.method != 'captureManagedFileLeafIdentity' &&
                expectedLeafIdentity is! String)) {
          throw PlatformException(
              code: 'invalid_path', message: 'Invalid managed-file entry');
        }
        await _verifyNoFollowRootWalk(root);
        if (_identityForDirectory(root) != expectedRootIdentity) {
          throw PlatformException(
              code: 'identity_mismatch', message: 'Managed-file root changed');
        }
        final target = p.join(root, leaf);
        final type = await FileSystemEntity.type(target, followLinks: false);
        if (type == FileSystemEntityType.notFound) {
          throw PlatformException(
              code: 'missing_leaf', message: 'Managed-file entry is missing');
        }
        if (type != FileSystemEntityType.file) {
          throw PlatformException(
              code: 'unsafe_leaf', message: 'Managed entry is not a file');
        }
        final leafIdentity = _leafIdentityForPath(target);
        if (call.method == 'captureManagedFileLeafIdentity') {
          return <String, Object?>{'leafIdentity': leafIdentity};
        }
        if (expectedLeafIdentity != leafIdentity) {
          throw PlatformException(
              code: 'identity_mismatch', message: 'Managed-file leaf changed');
        }
        if (call.method == 'readManagedFileChunk') {
          final offset = args['offset'];
          final maxBytes = args['maxBytes'];
          if (offset is! int ||
              maxBytes is! int ||
              offset < 0 ||
              maxBytes < 1 ||
              maxBytes > SecureReceiveFile.managedFileReadChunkLimit ||
              offset > 0x7fffffffffffffff - maxBytes) {
            throw PlatformException(
                code: 'invalid_read', message: 'Invalid managed read range');
          }
          final targetFile = File(target);
          final stat = await targetFile.stat();
          final handle = await targetFile.open(mode: FileMode.read);
          late final Uint8List bytes;
          try {
            await handle.setPosition(offset);
            bytes = Uint8List.fromList(await handle.read(maxBytes));
          } finally {
            await handle.close();
          }
          return <String, Object?>{
            'bytes': bytes,
            'fileLength': stat.size,
            'modifiedTimeMicros': stat.modified.toUtc().microsecondsSinceEpoch,
          };
        }
        if (_managedUnlinkFailures.remove(leaf)) {
          throw PlatformException(
              code: 'unlink_failed',
              message: 'Injected managed unlink failure');
        }
        await File(target).delete();
        _leafIdentities.remove(_directoryKey(target));
        return null;
      }

      if (call.method == 'removeReceiveQuarantine') {
        final sessionId = args['sessionId'];
        final expectedRootIdentity = args['expectedRootIdentity'];
        final expectedQuarantineIdentity = args['expectedQuarantineIdentity'];
        if (root != p.normalize(root) ||
            sessionId is! String ||
            !_uuidPattern.hasMatch(sessionId) ||
            expectedRootIdentity is! String ||
            expectedQuarantineIdentity is! String) {
          throw PlatformException(
              code: 'invalid_path',
              message: 'Invalid quarantine directory pin');
        }
        await _verifyNoFollowRootWalk(root);
        if (_identityForDirectory(root) != expectedRootIdentity) {
          throw PlatformException(
              code: 'identity_mismatch', message: 'Receive root changed');
        }
        final quarantineSession = Directory(
            p.join(root, SecureReceiveFile.quarantineDirectoryName, sessionId));
        if (await FileSystemEntity.type(quarantineSession.path,
                followLinks: false) !=
            FileSystemEntityType.directory) {
          throw PlatformException(
              code: 'unsafe_quarantine',
              message: 'Pinned quarantine is missing');
        }
        final key = _directoryKey(quarantineSession.path);
        if (_quarantineIdentities[key] != expectedQuarantineIdentity) {
          throw PlatformException(
              code: 'identity_mismatch',
              message: 'Quarantine directory changed');
        }
        if ((await quarantineSession.list(followLinks: false).toList())
            .isNotEmpty) {
          throw PlatformException(
              code: 'unsafe_quarantine',
              message: 'Quarantine directory is not empty');
        }
        await quarantineSession.delete();
        _quarantineIdentities.remove(key);
        return null;
      }

      final relativeParent = args['relativeParent'];
      if (!_uuidPattern.hasMatch(p.basename(root)) ||
          relativeParent is! String ||
          relativeParent.isNotEmpty && !_isValidReceiveDate(relativeParent)) {
        throw PlatformException(
            code: 'invalid_path', message: 'Invalid receive directory');
      }
      await _verifyNoFollowRootWalk(root);
      final rootIdentity = _identityForDirectory(root);
      String? parentIdentity;
      var sourceParentMissing = false;
      var parent = root;
      if (relativeParent.isNotEmpty) {
        parent = p.join(root, relativeParent);
        final parentType =
            await FileSystemEntity.type(parent, followLinks: false);
        if (parentType == FileSystemEntityType.directory) {
          parentIdentity = _identityForDirectory(parent);
        } else if (parentType == FileSystemEntityType.notFound &&
            call.method == 'unlinkReceiveEntry' &&
            args['quarantineLeaf'] is String) {
          // A missing dated parent can still have a crash-recovery entry in
          // the pinned root quarantine directory. Never substitute the root
          // for the source parent during recovery or mismatch restoration.
          sourceParentMissing = true;
          parentIdentity = args['expectedParentIdentity'] as String?;
        } else {
          throw PlatformException(
              code: 'unsafe_parent', message: 'Receive parent changed');
        }
      }

      if (call.method == 'captureReceiveDirectoryIdentity') {
        return <String, Object?>{
          'rootIdentity': rootIdentity,
          'parentIdentity': parentIdentity,
        };
      }
      if (!<String>{
        'createReceiveEntry',
        'captureReceiveEntryIdentity',
        'publishReceiveEntry',
        'prepareReceiveQuarantine',
        'unlinkReceiveEntry',
      }.contains(call.method)) {
        throw MissingPluginException('Unexpected secure filesystem call');
      }

      final leaf = args['leaf'];
      final expectedRootIdentity = args['expectedRootIdentity'];
      final expectedParentIdentity = args['expectedParentIdentity'];
      if (call.method == 'unlinkReceiveEntry' &&
              (args['quarantineSessionId'] == null) !=
                  (args['quarantineLeaf'] == null) ||
          call.method == 'unlinkReceiveEntry' &&
              (args['quarantineLeaf'] == null) !=
                  (args['expectedQuarantineIdentity'] == null)) {
        throw PlatformException(
            code: 'invalid_path', message: 'Incomplete receive quarantine pin');
      }
      if (leaf is! String ||
          leaf.isEmpty ||
          leaf == '.' ||
          leaf == '..' ||
          leaf.contains('/') ||
          leaf.contains('\\') ||
          leaf.contains('\u0000') ||
          leaf.runes
              .any((rune) => rune < 0x20 || (rune >= 0x7f && rune <= 0x9f)) ||
          expectedRootIdentity is! String ||
          (expectedParentIdentity != null &&
              expectedParentIdentity is! String) ||
          (relativeParent.isEmpty && expectedParentIdentity != null) ||
          (relativeParent.isNotEmpty && expectedParentIdentity is! String)) {
        throw PlatformException(
            code: 'invalid_path', message: 'Invalid receive entry');
      }
      if (rootIdentity != expectedRootIdentity ||
          parentIdentity != expectedParentIdentity) {
        throw PlatformException(
            code: 'identity_mismatch', message: 'Receive directory changed');
      }

      final target = p.join(parent, leaf);
      if (call.method == 'prepareReceiveQuarantine') {
        final expectedLeafIdentity = args['expectedLeafIdentity'];
        final quarantineSessionId = args['quarantineSessionId'];
        final quarantineLeaf = args['quarantineLeaf'];
        if (expectedLeafIdentity is! String ||
            quarantineSessionId is! String ||
            quarantineLeaf is! String) {
          throw PlatformException(
              code: 'invalid_path',
              message: 'Invalid quarantine leaf identity');
        }
        final identity = await _mockPrepareReceiveQuarantine(
          root: root,
          target: target,
          sourceLeaf: leaf,
          sessionId: quarantineSessionId,
          quarantineLeaf: quarantineLeaf,
          expectedLeafIdentity: expectedLeafIdentity,
        );
        return <String, Object?>{'quarantineIdentity': identity};
      }
      if (call.method == 'createReceiveEntry') {
        if (!RegExp(
                r'^\.[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.part$')
            .hasMatch(leaf)) {
          throw PlatformException(
              code: 'invalid_path', message: 'Invalid receive partial');
        }
        await File(target).create(exclusive: true);
        return <String, Object?>{'leafIdentity': _leafIdentityForPath(target)};
      }
      if (call.method == 'publishReceiveEntry') {
        return _serializeReceivePublish(() async {
          final destinationLeaf = args['destinationLeaf'];
          final expectedLeafIdentity = args['expectedLeafIdentity'];
          if (destinationLeaf is! String || expectedLeafIdentity is! String) {
            throw PlatformException(
                code: 'invalid_path', message: 'Invalid receive move entry');
          }
          final sourceIsPart = _receivePartLeafPattern.hasMatch(leaf);
          final destinationIsPart =
              _receivePartLeafPattern.hasMatch(destinationLeaf);
          if (sourceIsPart == destinationIsPart ||
              !_isSafeReceiveLeaf(leaf) ||
              !_isSafeReceiveLeaf(destinationLeaf)) {
            throw PlatformException(
                code: 'invalid_path', message: 'Invalid receive move entry');
          }
          if (await FileSystemEntity.type(target, followLinks: false) !=
              FileSystemEntityType.file) {
            throw PlatformException(
                code: 'missing_leaf', message: 'Receive source is missing');
          }
          final sourceKey = _directoryKey(target);
          final sourceIdentity = _leafIdentityForPath(sourceKey);
          if (sourceIdentity != expectedLeafIdentity) {
            throw PlatformException(
                code: 'identity_mismatch', message: 'Receive source changed');
          }
          final destination = p.join(parent, destinationLeaf);
          final destinationKey = _directoryKey(destination);
          if (_receivePublishCollisions.containsKey(destinationKey)) {
            final contents = _receivePublishCollisions.remove(destinationKey)!;
            await File(destination).create(exclusive: true);
            await File(destination).writeAsString(contents, flush: true);
            _leafIdentities[destinationKey] = _nextLeafId();
            return false;
          }
          if (await FileSystemEntity.type(destination, followLinks: false) !=
              FileSystemEntityType.notFound) {
            return false;
          }
          await File(target).rename(destination);
          _leafIdentities.remove(sourceKey);
          _leafIdentities[destinationKey] = sourceIdentity;
          if (_receivePublishFailuresAfterMove.remove(destinationKey)) {
            throw PlatformException(
                code: 'lost_response',
                message: 'Simulated lost publish response');
          }
          return true;
        });
      }

      if (call.method == 'unlinkReceiveEntry' &&
          args['quarantineLeaf'] != null) {
        final quarantineSessionId = args['quarantineSessionId'];
        final quarantineLeaf = args['quarantineLeaf'];
        final expectedLeafIdentity = args['expectedLeafIdentity'];
        final expectedQuarantineIdentity = args['expectedQuarantineIdentity'];
        if (quarantineSessionId is! String ||
            quarantineLeaf is! String ||
            expectedLeafIdentity is! String ||
            expectedQuarantineIdentity is! String) {
          throw PlatformException(
              code: 'invalid_path', message: 'Invalid receive quarantine');
        }
        await _mockQuarantinedUnlink(
          root: root,
          target: target,
          sourceLeaf: leaf,
          sessionId: quarantineSessionId,
          quarantineLeaf: quarantineLeaf,
          expectedLeafIdentity: expectedLeafIdentity,
          expectedQuarantineIdentity: expectedQuarantineIdentity,
          sourceParentMissing: sourceParentMissing,
        );
        if (_receivePublishFailureCleanupPath == _directoryKey(target)) {
          final cleanup = _receivePublishFailureCleanup;
          if (cleanup != null && !cleanup.isCompleted) cleanup.complete();
        }
        return null;
      }

      final type = await FileSystemEntity.type(target, followLinks: false);
      if (type == FileSystemEntityType.notFound) {
        if (call.method == 'unlinkReceiveEntry') return null;
        throw PlatformException(
            code: 'missing_leaf', message: 'Receive entry is missing');
      }
      if (type != FileSystemEntityType.file) {
        throw PlatformException(
            code: 'unsafe_leaf', message: 'Receive entry is not a file');
      }
      if (call.method == 'captureReceiveEntryIdentity') {
        final expectedLeafIdentity = args['expectedLeafIdentity'];
        final actualLeafIdentity = _leafIdentityForPath(target);
        if (expectedLeafIdentity is! String ||
            expectedLeafIdentity != actualLeafIdentity) {
          throw PlatformException(
              code: 'identity_mismatch', message: 'Receive entry changed');
        }
        return <String, Object?>{'leafIdentity': actualLeafIdentity};
      }

      final expectedLeafIdentity = args['expectedLeafIdentity'];
      final identityAtTarget = _leafIdentities[_directoryKey(target)];
      final actualLeafIdentity = identityAtTarget == expectedLeafIdentity
          ? identityAtTarget
          : _leafIdentities.values.contains(expectedLeafIdentity)
              ? expectedLeafIdentity
              : identityAtTarget;
      if (expectedLeafIdentity is! String ||
          actualLeafIdentity != expectedLeafIdentity) {
        throw PlatformException(
            code: 'identity_mismatch', message: 'Receive entry changed');
      }
      await File(target).delete();
      _leafIdentities.remove(_directoryKey(target));
      return null;
    },
  );
}
