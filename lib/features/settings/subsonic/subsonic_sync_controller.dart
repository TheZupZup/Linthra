import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/repositories/remote_sync_result.dart';
import '../../../core/sources/subsonic/subsonic_exception.dart';
import '../../../core/sources/subsonic/subsonic_music_source.dart';
import '../../../data/repositories/favorites_repository_provider.dart';
import '../../../data/repositories/music_library_repository_provider.dart';
import '../../../data/repositories/playlist_repository_provider.dart';
import '../../library/library_controller.dart';
import 'subsonic_settings_controller.dart';
import 'subsonic_sync_state.dart';

/// Drives the "Sync Navidrome library" action.
///
/// Reads the signed-in [SubsonicMusicSource] (via [subsonicMusicSourceProvider])
/// to fetch the catalog, then hands the results to the `MusicLibraryRepository`
/// under the stable `subsonic` source id — the same upsert path local scanning
/// and Jellyfin use. The Library screen reads from that repository, so a refresh
/// after the upsert makes the synced tracks appear. It then imports Navidrome
/// **playlists** and adopts server **favourites** best-effort (mirroring the
/// Jellyfin sync), so a failure there never aborts a successful track sync.
///
/// Security: the source mints any authenticated stream/download URL lazily at
/// use time, so nothing persisted here carries a credential. This controller
/// never logs the session, and surfaces only friendly, secret-free messages.
class SubsonicSyncController extends Notifier<SubsonicSyncState> {
  @override
  SubsonicSyncState build() => const SubsonicSyncState();

  /// Pulls artists/albums/tracks from the server and upserts them into the local
  /// catalog. Reflects loading/success/error through [state]; never throws.
  Future<void> sync() async {
    final SubsonicMusicSource? source = ref.read(subsonicMusicSourceProvider);
    if (source == null) {
      state = const SubsonicSyncState.error(
        'Connect to your Subsonic/Navidrome server in Settings before syncing.',
      );
      return;
    }

    state = const SubsonicSyncState.syncing();
    try {
      final tracks = await source.fetchTracks();
      final albums = await source.fetchAlbums();
      final artists = await source.fetchArtists();

      if (tracks.isEmpty) {
        // Still reconcile server playlists/favourites — the library may be
        // empty locally but the account can still have hearts/playlists.
        final PlaylistSyncResult playlists = await _refreshPlaylists();
        final FavoritesSyncResult favorites = await _refreshFavorites();
        state = SubsonicSyncState.success(
          trackCount: 0,
          playlistCount: playlists.playlistCount,
          favoriteCount: favorites.favoriteCount,
          playlistsFailed: playlists.didFail,
          favoritesFailed: favorites.didFail,
          message: _composeMessage(
            trackCount: 0,
            playlists: playlists,
            favorites: favorites,
            empty: true,
          ),
        );
        return;
      }

      await ref.read(musicLibraryRepositoryProvider).upsertCatalog(
            sourceId: source.id,
            tracks: tracks,
            albums: albums,
            artists: artists,
          );
      await ref.read(libraryControllerProvider.notifier).refresh();

      // Import Navidrome playlists and adopt server favourites best-effort; a
      // failure here is reported calmly but never fails the track sync.
      final PlaylistSyncResult playlists = await _refreshPlaylists();
      final FavoritesSyncResult favorites = await _refreshFavorites();

      state = SubsonicSyncState.success(
        trackCount: tracks.length,
        playlistCount: playlists.playlistCount,
        favoriteCount: favorites.favoriteCount,
        playlistsFailed: playlists.didFail,
        favoritesFailed: favorites.didFail,
        message: _composeMessage(
          trackCount: tracks.length,
          playlists: playlists,
          favorites: favorites,
        ),
      );
    } on SubsonicException catch (error) {
      state = SubsonicSyncState.error(_friendlyMessage(error));
    } catch (_) {
      state = const SubsonicSyncState.error(
        'Something went wrong saving your library. Please try again.',
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

  /// Builds the friendly success line from what actually synced (tracks,
  /// playlists, favourites) plus a calm note for any part that couldn't load, so
  /// a partial outcome reads clearly rather than as a scary failure. Every value
  /// is display-safe; no secret can reach here.
  String _composeMessage({
    required int trackCount,
    required PlaylistSyncResult playlists,
    required FavoritesSyncResult favorites,
    bool empty = false,
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

    final StringBuffer message = StringBuffer();
    if (synced.isEmpty) {
      message.write(empty
          ? 'Your library looks empty — nothing to sync yet.'
          : 'Synced your library.');
    } else {
      message.write('Synced ${_join(synced)}.');
    }
    if (failures.isNotEmpty) {
      message.write(' Some items could not be synced (${_join(failures)}).');
    }
    return message.toString();
  }

  /// Joins parts as "a", "a and b", or "a, b and c".
  static String _join(List<String> parts) {
    if (parts.length == 1) return parts.first;
    if (parts.length == 2) return '${parts[0]} and ${parts[1]}';
    return '${parts.sublist(0, parts.length - 1).join(', ')} '
        'and ${parts.last}';
  }

  /// Turns a typed Subsonic failure into a friendly, actionable line. Branches
  /// on [SubsonicErrorKind] rather than message text.
  String _friendlyMessage(SubsonicException error) {
    switch (error.kind) {
      case SubsonicErrorKind.notReachable:
        return "Couldn't reach your music server. Check your connection and "
            'that the server is online.';
      case SubsonicErrorKind.unauthorized:
        return 'Your session was rejected. Sign out and sign in again to '
            'refresh it.';
      case SubsonicErrorKind.notSubsonic:
        return "That server didn't respond like Subsonic. Double-check the "
            'server address in Settings.';
      case SubsonicErrorKind.serverError:
        return 'Your music server reported an error. Try again in a moment.';
      // The factory messages for these already carry specific, actionable
      // wording (which scheme to use, the certificate hint, …), so surface them.
      case SubsonicErrorKind.cleartextBlocked:
      case SubsonicErrorKind.insecureConnection:
      case SubsonicErrorKind.invalidUrl:
      case SubsonicErrorKind.streamUnavailable:
      case SubsonicErrorKind.unsupportedResponse:
      case SubsonicErrorKind.unexpected:
        return error.message;
    }
  }
}

final subsonicSyncControllerProvider =
    NotifierProvider<SubsonicSyncController, SubsonicSyncState>(
  SubsonicSyncController.new,
);
