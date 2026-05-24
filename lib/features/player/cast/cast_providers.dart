import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/cast_state.dart';
import '../../../core/services/cast/cast_service.dart';
import '../../../core/services/cast/unavailable_cast_service.dart';

/// The single [CastService] the app drives casting through.
///
/// Defaults to [UnavailableCastService] — casting is a UI + architecture
/// foundation in this build, not a live backend. A real Chromecast/Cast SDK
/// implementation slots in by overriding only this provider; the cast button
/// and device sheet are unchanged. Disposed with the provider scope so any
/// future backend releases its resources on shutdown.
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
