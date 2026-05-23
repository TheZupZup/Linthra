import '../../core/repositories/download_preferences.dart';

/// A non-persistent [DownloadPreferences] for development and tests.
class InMemoryDownloadPreferences implements DownloadPreferences {
  InMemoryDownloadPreferences({bool wifiOnly = false}) : _wifiOnly = wifiOnly;

  bool _wifiOnly;

  @override
  Future<bool> wifiOnly() async => _wifiOnly;

  @override
  Future<void> setWifiOnly(bool value) async {
    _wifiOnly = value;
  }
}
