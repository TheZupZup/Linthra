import '../models/audio_stream_quality.dart';

/// Asks the on-device audio engine what it is decoding.
///
/// Read-only by contract: an implementation reads state the engine already
/// keeps and never opens, seeks, reloads or reconfigures anything, so asking
/// can never change what plays or how soon it starts. It also never reaches a
/// server or reads a file.
///
/// It does not know which track is playing. Pairing a report with the right
/// track (and throwing away a report that may still describe the previous
/// one) is the caller's job.
abstract interface class AudioQualityProbe {
  /// Whether this engine can report anything at all. False where Linthra has
  /// no way to read it, which hides the setting there.
  bool get isAvailable;

  /// The engine's report for the stream it holds right now, or `null` when it
  /// cannot say (nothing loaded, more than one candidate, an engine that does
  /// not answer). Never throws.
  AudioStreamQuality? current();

  /// Fires whenever the engine's report may have changed. Carries no data:
  /// listeners call [current] again.
  Stream<void> changes();
}

/// The probe for engines Linthra cannot read: reports nothing, ever.
class UnavailableAudioQualityProbe implements AudioQualityProbe {
  const UnavailableAudioQualityProbe();

  @override
  bool get isAvailable => false;

  @override
  AudioStreamQuality? current() => null;

  @override
  Stream<void> changes() => const Stream<void>.empty();
}
