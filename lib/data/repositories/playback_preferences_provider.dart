import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/repositories/playback_preferences.dart';
import 'in_memory_playback_preferences.dart';
import 'shared_preferences_playback_preferences.dart';

/// The user's playback preferences (currently "Normalize volume"). In-memory by
/// default so tests and dev runs need no plugins; the app persists them via
/// `shared_preferences` through [sharedPreferencesPlaybackPreferencesOverride].
final playbackPreferencesProvider = Provider<PlaybackPreferences>((ref) {
  return InMemoryPlaybackPreferences();
});

final sharedPreferencesPlaybackPreferencesOverride =
    playbackPreferencesProvider.overrideWithValue(
  const SharedPreferencesPlaybackPreferences(),
);
