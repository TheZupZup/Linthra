import '../../core/repositories/playback_preferences.dart';

/// A non-persistent [PlaybackPreferences] for development and tests.
class InMemoryPlaybackPreferences implements PlaybackPreferences {
  InMemoryPlaybackPreferences({bool normalizeVolume = false})
      : _normalizeVolume = normalizeVolume;

  bool _normalizeVolume;

  @override
  Future<bool> normalizeVolume() async => _normalizeVolume;

  @override
  Future<void> setNormalizeVolume(bool value) async {
    _normalizeVolume = value;
  }
}
