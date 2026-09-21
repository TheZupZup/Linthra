import '../../models/audio_cd.dart';
import '../../models/optical_media.dart';
import '../../platform/host_platform.dart';
import 'audio_cd_toc_service.dart';
import 'linux_audio_cd_toc_service.dart';
import 'unsupported_audio_cd_toc_service.dart';

/// The default [AudioCdTocService]: a real read on Linux, a safe "unsupported"
/// everywhere else.
///
/// The one place that knows about the platform split, mirroring
/// [PlatformOpticalMediaService] exactly. Linux gets
/// [LinuxAudioCdTocService], which reads the disc through Linthra's own
/// runner channel; every other platform — **Android above all** — gets
/// [UnsupportedAudioCdTocService] and never builds a channel, never names a
/// device and gains no permission.
///
/// The Linux service is built lazily for the same reason it is in the
/// detection twin: constructing a platform binding must not reach for a
/// platform.
class PlatformAudioCdTocService implements AudioCdTocService {
  PlatformAudioCdTocService({
    HostPlatform? host,
    AudioCdTocService? linuxService,
    AudioCdTocService fallbackService = const UnsupportedAudioCdTocService(),
  })  : _host = host,
        _linuxService = linuxService,
        _fallbackService = fallbackService;

  /// The platform to answer for; null reads the real host. Injectable so the
  /// split can be exercised for both platforms on one machine.
  final HostPlatform? _host;

  AudioCdTocService? _linuxService;
  final AudioCdTocService _fallbackService;

  AudioCdTocService get _delegate {
    if ((_host ?? HostPlatform.current) != HostPlatform.linux) {
      return _fallbackService;
    }
    return _linuxService ??= LinuxAudioCdTocService();
  }

  @override
  bool get isSupported => _delegate.isSupported;

  @override
  Future<AudioCdInspection> inspect(OpticalDrive drive) =>
      _delegate.inspect(drive);
}
