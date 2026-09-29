/// What a Subsonic library walk (`SubsonicMusicSource.walkTracks`) saw.
///
/// The sync uses it for one decision: whether the walk is trustworthy enough to
/// prune the catalog rows it did not see ([isComplete]). Everything else is
/// plain counting for the status line and diagnostics.
class SubsonicCatalogWalk {
  const SubsonicCatalogWalk({
    required this.albumCount,
    required this.missingAlbumCount,
    required this.trackCount,
    required this.truncated,
    this.stopped = false,
  });

  /// How many distinct albums the album list returned.
  final int albumCount;

  /// Albums the list returned but `getAlbum` then answered "not found"
  /// (Subsonic error 70): removed on the server while the walk was running.
  final int missingAlbumCount;

  /// How many tracks were handed to the batch callback.
  final int trackCount;

  /// The album list hit the page safety cap with a full last page, so there
  /// may be albums the walk never saw.
  final bool truncated;

  /// The batch callback asked the walk to stop (the account changed), so the
  /// rest of the library was never read.
  final bool stopped;

  /// Whether every album the server has was read, so a track the walk did not
  /// see is genuinely gone and its row may be pruned.
  ///
  /// A handful of missing albums is expected (a rescan on the server removed
  /// them mid-walk) and their rows really are stale. When a large share of the
  /// list goes missing, something other than an edit is going on, so the walk
  /// is not trusted to prune: the rows stay until a later sync, which will not
  /// list those albums at all if they are truly gone.
  bool get isComplete =>
      !stopped &&
      !truncated &&
      missingAlbumCount * _maxMissingAlbumRatio <= albumCount;

  /// At most one album in ten may go missing for the walk to count as complete.
  static const int _maxMissingAlbumRatio = 10;
}
