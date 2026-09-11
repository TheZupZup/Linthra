import '../models/local_file_stamp.dart';

/// Optional capability a [MusicLibraryRepository] may also implement so a
/// source that reads files off a disk can store, and read back, what each file
/// looked like when its tags were parsed.
///
/// This is what makes a local scan incremental. The scan stats every candidate
/// file and compares the result with the stamp stored beside the track row; a
/// file whose size and mtime are unchanged is not opened at all, and its
/// existing row is carried straight over. On a library of any size that turns a
/// rescan from "parse everything again" into "parse what changed".
///
/// Kept as a separate capability, in the same shape as `SourceCatalogReader`
/// and `IncrementalCatalogWriter`, so the repositories and test fakes that only
/// ever deal in plain tracks stay source-compatible: a caller checks
/// `repo is StampedCatalogWriter` and falls back to
/// [MusicLibraryRepository.upsertCatalog] plus a full parse when it is absent.
/// Falling back is always *correct*, only slower, which is the property that
/// lets this be an optional capability at all.
///
/// The stamp is written in the same transaction as the row it belongs to. That
/// is the whole reason it lives on the row rather than in a store of its own:
/// there is no window in which a stamp says "already parsed" for a track the
/// catalog does not have, so an interrupted write can never make a later scan
/// skip a file it never actually indexed.
abstract interface class StampedCatalogWriter {
  /// Replaces every track stored for [sourceId] with [tracks], recording each
  /// one's on-disk stamp alongside it.
  ///
  /// The end state matches
  /// [MusicLibraryRepository.upsertCatalog] with the same tracks; the only
  /// difference is that the stamps are stored too. A [StampedTrack] with a null
  /// stamp stores nulls, which reads back as "parse this file next time".
  Future<void> upsertStampedCatalog({
    required String sourceId,
    required List<StampedTrack> tracks,
  });

  /// The tracks stored for [sourceId] with the stamps they were parsed at, in
  /// no particular order.
  ///
  /// Throws [UnsupportedError] when this repository wraps one that cannot
  /// answer, matching `SourceCatalogReader.getTracksForSource`: a caller has to
  /// be able to tell "this source has nothing stored" from "I cannot know",
  /// because the second is not a licence to treat every file as new.
  Future<List<StampedTrack>> getStampedTracksForSource(String sourceId);
}
