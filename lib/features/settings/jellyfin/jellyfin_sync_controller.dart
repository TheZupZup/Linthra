import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/repositories/remote_sync_result.dart';
import '../../../core/sources/jellyfin/jellyfin_exception.dart';
import '../../../core/sources/jellyfin/jellyfin_music_source.dart';
import '../../../data/repositories/favorites_repository_provider.dart';
import '../../../data/repositories/music_library_repository_provider.dart';
import '../../../data/repositories/playlist_repository_provider.dart';
import '../../library/library_controller.dart';
import 'jellyfin_settings_controller.dart';
import 'jellyfin_sync_state.dart';

/// Drives the "Sync Jellyfin library" action.
///
/// Reads the signed-in [JellyfinMusicSource] (via [jellyfinMusicSourceProvider])
/// to fetch the catalog, then hands the results to the
/// `MusicLibraryRepository` under the stable `jellyfin` source id — the same
/// upsert path local scanning uses. It then refreshes the user's Jellyfin
/// playlists and favourites/liked tracks, so a single "Sync library" brings the
/// whole account across (and picks up changes made on the server since last
/// time). The Library/Playlists/Favorites screens read from those repositories,
/// so a refresh after the sync makes everything appear.
///
/// Playlist and favourite refresh are best-effort: a failure in either is
/// reported in the status but never fails the track sync that already landed, so
/// a partial outcome reads honestly ("Tracks synced, but playlists could not be
/// loaded.").
///
/// Security: the source mints any authenticated streaming URL lazily at play
/// time, so nothing persisted here carries a token. This controller never logs
/// the session, and surfaces only friendly, secret-free messages through
/// [JellyfinSyncState].
class JellyfinSyncController extends Notifier<JellyfinSyncState> {
  @override
  JellyfinSyncState build() => const JellyfinSyncState();

  /// Pulls artists/albums/tracks from Jellyfin and upserts them into the local
  /// catalog, then refreshes Jellyfin playlists and favourites. Reflects
  /// loading/success/error through [state]; never throws.
  Future<void> sync() async {
    final JellyfinMusicSource? source = ref.read(jellyfinMusicSourceProvider);
    if (source == null) {
      state = const JellyfinSyncState.error(
        'Connect to your Jellyfin server in Settings before syncing.',
      );
      return;
    }

    state = const JellyfinSyncState.syncing();
    try {
      final tracks = await source.fetchTracks();
      final albums = await source.fetchAlbums();
      final artists = await source.fetchArtists();

      // Upsert only when there's something to store, so an empty fetch can
      // never wipe an existing catalog.
      if (tracks.isNotEmpty) {
        await ref.read(musicLibraryRepositoryProvider).upsertCatalog(
              sourceId: source.id,
              tracks: tracks,
              albums: albums,
              artists: artists,
            );
        // Reload the Library so the freshly synced tracks show up immediately.
        await ref.read(libraryControllerProvider.notifier).refresh();
      }

      // Pull playlists and favourites too — this is what makes a Jellyfin sync
      // bring across the user's playlists and liked tracks by default, and pick
      // up server-side changes. Both are best-effort and never throw out here.
      final PlaylistSyncResult playlists = await _refreshPlaylists();
      final FavoritesSyncResult favorites = await _refreshFavorites();

      state = JellyfinSyncState.success(
        trackCount: tracks.length,
        playlistCount: playlists.didSync ? playlists.playlistCount : 0,
        favoriteCount: favorites.didSync ? favorites.favoriteCount : 0,
        playlistsFailed: playlists.didFail,
        favoritesFailed: favorites.didFail,
        message: _composeMessage(
          trackCount: tracks.length,
          playlists: playlists,
          favorites: favorites,
        ),
      );
    } on JellyfinException catch (error) {
      state = JellyfinSyncState.error(_friendlyMessage(error));
    } catch (_) {
      // A non-Jellyfin failure (e.g. the local store): keep it generic and
      // secret-free rather than dumping a raw error.
      state = const JellyfinSyncState.error(
        "Something went wrong saving your Jellyfin library. Please try again.",
      );
    }
  }

  /// Best-effort playlist refresh that never throws out of [sync]: a thrown
  /// error (rather than the repository's own friendly result) is mapped to a
  /// failed outcome so a single bad call can't abort a successful track sync.
  Future<PlaylistSyncResult> _refreshPlaylists() async {
    try {
      return await ref.read(playlistRepositoryProvider).refreshFromRemote();
    } catch (_) {
      return const PlaylistSyncResult.failed();
    }
  }

  /// Best-effort favourites refresh, mirroring [_refreshPlaylists].
  Future<FavoritesSyncResult> _refreshFavorites() async {
    try {
      return await ref.read(favoritesRepositoryProvider).refreshFromRemote();
    } catch (_) {
      return const FavoritesSyncResult.failed();
    }
  }

  /// Builds the friendly success line from what actually synced: tracks,
  /// playlists, and favourites that came across, plus an honest note for any
  /// part that couldn't load — so a partial failure reads clearly. All values
  /// are display-safe; no secret can reach here.
  String _composeMessage({
    required int trackCount,
    required PlaylistSyncResult playlists,
    required FavoritesSyncResult favorites,
  }) {
    final List<String> synced = <String>[];
    if (trackCount > 0) {
      synced.add(trackCount == 1 ? '1 track' : '$trackCount tracks');
    }
    if (playlists.didSync && playlists.playlistCount > 0) {
      final int n = playlists.playlistCount;
      synced.add(n == 1 ? '1 playlist' : '$n playlists');
    }
    if (favorites.didSync && favorites.favoriteCount > 0) {
      final int n = favorites.favoriteCount;
      synced.add(n == 1 ? '1 favorite' : '$n favorites');
    }

    final List<String> failures = <String>[];
    if (playlists.didFail) failures.add('playlists could not be loaded');
    if (favorites.didFail) failures.add('favorites could not be synced');

    if (synced.isEmpty && failures.isEmpty) {
      return 'Your Jellyfin library looks empty — nothing to sync yet.';
    }

    final StringBuffer message = StringBuffer();
    if (synced.isNotEmpty) {
      message.write('Synced ${_joinAnd(synced)} from your Jellyfin library.');
    }
    if (failures.isNotEmpty) {
      if (message.isNotEmpty) message.write(' ');
      message.write('${_capitalize(_joinAnd(failures))}.');
    }
    return message.toString();
  }

  /// Joins parts with commas and a trailing "and": `["a"]` → "a";
  /// `["a", "b"]` → "a and b"; `["a", "b", "c"]` → "a, b and c".
  String _joinAnd(List<String> parts) {
    if (parts.length == 1) return parts.first;
    if (parts.length == 2) return '${parts[0]} and ${parts[1]}';
    final String head = parts.sublist(0, parts.length - 1).join(', ');
    return '$head and ${parts.last}';
  }

  String _capitalize(String text) =>
      text.isEmpty ? text : '${text[0].toUpperCase()}${text.substring(1)}';

  /// Turns a typed Jellyfin failure into a friendly, actionable line. Branches
  /// on [JellyfinErrorKind] rather than message text so the wording can change
  /// without breaking this mapping.
  String _friendlyMessage(JellyfinException error) {
    switch (error.kind) {
      case JellyfinErrorKind.notReachable:
        return "Couldn't reach your Jellyfin server. Check your connection and "
            'that the server is online.';
      case JellyfinErrorKind.unauthorized:
        return 'Your Jellyfin session has expired. Sign out and sign in again '
            'to refresh it.';
      case JellyfinErrorKind.notJellyfin:
      case JellyfinErrorKind.webPage:
        return "That server didn't respond like Jellyfin. Double-check the "
            'server address in Settings.';
      case JellyfinErrorKind.serverError:
        return 'Your Jellyfin server reported an error. Try again in a moment.';
      case JellyfinErrorKind.invalidUrl:
      case JellyfinErrorKind.notAudioStream:
      case JellyfinErrorKind.streamUnavailable:
      case JellyfinErrorKind.unsupportedResponse:
      case JellyfinErrorKind.unexpected:
        return error.message;
    }
  }
}

final jellyfinSyncControllerProvider =
    NotifierProvider<JellyfinSyncController, JellyfinSyncState>(
  JellyfinSyncController.new,
);
