import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/services/cast/cast_receiver_pinning.dart';
import 'shared_preferences_cast_receiver_pin_store.dart';

/// The single [CastReceiverPinStore] the app remembers cast receivers through.
///
/// Defaults to [InMemoryCastReceiverPinStore] so widget and unit tests stay free
/// of platform plugins, and so that a missing override shortens how long the app
/// remembers rather than turning pinning off. The running app overrides this
/// with [sharedPreferencesCastReceiverPinStoreOverride].
///
/// Two callers, one of which does not exist yet. The cast sheet reads it to
/// offer "forget this device", the recovery
/// [CastTrustFailureKind.changedReceiver] points the user at. The reviewed
/// restoration ([#575](https://github.com/TheZupZup/Linthra/issues/575)) hands
/// it to [TrustGatedCastTransport], which is where it becomes a security
/// boundary rather than a preference (see docs/cast-hardened-design.md).
final castReceiverPinStoreProvider = Provider<CastReceiverPinStore>((ref) {
  return InMemoryCastReceiverPinStore();
});

/// Production binding: pins survive a restart. Applied in
/// [productionApplicationOverrides].
final sharedPreferencesCastReceiverPinStoreOverride =
    castReceiverPinStoreProvider.overrideWithValue(
  const SharedPreferencesCastReceiverPinStore(),
);
