import '../models/audio_output_device.dart';
import 'audio_output_device_service.dart';

/// An [AudioOutputDeviceService] that enumerates nothing and routes nothing.
///
/// It is the default provider binding (so unit and widget tests stay free of
/// libmpv) and the real implementation on every platform that has no
/// app-level output routing — Android included, where the system owns the
/// output. [isSupported] is `false`, so the Settings card hides itself instead
/// of showing an empty picker.
class NoopAudioOutputDeviceService implements AudioOutputDeviceService {
  const NoopAudioOutputDeviceService();

  @override
  bool get isSupported => false;

  @override
  Future<List<AudioOutputDevice>> devices() async =>
      const <AudioOutputDevice>[];

  @override
  Future<bool> select(AudioOutputDevice device) async => false;

  /// Nothing to observe: an empty stream that closes immediately, so a listener
  /// is never left waiting on events that cannot come.
  @override
  Stream<List<AudioOutputDevice>> get deviceChanges =>
      const Stream<List<AudioOutputDevice>>.empty();
}
