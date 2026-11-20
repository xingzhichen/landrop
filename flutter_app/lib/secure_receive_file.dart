import 'dart:io';

import 'package:flutter/services.dart';

/// Identity of the opened receive root and optional date directory.
class ReceiveDirectoryIdentity {
  const ReceiveDirectoryIdentity({
    required this.rootIdentity,
    required this.parentIdentity,
  });

  final String rootIdentity;
  final String? parentIdentity;
}

class ManagedFileDirectoryIdentity {
  const ManagedFileDirectoryIdentity({required this.rootIdentity});

  final String rootIdentity;
}

/// Opaque identity returned by the platform when it opens or creates a leaf.
class ReceiveLeafIdentity {
  const ReceiveLeafIdentity(this.value);

  final String value;
}

/// Bytes and metadata read from one identity-checked managed-file handle.
class ManagedFileChunk {
  const ManagedFileChunk({
    required this.bytes,
    required this.fileLength,
    required this.modifiedTimeMicros,
  });

  final Uint8List bytes;
  final int fileLength;
  final int modifiedTimeMicros;
}

/// Performs identity-pinned operations relative to a validated receive root.
///
/// Native implementations walk without following links/reparse points and
/// compare root, parent, and leaf identities. Raw and resumable cleanup can
/// request a no-replace move into a private quarantine before identity
/// verification and crash recovery. Managed read chunks are returned from the
/// same no-follow native handle that passed the identity check; each later
/// chunk reopens and rechecks the leaf. This does not prevent same-UID in-place
/// content mutation. Direct POSIX unlink callers still have a check-then-unlink
/// race; quarantine does not isolate against hostile same-UID processes. Managed-file read chunks come from the same native handle checked
/// for identity, and each later chunk reopens and rechecks the leaf.
/// Paths are passed as root + constrained components, never as mutable
/// absolute target paths.
class SecureReceiveFile {
  SecureReceiveFile._();

  static const MethodChannel _channel = MethodChannel('landrop/secure_fs');
  static const String quarantineDirectoryName = '.landrop-quarantine';
  static const int managedFileReadChunkLimit = 1024 * 1024;
  static final RegExp _uuidPattern =
      RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$');

  static Future<ReceiveDirectoryIdentity> captureDirectoryIdentity({
    required String root,
    required String relativeParent,
  }) async {
    try {
      final result = await _channel.invokeMapMethod<String, Object?>(
          'captureReceiveDirectoryIdentity', <String, Object>{
        'root': root,
        'relativeParent': relativeParent,
      });
      final rootIdentity = result?['rootIdentity'];
      final parentIdentity = result?['parentIdentity'];
      if (rootIdentity is! String ||
          (parentIdentity != null && parentIdentity is! String)) {
        throw FileSystemException(
            'Native secure filesystem returned invalid directory identity',
            root);
      }
      return ReceiveDirectoryIdentity(
          rootIdentity: rootIdentity,
          parentIdentity: parentIdentity as String?);
    } on PlatformException catch (error) {
      throw FileSystemException(
        error.message ?? 'Could not identify receive directory',
        root,
      );
    }
  }

  static bool isValidLeafIdentity(String? value) {
    if (value == null) return false;
    return RegExp(r'^dev=\d+;ino=\d+$').hasMatch(value) ||
        RegExp(r'^[0-9a-f]{16}:[0-9a-f]{32}$', caseSensitive: false)
            .hasMatch(value);
  }

  static bool _isValidLeafIdentity(String? value) => isValidLeafIdentity(value);

  static bool _isSafeLeaf(String value) =>
      value.isNotEmpty &&
      value != '.' &&
      value != '..' &&
      !value.contains('/') &&
      !value.contains('\\') &&
      !value.contains('\u0000');

  static Future<ReceiveLeafIdentity> createReceiveEntry({
    required String root,
    required String relativeParent,
    required String leaf,
    required String expectedRootIdentity,
    required String? expectedParentIdentity,
  }) async {
    try {
      final result = await _channel.invokeMapMethod<String, Object?>(
          'createReceiveEntry', <String, Object?>{
        'root': root,
        'relativeParent': relativeParent,
        'leaf': leaf,
        'expectedRootIdentity': expectedRootIdentity,
        'expectedParentIdentity': expectedParentIdentity,
      });
      final identity = result?['leafIdentity'];
      if (identity is! String || !_isValidLeafIdentity(identity)) {
        throw FileSystemException(
            'Native secure filesystem returned invalid leaf identity', root);
      }
      return ReceiveLeafIdentity(identity);
    } on PlatformException catch (error) {
      throw FileSystemException(
          error.message ?? 'Could not securely create receive entry', root);
    }
  }

  static Future<ReceiveLeafIdentity> captureReceiveEntryIdentity({
    required String root,
    required String relativeParent,
    required String leaf,
    required String expectedRootIdentity,
    required String? expectedParentIdentity,
  }) async {
    try {
      final result = await _channel.invokeMapMethod<String, Object?>(
          'captureReceiveEntryIdentity', <String, Object?>{
        'root': root,
        'relativeParent': relativeParent,
        'leaf': leaf,
        'expectedRootIdentity': expectedRootIdentity,
        'expectedParentIdentity': expectedParentIdentity,
      });
      final identity = result?['leafIdentity'];
      if (identity is! String || !_isValidLeafIdentity(identity)) {
        throw FileSystemException(
            'Native secure filesystem returned invalid leaf identity', root);
      }
      return ReceiveLeafIdentity(identity);
    } on PlatformException catch (error) {
      throw FileSystemException(
          error.message ?? 'Could not identify receive entry', root);
    }
  }

  static Future<ReceiveLeafIdentity> prepareReceiveQuarantine({
    required String root,
    required String relativeParent,
    required String leaf,
    required String sessionId,
    required String quarantineLeaf,
    required String expectedRootIdentity,
    required String? expectedParentIdentity,
    required String expectedLeafIdentity,
  }) async {
    final sourceMatch = RegExp(r'^\.([0-9a-f-]{36})\.part$').firstMatch(leaf);
    if (!_isValidLeafIdentity(expectedLeafIdentity) ||
        !_isSafeLeaf(leaf) ||
        !_uuidPattern.hasMatch(sessionId) ||
        quarantineLeaf != '.$sessionId.quarantine' ||
        (sourceMatch != null && sourceMatch[1] != sessionId)) {
      throw FileSystemException('Invalid receive quarantine request', root);
    }
    try {
      final result = await _channel.invokeMapMethod<String, Object?>(
          'prepareReceiveQuarantine', <String, Object?>{
        'root': root,
        'relativeParent': relativeParent,
        'leaf': leaf,
        'quarantineSessionId': sessionId,
        'quarantineLeaf': quarantineLeaf,
        'expectedRootIdentity': expectedRootIdentity,
        'expectedParentIdentity': expectedParentIdentity,
        'expectedLeafIdentity': expectedLeafIdentity,
      });
      final identity = result?['quarantineIdentity'];
      if (identity is! String || !_isValidLeafIdentity(identity)) {
        throw FileSystemException(
            'Native secure filesystem returned invalid quarantine identity',
            root);
      }
      return ReceiveLeafIdentity(identity);
    } on PlatformException catch (error) {
      throw FileSystemException(
        error.message ?? 'Could not prepare receive quarantine',
        root,
      );
    }
  }

  static Future<ManagedFileDirectoryIdentity>
      captureManagedFileDirectoryIdentity(String root) async {
    try {
      final result = await _channel.invokeMapMethod<String, Object?>(
          'captureManagedFileDirectoryIdentity', <String, Object>{
        'root': root,
      });
      final rootIdentity = result?['rootIdentity'];
      if (rootIdentity is! String || !_isValidLeafIdentity(rootIdentity)) {
        throw FileSystemException(
            'Native secure filesystem returned invalid directory identity',
            root);
      }
      return ManagedFileDirectoryIdentity(rootIdentity: rootIdentity);
    } on PlatformException catch (error) {
      throw FileSystemException(
        error.message ?? 'Could not identify managed-file directory',
        root,
      );
    }
  }

  static Future<ReceiveLeafIdentity> captureManagedFileLeafIdentity({
    required String root,
    required String leaf,
    required String expectedRootIdentity,
  }) async {
    if (!_uuidPattern.hasMatch(leaf) ||
        !_isValidLeafIdentity(expectedRootIdentity)) {
      throw FileSystemException('Invalid managed-file identity request', root);
    }
    try {
      final result = await _channel.invokeMapMethod<String, Object?>(
          'captureManagedFileLeafIdentity', <String, Object>{
        'root': root,
        'leaf': leaf,
        'expectedRootIdentity': expectedRootIdentity,
      });
      final identity = result?['leafIdentity'];
      if (identity is! String || !_isValidLeafIdentity(identity)) {
        throw FileSystemException(
            'Native secure filesystem returned invalid managed leaf identity',
            root);
      }
      return ReceiveLeafIdentity(identity);
    } on PlatformException catch (error) {
      throw FileSystemException(
        error.message ?? 'Could not identify managed-file leaf',
        root,
      );
    }
  }

  /// Reads a bounded range from the same no-follow native handle used to
  /// validate the managed leaf identity. Each call reopens and revalidates the
  /// current entry, so a path replacement between chunks fails closed.
  static Future<ManagedFileChunk> readManagedFileChunk({
    required String root,
    required String leaf,
    required String expectedRootIdentity,
    required String expectedLeafIdentity,
    required int offset,
    required int maxBytes,
  }) async {
    if (!_uuidPattern.hasMatch(leaf) ||
        !_isValidLeafIdentity(expectedRootIdentity) ||
        !_isValidLeafIdentity(expectedLeafIdentity) ||
        offset < 0 ||
        maxBytes < 1 ||
        maxBytes > managedFileReadChunkLimit ||
        offset > 0x7fffffffffffffff - maxBytes) {
      throw FileSystemException('Invalid managed-file read request', root);
    }
    try {
      final result = await _channel.invokeMapMethod<String, Object?>(
          'readManagedFileChunk', <String, Object>{
        'root': root,
        'leaf': leaf,
        'expectedRootIdentity': expectedRootIdentity,
        'expectedLeafIdentity': expectedLeafIdentity,
        'offset': offset,
        'maxBytes': maxBytes,
      });
      final rawBytes = result?['bytes'];
      final fileLength = result?['fileLength'];
      final modifiedTimeMicros = result?['modifiedTimeMicros'];
      if (rawBytes is! Uint8List ||
          fileLength is! int ||
          fileLength < 0 ||
          modifiedTimeMicros is! int ||
          rawBytes.length > maxBytes ||
          (rawBytes.isNotEmpty && offset + rawBytes.length > fileLength)) {
        throw FileSystemException(
            'Native secure filesystem returned invalid managed-file data',
            root);
      }
      return ManagedFileChunk(
        bytes: rawBytes,
        fileLength: fileLength,
        modifiedTimeMicros: modifiedTimeMicros,
      );
    } on PlatformException catch (error) {
      throw FileSystemException(
        error.message ?? 'Could not securely read managed-file content',
        root,
      );
    }
  }

  static Future<void> unlinkManagedFile({
    required String root,
    required String leaf,
    required String expectedRootIdentity,
    required String expectedLeafIdentity,
  }) async {
    if (!_uuidPattern.hasMatch(leaf) ||
        !_isValidLeafIdentity(expectedRootIdentity) ||
        !_isValidLeafIdentity(expectedLeafIdentity)) {
      throw FileSystemException('Invalid managed-file unlink identity', root);
    }
    try {
      await _channel.invokeMethod<void>('unlinkManagedFile', <String, Object>{
        'root': root,
        'leaf': leaf,
        'expectedRootIdentity': expectedRootIdentity,
        'expectedLeafIdentity': expectedLeafIdentity,
      });
    } on PlatformException catch (error) {
      throw FileSystemException(
        error.message ?? 'Secure managed-file cleanup failed',
        root,
      );
    }
  }

  static Future<void> removeReceiveQuarantine({
    required String root,
    required String sessionId,
    required String expectedRootIdentity,
    required String expectedQuarantineIdentity,
  }) async {
    if (!_uuidPattern.hasMatch(sessionId) ||
        !_isValidLeafIdentity(expectedQuarantineIdentity)) {
      throw FileSystemException(
          'Invalid receive quarantine directory pin', root);
    }
    try {
      await _channel
          .invokeMethod<void>('removeReceiveQuarantine', <String, Object>{
        'root': root,
        'sessionId': sessionId,
        'expectedRootIdentity': expectedRootIdentity,
        'expectedQuarantineIdentity': expectedQuarantineIdentity,
      });
    } on PlatformException catch (error) {
      throw FileSystemException(
        error.message ?? 'Could not remove receive quarantine directory',
        root,
      );
    }
  }

  static Future<void> unlinkEntry({
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
    if (!_isValidLeafIdentity(expectedLeafIdentity) || !_isSafeLeaf(leaf)) {
      throw FileSystemException('Invalid expected receive-file identity', root);
    }
    final hasQuarantine = quarantineSessionId != null ||
        quarantineLeaf != null ||
        expectedQuarantineIdentity != null;
    if (hasQuarantine &&
        (quarantineSessionId == null ||
            quarantineLeaf == null ||
            expectedQuarantineIdentity == null)) {
      throw FileSystemException('Incomplete receive quarantine identity', root);
    }
    if (quarantineLeaf != null && quarantineSessionId != null) {
      final match = RegExp(r'^\.([0-9a-f-]{36})\.part$').firstMatch(leaf);
      if (!_uuidPattern.hasMatch(quarantineSessionId) ||
          quarantineLeaf != '.$quarantineSessionId.quarantine' ||
          (match != null && match[1] != quarantineSessionId) ||
          !_isValidLeafIdentity(expectedQuarantineIdentity)) {
        throw FileSystemException('Invalid receive quarantine entry', root);
      }
    }
    try {
      await _channel.invokeMethod<void>('unlinkReceiveEntry', <String, Object?>{
        'root': root,
        'relativeParent': relativeParent,
        'leaf': leaf,
        'expectedRootIdentity': expectedRootIdentity,
        'expectedParentIdentity': expectedParentIdentity,
        'expectedLeafIdentity': expectedLeafIdentity,
        'quarantineSessionId': quarantineSessionId,
        'quarantineLeaf': quarantineLeaf,
        'expectedQuarantineIdentity': expectedQuarantineIdentity,
      });
    } on PlatformException catch (error) {
      throw FileSystemException(
        error.message ?? 'Secure receive-file cleanup failed',
        root,
      );
    }
  }
}
