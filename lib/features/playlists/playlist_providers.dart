import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/playlist.dart';
import '../../core/models/track.dart';
import '../../data/repositories/music_library_repository_provider.dart';
import '../../data/repositories/playlist_repository_provider.dart';

/// Streams the user's playlists for the UI; emits on every change.
final playlistsProvider = StreamProvider<List<Playlist>>((ref) {
  return ref.watch(playlistRepositoryProvider).playlistsStream;
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

/// Resolves a playlist's stored track ids to catalog [Track]s, preserving order
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
  final Map<String, Track> byId = <String, Track>{
    for (final Track track in all) track.id: track,
  };
  final List<Track> resolved = <Track>[];
  int missing = 0;
  for (final String trackId in playlist.trackIds) {
    final Track? track = byId[trackId];
    if (track != null) {
      resolved.add(track);
    } else {
      missing++;
    }
  }
  return PlaylistTracks(tracks: resolved, missingCount: missing);
});
