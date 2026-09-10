import 'dart:io';

import '../../models/local_file_stamp.dart';

/// Reads the cheap facts about a file that decide whether it needs re-parsing:
/// its size and last-modified time.
///
/// A seam beside [AudioFileScanner] and [LocalMetadataReader], for the same
/// reason as those: it is the only place an incremental scan touches storage
/// beyond listing and parsing, so keeping it injectable is what lets the
/// "unchanged files are not re-parsed" rule be tested without a disk.
///
/// Never throws. A file that cannot be stat'ed (deleted between the listing and
/// here, a permission change, a mount that went away) answers null, and a null
/// stamp means "parse it", which is the pre-incremental behaviour.
abstract interface class LocalFileStatReader {
  /// The stamp for the file at [path], or null when it cannot be read.
  Future<LocalFileStamp?> stamp(String path);
}

/// The production [LocalFileStatReader]: one `stat` per file through
/// `dart:io`.
class IoLocalFileStatReader implements LocalFileStatReader {
  const IoLocalFileStatReader();

  @override
  Future<LocalFileStamp?> stamp(String path) async {
    try {
      final FileStat stat = await FileStat.stat(path);
      if (stat.type != FileSystemEntityType.file) return null;
      return LocalFileStamp(
        sizeBytes: stat.size,
        modifiedAtMs: stat.modified.millisecondsSinceEpoch,
      );
    } catch (_) {
      return null;
    }
  }
}

/// A [LocalFileStatReader] that answers nothing, for the platforms where an
/// incremental filesystem scan does not apply: Android, whose local library
/// comes from the content resolver rather than paths, and tests that are about
/// something else.
///
/// Every file then reads as "no stamp", so every file is parsed, which is
/// exactly how scanning behaved before incremental scans existed.
class UnsupportedLocalFileStatReader implements LocalFileStatReader {
  const UnsupportedLocalFileStatReader();

  @override
  Future<LocalFileStamp?> stamp(String path) async => null;
}
