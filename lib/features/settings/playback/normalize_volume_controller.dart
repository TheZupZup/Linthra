import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/repositories/playback_preferences_provider.dart';

/// Owns the "Normalize volume" switch: loads the persisted value and writes
/// changes back through [PlaybackPreferences]. When on, playback applies each
/// track's ReplayGain so songs play at a more even loudness; off (the default)
/// leaves audio untouched.
class NormalizeVolumeController extends AsyncNotifier<bool> {
  @override
  Future<bool> build() {
    return ref.read(playbackPreferencesProvider).normalizeVolume();
  }

  Future<void> setEnabled(bool value) async {
    await ref.read(playbackPreferencesProvider).setNormalizeVolume(value);
    state = AsyncData<bool>(value);
  }
}

final normalizeVolumeControllerProvider =
    AsyncNotifierProvider<NormalizeVolumeController, bool>(
  NormalizeVolumeController.new,
);
