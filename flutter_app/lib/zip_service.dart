import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;

/// Cancellation is checked at the native read boundary, including archive's
/// CRC pass. A marker works while this worker is busy in synchronous encoding;
/// a ReceivePort message alone cannot interrupt a synchronous multi-GiB entry.
class _CancellableFileHandle extends FileHandle {
  _CancellableFileHandle(super.path, this.cancellation);
  final File cancellation;

  @override
  int readInto(Uint8List buffer, [int? length]) {
    if (cancellation.existsSync()) throw const _ZipCancelled();
    return super.readInto(buffer, length);
  }
}

class _ZipCancelled implements Exception {
  const _ZipCancelled();
  @override
  String toString() => 'ZIP cancelled';
}

bool _matchesExpectedCanonicalPath(String source, String expected) =>
    p.equals(File(source).resolveSymbolicLinksSync(), expected);

/// Builds a streamed, disk-backed STORE ZIP (including ZIP64) off the UI isolate.
/// args: result port, output path, whitelisted [source, name, optional expected
/// canonical source path] entries, cancel path, and optionally an observer port
/// used by handle-lifecycle integration tests. Canonical paths are checked both
/// before and after opening the input handle. The result is sent only AFTER every
/// native input/output handle is closed. The owner must also await onExit before
/// removing its directory.
void buildZipWorker(List<Object> arguments) {
  final port = arguments[0] as SendPort;
  final destination = arguments[1] as String;
  final entries = arguments[2] as List<List<String>>;
  final cancellation = File(arguments[3] as String);
  final observer = arguments.length > 4 ? arguments[4] as SendPort : null;
  OutputFileStream? output;
  String? error;
  try {
    if (cancellation.existsSync()) throw const _ZipCancelled();
    output = OutputFileStream(destination);
    final encoder = ZipEncoder(streamed: true)..startEncode(output, level: 0);
    for (final entry in entries) {
      if (cancellation.existsSync()) throw const _ZipCancelled();
      final expectedPath = entry.length > 2 ? entry[2] : null;
      if (FileSystemEntity.typeSync(entry[0], followLinks: false) !=
              FileSystemEntityType.file ||
          (expectedPath != null &&
              !_matchesExpectedCanonicalPath(entry[0], expectedPath))) {
        throw const FileSystemException('Unsafe archive source');
      }
      final handle = _CancellableFileHandle(entry[0], cancellation);
      try {
        // Opening the handle pins the file even if an ancestor changes later.
        // Recheck the path after open, before the worker reads any content.
        if (expectedPath != null &&
            !_matchesExpectedCanonicalPath(entry[0], expectedPath)) {
          throw const FileSystemException('Unsafe archive source');
        }
        // FileBuffer performs its first native read in this constructor. Keep
        // the handle in scope even if cancellation interrupts construction.
        final input = InputFileStream.withFileHandle(handle);
        observer?.send('opened');
        final file = ArchiveFile.stream(entry[1], input)
          ..compression = CompressionType.none;
        encoder.add(file, level: 0);
      } finally {
        // Never kill the isolate: kill bypasses this finally on Windows and
        // leaves the source locked until a later VM finalizer/GC cycle.
        handle.closeSync();
      }
    }
    if (cancellation.existsSync()) throw const _ZipCancelled();
    encoder.endEncode();
  } catch (failure) {
    error = failure.toString();
  } finally {
    try {
      output?.closeSync();
    } catch (failure) {
      error ??= failure.toString();
    }
  }
  port.send({'error': error});
}
