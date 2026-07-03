import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/repositories/remote_sync_result.dart';
import '../../../core/repositories/subsonic_auto_sync_store.dart';
import '../../../core/sources/subsonic/subsonic_account_fingerprint.dart';
import '../../../core/sources/subsonic/subsonic_exception.dart';
import '../../../core/sources/subsonic/subsonic_music_source.dart';
import '../../../data/repositories/favorites_repository_provider.dart';
import '../../../data/repositories/music_library_repository_provider.dart';
import '../../../data/repositories/playlist_repository_provider.dart';
import '../../../data/repositories/subsonic_auto_sync_store_provider.dart';
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
/// Onboarding: a fresh Subsonic/Navidrome connection triggers [autoSyncIfNeeded]
/// once, so the library populates on its own without the user discovering the
/// manual "Sync Navidrome library" button. It runs the exact same path as the
/// manual [sync] and is gated by a persisted per-account fingerprint, so it
/// fires for a new server/account but not on a reconnect, a rebuild, a reopened
/// Settings screen, or an app restart of an already-synced account — mirroring
/// the Jellyfin onboarding. The manual [sync] is always available.
///
/// Security: the source mints any authenticated stream/download URL lazily at
/// use time, so nothing persisted here carries a credential. This controller
/// never logs the session, and surfaces only friendly, secret-free messages.
class SubsonicSyncController extends Notifier<SubsonicSyncState> {
  /// Guards against overlapping syncs (an auto-sync racing a manual tap). Set
  /// synchronously before any await so a second concurrent call simply bails,
  /// satisfying "never run two syncs at once" without cancelling the first.
  bool _syncing = false;

  @override
  SubsonicSyncState build() => const SubsonicSyncState();

  /// The manual "Sync Navidrome library" action. Pulls artists/albums/tracks and
  /// upserts them into the local catalog, then refreshes Navidrome playlists and
  /// favourites. Reflects loading/success/error through [state]; never throws.
  Future<void> sync() => _runSync();

  /// Runs the **first** automatic sync for a freshly connected server/account.
  ///
  /// Idempotent by account: if this exact server+user has already been
  /// auto-synced before, it does nothing — so a reconnect, a provider rebuild, a
  /// reopened Settings screen, or an app restart never re-pulls the whole
  /// library on its own. Changing the server URL or signing in as a different
  /// user is a new account, and syncs again. The manual [sync] stays available
  /// for an on-demand refresh. Never throws.
  Future<void> autoSyncIfNeeded() async {
    final SubsonicMusicSource? source = ref.read(subsonicMusicSourceProvider);
    if (source == null) {
      // Not connected (shouldn't happen right after a sign-in) — nothing to do.
      return;
    }
    final String fingerprint = subsonicAccountFingerprint(source.session);
    final SubsonicAutoSyncStore store = ref.read(subsonicAutoSyncStoreProvider);
    String? lastSynced;
    try {
      lastSynced = await store.read();
    } catch (_) {
      // A storage hiccup must never block onboarding; treat it as "not synced
      // yet" and let the sync proceed — re-running it is safe and idempotent.
      lastSynced = null;
    }
    if (lastSynced == fingerprint) {
      // This account's first sync already happened; don't resync on its own.
      return;
    }
    await _runSync(recordFingerprint: fingerprint);
  }

  /// The shared sync path behind both [sync] and [autoSyncIfNeeded].
  ///
  /// When [recordFingerprint] is non-null (an auto-sync), the account is
  /// remembered **only after a successful sync**, so a sync that failed (e.g.
  /// the server became unreachable right after sign-in) is retried
  /// automatically on the next fresh connection rather than being silently
  /// marked done — and the manual sync stays available meanwhile.
  Future<void> _runSync({String? recordFingerprint}) async {
    if (_syncing) {
      // A sync is already in flight; never stack a second concurrent one.
      return;
    }
    final SubsonicMusicSource? source = ref.read(subsonicMusicSourceProvider);
    if (source == null) {
      state = const SubsonicSyncState.error(
        'Connect to your Subsonic/Navidrome server in Settings before syncing.',
      );
      return;
    }

    _syncing = true;
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
        await _recordAutoSynced(recordFingerprint);
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
      await _recordAutoSynced(recordFingerprint);
    } on SubsonicException catch (error) {
      state = SubsonicSyncState.error(_friendlyMessage(error));
    } catch (_) {
      state = const SubsonicSyncState.error(
        'Something went wrong saving your library. Please try again.',
      );
    } finally {
      _syncing = false;
    }
  }

  /// Remembers a completed auto-sync's account [fingerprint], best-effort: a
  /// no-op for a manual sync (null), and a storage hiccup only means the next
  /// fresh connection re-runs the (idempotent) initial sync.
  Future<void> _recordAutoSynced(String? fingerprint) async {
    if (fingerprint == null) return;
    try {
      await ref.read(subsonicAutoSyncStoreProvider).write(fingerprint);
    } catch (_) {
      // Ignore: worst case the next connection auto-syncs again.
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
