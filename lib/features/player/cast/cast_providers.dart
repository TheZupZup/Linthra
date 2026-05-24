import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/cast_state.dart';
import '../../../core/services/cast/cast_media_resolver.dart';
import '../../../core/services/cast/cast_service.dart';
import '../../../core/services/cast/chromecast_cast_transport.dart';
import '../../../core/services/cast/default_cast_service.dart';
import '../../../core/services/cast/unavailable_cast_service.dart';
import '../../../core/sources/jellyfin/jellyfin_cast_media_resolver.dart';
import '../../settings/jellyfin/jellyfin_settings_controller.dart';
import '../player_providers.dart';

/// The single [CastService] the app drives casting through.
///
/// Defaults to [UnavailableCastService] so tests (and any platform without a
/// Chromecast stack) keep an honest, inert cast button. Production swaps in the
/// real backend via [chromecastCastServiceOverride]; the cast button and device
/// sheet are unchanged either way.
final castServiceProvider = Provider<CastService>((ref) {
  final service = UnavailableCastService();
  ref.onDispose(service.dispose);
  return service;
});

/// Streams [CastState] for the UI. Until the first event arrives, callers fall
/// back to the service's synchronous [CastService.state].
final castStateProvider = StreamProvider<CastState>((ref) {
  return ref.watch(castServiceProvider).stateStream;
});

/// Resolves the current track into a castable URL on demand at cast time.
/// Jellyfin tracks mint an authenticated stream URL (the receiver fetches it
/// directly); on-device files report [CastMediaResolver.canCast] false so the
/// service can show a clear limitation instead of failing.
final castMediaResolverProvider = Provider<CastMediaResolver>((ref) {
  return JellyfinCastMediaResolver(() => ref.read(jellyfinMusicSourceProvider));
});

/// Production binding: the real Chromecast backend, applied in `main`.
///
/// It wires [DefaultCastService] to the live [ChromecastCastTransport] and to
/// the playback controller — reading the current track, mirroring track
/// changes, and pausing/resuming local playback around a handoff. Only Android
/// and iOS get it; every other platform keeps the unavailable default so the
/// app never claims a cast ability the platform lacks. Tests don't apply this,
/// so they keep the inert default unless they override the service themselves.
final chromecastCastServiceOverride = castServiceProvider.overrideWith((ref) {
  final bool castable = defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;
  if (!castable) {
    final UnavailableCastService fallback = UnavailableCastService();
    ref.onDispose(fallback.dispose);
    return fallback;
  }

  final controller = ref.read(playbackControllerProvider);
  final service = DefaultCastService(
    transport: ChromecastCastTransport(),
    mediaResolver: ref.read(castMediaResolverProvider),
    currentTrack: () => controller.state.currentTrack,
    trackChanges: controller.stateStream.map((s) => s.currentTrack).distinct(),
    // Silence the local engine while the receiver plays, and resume it when
    // casting ends, so the device recovers where it left off.
    onCastingStarted: () => controller.pause(),
    onCastingStopped: () => controller.play(),
  );
  ref.onDispose(service.dispose);
  return service;
});
