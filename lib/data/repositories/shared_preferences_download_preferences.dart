import 'package:shared_preferences/shared_preferences.dart';

import '../../core/repositories/download_preferences.dart';

/// A [DownloadPreferences] backed by `shared_preferences`. The "Wi-Fi only"
/// switch is a single bool, so it lives next to the other small user choices in
/// the key/value store rather than in the SQLite catalog.
class SharedPreferencesDownloadPreferences implements DownloadPreferences {
  const SharedPreferencesDownloadPreferences();

  static const String _key = 'downloads_wifi_only';

  @override
  Future<bool> wifiOnly() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_key) ?? false;
  }

  @override
  Future<void> setWifiOnly(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_key, value);
  }
}
