import 'dart:ffi';

import 'package:ffi/ffi.dart';

import '../models/local_file_stamp.dart';
import 'linthra_core_ffi.dart';

/// One track a CUE sheet cuts from an audio file: the sheet's stamp, and the
/// row indexed under the track's uri.
typedef NativeScanCueEntry = ({LocalFileStamp? sheet, StampedTrack? indexed});

/// What [NativeScanPlan.settle] decides for a file whose tags were read.
typedef NativeScanSettled = ({
  /// The indexed row(s) stand as they are; otherwise new ones are built.
  bool keep,

  /// The file's stamp is stored with its row(s).
  bool stamp,

  /// Listed by the walk, then neither stat'ed nor read.
  bool vanished,

  /// Counted among the scan's reused tracks.
  bool reused,
});

/// The incremental scan's decisions in the Rust core
/// (native/linthra_core/src/scan/incremental.rs), for
/// `LocalMusicSource._scanFiles`.
///
/// A file is a plain audio file with at most one [indexed] row under its
/// path, or the audio CUE sheets cut into tracks ([cue] not empty). A rule
/// that panics gets Rust's safe answer (read the file; keep what is indexed
/// without a stamp), so these throw only when that panicked too.
abstract final class NativeScanPlan {
  /// Whether the row(s) already indexed for the file are reused without
  /// reading its tags.
  static bool reuse({
    required LocalFileStamp? stamp,
    required StampedTrack? indexed,
    required List<NativeScanCueEntry> cue,
    required Set<Uri> missingArtwork,
    required bool readUnchanged,
  }) {
    return using((Arena arena) {
      final _Records records =
          _Records(arena, stamp, indexed, cue, missingArtwork);
      final int answer = linthraScanPlan(
        records.file,
        records.indexed,
        records.cue,
        cue.length,
        readUnchanged,
      );
      if (answer < 0) throw StateError('linthra_scan_plan gave no answer');
      return answer == 1;
    });
  }

  /// Which row(s) the file gets once its tags were read: [hasTags] when tags
  /// came back, [failed] when the read failed rather than found none.
  static NativeScanSettled settle({
    required LocalFileStamp? stamp,
    required StampedTrack? indexed,
    required List<NativeScanCueEntry> cue,
    required bool readUnchanged,
    required bool hasTags,
    required bool failed,
  }) {
    return using((Arena arena) {
      final _Records records =
          _Records(arena, stamp, indexed, cue, const <Uri>{});
      final int answer = linthraScanSettle(
        records.file,
        records.indexed,
        records.cue,
        cue.length,
        readUnchanged,
        hasTags,
        failed,
      );
      if (answer < 0) throw StateError('linthra_scan_settle gave no answer');
      return (
        keep: answer & LinthraScanPlan.keep != 0,
        stamp: answer & LinthraScanPlan.stamp != 0,
        vanished: answer & LinthraScanPlan.vanished != 0,
        reused: answer & LinthraScanPlan.reused != 0,
      );
    });
  }
}

/// A file, its indexed row and its CUE tracks as the flat records the Rust
/// calls read.
class _Records {
  _Records(
    Arena arena,
    LocalFileStamp? stamp,
    StampedTrack? indexedRow,
    List<NativeScanCueEntry> cueEntries,
    Set<Uri> missingArtwork,
  )   : file = arena<Int64>(LinthraScanPlan.fileFields),
        indexed = arena<Int64>(LinthraScanPlan.indexedFields),
        cue = arena<Int64>(
          cueEntries.length * LinthraScanPlan.cueFields + 1,
        ) {
    _stamp(file, stamp);
    _indexed(indexed, indexedRow, missingArtwork);
    for (int i = 0; i < cueEntries.length; i++) {
      final Pointer<Int64> at = cue + i * LinthraScanPlan.cueFields;
      _stamp(at, cueEntries[i].sheet);
      _indexed(at + 3, cueEntries[i].indexed, missingArtwork);
    }
  }

  final Pointer<Int64> file;
  final Pointer<Int64> indexed;
  final Pointer<Int64> cue;

  static void _stamp(Pointer<Int64> at, LocalFileStamp? stamp) {
    at[0] = stamp == null ? 0 : 1;
    at[1] = stamp?.sizeBytes ?? 0;
    at[2] = stamp?.modifiedAtMs ?? 0;
  }

  static void _indexed(
    Pointer<Int64> at,
    StampedTrack? row,
    Set<Uri> missingArtwork,
  ) {
    for (int i = 0; i < LinthraScanPlan.indexedFields; i++) {
      at[i] = 0;
    }
    if (row == null) return;
    at[0] = 1;
    _stamp(at + 1, row.stamp);
    final int? cueSize = row.track.cueSheetSizeBytes;
    final int? cueModified = row.track.cueSheetModifiedAtMs;
    at[4] = cueSize == null ? 0 : 1;
    at[5] = cueSize ?? 0;
    at[6] = cueModified == null ? 0 : 1;
    at[7] = cueModified ?? 0;
    at[8] = missingArtwork.contains(row.track.artworkUri) ? 1 : 0;
  }
}
