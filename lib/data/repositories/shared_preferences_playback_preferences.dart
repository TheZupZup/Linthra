import 'package:shared_preferences/shared_preferences.dart';

import '../../core/models/playback_state.dart';
import '../../core/repositories/playback_preferences.dart';

/// A [PlaybackPreferences] backed by `shared_preferences`. The choices are a
/// small bool, a level, and a short device id, so they live next to the other
/// small user choices in the key/value store rather than in the SQLite catalog.
class SharedPreferencesPlaybackPreferences implements PlaybackPreferences {
  const SharedPreferencesPlaybackPreferences();

  static const String _normalizeVolumeKey = 'playback_normalize_volume';
  static const String _volumeKey = 'playback_volume';
  static const String _audioOutputDeviceKey = 'playback_audio_output_device';
  static const String _autoSkipUnplayableKey = 'playback_auto_skip_unplayable';

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

  @override
  Future<double> volume() async {
    final prefs = await SharedPreferences.getInstance();
    // Sanitized on the way out, not trusted: the store is a plain file a user
    // (or a future bug) can leave a 7.5, a -1, or a NaN in, and an unbounded
    // value must never reach the audio engine. Nothing stored means full
    // volume, the level the app has always played at.
    final double? stored = prefs.getDouble(_volumeKey);
    return stored == null ? 1.0 : PlaybackState.sanitizeVolume(stored);
  }

  @override
  Future<void> setVolume(double value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_volumeKey, PlaybackState.sanitizeVolume(value));
  }

  @override
  Future<String?> audioOutputDeviceId() async {
    final prefs = await SharedPreferences.getInstance();
    final String? stored = prefs.getString(_audioOutputDeviceKey);
    // An empty string is not a device; treat it as "system default" so a
    // half-written value can never route playback nowhere.
    return (stored == null || stored.isEmpty) ? null : stored;
  }

  @override
  Future<void> setAudioOutputDeviceId(String? id) async {
    final prefs = await SharedPreferences.getInstance();
    if (id == null || id.isEmpty) {
      await prefs.remove(_audioOutputDeviceKey);
      return;
    }
    await prefs.setString(_audioOutputDeviceKey, id);
  }

  @override
  Future<bool?> autoSkipUnplayable() async {
    final prefs = await SharedPreferences.getInstance();
    // Read as an Object so a value of the wrong type (a hand-edited or
    // half-written store) counts as "not chosen yet" rather than throwing.
    final Object? stored = prefs.get(_autoSkipUnplayableKey);
    return stored is bool ? stored : null;
  }

  @override
  Future<void> setAutoSkipUnplayable(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_autoSkipUnplayableKey, value);
  }
}
