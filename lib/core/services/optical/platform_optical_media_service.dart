import '../../models/optical_media.dart';
import '../../platform/host_platform.dart';
import 'linux_optical_media_service.dart';
import 'optical_media_service.dart';
import 'unsupported_optical_media_service.dart';

/// The default [OpticalMediaService]: real detection on Linux, a safe
/// "unsupported" everywhere else.
///
/// The one place that knows about the platform split, mirroring
/// [PlatformAudioOutputDeviceService] and [PlatformShareService]. Linux gets
/// [LinuxOpticalMediaService], which reads UDisks2 over D-Bus; every other
/// platform — **Android above all** — gets
/// [UnsupportedOpticalMediaService] and never loads a line of the Linux
/// implementation, never opens a bus and never gains a permission.
///
/// The Linux service is built lazily for exactly that reason: it is the only
/// object in this graph that imports `dbus`, so a non-Linux host never touches
/// it.
class PlatformOpticalMediaService implements OpticalMediaService {
  PlatformOpticalMediaService({
    HostPlatform? host,
    OpticalMediaService? linuxService,
    OpticalMediaService fallbackService =
        const UnsupportedOpticalMediaService(),
  })  : _host = host,
        _linuxService = linuxService,
        _fallbackService = fallbackService;

  /// The platform to answer for; null reads the real host. Injectable so the
  /// split can be exercised for both platforms on one machine.
  final HostPlatform? _host;

  OpticalMediaService? _linuxService;
  final OpticalMediaService _fallbackService;

  OpticalMediaService get _delegate {
    if ((_host ?? HostPlatform.current) != HostPlatform.linux) {
      return _fallbackService;
    }
    return _linuxService ??= LinuxOpticalMediaService();
  }

  @override
  bool get isSupported => _delegate.isSupported;

  @override
  Future<OpticalMediaSnapshot> inspect() => _delegate.inspect();

  @override
  Stream<OpticalMediaSnapshot> get changes => _delegate.changes;

  /// Disposes only what was actually built. A platform that never reached the
  /// Linux branch has nothing to tear down, and asking for the delegate here
  /// would construct one purely in order to throw it away.
  @override
  Future<void> dispose() async {
    await _linuxService?.dispose();
    await _fallbackService.dispose();
  }
}
