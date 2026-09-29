import '../models/track.dart';

/// Optional capability a [MusicLibraryRepository] may also implement so a long
/// remote sync can **reconcile** a source's slice instead of replacing it.
///
/// A replacement (`upsertCatalog`, `beginCatalogReplacement`) removes the old
/// slice as part of the write, so it is only safe when the whole new catalog is
/// in hand. A big remote library (issue #680: a Navidrome server with ~80k
/// tracks) takes thousands of requests to enumerate, and a sync that must hold
/// everything until the end loses all of it when Android freezes or kills the
/// app halfway. Reconciling splits the write in two:
///
///  1. [upsertTracks] writes each batch as it arrives, inserting new rows and
///     updating existing ones by [Track.uri]. It never deletes, so a sync that
///     stops early leaves every earlier row (old or new) in place.
///  2. [removeTracksNotIn] drops the rows the finished sync did not see. The
///     caller only runs it once it *knows* the enumeration was complete; an
///     interrupted or truncated walk skips it and keeps the stale rows.
///
/// Both steps are idempotent, so re-running an interrupted sync from the start
/// is always safe.
///
/// Kept as a separate capability, like [IncrementalCatalogWriter], so fakes and
/// repositories that only do whole-catalog writes stay source-compatible. A
/// caller checks `repo is ReconcilingCatalogWriter` and falls back otherwise.
abstract interface class ReconcilingCatalogWriter {
  /// Inserts [tracks] into [sourceId]'s slice, replacing any existing row with
  /// the same [Track.uri]. Never deletes a row. An empty [tracks] is a no-op.
  Future<void> upsertTracks({
    required String sourceId,
    required List<Track> tracks,
  });

  /// Deletes every row of [sourceId] whose [Track.uri] is not in [keepUris],
  /// and returns the uris it removed. Other sources' rows are untouched.
  ///
  /// Only call this after an enumeration that is known to be complete: it is
  /// the one step of a reconciling sync that removes music.
  Future<List<String>> removeTracksNotIn({
    required String sourceId,
    required Set<String> keepUris,
  });
}
