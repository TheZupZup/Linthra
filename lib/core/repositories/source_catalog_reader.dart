import '../models/track.dart';

/// Reads back the catalog slice one source owns.
///
/// An optional capability beside [MusicLibraryRepository], in the same shape as
/// `IncrementalCatalogWriter`: the repositories that can answer it implement it,
/// and a caller checks with `is SourceCatalogReader` before relying on it.
/// Keeping it separate means a test fake or a future repository is not forced
/// to grow a method it has no use for.
///
/// The local library is what needs it. A rescan replaces the whole local slice,
/// so when one of several music folders is unreachable — an unplugged drive, a
/// revoked portal document — the tracks already indexed for that folder have to
/// be read back and carried into the new slice. Without that, refreshing the
/// folders that *are* readable would delete the music of the one that is not.
abstract interface class SourceCatalogReader {
  /// The tracks currently stored for [sourceId], in no particular order.
  ///
  /// Throws [UnsupportedError] when this repository wraps one that cannot
  /// answer, so a caller can tell "this source has no tracks" apart from "I
  /// cannot know" — a distinction that decides whether it is safe to overwrite
  /// a catalog slice.
  Future<List<Track>> getTracksForSource(String sourceId);
}
