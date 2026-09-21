import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/optical_media.dart';
import 'package:linthra/core/platform/host_platform.dart';
import 'package:linthra/core/services/optical/optical_media_service.dart';
import 'package:linthra/core/services/optical/platform_optical_media_service.dart';
import 'package:linthra/core/services/optical/unsupported_optical_media_service.dart';

/// Records what it was asked, so the platform split can be asserted without a
/// bus.
class _RecordingService implements OpticalMediaService {
  _RecordingService({
    required this.isSupported,
    this.snapshot = const OpticalMediaSnapshot.noDrive(),
  });

  @override
  final bool isSupported;

  final OpticalMediaSnapshot snapshot;

  int inspections = 0;
  int disposals = 0;

  final StreamController<OpticalMediaSnapshot> published =
      StreamController<OpticalMediaSnapshot>.broadcast();

  @override
  Future<OpticalMediaSnapshot> inspect() async {
    inspections++;
    return snapshot;
  }

  @override
  Stream<OpticalMediaSnapshot> get changes => published.stream;

  @override
  Future<void> dispose() async {
    disposals++;
    await published.close();
  }
}

void main() {
  group('PlatformOpticalMediaService', () {
    const OpticalMediaSnapshot withAudioCd = OpticalMediaSnapshot(
      availability: OpticalMediaAvailability.supported,
      drives: <OpticalDrive>[
        OpticalDrive(id: '/dev/sr0', disc: OpticalDiscState.audioCd),
      ],
    );

    test('on Linux, routes to the UDisks2-backed service', () async {
      final _RecordingService linux =
          _RecordingService(isSupported: true, snapshot: withAudioCd);
      final _RecordingService fallback = _RecordingService(isSupported: false);
      final PlatformOpticalMediaService service = PlatformOpticalMediaService(
        host: HostPlatform.linux,
        linuxService: linux,
        fallbackService: fallback,
      );
      addTearDown(service.dispose);

      expect(service.isSupported, isTrue);
      expect(await service.inspect(), withAudioCd);
      expect(linux.inspections, 1);
      expect(fallback.inspections, 0);

      final Future<OpticalMediaSnapshot> watched = service.changes.first;
      linux.published.add(withAudioCd);
      expect(await watched, withAudioCd);
    });

    test('on Android, nothing optical exists and nothing is asked', () async {
      final _RecordingService linux =
          _RecordingService(isSupported: true, snapshot: withAudioCd);
      final _RecordingService fallback = _RecordingService(isSupported: false);
      final PlatformOpticalMediaService service = PlatformOpticalMediaService(
        host: HostPlatform.android,
        linuxService: linux,
        fallbackService: fallback,
      );
      addTearDown(service.dispose);

      expect(service.isSupported, isFalse);
      expect(await service.inspect(), const OpticalMediaSnapshot.noDrive());
      expect(linux.inspections, 0);
      expect(fallback.inspections, 1);
    });

    test('an unknown platform falls back rather than guessing', () async {
      final PlatformOpticalMediaService service = PlatformOpticalMediaService(
        host: HostPlatform.other,
      );
      addTearDown(service.dispose);

      expect(service.isSupported, isFalse);
      expect(await service.inspect(), const OpticalMediaSnapshot.unsupported());
      expect(await service.changes.isEmpty, isTrue);
    });

    test('disposing a platform that never looked tears down only what exists',
        () async {
      final _RecordingService fallback = _RecordingService(isSupported: false);
      final PlatformOpticalMediaService service = PlatformOpticalMediaService(
        host: HostPlatform.android,
        fallbackService: fallback,
      );

      await service.dispose();

      // Nothing built a Linux service on this platform, so there is nothing
      // of it to tear down — and disposal must not be what finally builds one.
      expect(fallback.disposals, 1);
    });
  });

  group('UnsupportedOpticalMediaService', () {
    test('answers unsupported, not "no drive"', () async {
      const UnsupportedOpticalMediaService service =
          UnsupportedOpticalMediaService();

      expect(service.isSupported, isFalse);
      expect(await service.inspect(), const OpticalMediaSnapshot.unsupported());
      expect(await service.changes.isEmpty, isTrue);
      await service.dispose();
      await service.dispose();
    });
  });
}
