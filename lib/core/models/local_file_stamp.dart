import 'track.dart';

/// What a local file looked like on disk the last time Linthra parsed it: its
/// size and its last-modified time.
///
/// This is the whole basis of an incremental scan. Reading a file's tags means
/// opening it and parsing its metadata blocks; a `stat` costs one syscall. So a
/// scan stats every candidate, compares the answer with the stamp stored beside
/// the track row, and only opens the files whose stamp changed.
///
/// **Why size and mtime.** Between them they catch every ordinary way a music
/// file changes: a re-tag rewrites the metadata block (mtime, usually size), a
/// re-encode replaces the file (both), and a fresh copy or a download lands with
/// a new mtime. They are also what every incremental tool of this shape uses,
/// from `make` to `rsync`'s default, for the same reason: they are cheap,
/// present on every filesystem, and preserved across a normal write.
///
/// **What they miss**, honestly: a write that restores the previous mtime *and*
/// lands on exactly the same byte count. `touch -r` after an in-place edit does
/// it, and so does a backup tool restoring an old file over a new one. Hashing
/// contents would catch those, but at the cost of reading every byte of every
/// file on every scan, which is the thing being avoided. The escape hatch is a
/// full rescan, which ignores every stamp and re-parses the library.
///
/// The stamp is *not* an identity. Two different files can easily share a size
/// and an mtime; a stamp only ever answers "is the file at this path still the
/// one I parsed?", never "which file is this?".
class LocalFileStamp {
  const LocalFileStamp({required this.sizeBytes, required this.modifiedAtMs});

  /// The file's length in bytes.
  final int sizeBytes;

  /// Last modification time, as milliseconds since the Unix epoch.
  ///
  /// Milliseconds rather than the full `DateTime` because that is the
  /// resolution SQLite stores and every filesystem Linthra runs on reports at
  /// least that; keeping one unit end to end means a stamp read back from the
  /// database compares equal to one taken from disk without any rounding
  /// question.
  final int modifiedAtMs;

  /// Whether a file with this stamp needs re-parsing given [previous]. A null
  /// [previous] means the file was never parsed, so yes.
  bool differsFrom(LocalFileStamp? previous) =>
      previous == null ||
      previous.sizeBytes != sizeBytes ||
      previous.modifiedAtMs != modifiedAtMs;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is LocalFileStamp &&
          other.sizeBytes == sizeBytes &&
          other.modifiedAtMs == modifiedAtMs);

  @override
  int get hashCode => Object.hash(sizeBytes, modifiedAtMs);

  @override
  String toString() => 'LocalFileStamp($sizeBytes bytes, mtime $modifiedAtMs)';
}

/// A [Track] together with the on-disk stamp it was parsed from, when there is
/// one.
///
/// [stamp] is null for everything that is not a plain local file: remote tracks,
/// Android SAF documents and MediaStore rows, and rows written by a build that
/// predates the stamp columns. A null stamp simply means "re-parse this", which
/// is exactly the pre-incremental behaviour, so nothing has to be migrated or
/// backfilled for the feature to be correct.
class StampedTrack {
  const StampedTrack({required this.track, this.stamp});

  final Track track;
  final LocalFileStamp? stamp;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is StampedTrack && other.track == track && other.stamp == stamp);

  @override
  int get hashCode => Object.hash(track, stamp);
}
