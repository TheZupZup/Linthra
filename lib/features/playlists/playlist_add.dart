import 'package:flutter/foundation.dart';

import '../../core/models/playlist.dart';
import '../../core/models/track.dart';
import '../../core/repositories/playlist_repository.dart';
import '../../core/sources/jellyfin/jellyfin_track_mapper.dart';
import '../../core/sources/subsonic/subsonic_track_mapper.dart';

/// What adding a set of tracks to a playlist would actually do.
///
/// Two rules decide it, and both were previously private to the "Add to
/// playlist" sheet:
///
///  * a synced playlist only takes its own server's tracks, so it stays
///    consistent with the server (a Jellyfin playlist holds only `jellyfin:`
///    uris, a Navidrome playlist only `subsonic:` ones)
///  * the repository skips uris already in the playlist, so the count a user is
///    told must be the genuinely-new ones
///
/// It lives here because drag-and-drop (#389) is a second way into the same
/// operation, and a drop that used its own rules could put a Jellyfin track in
/// a Navidrome playlist by going around the sheet. One plan, both paths.
///
/// Pure and free of Flutter, so every awkward case (a mixed selection onto a
/// synced playlist, a drop of tracks that are all already there, an empty
/// selection) is unit-testable without pumping a widget.
@immutable
class PlaylistAddPlan {
  const PlaylistAddPlan._({
    required this.playlist,
    required this.requested,
    required this.addable,
    required this.newTracks,
  });

  /// Works out what adding [tracks] to [playlist] would do.
  factory PlaylistAddPlan.of({
    required Playlist playlist,
    required List<Track> tracks,
  }) {
    final String? scheme = _schemeFor(playlist.source);
    final List<Track> addable = scheme == null
        ? List<Track>.unmodifiable(tracks)
        : List<Track>.unmodifiable(<Track>[
            for (final Track track in tracks)
              if (track.uri.startsWith(scheme)) track,
          ]);
    // Keyed by the provider-namespaced uri, so adding `subsonic:101` to a
    // playlist holding `jellyfin:101` is a real add rather than a no-op.
    final Set<String> existing = playlist.trackIds.toSet();
    return PlaylistAddPlan._(
      playlist: playlist,
      requested: tracks.length,
      addable: addable,
      newTracks: List<Track>.unmodifiable(<Track>[
        for (final Track track in addable)
          if (!existing.contains(track.uri)) track,
      ]),
    );
  }

  final Playlist playlist;

  /// How many tracks were offered, including ones this playlist cannot take.
  final int requested;

  /// The offered tracks this playlist's source allows.
  final List<Track> addable;

  /// The subset of [addable] not already in the playlist: what an add changes.
  final List<Track> newTracks;

  /// Whether this playlist can take *any* of the offered tracks.
  ///
  /// This is the question a drop target asks while a drag hovers, so it is
  /// deliberately about the source rule alone. Tracks that are already in the
  /// playlist still count as acceptable: dropping them is a harmless no-op, and
  /// refusing the whole drop because one song is already there would be a
  /// worse answer than saying so afterwards.
  bool get accepts => addable.isNotEmpty;

  /// Whether performing this add would change the playlist at all.
  bool get changesAnything => newTracks.isNotEmpty;

  /// The uris to hand the repository.
  List<String> get uris =>
      <String>[for (final Track track in addable) track.uri];

  /// Why a drop was refused outright, or `null` when something can be added.
  ///
  /// Only a synced playlist can refuse: a local playlist takes anything, so an
  /// empty [addable] there means an empty selection, which has nothing to say.
  String? get refusalMessage {
    if (accepts) return null;
    final String? label = playlist.source.serverLabel;
    if (label == null) return null;
    return 'Only $label tracks can be added to ${playlist.name}.';
  }

  /// The line to show once the add has run. Never claims more than landed.
  String get resultMessage {
    final int added = newTracks.length;
    if (added == 0) {
      // Nothing new landed. Either the whole selection was unsupported, or
      // every track was already in the playlist.
      final String? refusal = refusalMessage;
      if (refusal != null) return refusal;
      return requested == 1
          ? "That song's already in ${playlist.name}."
          : 'Those songs are already in ${playlist.name}.';
    }
    final int skipped = requested - added;
    final String base = added == 1
        ? 'Added to ${playlist.name}.'
        : 'Added $added songs to ${playlist.name}.';
    if (skipped > 0) {
      return '$base $skipped skipped (already added or not supported).';
    }
    return base;
  }

  /// The track-uri scheme a synced playlist of [source] accepts, or `null` for
  /// a local playlist (which accepts any source's tracks).
  static String? _schemeFor(PlaylistSource source) {
    switch (source) {
      case PlaylistSource.local:
        return null;
      case PlaylistSource.jellyfin:
        return JellyfinTrackMapper.uriScheme;
      case PlaylistSource.subsonic:
        return SubsonicTrackMapper.uriScheme;
    }
  }
}

/// Adds [tracks] to [playlist] through [repository] and returns what happened.
///
/// The repository is passed in rather than read from a provider so this stays
/// testable with a fake, and so both entry points, the sheet and a drop,
/// persist through the same path the rest of the app uses.
///
/// A plan with nothing addable performs no write at all: an unsupported drop
/// should not touch the playlist's `updatedAt`, let alone queue a sync.
Future<PlaylistAddPlan> addTracksToPlaylist({
  required PlaylistRepository repository,
  required Playlist playlist,
  required List<Track> tracks,
}) async {
  final PlaylistAddPlan plan =
      PlaylistAddPlan.of(playlist: playlist, tracks: tracks);
  if (plan.accepts) {
    await repository.addTracks(playlist.id, plan.uris);
  }
  return plan;
}
