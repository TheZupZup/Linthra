import 'dart:io';

import 'package:path/path.dart' as p;

import '../../models/local_file_stamp.dart';
import 'directory_readability.dart';

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

/// The optional half of a [LocalFileStatReader] that can tell a file that is
/// gone from one that only could not be reached.
///
/// A file the walk listed and then could not stat or read may have been moved
/// or deleted, or its drive may have gone away, or its storage may be failing
/// for a moment. Only the first is "gone", and the evidence for it is the same
/// a later walk would have: the folder it was in answers, and answers without
/// it.
abstract interface class LocalFileAbsence {
  /// Whether [path], inside the selected folder [root], is gone: the nearest
  /// folder on the way from [path] up to [root] that can be listed answers
  /// without the next part of [path]. A folder that renamed or moved away is
  /// gone the same way, from the folder above it.
  ///
  /// False whenever that cannot be shown: no folder up to [root] can be listed
  /// (a drive that went away), or the folder still lists [path] (a read that
  /// failed for a moment). Never throws.
  Future<bool> isGone(String path, {required String root});
}

/// The production [LocalFileStatReader]: one `stat` per file through
/// `dart:io`.
class IoLocalFileStatReader implements LocalFileStatReader, LocalFileAbsence {
  const IoLocalFileStatReader({Duration stallLimit = storageStallLimit})
      : _stallLimit = stallLimit;

  /// How long a `stat` or a listing may go without an answer before it counts
  /// as one that failed. See [storageStallLimit].
  final Duration _stallLimit;

  @override
  Future<bool> isGone(String path, {required String root}) async {
    final String top = p.normalize(root);
    String child = p.normalize(path);
    if (!p.isWithin(top, child)) return false;
    while (true) {
      final String folder = p.dirname(child);
      final Set<String>? names = await _namesIn(folder);
      if (names != null) return !names.contains(p.basename(child));
      if (!p.isWithin(top, folder)) return false;
      child = folder;
    }
  }

  /// The names [folder] lists, or null when it cannot be listed in full, a
  /// listing that stops answering included.
  Future<Set<String>?> _namesIn(String folder) async {
    try {
      final Set<String> names = <String>{};
      await for (final FileSystemEntity entity
          in Directory(folder).list(followLinks: false).timeout(_stallLimit)) {
        names.add(p.basename(entity.path));
      }
      return names;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<LocalFileStamp?> stamp(String path) async {
    try {
      // A `stat` that doesn't answer (a share that went away, #778) is one
      // that failed, and is left blocked on its I/O thread.
      final FileStat stat = await FileStat.stat(path).timeout(_stallLimit);
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
