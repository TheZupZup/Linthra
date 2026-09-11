import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/audio_output_device.dart';
import 'package:linthra/core/services/audio_output_device_service.dart';
import 'package:linthra/data/repositories/audio_output_device_service_provider.dart';
import 'package:linthra/data/repositories/in_memory_playback_preferences.dart';
import 'package:linthra/data/repositories/playback_preferences_provider.dart';
import 'package:linthra/features/settings/playback/audio_output_controller.dart';

/// A stand-in for libmpv: it reports whatever device list the test sets up and
/// records every routing call, so the controller's policy can be asserted
/// without a sound card.
class _FakeService implements AudioOutputDeviceService {
  _FakeService({
    this.isSupported = true,
    List<AudioOutputDevice>? devices,
  }) : available = devices ?? <AudioOutputDevice>[];

  @override
  final bool isSupported;

  List<AudioOutputDevice> available;
  final List<AudioOutputDevice> routed = <AudioOutputDevice>[];
  int enumerations = 0;

  /// Whether the backend accepts a switch. `false` stands in for a device that
  /// disappeared between the list and the tap.
  bool routingSucceeds = true;

  /// Held futures, so a test can interleave two operations deliberately.
  final List<Completer<void>> pendingRoutes = <Completer<void>>[];
  bool holdRouting = false;

  @override
  Future<List<AudioOutputDevice>> devices() async {
    enumerations++;
    return available;
  }

  @override
  Future<bool> select(AudioOutputDevice device) async {
    if (holdRouting) {
      final Completer<void> gate = Completer<void>();
      pendingRoutes.add(gate);
      await gate.future;
    }
    if (!routingSucceeds) return false;
    routed.add(device);
    return true;
  }

  /// The hotplug channel (#403): the test pushes a device list the way libmpv
  /// republishes `audio-device-list` when hardware comes or goes.
  final StreamController<List<AudioOutputDevice>> changes =
      StreamController<List<AudioOutputDevice>>.broadcast();

  int deviceChangeListeners = 0;

  @override
  Stream<List<AudioOutputDevice>> get deviceChanges {
    deviceChangeListeners++;
    return changes.stream;
  }

  /// Publishes [devices] as the host's new output list and also makes them what
  /// a later enumeration reports, the way a real unplug does both.
  void hotplug(List<AudioOutputDevice> devices) {
    available = devices;
    changes.add(devices);
  }
}

void main() {
  const AudioOutputDevice headset = AudioOutputDevice(
    id: 'pipewire/alsa_output.usb-headset',
    label: 'USB Headset',
  );
  const AudioOutputDevice builtIn = AudioOutputDevice(
    id: 'pipewire/alsa_output.pci-0000_00_1f.3.analog-stereo',
    label: 'Built-in Audio',
  );
  const AudioOutputDevice unstable = AudioOutputDevice(
    id: 'alsa/hw:2,0',
    label: 'Some card',
  );

  ProviderContainer containerFor(
    _FakeService service,
    InMemoryPlaybackPreferences preferences,
  ) {
    final ProviderContainer container = ProviderContainer(
      overrides: <Override>[
        audioOutputDeviceServiceProvider.overrideWithValue(service),
        playbackPreferencesProvider.overrideWithValue(preferences),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  group('AudioOutputController at startup', () {
    test('does not probe the backend when nothing is saved', () async {
      final _FakeService service = _FakeService(
        devices: <AudioOutputDevice>[AudioOutputDevice.systemDefault, headset],
      );
      final ProviderContainer container =
          containerFor(service, InMemoryPlaybackPreferences());

      final AudioOutputSettingsState state =
          await container.read(audioOutputControllerProvider.future);

      expect(service.enumerations, 0);
      expect(service.routed, isEmpty);
      expect(state.selected, AudioOutputDevice.systemDefault);
      expect(state.hasEnumerated, isFalse);
    });

    test('re-applies a saved device that is still there', () async {
      final _FakeService service = _FakeService(
        devices: <AudioOutputDevice>[
          AudioOutputDevice.systemDefault,
          builtIn,
          headset,
        ],
      );
      final ProviderContainer container = containerFor(
        service,
        InMemoryPlaybackPreferences(audioOutputDeviceId: headset.id),
      );

      final AudioOutputSettingsState state =
          await container.read(audioOutputControllerProvider.future);

      expect(service.routed, <AudioOutputDevice>[headset]);
      expect(state.selected, headset);
      expect(state.savedDeviceUnavailable, isFalse);
    });

    test('falls back to the system default when the saved device is gone',
        () async {
      final _FakeService service = _FakeService(
        devices: <AudioOutputDevice>[AudioOutputDevice.systemDefault, builtIn],
      );
      final InMemoryPlaybackPreferences preferences =
          InMemoryPlaybackPreferences(audioOutputDeviceId: headset.id);
      final ProviderContainer container = containerFor(service, preferences);

      final AudioOutputSettingsState state =
          await container.read(audioOutputControllerProvider.future);

      // Nothing was routed: playback never left the system default, so there
      // is nothing to move it back to.
      expect(service.routed, isEmpty);
      expect(state.selected, AudioOutputDevice.systemDefault);
      expect(state.savedDeviceUnavailable, isTrue);
      // Forgotten, so the next launch does not keep chasing a name that no
      // longer means anything on this machine.
      expect(await preferences.audioOutputDeviceId(), isNull);
    });

    test('a backend that reports nothing is not treated as "device gone"',
        () async {
      final _FakeService service = _FakeService();
      final InMemoryPlaybackPreferences preferences =
          InMemoryPlaybackPreferences(audioOutputDeviceId: headset.id);
      final ProviderContainer container = containerFor(service, preferences);

      final AudioOutputSettingsState state =
          await container.read(audioOutputControllerProvider.future);

      expect(service.routed, isEmpty);
      expect(state.hasEnumerated, isTrue);
      expect(state.devices, isEmpty);
      expect(await preferences.audioOutputDeviceId(), headset.id);
    });

    test('does nothing at all where the platform owns output routing',
        () async {
      final _FakeService service = _FakeService(isSupported: false);
      final ProviderContainer container = containerFor(
        service,
        InMemoryPlaybackPreferences(audioOutputDeviceId: headset.id),
      );

      final AudioOutputSettingsState state =
          await container.read(audioOutputControllerProvider.future);

      expect(service.enumerations, 0);
      expect(service.routed, isEmpty);
      expect(state.selected, AudioOutputDevice.systemDefault);
    });
  });

  group('AudioOutputController.select', () {
    test('routes playback and remembers a stable device', () async {
      final _FakeService service = _FakeService(
        devices: <AudioOutputDevice>[AudioOutputDevice.systemDefault, headset],
      );
      final InMemoryPlaybackPreferences preferences =
          InMemoryPlaybackPreferences();
      final ProviderContainer container = containerFor(service, preferences);
      await container.read(audioOutputControllerProvider.future);

      await container
          .read(audioOutputControllerProvider.notifier)
          .select(headset);

      expect(service.routed, <AudioOutputDevice>[headset]);
      expect(await preferences.audioOutputDeviceId(), headset.id);
      expect(
        container.read(audioOutputControllerProvider).requireValue.selected,
        headset,
      );
    });

    test('applies an unstable device but does not remember it', () async {
      final _FakeService service = _FakeService(
        devices: <AudioOutputDevice>[AudioOutputDevice.systemDefault, unstable],
      );
      final InMemoryPlaybackPreferences preferences =
          InMemoryPlaybackPreferences();
      final ProviderContainer container = containerFor(service, preferences);
      await container.read(audioOutputControllerProvider.future);

      await container
          .read(audioOutputControllerProvider.notifier)
          .select(unstable);

      expect(service.routed, <AudioOutputDevice>[unstable]);
      expect(await preferences.audioOutputDeviceId(), isNull);
      expect(
        container.read(audioOutputControllerProvider).requireValue.isRemembered,
        isFalse,
      );
    });

    test('going back to the system default clears the stored device', () async {
      final _FakeService service = _FakeService(
        devices: <AudioOutputDevice>[AudioOutputDevice.systemDefault, headset],
      );
      final InMemoryPlaybackPreferences preferences =
          InMemoryPlaybackPreferences(audioOutputDeviceId: headset.id);
      final ProviderContainer container = containerFor(service, preferences);
      await container.read(audioOutputControllerProvider.future);

      await container
          .read(audioOutputControllerProvider.notifier)
          .select(AudioOutputDevice.systemDefault);

      expect(
        service.routed,
        <AudioOutputDevice>[headset, AudioOutputDevice.systemDefault],
      );
      expect(await preferences.audioOutputDeviceId(), isNull);
    });

    test('re-picking the output already in use does not re-route', () async {
      final _FakeService service = _FakeService(
        devices: <AudioOutputDevice>[AudioOutputDevice.systemDefault, headset],
      );
      final ProviderContainer container =
          containerFor(service, InMemoryPlaybackPreferences());
      await container.read(audioOutputControllerProvider.future);

      await container
          .read(audioOutputControllerProvider.notifier)
          .select(headset);
      await container
          .read(audioOutputControllerProvider.notifier)
          .select(headset);

      expect(service.routed, <AudioOutputDevice>[headset]);
    });
  });

  group('AudioOutputController.refresh', () {
    test('picks up a device that was plugged in after launch', () async {
      final _FakeService service = _FakeService(
        devices: <AudioOutputDevice>[AudioOutputDevice.systemDefault],
      );
      final ProviderContainer container =
          containerFor(service, InMemoryPlaybackPreferences());
      await container.read(audioOutputControllerProvider.future);

      service.available = <AudioOutputDevice>[
        AudioOutputDevice.systemDefault,
        headset,
      ];
      await container.read(audioOutputControllerProvider.notifier).refresh();

      expect(
        container.read(audioOutputControllerProvider).requireValue.devices,
        contains(headset),
      );
    });

    test('keeps a session-only choice across a refresh', () async {
      final _FakeService service = _FakeService(
        devices: <AudioOutputDevice>[AudioOutputDevice.systemDefault, unstable],
      );
      final ProviderContainer container =
          containerFor(service, InMemoryPlaybackPreferences());
      await container.read(audioOutputControllerProvider.future);
      await container
          .read(audioOutputControllerProvider.notifier)
          .select(unstable);

      await container.read(audioOutputControllerProvider.notifier).refresh();

      // Nothing was stored (the id is unstable), so the refresh must fall back
      // to the live selection rather than looking like a reset.
      expect(
        container.read(audioOutputControllerProvider).requireValue.selected,
        unstable,
      );
    });

    test('reports a chosen device that disappeared while running', () async {
      final _FakeService service = _FakeService(
        devices: <AudioOutputDevice>[AudioOutputDevice.systemDefault, headset],
      );
      final ProviderContainer container =
          containerFor(service, InMemoryPlaybackPreferences());
      await container.read(audioOutputControllerProvider.future);
      await container
          .read(audioOutputControllerProvider.notifier)
          .select(headset);

      service.available = <AudioOutputDevice>[AudioOutputDevice.systemDefault];
      await container.read(audioOutputControllerProvider.notifier).refresh();

      final AudioOutputSettingsState state =
          container.read(audioOutputControllerProvider).requireValue;
      expect(state.selected, AudioOutputDevice.systemDefault);
      expect(state.savedDeviceUnavailable, isTrue);
      expect(service.routed.last, AudioOutputDevice.systemDefault);
    });
  });

  group('AudioOutputController when the backend does not cooperate', () {
    test('a refused switch is neither stored nor shown as playing', () async {
      final _FakeService service = _FakeService(
        devices: <AudioOutputDevice>[AudioOutputDevice.systemDefault, headset],
      )..routingSucceeds = false;
      final InMemoryPlaybackPreferences preferences =
          InMemoryPlaybackPreferences();
      final ProviderContainer container = containerFor(service, preferences);
      await container.read(audioOutputControllerProvider.future);

      await container
          .read(audioOutputControllerProvider.notifier)
          .select(headset);

      final AudioOutputSettingsState state =
          container.read(audioOutputControllerProvider).requireValue;
      expect(state.selected, AudioOutputDevice.systemDefault);
      expect(state.selectionFailed, isTrue);
      expect(await preferences.audioOutputDeviceId(), isNull);
    });

    test('a refused switch is retried, not assumed applied', () async {
      final _FakeService service = _FakeService(
        devices: <AudioOutputDevice>[AudioOutputDevice.systemDefault, headset],
      )..routingSucceeds = false;
      final ProviderContainer container =
          containerFor(service, InMemoryPlaybackPreferences());
      await container.read(audioOutputControllerProvider.future);
      await container
          .read(audioOutputControllerProvider.notifier)
          .select(headset);

      service.routingSucceeds = true;
      await container
          .read(audioOutputControllerProvider.notifier)
          .select(headset);

      expect(service.routed, <AudioOutputDevice>[headset]);
      expect(
        container.read(audioOutputControllerProvider).requireValue.selected,
        headset,
      );
    });

    test('a failed enumeration keeps a session-only selection', () async {
      final _FakeService service = _FakeService(
        devices: <AudioOutputDevice>[AudioOutputDevice.systemDefault, unstable],
      );
      final ProviderContainer container =
          containerFor(service, InMemoryPlaybackPreferences());
      await container.read(audioOutputControllerProvider.future);
      await container
          .read(audioOutputControllerProvider.notifier)
          .select(unstable);

      // The backend goes quiet for one refresh, then comes back.
      service.available = <AudioOutputDevice>[];
      await container.read(audioOutputControllerProvider.notifier).refresh();

      final AudioOutputSettingsState duringOutage =
          container.read(audioOutputControllerProvider).requireValue;
      expect(duringOutage.devices, isEmpty);
      expect(duringOutage.selected, unstable);

      service.available = <AudioOutputDevice>[
        AudioOutputDevice.systemDefault,
        unstable,
      ];
      await container.read(audioOutputControllerProvider.notifier).refresh();

      // The outage must not have routed the listener away from their device.
      expect(
        container.read(audioOutputControllerProvider).requireValue.selected,
        unstable,
      );
      expect(service.routed, <AudioOutputDevice>[unstable]);
    });

    test('two quick choices leave playback on the later one', () async {
      final _FakeService service = _FakeService(
        devices: <AudioOutputDevice>[
          AudioOutputDevice.systemDefault,
          builtIn,
          headset,
        ],
      );
      final InMemoryPlaybackPreferences preferences =
          InMemoryPlaybackPreferences();
      final ProviderContainer container = containerFor(service, preferences);
      await container.read(audioOutputControllerProvider.future);
      final AudioOutputController controller =
          container.read(audioOutputControllerProvider.notifier);

      service.holdRouting = true;
      final Future<void> first = controller.select(builtIn);
      final Future<void> second = controller.select(headset);

      // Release the first route only once both gestures are in flight, and let
      // it finish last if the calls were not serialized.
      await Future<void>.delayed(Duration.zero);
      expect(service.pendingRoutes, hasLength(1),
          reason: 'the second choice must wait for the first');
      service.holdRouting = false;
      service.pendingRoutes.single.complete();
      await Future.wait(<Future<void>>[first, second]);

      expect(service.routed, <AudioOutputDevice>[builtIn, headset]);
      expect(await preferences.audioOutputDeviceId(), headset.id);
      expect(
        container.read(audioOutputControllerProvider).requireValue.selected,
        headset,
      );
    });
  });
}
