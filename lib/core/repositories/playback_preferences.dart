/// The user's playback preferences.
///
/// Kept behind an interface (like [DownloadPreferences]) so the playback layer
/// can consult the user's choices without binding to a storage plugin.
///
///  - "Normalize volume": when on, playback applies a track's ReplayGain so
///    songs play at a more even loudness. Off by default — the safe choice, so
///    audio is never altered unless the listener opts in.
abstract interface class PlaybackPreferences {
  /// Whether volume normalization (ReplayGain) is applied during playback.
  /// Defaults to `false`, so audio plays untouched out of the box.
  Future<bool> normalizeVolume();

  Future<void> setNormalizeVolume(bool value);
}
