import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/sources/subsonic/subsonic_exception.dart';
import '../../../core/sources/subsonic/subsonic_music_source.dart';
import '../../../data/repositories/music_library_repository_provider.dart';
import '../../library/library_controller.dart';
import 'subsonic_settings_controller.dart';
import 'subsonic_sync_state.dart';

/// Drives the "Sync Navidrome library" action.
///
/// Reads the signed-in [SubsonicMusicSource] (via [subsonicMusicSourceProvider])
/// to fetch the catalog, then hands the results to the `MusicLibraryRepository`
/// under the stable `subsonic` source id — the same upsert path local scanning
/// and Jellyfin use. The Library screen reads from that repository, so a refresh
/// after the upsert makes the synced tracks appear.
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
        state = const SubsonicSyncState.success(
          trackCount: 0,
          message: 'Your library looks empty — nothing to sync yet.',
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

      state = SubsonicSyncState.success(
        trackCount: tracks.length,
        message: _successMessage(tracks.length),
      );
    } on SubsonicException catch (error) {
      state = SubsonicSyncState.error(_friendlyMessage(error));
    } catch (_) {
      state = const SubsonicSyncState.error(
        'Something went wrong saving your library. Please try again.',
      );
    }
  }

  String _successMessage(int trackCount) {
    final String tracks = trackCount == 1 ? '1 track' : '$trackCount tracks';
    return 'Synced $tracks from your library.';
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
