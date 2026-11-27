import '../../models/local_file_stamp.dart';

/// Reads the cheap facts about a file that decide whether it needs re-parsing:
/// its size and last-modified time.
///
/// A seam beside [AudioFileScanner] and [LocalMetadataReader], for the same
/// reason as those: it is the only place an incremental scan touches storage
/// beyond listing and parsing, so keeping it injectable is what lets the
/// "unchanged files are not re-parsed" rule be tested without a disk. The
/// production one is `NativeLocalFileStatReader`, in the Rust core.
///
/// Never throws. A file that cannot be stat'ed (deleted between the listing and
/// here, a permission change, a mount that went away) answers null, and a null
/// stamp means "parse it", which is the pre-incremental behaviour.
abstract interface class LocalFileStatReader {
  /// The stamp for the file at [path], or null when it cannot be read.
  Future<LocalFileStamp?> stamp(String path);
}

/// The optional half of a [LocalFileStatReader] that stamps many files in one
/// call, for a scan that is about to stamp every file it listed.
abstract interface class LocalFileStampBatch {
  /// What [LocalFileStatReader.stamp] answers for each of [paths], in order.
  ///
  /// May answer fewer than asked, down to none: storage that stops answering
  /// ends the list at the stamp that stalled, and the caller asks for the
  /// rest one by one, as it would have without the batch. Never throws.
  Future<List<LocalFileStamp?>> stampAll(List<String> paths);
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
