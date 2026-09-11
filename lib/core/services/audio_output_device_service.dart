import '../models/audio_output_device.dart';

/// Lists the audio outputs the host offers and moves playback onto one of them.
///
/// This is a *routing* seam, not a playback one: it never starts, stops or
/// re-loads a track. On Linux the implementation drives libmpv's `audio-device`
/// through media_kit, so switching moves the audio that is already playing.
///
/// Android is deliberately not implemented here. Output routing there belongs to
/// the platform (the system output picker, Bluetooth, Android Auto), and the app
/// must not fight it — so Android gets [NoopAudioOutputDeviceService] and the
/// Settings card is simply not shown, exactly like "Share Linthra" off Android.
///
/// Implementations must never throw into the UI. A backend that is not ready,
/// a device that disappeared mid-switch, or a host with no enumeration at all
/// all end as "no devices" / "nothing happened", never as an error dialog.
abstract interface class AudioOutputDeviceService {
  /// Whether this build can enumerate and choose an output. `false` off Linux
  /// (and in tests), so the UI can hide the card rather than offer a control
  /// that does nothing.
  bool get isSupported;

  /// The outputs the host currently offers, [AudioOutputDevice.systemDefault]
  /// first. Empty when nothing could be enumerated.
  Future<List<AudioOutputDevice>> devices();

  /// Routes playback to [device], reporting whether it actually took effect.
  ///
  /// Applies to audio that is already playing *and* to the next player the
  /// engine creates, so the choice survives a stop/start without being
  /// re-applied by the caller. Passing [AudioOutputDevice.systemDefault] hands
  /// the decision back to the system.
  ///
  /// Returns `false` when the backend refused — a device that disappeared
  /// between the list and the tap, say. Callers must not treat a refused switch
  /// as done: it is the difference between remembering an output that is
  /// playing and remembering one that never started.
  Future<bool> select(AudioOutputDevice device);

  /// Emits the host's output list whenever the backend reports that it changed
  /// — a headset plugged in or pulled out, a Bluetooth speaker connecting or
  /// dropping, an HDMI sink appearing when a monitor wakes, the system default
  /// moving.
  ///
  /// Each event is the full list in the same shape [devices] returns, so a
  /// listener compares lists rather than reconstructing a diff from events it
  /// might have missed.
  ///
  /// This is *observation only*: it starts, stops and re-routes nothing. What
  /// to do about a device that vanished is policy, and it lives in
  /// `AudioOutputController` — the same place that already owns which output
  /// is chosen and whether it is remembered.
  ///
  /// A broadcast stream: several listeners are fine and none of them changes
  /// what the others see. Implementations that cannot observe (every platform
  /// but Linux) return an empty stream rather than throwing, so a caller never
  /// has to ask whether watching is supported before listening.
  Stream<List<AudioOutputDevice>> get deviceChanges;
}
