import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/album.dart';
import '../../../core/models/artist.dart';
import '../../../core/models/track.dart';
import '../../../core/sources/plex/plex_exception.dart';
import '../../../core/sources/plex/plex_music_source.dart';
import '../../../data/repositories/music_library_repository_provider.dart';
import '../../library/library_controller.dart';
import 'plex_settings_controller.dart';
import 'plex_sync_state.dart';

/// Drives the "Sync Plex library" action.
///
/// Reads the signed-in [PlexMusicSource] (via [plexMusicSourceProvider]) to
/// fetch the catalog, then hands the results to the `MusicLibraryRepository`
/// under the stable `plex` source id — the same upsert path local scanning,
/// Jellyfin, and Subsonic use. The Library screen reads from that repository,
/// so a refresh after the upsert makes the synced tracks appear.
///
/// Unlike Jellyfin/Subsonic (which sync the whole server), the Plex library is
/// **scoped by the user's selected music sections**, so the catalog must
/// mirror the selection: a sync against an empty result (or an empty
/// selection) **replaces** the stored Plex rows rather than skipping the
/// write, so deselecting a library actually removes its tracks on the next
/// sync instead of leaving stale, unplayable rows behind.
///
/// The settings controller kicks [syncAfterSelectionChange] after every
/// committed selection change, so picking a library populates the Library
/// screen on its own — mirroring how Jellyfin auto-syncs a fresh connection.
/// Rapid checkbox toggles coalesce: changes that land while a sync is running
/// mark it dirty and the finished sync re-runs once against the newest
/// selection, instead of queueing one full library walk per tap.
///
/// Security: the source mints any authenticated stream URL lazily at play
/// time, so nothing persisted here carries a credential. This controller
/// never logs the session, and surfaces only friendly, secret-free messages
/// through [PlexSyncState].
class PlexSyncController extends Notifier<PlexSyncState> {
  /// Guards against overlapping syncs (an auto-sync racing a manual tap). Set
  /// synchronously before any await so a second concurrent call simply bails,
  /// satisfying "never run two syncs at once" without cancelling the first.
  bool _syncing = false;

  /// Set when a selection change lands while a sync is already running, so
  /// the in-flight sync re-runs once when it finishes — the catalog must end
  /// on the newest selection, not the one the first walk started with.
  bool _selectionChangedDuringSync = false;

  @override
  PlexSyncState build() => const PlexSyncState();

  /// The manual "Sync Plex library" action. Pulls artists/albums/tracks from
  /// the selected sections and replaces the Plex slice of the local catalog.
  /// Reflects loading/success/error through [state]; never throws.
  Future<void> sync() => _runSync();

  /// Keeps the catalog in step after a library-selection change. Coalesces:
  /// if a sync is already running it only marks it dirty (one re-run at the
  /// end), so toggling several checkboxes doesn't stack full library walks.
  Future<void> syncAfterSelectionChange() {
    if (_syncing) {
      _selectionChangedDuringSync = true;
      return Future<void>.value();
    }
    return _runSync();
  }

  /// Removes every synced Plex row from the local catalog and refreshes the
  /// Library screen. Used on disconnect (the rows are unplayable without a
  /// session — phase 1 has no offline cache) and when connecting to a
  /// different server (the old rows' ratingKeys belong to another machine).
  ///
  /// Quiet by design: it reports nothing through [state] — the caller owns
  /// the user-facing message — but throws on a storage failure so the caller
  /// can phrase that message honestly.
  Future<void> removeSyncedCatalog() =>
      _replacePlexCatalog(tracks: const <Track>[]);

  Future<void> _runSync() async {
    if (_syncing) return;
    _syncing = true;
    try {
      do {
        _selectionChangedDuringSync = false;
        await _syncOnce();
      } while (_selectionChangedDuringSync);
    } finally {
      _syncing = false;
    }
  }

  Future<void> _syncOnce() async {
    final PlexMusicSource? source = ref.read(plexMusicSourceProvider);
    if (source == null) {
      state = const PlexSyncState.error(
        'Connect to your Plex server in Settings before syncing.',
      );
      return;
    }

    if (source.session.selectedSectionKeys.isEmpty) {
      // No selection means an empty Plex library by definition, so prune any
      // rows a previous selection synced — without touching the server.
      try {
        await _replacePlexCatalog(tracks: const <Track>[]);
      } catch (_) {
        state = const PlexSyncState.error(_savingFailedMessage);
        return;
      }
      state = const PlexSyncState.success(
        trackCount: 0,
        message: 'No music libraries are selected — choose at least one '
            'above to sync its music.',
      );
      return;
    }

    state = const PlexSyncState.syncing();
    try {
      final List<Track> tracks = await source.fetchTracks();
      final List<Album> albums = await source.fetchAlbums();
      final List<Artist> artists = await source.fetchArtists();

      // Replace even when empty: the result *is* the selected libraries'
      // honest content, and skipping the write would leave rows from a
      // previously wider selection lingering as unplayable entries.
      await _replacePlexCatalog(
          tracks: tracks, albums: albums, artists: artists);

      state = tracks.isEmpty
          ? const PlexSyncState.success(
              trackCount: 0,
              message: 'Your selected libraries have no tracks yet — '
                  'nothing to sync.',
            )
          : PlexSyncState.success(
              trackCount: tracks.length,
              message: _successMessage(tracks.length),
            );
    } on PlexException catch (error) {
      state = PlexSyncState.error(_friendlyMessage(error));
    } catch (_) {
      state = const PlexSyncState.error(_savingFailedMessage);
    }
  }

  /// Replaces the Plex slice of the catalog and refreshes the Library screen
  /// so the change is visible immediately. Other sources' rows are untouched
  /// (the repository replaces per `sourceId`).
  Future<void> _replacePlexCatalog({
    required List<Track> tracks,
    List<Album> albums = const <Album>[],
    List<Artist> artists = const <Artist>[],
  }) async {
    await ref.read(musicLibraryRepositoryProvider).upsertCatalog(
          sourceId: PlexMusicSource.sourceId,
          tracks: tracks,
          albums: albums,
          artists: artists,
        );
    await ref.read(libraryControllerProvider.notifier).refresh();
  }

  static const String _savingFailedMessage =
      'Something went wrong saving your Plex library. Please try again.';

  String _successMessage(int trackCount) {
    final String tracks = trackCount == 1 ? '1 track' : '$trackCount tracks';
    return 'Synced $tracks from your Plex libraries.';
  }

  /// Turns a typed Plex failure into a friendly, actionable line. Branches on
  /// [PlexErrorKind] rather than message text, and never carries the token —
  /// every string here is static.
  String _friendlyMessage(PlexException error) {
    switch (error.kind) {
      case PlexErrorKind.notReachable:
        return "Couldn't reach your Plex server. Check your connection and "
            'that the server is online.';
      case PlexErrorKind.unauthorized:
        return 'Your Plex session was rejected by the server. Disconnect and '
            'connect again with a new token.';
      case PlexErrorKind.notPlex:
        return "That server didn't respond like a Plex Media Server. "
            'Double-check the server address in Settings.';
      case PlexErrorKind.serverError:
        return 'Your Plex server reported an error. Try again in a moment.';
      case PlexErrorKind.notFound:
        return "A selected library wasn't found on your Plex server. Refresh "
            'your music libraries in Settings, then sync again.';
      // The factory messages for these already carry specific, actionable,
      // token-free wording (which port Plex listens on, the unsupported-
      // version hint, …), so surface them as-is.
      case PlexErrorKind.invalidUrl:
      case PlexErrorKind.unsupportedResponse:
      case PlexErrorKind.unexpected:
        return error.message;
    }
  }
}

final plexSyncControllerProvider =
    NotifierProvider<PlexSyncController, PlexSyncState>(
  PlexSyncController.new,
);
