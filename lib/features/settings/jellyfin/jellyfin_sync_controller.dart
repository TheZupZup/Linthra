import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/sources/jellyfin/jellyfin_exception.dart';
import '../../../core/sources/jellyfin/jellyfin_music_source.dart';
import '../../../data/repositories/music_library_repository_provider.dart';
import '../../library/library_controller.dart';
import 'jellyfin_settings_controller.dart';
import 'jellyfin_sync_state.dart';

/// Drives the "Sync Jellyfin library" action.
///
/// Reads the signed-in [JellyfinMusicSource] (via [jellyfinMusicSourceProvider])
/// to fetch the catalog, then hands the results to the
/// `MusicLibraryRepository` under the stable `jellyfin` source id — the same
/// upsert path local scanning uses. The Library screen reads from that
/// repository, so a refresh after the upsert makes the synced tracks appear.
///
/// Security: the source mints any authenticated streaming URL lazily at play
/// time, so nothing persisted here carries a token. This controller never logs
/// the session, and surfaces only friendly, secret-free messages through
/// [JellyfinSyncState].
class JellyfinSyncController extends Notifier<JellyfinSyncState> {
  @override
  JellyfinSyncState build() => const JellyfinSyncState();

  /// Pulls artists/albums/tracks from Jellyfin and upserts them into the local
  /// catalog. Reflects loading/success/error through [state]; never throws.
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

      if (tracks.isEmpty) {
        state = const JellyfinSyncState.success(
          trackCount: 0,
          message: 'Your Jellyfin library looks empty — nothing to sync yet.',
        );
        return;
      }

      await ref.read(musicLibraryRepositoryProvider).upsertCatalog(
            sourceId: source.id,
            tracks: tracks,
            albums: albums,
            artists: artists,
          );
      // Reload the Library so the freshly synced tracks show up immediately.
      await ref.read(libraryControllerProvider.notifier).refresh();

      state = JellyfinSyncState.success(
        trackCount: tracks.length,
        message: _successMessage(tracks.length),
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

  String _successMessage(int trackCount) {
    final String tracks = trackCount == 1 ? '1 track' : '$trackCount tracks';
    return 'Synced $tracks from your Jellyfin library.';
  }

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
      case JellyfinErrorKind.unexpected:
        return error.message;
    }
  }
}

final jellyfinSyncControllerProvider =
    NotifierProvider<JellyfinSyncController, JellyfinSyncState>(
  JellyfinSyncController.new,
);
