import '../models/track.dart';

/// Optional capability a [MusicLibraryRepository] may also implement so a large
/// remote sync can build a source's catalog slice **incrementally**, across
/// several batches, instead of one monolithic write.
///
/// A whole-library `upsertCatalog` of a big remote library (≈1000+ tracks)
/// serializes every row to the database isolate in one burst and only becomes
/// visible once the entire payload lands — so nothing appears until the very
/// end. Writing in chunks instead lets the library be read (and shown) as it
/// fills, and keeps each main-isolate serialization step small enough to stay
/// responsive.
///
/// Kept as a *separate* capability rather than widening [MusicLibraryRepository]
/// so the many repositories and test fakes that only ever do whole-catalog
/// upserts stay source-compatible. A caller that wants progressive writes checks
/// `repo is IncrementalCatalogWriter` and falls back to
/// [MusicLibraryRepository.upsertCatalog] when the capability is absent.
///
/// The end state of `beginCatalogReplacement(tracks: a)` followed by
/// `appendToCatalog(tracks: b)` matches a single `upsertCatalog(tracks: a + b)`
/// for the same `sourceId`; only the timing differs (the slice is readable, and
/// already partly populated, between batches).
abstract interface class IncrementalCatalogWriter {
  /// Starts a fresh incremental sync for [sourceId]: removes the source's
  /// existing rows and writes the first [tracks] batch in **one** transaction,
  /// so a reader never observes the old slice with the first batch missing.
  /// Other sources' rows are untouched. An empty [tracks] simply clears the
  /// slice (the "deselected everything" case).
  Future<void> beginCatalogReplacement({
    required String sourceId,
    required List<Track> tracks,
  });

  /// Appends one more [tracks] batch to the slice started by
  /// [beginCatalogReplacement] for the same [sourceId]. Other sources' rows are
  /// untouched. An empty [tracks] is a no-op.
  Future<void> appendToCatalog({
    required String sourceId,
    required List<Track> tracks,
  });
}
