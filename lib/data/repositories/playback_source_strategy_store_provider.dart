import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/repositories/playback_source_strategy_store.dart';
import 'in_memory_playback_source_strategy_store.dart';
import 'shared_preferences_playback_source_strategy_store.dart';

/// The single [PlaybackSourceStrategyStore] the app reads/writes the chosen
/// playback source strategy through.
///
/// Defaults to the in-memory implementation so widget and unit tests stay free
/// of platform plugins. The running app overrides this with
/// [sharedPreferencesPlaybackSourceStrategyStoreOverride] so the choice persists
/// across restarts.
final playbackSourceStrategyStoreProvider =
    Provider<PlaybackSourceStrategyStore>((ref) {
  return InMemoryPlaybackSourceStrategyStore();
});

/// Production binding: persists the chosen strategy via `shared_preferences`.
/// Applied in `main`.
final sharedPreferencesPlaybackSourceStrategyStoreOverride =
    playbackSourceStrategyStoreProvider.overrideWithValue(
  const SharedPreferencesPlaybackSourceStrategyStore(),
);
