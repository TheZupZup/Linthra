import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/lyrics.dart';
import '../../core/models/track.dart';
import '../../core/services/composite_lyrics_service.dart';
import '../../core/services/jellyfin_lyrics_service.dart';
import '../../core/services/local_lyrics_service.dart';
import '../../core/services/lyrics_service.dart';
import '../../core/services/subsonic_lyrics_service.dart';
import '../../core/sources/local/io_local_lyrics_reader.dart';
import '../../core/sources/local/local_lyrics_reader.dart';
import '../../core/sources/local/method_channel_saf_lyrics_reader.dart';
import '../settings/jellyfin/jellyfin_settings_controller.dart';
import '../settings/jellyfin/jellyfin_settings_providers.dart';
import '../settings/subsonic/subsonic_settings_controller.dart';
import '../settings/subsonic/subsonic_settings_providers.dart';
import 'player_providers.dart';

/// The lyrics backend. Defaults to "no lyrics" so tests and local-only use need
/// no server wiring; the app overrides it with the remote-backed service that
/// reads from Jellyfin or Subsonic/Navidrome.
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

/// Production binding: read lyrics from whichever source owns the track — a
/// signed-in Jellyfin or Subsonic/Navidrome server, or a sidecar file next to a
/// local track. Each backend filters by the track's URI scheme (local claims
/// anything that isn't a remote scheme), so a track resolves through exactly one
/// of them (or none). The live clients + sessions are read lazily so signing
/// in/out is picked up without a rebuild; the local reader is platform-bound via
/// [localLyricsReaderProvider]. Applied in `main`; tests keep the no-lyrics
/// default.
final lyricsServiceOverride = lyricsServiceProvider.overrideWith((ref) {
  return CompositeLyricsService(<LyricsService>[
    JellyfinLyricsService(
      client: ref.read(jellyfinClientProvider),
      session: () =>
          ref.read(jellyfinSettingsControllerProvider.notifier).session,
    ),
    SubsonicLyricsService(
      client: ref.read(subsonicClientProvider),
      session: () =>
          ref.read(subsonicSettingsControllerProvider.notifier).session,
    ),
    LocalLyricsService(ref.read(localLyricsReaderProvider)),
  ]);
});

/// The honest local-only default: no lyrics source wired, so every track
/// resolves to "none" and the UI shows a calm placeholder.
class _NoLyricsService implements LyricsService {
  const _NoLyricsService();

  @override
  Future<Lyrics?> lyricsFor(Track track) async => null;
}
