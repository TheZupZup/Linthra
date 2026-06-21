import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/lyrics.dart';
import '../../core/models/track.dart';
import '../../core/services/jellyfin_lyrics_provider.dart';
import '../../core/services/local_lyrics_provider.dart';
import '../../core/services/lyrics_provider.dart';
import '../../core/services/lyrics_resolver.dart';
import '../../core/services/lyrics_service.dart';
import '../../core/services/plex_lyrics_provider.dart';
import '../../core/services/subsonic_lyrics_provider.dart';
import '../../core/sources/local/io_local_lyrics_reader.dart';
import '../../core/sources/local/local_lyrics_reader.dart';
import '../../core/sources/local/method_channel_saf_lyrics_reader.dart';
import '../settings/jellyfin/jellyfin_settings_controller.dart';
import '../settings/jellyfin/jellyfin_settings_providers.dart';
import '../settings/plex/plex_settings_controller.dart';
import '../settings/plex/plex_settings_providers.dart';
import '../settings/subsonic/subsonic_settings_controller.dart';
import '../settings/subsonic/subsonic_settings_providers.dart';
import 'player_providers.dart';

/// The lyrics backend the UI watches. Defaults to the empty [LyricsResolver]
/// (no providers registered → every track is the calm "no lyrics" state) so
/// tests and local-only use need no server wiring; the app overrides it with
/// the resolver wired to every shipped [LyricsProvider].
final lyricsServiceProvider = Provider<LyricsService>((ref) {
  return LyricsResolver.none;
});

/// Lyrics for a single track, keyed by the track itself (whose equality is its
/// provider-namespaced uri), fetched on demand and cached while watched — so two
/// same-bare-id copies from different providers (`jellyfin:101`, `subsonic:101`)
/// resolve independently. Auto-disposed so a track no longer current drops its
/// request.
final trackLyricsProvider =
    FutureProvider.autoDispose.family<Lyrics?, Track>((ref, track) {
  return ref.watch(lyricsServiceProvider).lyricsFor(track);
});

/// The track playing right now, distinct by uri. Selecting `currentTrack` (whose
/// equality is uri-based) means this changes only when the *track* changes — not
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
/// [trackLyricsProvider], by the track's provider-namespaced uri) and reports
/// loading during
/// the switch, so the previous song's lines never linger. Resolves to
/// `data(null)` when nothing is playing. The UI watches this and never calls a
/// lyrics provider directly.
final currentTrackLyricsProvider =
    Provider.autoDispose<AsyncValue<Lyrics?>>((ref) {
  final Track? track = ref.watch(_currentlyPlayingTrackProvider);
  if (track == null) {
    return const AsyncData<Lyrics?>(null);
  }
  return ref.watch(trackLyricsProvider(track));
});

/// The platform binding that reads a local track's sidecar lyrics file. Android
/// reads the sibling SAF document through the native content resolver (under the
/// folder's existing grant, no broad storage permission); elsewhere (desktop) it
/// reads the neighbouring file from the filesystem. Tests override
/// [lyricsServiceProvider] directly, so this is only exercised in a real app
/// build.
final localLyricsReaderProvider = Provider<LocalLyricsReader>((ref) {
  return Platform.isAndroid
      ? const MethodChannelSafLyricsReader()
      : const IoLocalLyricsReader();
});

/// Production binding: a [LyricsResolver] that routes each track, by the
/// source that owns its URI, to that source's [LyricsProvider] — a signed-in
/// Jellyfin, Subsonic/Navidrome, or Plex server, or the sidecar file next to a
/// local track. The live clients + sessions are read lazily so signing in/out
/// (connecting/disconnecting) is picked up without a rebuild; the local reader
/// is platform-bound via [localLyricsReaderProvider]. Applied in `main`; tests
/// keep the empty-resolver default.
final lyricsServiceOverride = lyricsServiceProvider.overrideWith((ref) {
  return LyricsResolver(<LyricsProvider>[
    JellyfinLyricsProvider(
      client: ref.read(jellyfinClientProvider),
      session: () =>
          ref.read(jellyfinSettingsControllerProvider.notifier).session,
    ),
    SubsonicLyricsProvider(
      client: ref.read(subsonicClientProvider),
      session: () =>
          ref.read(subsonicSettingsControllerProvider.notifier).session,
    ),
    PlexLyricsProvider(
      client: ref.read(plexClientProvider),
      session: () => ref.read(plexSettingsControllerProvider.notifier).session,
    ),
    LocalLyricsProvider(ref.read(localLyricsReaderProvider)),
  ]);
});
