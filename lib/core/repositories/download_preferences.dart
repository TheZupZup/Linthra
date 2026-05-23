/// The user's download preferences.
///
/// Right now this is just the "Wi-Fi only" switch, kept behind an interface so
/// the [DownloadRepository] can consult it without binding to a storage plugin.
/// When set, downloads that would run over mobile data are queued instead of
/// started — the policy lives in the repository, this only remembers the choice.
abstract interface class DownloadPreferences {
  /// Whether downloads should only run on Wi-Fi. Defaults to `false`.
  Future<bool> wifiOnly();

  Future<void> setWifiOnly(bool value);
}
