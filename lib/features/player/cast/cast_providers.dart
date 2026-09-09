import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/lifecycle/async_disposal_registry.dart';
import '../../../core/models/cast_state.dart';
import '../../../core/services/cast/cast_containment.dart';
import '../../../core/services/cast/cast_media_resolver.dart';
import '../../../core/services/cast/cast_receiver_pinning.dart';
import '../../../core/services/cast/cast_service.dart';
import '../../../core/services/cast/routing_cast_media_resolver.dart';
import '../../../core/services/cast/unavailable_cast_service.dart';
import '../../../core/sources/jellyfin/jellyfin_cast_media_resolver.dart';
import '../../../core/sources/subsonic/subsonic_cast_media_resolver.dart';
import '../../../data/repositories/cast_receiver_pin_store_provider.dart';
import '../../settings/jellyfin/jellyfin_settings_controller.dart';
import '../../settings/subsonic/subsonic_settings_controller.dart';

/// The single [CastService] the app drives casting through.
///
/// Defaults to [UnavailableCastService] so tests (and any platform without a
/// cast backend) keep an honest, inert cast button. A service test that needs
/// live behaviour overrides this provider with its own fake; production applies
/// [containedCastServiceOverride].
final castServiceProvider = Provider<CastService>((ref) {
  final service = UnavailableCastService();
  ref.onDisposeAsync(service.dispose);
  return service;
});

/// Streams [CastState] for the UI. Until the first event arrives, callers fall
/// back to the service's synchronous [CastService.state].
final castStateProvider = StreamProvider<CastState>((ref) {
  return ref.watch(castServiceProvider).stateStream;
});

/// Resolves the current track into a castable URL on demand at cast time.
/// Jellyfin and Subsonic tracks each mint an authenticated stream URL (the
/// receiver fetches it directly); on-device files report
/// [CastMediaResolver.canCast] false so the service can show a clear limitation
/// instead of failing. Composed so multiple remote sources cast through one
/// resolver.
///
/// Unused by production while [CastContainment.isActive] — nothing resolves a
/// stream URL for a receiver when no session can be opened. It stays wired and
/// tested because [#576](https://github.com/TheZupZup/Linthra/issues/576) builds
/// on it, rather than rebuilding it afterwards.
final castMediaResolverProvider = Provider<CastMediaResolver>((ref) {
  return RoutingCastMediaResolver(<CastMediaResolver>[
    JellyfinCastMediaResolver(() => ref.read(jellyfinMusicSourceProvider)),
    SubsonicCastMediaResolver(() => ref.read(subsonicMusicSourceProvider)),
  ]);
});

/// Production binding: the security containment ([CastContainment]).
///
/// Every platform gets [UnavailableCastService], so shipped builds construct no
/// cast transport and open no receiver socket. This *is* the production path:
/// there is no branch here that builds a live backend, and no flag that selects
/// one, because a second production path is exactly what containment cannot
/// have. The cast button and device sheet are unchanged; they read the message
/// and say casting is temporarily off.
///
/// Restoring casting is a separate reviewed change, tracked in
/// [#575](https://github.com/TheZupZup/Linthra/issues/575). Until then the
/// transport and the media handoff refuse independently of this provider, so
/// reverting this alone still cannot reach a receiver.
final containedCastServiceOverride = castServiceProvider.overrideWith((ref) {
  final service = UnavailableCastService(
    message: CastContainment.isActive ? CastContainment.userMessage : null,
  );
  ref.onDisposeAsync(service.dispose);
  return service;
});

/// Whether Linthra already remembers which receiver a cast device is, so the
/// sheet only offers "forget this device" where there is something to forget.
///
/// Auto-disposing and per-device: the sheet is opened, used and closed, and a
/// pin read on one visit says nothing about the next. Invalidate it after a
/// [CastReceiverPinStore.forget] so the row stops offering an action that has
/// already been taken.
///
/// A store that throws answers *true* here. This provider decides whether a
/// menu item is drawn, not whether a receiver is trusted. That is
/// [TrustGatedCastTransport]'s job, and it refuses on the same throw. Hiding
/// the recovery because the store is unhappy would strand a user whose only way
/// forward is to clear a pin, and forgetting a device that has none does
/// nothing.
final castDeviceIsPinnedProvider = FutureProvider.autoDispose
    .family<bool, String>((ref, String deviceId) async {
  final CastReceiverPinStore store = ref.watch(castReceiverPinStoreProvider);
  try {
    return await store.pinFor(deviceId) != null;
  } catch (_) {
    return true;
  }
});
