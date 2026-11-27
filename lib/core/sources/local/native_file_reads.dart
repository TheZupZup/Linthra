import 'dart:async';
import 'dart:io';

import '../../models/local_file_stamp.dart';
import '../../native/api/scan.dart' as rust;
import '../../native/linthra_bridge.dart';
import 'directory_readability.dart';
import 'local_file_stat.dart';

/// [IoLocalFileStatReader] in the Rust core
/// (native/linthra_core/src/scan/files.rs): the same stamps, the same answer
/// to "is this file gone?", and the same [storageStallLimit] on storage that
/// stops answering.
///
/// Without the Rust core it hands both to [IoLocalFileStatReader].
class NativeLocalFileStatReader
    implements LocalFileStatReader, LocalFileStampBatch, LocalFileAbsence {
  const NativeLocalFileStatReader({Duration stallLimit = storageStallLimit})
      : _stallLimit = stallLimit;

  final Duration _stallLimit;

  IoLocalFileStatReader get _fallback =>
      IoLocalFileStatReader(stallLimit: _stallLimit);

  @override
  Future<LocalFileStamp?> stamp(String path) async {
    if (!await LinthraBridgeLoader.ready()) return _fallback.stamp(path);
    final rust.FileStamp? stamp = await rust.stampFile(
      path: path,
      stallLimitMs: _stallLimit.inMilliseconds,
    );
    return stamp == null ? null : _stampOf(stamp);
  }

  static LocalFileStamp _stampOf(rust.FileStamp stamp) => LocalFileStamp(
        sizeBytes: stamp.sizeBytes,
        modifiedAtMs: stamp.modifiedAtMs,
      );

  /// One call into the Rust core for the lot: a call per file costs more
  /// than the `stat` it runs. Without the Rust core, answers none.
  @override
  Future<List<LocalFileStamp?>> stampAll(List<String> paths) async {
    if (paths.isEmpty || !await LinthraBridgeLoader.ready()) {
      return const <LocalFileStamp?>[];
    }
    final List<rust.FileStamp?> stamps = await rust.stampFiles(
      paths: paths,
      stallLimitMs: _stallLimit.inMilliseconds,
    );
    return <LocalFileStamp?>[
      for (final rust.FileStamp? stamp in stamps)
        stamp == null ? null : _stampOf(stamp),
    ];
  }

  @override
  Future<bool> isGone(String path, {required String root}) async {
    if (!await LinthraBridgeLoader.ready()) {
      return _fallback.isGone(path, root: root);
    }
    return rust.isFileGone(
      path: path,
      root: root,
      stallLimitMs: _stallLimit.inMilliseconds,
    );
  }
}

/// The bytes of the file at [path], or null when it can't be read in full
/// within [stallLimit]: a file the scan reads whole, a CUE sheet.
///
/// Read in the Rust core when the build has it, and through `dart:io`
/// otherwise, with the same answer.
Future<List<int>?> readScanFile(String path, Duration stallLimit) async {
  if (await LinthraBridgeLoader.ready()) {
    return rust.readFile(path: path, stallLimitMs: stallLimit.inMilliseconds);
  }
  return readScanFileInDart(path, stallLimit);
}

/// [readScanFile] without the Rust core.
Future<List<int>?> readScanFileInDart(String path, Duration stallLimit) async {
  try {
    return await File(path).readAsBytes().timeout(stallLimit);
  } on FileSystemException {
    return null;
  } on TimeoutException {
    return null;
  }
}
