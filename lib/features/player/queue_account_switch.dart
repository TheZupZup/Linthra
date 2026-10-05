import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/track.dart';
import '../../core/sources/music_provider.dart';
import 'player_providers.dart';

/// Takes every one of [provider]'s songs out of the play queue.
typedef RemoveProviderSongsFromQueue = Future<void> Function(
  MusicProvider provider,
);

/// Run when a remote provider's songs stop being the signed-in account's (or,
/// for Plex, the connected server's): another account's library was cleared
/// for the one signing in, or Plex let its server go (#767).
///
/// A song id only means something on its own server, and the play queue holds
/// ids. Left in it, `subsonic:101` from server A plays server B's song 101
/// under A's title, and its scrobble, favourite, cover and lyrics go to B as
/// well. So the queue follows the library: when the library's songs go, the
/// queue's go with them, the one playing included.
final removeProviderSongsFromQueueProvider =
    Provider<RemoveProviderSongsFromQueue>((ref) {
  return (MusicProvider provider) async {
    // The queue lives in the local engine (the cast routing in front of it
    // only mirrors it). With no engine built yet there is no queue.
    if (!ref.exists(localPlaybackControllerProvider)) return;
    await ref.read(localPlaybackControllerProvider).removeTracksWhere(
          (Track track) =>
              identical(MusicProviders.forTrackUri(track.uri), provider),
        );
  };
});
