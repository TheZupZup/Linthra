import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/audio_cd.dart';
import 'package:linthra/core/models/optical_media.dart';
import 'package:linthra/core/platform/host_platform.dart';
import 'package:linthra/core/services/optical/audio_cd_toc_service.dart';
import 'package:linthra/core/services/optical/platform_audio_cd_toc_service.dart';
import 'package:linthra/core/services/optical/unsupported_audio_cd_toc_service.dart';

/// Records what it was asked, so the platform split can be asserted without a
/// drive or a channel.
class _RecordingService implements AudioCdTocService {
  _RecordingService({required this.isSupported});

  @override
  final bool isSupported;

  final List<String> inspections = <String>[];

  @override
  Future<AudioCdInspection> inspect(OpticalDrive drive) async {
    inspections.add(drive.id);
    return const AudioCdInspection.noDisc();
  }
}

void main() {
  const OpticalDrive drive =
      OpticalDrive(id: '/dev/sr0', disc: OpticalDiscState.audioCd);

  group('PlatformAudioCdTocService', () {
    test('reads the disc on Linux', () async {
      final _RecordingService linux = _RecordingService(isSupported: true);
      final PlatformAudioCdTocService service = PlatformAudioCdTocService(
        host: HostPlatform.linux,
        linuxService: linux,
      );

      expect(service.isSupported, isTrue);
      expect(
        (await service.inspect(drive)).status,
        AudioCdInspectionStatus.noDisc,
      );
      expect(linux.inspections, <String>['/dev/sr0']);
    });

    test('never reaches the Linux service on Android', () async {
      final _RecordingService linux = _RecordingService(isSupported: true);
      final PlatformAudioCdTocService service = PlatformAudioCdTocService(
        host: HostPlatform.android,
        linuxService: linux,
      );

      expect(service.isSupported, isFalse);
      expect(
        (await service.inspect(drive)).status,
        AudioCdInspectionStatus.unsupported,
      );
      expect(linux.inspections, isEmpty);
    });

    test('every non-Linux platform falls back safely', () async {
      for (final HostPlatform host in HostPlatform.values) {
        if (host == HostPlatform.linux) continue;
        final _RecordingService linux = _RecordingService(isSupported: true);
        final PlatformAudioCdTocService service = PlatformAudioCdTocService(
          host: host,
          linuxService: linux,
        );

        expect(service.isSupported, isFalse, reason: host.label);
        expect(
          (await service.inspect(drive)).status,
          AudioCdInspectionStatus.unsupported,
          reason: host.label,
        );
        expect(linux.inspections, isEmpty, reason: host.label);
      }
    });

    test('the default fallback is the unsupported service', () async {
      final PlatformAudioCdTocService service =
          PlatformAudioCdTocService(host: HostPlatform.android);

      expect(service.isSupported, isFalse);
      expect(
        (await service.inspect(drive)).status,
        AudioCdInspectionStatus.unsupported,
      );
    });

    test('a custom fallback is used off Linux', () async {
      final _RecordingService fallback = _RecordingService(isSupported: false);
      final PlatformAudioCdTocService service = PlatformAudioCdTocService(
        host: HostPlatform.macOS,
        fallbackService: fallback,
      );

      await service.inspect(drive);

      expect(fallback.inspections, <String>['/dev/sr0']);
    });
  });

  group('UnsupportedAudioCdTocService', () {
    test('answers unsupported and reads nothing', () async {
      const UnsupportedAudioCdTocService service =
          UnsupportedAudioCdTocService();

      expect(service.isSupported, isFalse);
      final AudioCdInspection inspection = await service.inspect(drive);
      expect(inspection.status, AudioCdInspectionStatus.unsupported);
      expect(inspection.disc, isNull);
    });
  });
}
