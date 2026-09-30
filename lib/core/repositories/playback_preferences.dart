/// The user's playback preferences.
///
/// Kept behind an interface (like [DownloadPreferences]) so the playback layer
/// can consult the user's choices without binding to a storage plugin.
///
///  - "Normalize volume": when on, playback applies a track's ReplayGain so
///    songs play at a more even loudness. Off by default — the safe choice, so
///    audio is never altered unless the listener opts in.
///  - The playback volume the desktop controls set, so a window that is closed
///    and reopened comes back at the level it was left at.
///  - "Audio output": which output device desktop playback is routed to. Unset
///    by default, which means the system default.
///  - "Automatically skip tracks that can't play": whether, once its recovery
///    for a track is spent, playback moves on to the next playable track after
///    a visible countdown instead of stopping. Unset until the listener
///    chooses, and unset behaves as off.
abstract interface class PlaybackPreferences {
  /// Whether volume normalization (ReplayGain) is applied during playback.
  /// Defaults to `false`, so audio plays untouched out of the box.
  Future<bool> normalizeVolume();

  Future<void> setNormalizeVolume(bool value);

  /// The listener's persisted playback volume, 0.0–1.0. Defaults to `1.0` (full
  /// volume) when nothing has been stored yet.
  ///
  /// Implementations sanitize what they read: a missing, out-of-range, or
  /// otherwise unusable stored value comes back as the default rather than
  /// reaching the audio engine.
  Future<double> volume();

  /// Stores [value] as the playback volume, sanitized to 0.0–1.0.
  Future<void> setVolume(double value);

  /// The backend id of the chosen audio output, or `null` for the system
  /// default.
  ///
  /// Only ids that survive a reboot are ever stored here (see
  /// `AudioOutputDevice.isPersistableId`); a device picked by an unstable
  /// handle stays a session-only choice, because remembering one would mean
  /// silently routing to whatever card took that index next boot.
  Future<String?> audioOutputDeviceId();

  /// Stores [id], or clears the preference when it is `null`.
  Future<void> setAudioOutputDeviceId(String? id);

  /// Whether the listener allows automatic skipping of tracks that can't play,
  /// or `null` while they haven't chosen.
  ///
  /// The difference between `null` and `false` is only whether to ask: both
  /// mean playback stops on a failed track. The question is asked once, the
  /// first time a track can't be recovered, and never again once answered.
  Future<bool?> autoSkipUnplayable();

  /// Records the listener's choice, which also stops the question being asked.
  Future<void> setAutoSkipUnplayable(bool value);
}
