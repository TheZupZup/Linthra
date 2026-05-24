import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/lyrics.dart';
import '../../core/models/track.dart';
import '../../core/services/jellyfin_lyrics_service.dart';
import '../../core/services/lyrics_service.dart';
import '../settings/jellyfin/jellyfin_settings_controller.dart';
import '../settings/jellyfin/jellyfin_settings_providers.dart';
import 'player_providers.dart';

/// The lyrics backend. Defaults to "no lyrics" so tests and local-only use need
/// no Jellyfin wiring; the app overrides it with the Jellyfin-backed service.
final lyricsServiceProvider = Provider<LyricsService>((ref) {
  return const _NoLyricsService();
});

/// Lyrics for a single track, keyed by the track itself (whose equality is its
/// stable id), fetched on demand and cached while watched. Auto-disposed so a
/// track that is no longer current drops its request.
final trackLyricsProvider =
    FutureProvider.autoDispose.family<Lyrics?, Track>((ref, track) {
  return ref.watch(lyricsServiceProvider).lyricsFor(track);
});

/// The track playing right now, distinct by id. Selecting `currentTrack` (whose
/// equality is id-based) means this changes only when the *track* changes — not
/// on every position tick — so lyrics aren't refetched every second. Falls back
/// to the controller's latest state until the first stream event arrives, so
/// opening lyrics mid-playback resolves immediately (mirroring the player UI).
final _currentlyPlayingTrackProvider = Provider.autoDispose<Track?>((ref) {
  final controller = ref.watch(playbackControllerProvider);
  final Track? streamed = ref.watch(
    playbackStateProvider.select((state) => state.valueOrNull?.currentTrack),
  );
  return streamed ?? controller.state.currentTrack;
});

/// Lyrics for whatever is playing now — the seam the Now Playing lyrics view
/// watches. It re-resolves whenever the current track changes (keyed, through
/// [trackLyricsProvider], by the track's stable id) and reports loading during
/// the switch, so the previous song's lines never linger. Resolves to
/// `data(null)` when nothing is playing. The UI watches this and never calls a
/// lyrics service directly.
final currentTrackLyricsProvider =
    Provider.autoDispose<AsyncValue<Lyrics?>>((ref) {
  final Track? track = ref.watch(_currentlyPlayingTrackProvider);
  if (track == null) {
    return const AsyncData<Lyrics?>(null);
  }
  return ref.watch(trackLyricsProvider(track));
});

/// Production binding: read lyrics from the signed-in Jellyfin server. Reads the
/// live client + session lazily so signing in/out is picked up without a
/// rebuild. Applied in `main`; tests keep the no-lyrics default.
final jellyfinLyricsOverride = lyricsServiceProvider.overrideWith((ref) {
  return JellyfinLyricsService(
    client: ref.read(jellyfinClientProvider),
    session: () =>
        ref.read(jellyfinSettingsControllerProvider.notifier).session,
  );
});

/// The honest local-only default: no lyrics source wired, so every track
/// resolves to "none" and the UI shows a calm placeholder.
class _NoLyricsService implements LyricsService {
  const _NoLyricsService();

  @override
  Future<Lyrics?> lyricsFor(Track track) async => null;
}
