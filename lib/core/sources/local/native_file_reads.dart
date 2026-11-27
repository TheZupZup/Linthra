import '../../models/local_file_stamp.dart';
import '../../native/api/scan.dart' as rust;
import '../../native/linthra_bridge.dart';
import 'directory_readability.dart';
import 'local_file_stat.dart';

/// The production [LocalFileStatReader], in the Rust core
/// (native/linthra_core/src/scan/files.rs, where the rules are explained):
/// file stamps, one by one or all at once, and whether a file the scan
/// couldn't read is really gone. A `stat` or a listing that doesn't answer
/// within [storageStallLimit] counts as one that failed.
class NativeLocalFileStatReader
    implements LocalFileStatReader, LocalFileStampBatch, LocalFileAbsence {
  const NativeLocalFileStatReader({Duration stallLimit = storageStallLimit})
      : _stallLimit = stallLimit;

  final Duration _stallLimit;

  @override
  Future<LocalFileStamp?> stamp(String path) async {
    await LinthraBridgeLoader.ensureReady();
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
  /// than the `stat` it runs.
  @override
  Future<List<LocalFileStamp?>> stampAll(List<String> paths) async {
    if (paths.isEmpty) return const <LocalFileStamp?>[];
    await LinthraBridgeLoader.ensureReady();
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
    await LinthraBridgeLoader.ensureReady();
    return rust.isFileGone(
      path: path,
      root: root,
      stallLimitMs: _stallLimit.inMilliseconds,
    );
  }
}

/// The bytes of the file at [path], or null when it can't be read in full
/// within [stallLimit]: a file the scan reads whole, a CUE sheet. Read in the
/// Rust core.
Future<List<int>?> readScanFile(String path, Duration stallLimit) async {
  await LinthraBridgeLoader.ensureReady();
  return rust.readFile(path: path, stallLimitMs: stallLimit.inMilliseconds);
}
