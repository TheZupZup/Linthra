import 'package:shared_preferences/shared_preferences.dart';

import '../../core/repositories/playback_preferences.dart';

/// A [PlaybackPreferences] backed by `shared_preferences`. The single choice is
/// a small bool, so it lives next to the other small user choices in the
/// key/value store rather than in the SQLite catalog.
class SharedPreferencesPlaybackPreferences implements PlaybackPreferences {
  const SharedPreferencesPlaybackPreferences();

  static const String _normalizeVolumeKey = 'playback_normalize_volume';

  @override
  Future<bool> normalizeVolume() async {
    final prefs = await SharedPreferences.getInstance();
    // Default false: never alter audio unless the listener opts in.
    return prefs.getBool(_normalizeVolumeKey) ?? false;
  }

  @override
  Future<void> setNormalizeVolume(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_normalizeVolumeKey, value);
  }
}
