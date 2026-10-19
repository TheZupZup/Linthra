import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/repositories/playback_preferences_provider.dart';

/// Owns the "Show audio quality" switch: loads the persisted value and writes
/// changes back through `PlaybackPreferences`. Off (the default) means Now
/// Playing never asks the engine anything.
class ShowAudioQualityController extends AsyncNotifier<bool> {
  @override
  Future<bool> build() {
    return ref.read(playbackPreferencesProvider).showAudioQuality();
  }

  Future<void> setEnabled(bool value) async {
    await ref.read(playbackPreferencesProvider).setShowAudioQuality(value);
    state = AsyncData<bool>(value);
  }
}

final showAudioQualityControllerProvider =
    AsyncNotifierProvider<ShowAudioQualityController, bool>(
  ShowAudioQualityController.new,
);
