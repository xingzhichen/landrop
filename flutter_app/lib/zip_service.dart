import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';

/// Builds a ZIP on a worker isolate. archive's file encoder uses streamed
/// entries and disk-backed input/output, not readAsBytes or an in-memory ZIP.
/// STORE avoids redundant recompression of media and supports ZIP64 archives.
/// Entry names have already been whitelisted/uniquified by the controller.
void buildZipWorker(List<Object> arguments) {
  final port = arguments[0] as SendPort;
  final destination = arguments[1] as String;
  final entries = arguments[2] as List<List<String>>;
  ZipFileEncoder? encoder;
  try {
    encoder = ZipFileEncoder()
      ..create(destination, level: ZipFileEncoder.store);
    for (final entry in entries) {
      // Recheck on the worker immediately before opening the file.
      if (FileSystemEntity.typeSync(entry[0], followLinks: false) !=
          FileSystemEntityType.file) {
        throw const FileSystemException('Unsafe archive source');
      }
      encoder.addFileSync(File(entry[0]), entry[1], ZipFileEncoder.store);
    }
    encoder.closeSync();
    encoder = null;
    port.send(null);
  } catch (error) {
    try {
      encoder?.closeSync();
    } catch (_) {
      // Report the original read/encode error, not a partial-archive close error.
    }
    port.send(error.toString());
  }
}
