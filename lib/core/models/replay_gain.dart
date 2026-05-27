import 'dart:math' as math;

/// Which ReplayGain reference to normalize against.
///
///  - [track]: each track is leveled independently. Best for shuffle/mixed
///    playback so every song lands near the same loudness.
///  - [album]: the album's single gain is applied to every track, preserving the
///    intended loudness *relationship* between tracks on the album.
enum ReplayGainMode { track, album }

/// ReplayGain loudness metadata for a track, as written by taggers/servers.
///
/// Gains are in **decibels** relative to the ReplayGain reference loudness
/// (positive means "turn up", negative means "turn down"). Peaks are the
/// track/album's maximum sample amplitude as a **linear** value where `1.0` is
/// full scale; a peak above `1.0` means the master already clips.
///
/// This is a pure value type — it carries the numbers but does not itself touch
/// the audio engine. [linearVolume] turns it into the safe multiplier the
/// playback layer applies. Everything is nullable because real-world files often
/// carry only some of the four fields (e.g. track gain but no peak).
class ReplayGain {
  const ReplayGain({
    this.trackGainDb,
    this.trackPeak,
    this.albumGainDb,
    this.albumPeak,
  });

  /// No ReplayGain data — the safe default for a track whose source didn't
  /// provide any. [linearVolume] returns `1.0` (no change) for this.
  static const ReplayGain none = ReplayGain();

  /// Per-track gain in dB, or null when the source didn't provide it.
  final double? trackGainDb;

  /// Per-track peak amplitude (linear, `1.0` == full scale), or null.
  final double? trackPeak;

  /// Per-album gain in dB, or null when the source didn't provide it.
  final double? albumGainDb;

  /// Per-album peak amplitude (linear, `1.0` == full scale), or null.
  final double? albumPeak;

  /// Whether this carries no usable gain at all (so normalization is a no-op).
  bool get isEmpty => trackGainDb == null && albumGainDb == null;

  /// The gain in dB to apply for [mode], falling back to the other reference
  /// when the preferred one is missing (album mode uses track gain when the file
  /// has no album gain, and vice versa), so a half-tagged file still levels.
  double? gainDbFor(ReplayGainMode mode) {
    switch (mode) {
      case ReplayGainMode.track:
        return trackGainDb ?? albumGainDb;
      case ReplayGainMode.album:
        return albumGainDb ?? trackGainDb;
    }
  }

  /// The peak to use alongside [gainDbFor], following the same fallback so the
  /// clipping guard always pairs with the gain it's guarding.
  double? peakFor(ReplayGainMode mode) {
    switch (mode) {
      case ReplayGainMode.track:
        return trackPeak ?? albumPeak;
      case ReplayGainMode.album:
        return albumPeak ?? trackPeak;
    }
  }

  /// The safe linear volume multiplier (in `0.0..maxVolume`) to apply for this
  /// track's ReplayGain.
  ///
  /// Three rules keep it safe:
  ///  1. **No data → no change.** Missing gain returns [maxVolume] (`1.0`), so a
  ///     track without ReplayGain plays untouched rather than guessed-at.
  ///  2. **Never clip.** When a peak is known, the gain is capped so the loudest
  ///     sample can't exceed full scale (`gain ≤ 1 / peak`).
  ///  3. **Attenuate only.** The result is clamped to `maxVolume` (default
  ///     `1.0`). `just_audio` exposes volume as `0.0..1.0` and cannot amplify
  ///     past the source level, so a *positive* gain (quiet track) can't be
  ///     fully applied — it simply plays at its original level. Loud tracks
  ///     (negative gain) are turned down as intended. This is the documented
  ///     trade-off, not a bug; see docs/volume-normalization.md.
  double linearVolume({
    ReplayGainMode mode = ReplayGainMode.track,
    double maxVolume = 1.0,
  }) {
    final double ceiling = maxVolume.clamp(0.0, 1.0).toDouble();
    final double? gainDb = gainDbFor(mode);
    if (gainDb == null) return ceiling;

    double linear = math.pow(10, gainDb / 20).toDouble();

    final double? peak = peakFor(mode);
    if (peak != null && peak > 0) {
      // Peak limiting: keep peak * gain ≤ full scale so applying the gain can
      // never push a sample into clipping.
      linear = math.min(linear, 1.0 / peak);
    }

    return linear.clamp(0.0, ceiling).toDouble();
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ReplayGain &&
          other.trackGainDb == trackGainDb &&
          other.trackPeak == trackPeak &&
          other.albumGainDb == albumGainDb &&
          other.albumPeak == albumPeak);

  @override
  int get hashCode =>
      Object.hash(trackGainDb, trackPeak, albumGainDb, albumPeak);

  @override
  String toString() => isEmpty
      ? 'ReplayGain.none'
      : 'ReplayGain(trackGainDb: $trackGainDb, trackPeak: $trackPeak, '
          'albumGainDb: $albumGainDb, albumPeak: $albumPeak)';
}
