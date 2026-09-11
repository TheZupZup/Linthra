import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/audio_output_device.dart';
import 'package:linthra/core/platform/host_platform.dart';
import 'package:linthra/core/services/audio_output_device_service.dart';
import 'package:linthra/core/services/noop_audio_output_device_service.dart';
import 'package:linthra/core/services/platform_audio_output_device_service.dart';

/// Records what it was asked to do, so the platform split can be asserted
/// without loading libmpv.
class _RecordingService implements AudioOutputDeviceService {
  _RecordingService({required this.isSupported});

  @override
  final bool isSupported;
  AudioOutputDevice? selected;

  @override
  Future<List<AudioOutputDevice>> devices() async =>
      const <AudioOutputDevice>[AudioOutputDevice.systemDefault];

  @override
  Future<bool> select(AudioOutputDevice device) async {
    selected = device;
    return true;
  }

  final StreamController<List<AudioOutputDevice>> changes =
      StreamController<List<AudioOutputDevice>>.broadcast();

  @override
  Stream<List<AudioOutputDevice>> get deviceChanges => changes.stream;
}

void main() {
  group('PlatformAudioOutputDeviceService', () {
    const AudioOutputDevice headset =
        AudioOutputDevice(id: 'pulse/headset', label: 'Headset');

    test('on Linux, routes through the media_kit-backed service', () async {
      final _RecordingService linux = _RecordingService(isSupported: true);
      final _RecordingService fallback = _RecordingService(isSupported: false);
      final PlatformAudioOutputDeviceService service =
          PlatformAudioOutputDeviceService(
        host: HostPlatform.linux,
        linuxService: linux,
        fallbackService: fallback,
      );

      expect(service.isSupported, isTrue);
      expect(await service.devices(), hasLength(1));
      await service.select(headset);
      expect(linux.selected, headset);
      expect(fallback.selected, isNull);
      // Hotplug watching follows the same split: a Linux build observes the
      // real backend, and the fallback is never subscribed to.
      final Future<List<AudioOutputDevice>> watched =
          service.deviceChanges.first;
      linux.changes.add(const <AudioOutputDevice>[headset]);
      expect(await watched, const <AudioOutputDevice>[headset]);
      expect(fallback.changes.hasListener, isFalse);
    });

    test('on Android, output routing stays with the system', () async {
      final _RecordingService linux = _RecordingService(isSupported: true);
      final PlatformAudioOutputDeviceService service =
          PlatformAudioOutputDeviceService(
        host: HostPlatform.android,
        linuxService: linux,
      );

      expect(service.isSupported, isFalse);
      expect(await service.devices(), isEmpty);
      expect(await service.deviceChanges.toList(), isEmpty,
          reason: 'Android has nothing to watch: the system owns routing');
      await service.select(headset);
      expect(linux.selected, isNull);
    });

    test('an unsupported desktop platform falls back too', () async {
      final PlatformAudioOutputDeviceService service =
          PlatformAudioOutputDeviceService(
        host: HostPlatform.macOS,
        linuxService: _RecordingService(isSupported: true),
      );

      expect(service.isSupported, isFalse);
    });
  });

  group('NoopAudioOutputDeviceService', () {
    test('enumerates nothing and routes nothing', () async {
      const NoopAudioOutputDeviceService service =
          NoopAudioOutputDeviceService();

      expect(service.isSupported, isFalse);
      expect(await service.devices(), isEmpty);
      await expectLater(
        service.select(AudioOutputDevice.systemDefault),
        completes,
      );
    });
  });
}
