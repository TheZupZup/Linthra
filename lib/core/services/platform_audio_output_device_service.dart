import '../models/audio_output_device.dart';
import '../platform/host_platform.dart';
import 'audio_output_device_service.dart';
import 'linux_audio_output_device_service.dart';
import 'noop_audio_output_device_service.dart';

/// The default [AudioOutputDeviceService]: real routing on Linux, a safe no-op
/// everywhere else.
///
/// This is the one place that knows about the platform split, mirroring
/// [PlatformShareService]. Linux gets [LinuxAudioOutputDeviceService], which
/// drives libmpv's `audio-device`; every other platform — Android included —
/// gets [NoopAudioOutputDeviceService], so the system keeps owning output
/// routing there and the Settings card is simply not shown.
class PlatformAudioOutputDeviceService implements AudioOutputDeviceService {
  PlatformAudioOutputDeviceService({
    HostPlatform? host,
    AudioOutputDeviceService? linuxService,
    AudioOutputDeviceService fallbackService =
        const NoopAudioOutputDeviceService(),
  })  : _host = host,
        _linuxService = linuxService,
        _fallbackService = fallbackService;

  /// The platform to route for; null reads the real host. Injectable so the
  /// split can be exercised for both platforms on one machine.
  final HostPlatform? _host;

  /// Built lazily: constructing it is cheap, but it is the only object in this
  /// graph that imports media_kit, so a non-Linux host never touches it.
  AudioOutputDeviceService? _linuxService;
  final AudioOutputDeviceService _fallbackService;

  AudioOutputDeviceService get _delegate {
    if ((_host ?? HostPlatform.current) != HostPlatform.linux) {
      return _fallbackService;
    }
    return _linuxService ??= LinuxAudioOutputDeviceService();
  }

  @override
  bool get isSupported => _delegate.isSupported;

  @override
  Future<List<AudioOutputDevice>> devices() => _delegate.devices();

  @override
  Future<bool> select(AudioOutputDevice device) => _delegate.select(device);

  @override
  Stream<List<AudioOutputDevice>> get deviceChanges => _delegate.deviceChanges;
}
