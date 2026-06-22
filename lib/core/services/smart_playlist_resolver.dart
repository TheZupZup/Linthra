import 'dart:math';

import '../models/play_history.dart';
import '../models/smart_playlist.dart';
import '../models/track.dart';
import '../repositories/download_store.dart';

/// Turns a [SmartPlaylistKind] plus the on-device signals into an ordered track
/// list. Pure and synchronous: it takes everything it needs as arguments and
/// performs no IO, so each mix is trivially unit-testable in isolation.
///
/// All inputs are catalog [Track]s and non-secret track ids — the resolver
/// never sees (or produces) a token or authenticated URL, so the resulting mix
/// is safe to render and queue as-is.
class SmartPlaylistResolver {
  const SmartPlaylistResolver({this.maxTracks = 100});

  /// Upper bound on the size of an open-ended, signal-ranked mix (recently
  /// added/played, most played, random, never played). Keeps a mix a digestible
  /// set — and keeps the random mix bounded — rather than the whole library.
  /// User-curated mixes (favourites, downloaded) are not capped: they're only as
  /// large as the user made them.
  final int maxTracks;

  /// Resolves the tracks for [kind]. Missing data degrades gracefully: an empty
  /// catalog (or empty signal) yields an empty list rather than throwing.
  ///
  /// [random] seeds the shuffle for [SmartPlaylistKind.random]; pass a seeded
  /// [Random] for deterministic tests. It's ignored by every other kind.
  List<Track> resolve(
    SmartPlaylistKind kind, {
    required List<Track> allTracks,
    required PlayHistory history,
    required Map<String, DateTime> addedAt,
    required Set<String> favoriteIds,
    required Set<String> downloadedKeys,
    Random? random,
  }) {
    switch (kind) {
      case SmartPlaylistKind.recentlyAdded:
        return _recentlyAdded(allTracks, addedAt);
      case SmartPlaylistKind.recentlyPlayed:
        return _byUriOrder(allTracks, history.recentlyPlayedKeys);
      case SmartPlaylistKind.mostPlayed:
        return _byUriOrder(allTracks, history.mostPlayedKeys);
      case SmartPlaylistKind.favorites:
        return _filter(allTracks, favoriteIds);
      case SmartPlaylistKind.downloaded:
        return _filterByKey(allTracks, downloadedKeys);
      case SmartPlaylistKind.random:
        return _random(allTracks, random);
      case SmartPlaylistKind.neverPlayed:
        return _bounded(
          <Track>[
            for (final Track track in allTracks)
              if (!history.hasPlayed(track.uri)) track,
          ],
        );
    }
  }

  /// Tracks newest-first by first-seen time. Tracks with no recorded timestamp
  /// (e.g. before timestamping was wired) sort oldest, so they still appear but
  /// never crowd out genuinely new additions.
  List<Track> _recentlyAdded(
    List<Track> allTracks,
    Map<String, DateTime> addedAt,
  ) {
    final List<Track> sorted = List<Track>.of(allTracks)
      ..sort(
          (a, b) => _addedTime(b, addedAt).compareTo(_addedTime(a, addedAt)));
    return _bounded(sorted);
  }

  /// First-seen time for [track] (the newest-first sort key). Reads the
  /// provider-namespaced [Track.uri] key written by
  /// RecordingMusicLibraryRepository so two providers' same-id tracks don't share
  /// a timestamp. Falls back to the legacy bare-`id` key for a remote track whose
  /// timestamp predates the uri-keyed store and hasn't been migrated yet — the
  /// first post-upgrade sync migrates it in place, but this read can run before
  /// that, so the fallback keeps Recently Added in order immediately after an
  /// upgrade instead of collapsing the whole library to catalog order until the
  /// next sync. Unknown tracks sort oldest (at [_epoch]).
  DateTime _addedTime(Track track, Map<String, DateTime> addedAt) {
    final DateTime? byUri = addedAt[track.uri];
    if (byUri != null) return byUri;
    if (track.uri != track.id) {
      final DateTime? legacy = addedAt[track.id];
      if (legacy != null) return legacy;
    }
    return _epoch;
  }

  /// Resolves [orderedUris] (provider-namespaced play-history keys) against the
  /// catalog, preserving the given order and dropping uris the catalog no longer
  /// has. Keying on [Track.uri] keeps the right copy when two providers share a
  /// bare id, so a play of `jellyfin:101` never surfaces `subsonic:101`.
  List<Track> _byUriOrder(List<Track> allTracks, List<String> orderedUris) {
    final Map<String, Track> byUri = <String, Track>{
      for (final Track track in allTracks) track.uri: track,
    };
    return _bounded(<Track>[
      for (final String uri in orderedUris)
        if (byUri[uri] != null) byUri[uri]!,
    ]);
  }

  /// Catalog-ordered subset whose uris are in [uris] — the favourites mix. Keyed
  /// by [Track.uri] so a same-id copy from another provider isn't pulled in. Not
  /// bounded: favourites are user-curated, so the mix shows all of them.
  List<Track> _filter(List<Track> allTracks, Set<String> uris) {
    return <Track>[
      for (final Track track in allTracks)
        if (uris.contains(track.uri)) track,
    ];
  }

  /// Catalog-ordered subset whose provider-aware cache key is in [keys] — the
  /// downloaded mix. Keyed by [CachedTrack.cacheKeyForTrack] (not the bare id) so
  /// only the copy actually downloaded appears, never a same-id copy from another
  /// provider that isn't cached. Not bounded: downloads are user-curated.
  List<Track> _filterByKey(List<Track> allTracks, Set<String> keys) {
    return <Track>[
      for (final Track track in allTracks)
        if (keys.contains(CachedTrack.cacheKeyForTrack(track))) track,
    ];
  }

  /// A bounded shuffle of the catalog. Shuffles a *copy* so the input is never
  /// mutated, and is safe on an empty catalog (returns an empty list).
  List<Track> _random(List<Track> allTracks, Random? random) {
    final List<Track> shuffled = List<Track>.of(allTracks)..shuffle(random);
    return _bounded(shuffled);
  }

  List<Track> _bounded(List<Track> tracks) =>
      tracks.length <= maxTracks ? tracks : tracks.sublist(0, maxTracks);

  static final DateTime _epoch = DateTime.fromMillisecondsSinceEpoch(0);
}
