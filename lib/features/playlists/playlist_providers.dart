import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/playlist.dart';
import '../../core/models/track.dart';
import '../../data/repositories/music_library_repository_provider.dart';
import '../../data/repositories/playlist_repository_provider.dart';
import '../settings/jellyfin/jellyfin_settings_controller.dart';
import '../settings/subsonic/subsonic_settings_controller.dart';
import 'widgets/create_playlist_dialog.dart';

/// Streams the user's playlists for the UI; emits on every change.
final playlistsProvider = StreamProvider<List<Playlist>>((ref) {
  return ref.watch(playlistRepositoryProvider).playlistsStream;
});

/// The servers a new playlist can be synced to — one [PlaylistSyncTarget] per
/// connected remote provider — so the create dialog only offers a "sync to"
/// choice for servers the user is actually signed in to. Empty for a local-only
/// setup, keeping the dialog local-only.
final playlistSyncTargetsProvider = Provider<List<PlaylistSyncTarget>>((ref) {
  final bool jellyfin = ref.watch(
    jellyfinSettingsControllerProvider.select((s) => s.isConnected),
  );
  final bool subsonic = ref.watch(
    subsonicSettingsControllerProvider.select((s) => s.isConnected),
  );
  return <PlaylistSyncTarget>[
    if (jellyfin) (source: PlaylistSource.jellyfin, label: 'Jellyfin'),
    if (subsonic) (source: PlaylistSource.subsonic, label: 'Navidrome'),
  ];
});

/// A single playlist by id, derived from [playlistsProvider] so it stays live as
/// the playlist is edited. `null` while loading or when the playlist is gone.
final playlistByIdProvider = Provider.family<Playlist?, String>((ref, id) {
  final List<Playlist> playlists =
      ref.watch(playlistsProvider).valueOrNull ?? const <Playlist>[];
  for (final Playlist playlist in playlists) {
    if (playlist.id == id) return playlist;
  }
  return null;
});

/// The resolved tracks of a playlist (in playlist order) plus a count of any
/// referenced tracks no longer present in the catalog, so the detail screen can
/// play what's available and surface missing ones honestly.
@immutable
class PlaylistTracks {
  const PlaylistTracks({required this.tracks, required this.missingCount});

  static const PlaylistTracks empty =
      PlaylistTracks(tracks: <Track>[], missingCount: 0);

  final List<Track> tracks;
  final int missingCount;
}

/// Resolves a playlist's stored track uris to catalog [Track]s, preserving order
/// and gracefully dropping (and counting) any that the catalog no longer has.
/// Re-runs whenever the playlist changes.
final playlistTracksProvider =
    FutureProvider.family.autoDispose<PlaylistTracks, String>((ref, id) async {
  final Playlist? playlist = ref.watch(playlistByIdProvider(id));
  if (playlist == null || playlist.trackIds.isEmpty) {
    return PlaylistTracks.empty;
  }
  final List<Track> all =
      await ref.watch(musicLibraryRepositoryProvider).getAllTracks();
  // Resolve by the provider-namespaced uri, so a `jellyfin:101` entry can never
  // resolve to a `subsonic:101` catalog track that merely shares the bare id.
  final Map<String, Track> byUri = <String, Track>{
    for (final Track track in all) track.uri: track,
  };
  final List<Track> resolved = <Track>[];
  int missing = 0;
  for (final String trackUri in playlist.trackIds) {
    final Track? track = byUri[trackUri];
    if (track != null) {
      resolved.add(track);
    } else {
      missing++;
    }
  }
  return PlaylistTracks(tracks: resolved, missingCount: missing);
});
