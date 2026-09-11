import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/audio_output_device.dart';
import 'package:linthra/core/services/audio_output_device_service.dart';
import 'package:linthra/data/repositories/audio_output_device_service_provider.dart';
import 'package:linthra/data/repositories/in_memory_playback_preferences.dart';
import 'package:linthra/data/repositories/playback_preferences_provider.dart';
import 'package:linthra/features/settings/playback/audio_output_controller.dart';

/// Linux audio-device hotplug recovery (#403).
///
/// Everything here drives the *policy*: the backend is a fake that reports
/// whatever device list the scenario says the host has, so a headphone unplug,
/// a Bluetooth dropout and reconnect, an HDMI sink appearing and a system
/// default moving are all deterministic and run on any machine.

/// A stand-in for libmpv that can also republish its device list.
class _FakeService implements AudioOutputDeviceService {
  _FakeService({this.isSupported = true, List<AudioOutputDevice>? devices})
      : available = devices ?? <AudioOutputDevice>[];

  @override
  final bool isSupported;

  List<AudioOutputDevice> available;
  final List<AudioOutputDevice> routed = <AudioOutputDevice>[];

  /// Device ids the backend refuses to route to, standing in for a sink that
  /// is listed but cannot be opened.
  final Set<String> refuses = <String>{};

  int enumerations = 0;
  int listenCount = 0;

  final StreamController<List<AudioOutputDevice>> _changes =
      StreamController<List<AudioOutputDevice>>.broadcast();

  @override
  Future<List<AudioOutputDevice>> devices() async {
    enumerations++;
    return available;
  }

  @override
  Future<bool> select(AudioOutputDevice device) async {
    if (refuses.contains(device.id)) return false;
    routed.add(device);
    return true;
  }

  @override
  Stream<List<AudioOutputDevice>> get deviceChanges {
    listenCount++;
    return _changes.stream;
  }

  /// The host's outputs changed: the new list is what enumeration reports from
  /// now on *and* what the backend republishes, the way a real unplug does
  /// both.
  void hotplug(List<AudioOutputDevice> devices) {
    available = devices;
    _changes.add(devices);
  }

  /// Whether anything is currently watching, so a test can assert the
  /// subscription is actually released.
  bool get isWatched => _changes.hasListener;

  Future<void> dispose() => _changes.close();
}

const AudioOutputDevice _builtIn = AudioOutputDevice(
  id: 'pipewire/alsa_output.pci-0000_00_1f.3.analog-stereo',
  label: 'Built-in Audio',
);
const AudioOutputDevice _headphones = AudioOutputDevice(
  id: 'pipewire/alsa_output.pci-0000_00_1f.3.analog-stereo.headphones',
  label: 'Headphones',
);
const AudioOutputDevice _bluetooth = AudioOutputDevice(
  id: 'pipewire/bluez_output.AC_12_2F_3D_4E_5F.1',
  label: 'Living room speaker',
);
const AudioOutputDevice _hdmi = AudioOutputDevice(
  id: 'pipewire/alsa_output.pci-0000_01_00.1.hdmi-stereo',
  label: 'HDMI Audio',
);

List<AudioOutputDevice> _hostWith(List<AudioOutputDevice> devices) =>
    <AudioOutputDevice>[AudioOutputDevice.systemDefault, ...devices];

void main() {
  late _FakeService service;
  late InMemoryPlaybackPreferences preferences;
  late ProviderContainer container;

  /// Builds a controller already routed to [chosen], the way it is after the
  /// listener picks an output in Settings.
  Future<void> chooseOutput(AudioOutputDevice chosen) async {
    await container.read(audioOutputControllerProvider.future);
    await container.read(audioOutputControllerProvider.notifier).select(chosen);
  }

  AudioOutputSettingsState currentState() =>
      container.read(audioOutputControllerProvider).valueOrNull ??
      const AudioOutputSettingsState();

  Future<void> hotplug(List<AudioOutputDevice> devices) async {
    service.hotplug(devices);
    // Let the broadcast reach the controller and its queued work settle.
    await pumpEventQueue();
  }

  void setUpWith({
    List<AudioOutputDevice>? devices,
    String? savedDeviceId,
  }) {
    service =
        _FakeService(devices: devices ?? _hostWith(<AudioOutputDevice>[]));
    preferences =
        InMemoryPlaybackPreferences(audioOutputDeviceId: savedDeviceId);
    container = ProviderContainer(
      overrides: <Override>[
        audioOutputDeviceServiceProvider.overrideWithValue(service),
        playbackPreferencesProvider.overrideWithValue(preferences),
      ],
    );
    addTearDown(container.dispose);
    addTearDown(service.dispose);
  }

  group('the watch itself', () {
    test(
        'exactly one subscription is opened, and it is closed with the '
        'notifier', () async {
      setUpWith();
      await container.read(audioOutputControllerProvider.future);
      expect(service.listenCount, 1);

      // A second read must not open another: two subscriptions would mean one
      // unplug handled twice, and one recovery becoming two.
      await container.read(audioOutputControllerProvider.future);
      expect(service.listenCount, 1);

      expect(service.isWatched, isTrue);
      container.dispose();
      await pumpEventQueue();
      expect(service.isWatched, isFalse,
          reason: 'a disposed notifier must not keep reacting to hotplug');
    });

    test('an unsupported backend is never watched', () async {
      service = _FakeService(isSupported: false);
      preferences = InMemoryPlaybackPreferences();
      container = ProviderContainer(
        overrides: <Override>[
          audioOutputDeviceServiceProvider.overrideWithValue(service),
          playbackPreferencesProvider.overrideWithValue(preferences),
        ],
      );
      addTearDown(container.dispose);
      addTearDown(service.dispose);

      await container.read(audioOutputControllerProvider.future);
      expect(service.listenCount, 0);
    });
  });

  group('playback continues transparently where it can', () {
    test('a device appearing does not move playback', () async {
      setUpWith(devices: _hostWith(<AudioOutputDevice>[_builtIn]));
      await chooseOutput(_builtIn);
      final int routedBefore = service.routed.length;

      // A monitor wakes and its HDMI sink shows up.
      await hotplug(_hostWith(<AudioOutputDevice>[_builtIn, _hdmi]));

      expect(service.routed.length, routedBefore,
          reason: 'nothing was re-routed: audio never had to move');
      expect(currentState().selected, _builtIn);
      expect(currentState().devices, contains(_hdmi));
      expect(currentState().savedDeviceUnavailable, isFalse);
    });

    test('an unrelated device disappearing does not move playback', () async {
      setUpWith(devices: _hostWith(<AudioOutputDevice>[_builtIn, _hdmi]));
      await chooseOutput(_builtIn);
      final int routedBefore = service.routed.length;

      await hotplug(_hostWith(<AudioOutputDevice>[_builtIn]));

      expect(service.routed.length, routedBefore);
      expect(currentState().selected, _builtIn);
      expect(currentState().savedDeviceUnavailable, isFalse);
    });

    test('the system default moving is the system\'s business, not ours',
        () async {
      // Nothing was chosen, so playback follows the host by itself. Re-routing
      // here would be an audible interruption caused only by the recovery code.
      setUpWith(devices: _hostWith(<AudioOutputDevice>[_builtIn]));
      await container.read(audioOutputControllerProvider.future);

      await hotplug(_hostWith(<AudioOutputDevice>[_builtIn, _headphones]));

      expect(service.routed, isEmpty);
      expect(currentState().selected, AudioOutputDevice.systemDefault);
      expect(currentState().devices, contains(_headphones));
    });
  });

  group('the selected output going away', () {
    test('wired headphones unplugged: playback falls back and says so',
        () async {
      setUpWith(devices: _hostWith(<AudioOutputDevice>[_builtIn, _headphones]));
      await chooseOutput(_headphones);

      await hotplug(_hostWith(<AudioOutputDevice>[_builtIn]));

      expect(service.routed.last, AudioOutputDevice.systemDefault);
      expect(currentState().selected, AudioOutputDevice.systemDefault);
      expect(currentState().savedDeviceUnavailable, isTrue);
      expect(currentState().outputRecoveryFailed, isFalse);
    });

    test('the preference is kept, so the device coming back can restore it',
        () async {
      setUpWith(devices: _hostWith(<AudioOutputDevice>[_builtIn, _bluetooth]));
      await chooseOutput(_bluetooth);
      expect(await preferences.audioOutputDeviceId(), _bluetooth.id);

      await hotplug(_hostWith(<AudioOutputDevice>[_builtIn]));

      expect(await preferences.audioOutputDeviceId(), _bluetooth.id,
          reason: 'a dropout is not a reason to forget the listener\'s choice');
    });

    test('a refused fallback is surfaced, not left silently muted', () async {
      setUpWith(devices: _hostWith(<AudioOutputDevice>[_builtIn, _headphones]));
      await chooseOutput(_headphones);
      service.refuses.add(AudioOutputDevice.systemDefaultId);

      await hotplug(_hostWith(<AudioOutputDevice>[_builtIn]));

      expect(currentState().outputRecoveryFailed, isTrue);
      expect(currentState().savedDeviceUnavailable, isTrue);
      // Playback is still shown on the output it was on, because that is where
      // the backend left it.
      expect(currentState().selected, _headphones);
    });

    test('retrying after the backend recovers clears the failure', () async {
      setUpWith(devices: _hostWith(<AudioOutputDevice>[_builtIn, _headphones]));
      await chooseOutput(_headphones);
      service.refuses.add(AudioOutputDevice.systemDefaultId);
      await hotplug(_hostWith(<AudioOutputDevice>[_builtIn]));
      expect(currentState().outputRecoveryFailed, isTrue);

      service.refuses.clear();
      await hotplug(_hostWith(<AudioOutputDevice>[_builtIn]));

      expect(currentState().outputRecoveryFailed, isFalse);
      expect(currentState().selected, AudioOutputDevice.systemDefault);
    });
  });

  group('reconnecting', () {
    test('a Bluetooth speaker coming back takes playback back', () async {
      setUpWith(devices: _hostWith(<AudioOutputDevice>[_builtIn, _bluetooth]));
      await chooseOutput(_bluetooth);

      await hotplug(_hostWith(<AudioOutputDevice>[_builtIn]));
      expect(currentState().selected, AudioOutputDevice.systemDefault);

      await hotplug(_hostWith(<AudioOutputDevice>[_builtIn, _bluetooth]));

      expect(currentState().selected, _bluetooth);
      expect(currentState().savedDeviceUnavailable, isFalse);
      expect(currentState().outputRecoveryFailed, isFalse);
    });

    test('a reconnect routes once, never twice', () async {
      setUpWith(devices: _hostWith(<AudioOutputDevice>[_builtIn, _bluetooth]));
      await chooseOutput(_bluetooth);
      await hotplug(_hostWith(<AudioOutputDevice>[_builtIn]));
      await hotplug(_hostWith(<AudioOutputDevice>[_builtIn, _bluetooth]));

      final int routesBack = service.routed
          .where((AudioOutputDevice d) => d.id == _bluetooth.id)
          .length;
      // Once when the listener chose it, once when it came back. Not more.
      expect(routesBack, 2);

      // A repeat of the same list changes nothing at all.
      final int before = service.routed.length;
      await hotplug(_hostWith(<AudioOutputDevice>[_builtIn, _bluetooth]));
      expect(service.routed.length, before);
    });

    test('a flapping device survives repeated cycles', () async {
      setUpWith(devices: _hostWith(<AudioOutputDevice>[_builtIn, _bluetooth]));
      await chooseOutput(_bluetooth);

      for (int i = 0; i < 5; i++) {
        await hotplug(_hostWith(<AudioOutputDevice>[_builtIn]));
        expect(currentState().selected, AudioOutputDevice.systemDefault);
        expect(currentState().savedDeviceUnavailable, isTrue);

        await hotplug(_hostWith(<AudioOutputDevice>[_builtIn, _bluetooth]));
        expect(currentState().selected, _bluetooth);
        expect(currentState().savedDeviceUnavailable, isFalse);
      }

      expect(service.listenCount, 1, reason: 'still one subscription');
      expect(await preferences.audioOutputDeviceId(), _bluetooth.id);
    });
  });

  group('the list the UI shows follows the host', () {
    test('every change republishes the real device list', () async {
      setUpWith(devices: _hostWith(<AudioOutputDevice>[_builtIn]));
      await chooseOutput(_builtIn);

      await hotplug(
          _hostWith(<AudioOutputDevice>[_builtIn, _hdmi, _bluetooth]));
      expect(
          currentState().devices,
          _hostWith(<AudioOutputDevice>[
            _builtIn,
            _hdmi,
            _bluetooth,
          ]));
      expect(currentState().hasEnumerated, isTrue);

      await hotplug(_hostWith(<AudioOutputDevice>[_builtIn]));
      expect(currentState().devices, _hostWith(<AudioOutputDevice>[_builtIn]));
    });

    test('an empty report is not treated as "every output is gone"', () async {
      // A backend that could not be asked is not evidence the sink vanished;
      // routing away on it would move audio the listener is still using.
      setUpWith(devices: _hostWith(<AudioOutputDevice>[_builtIn, _headphones]));
      await chooseOutput(_headphones);
      final int routedBefore = service.routed.length;

      await hotplug(const <AudioOutputDevice>[]);

      expect(service.routed.length, routedBefore);
      expect(currentState().selected, _headphones);
      expect(currentState().savedDeviceUnavailable, isFalse);
    });
  });

  group('startup rules from #402 still hold', () {
    test('a saved device never seen here is still forgotten', () async {
      // The "saved on another machine" rule: nothing has played on it this
      // session, so the preference is dropped rather than retried every launch.
      setUpWith(
        devices: _hostWith(<AudioOutputDevice>[_builtIn]),
        savedDeviceId: _headphones.id,
      );

      await container.read(audioOutputControllerProvider.future);

      expect(await preferences.audioOutputDeviceId(), isNull);
      expect(currentState().savedDeviceUnavailable, isTrue);
    });

    test('a refresh during a dropout keeps a device that worked this session',
        () async {
      setUpWith(devices: _hostWith(<AudioOutputDevice>[_builtIn, _bluetooth]));
      await chooseOutput(_bluetooth);
      await hotplug(_hostWith(<AudioOutputDevice>[_builtIn]));

      await container.read(audioOutputControllerProvider.notifier).refresh();

      expect(await preferences.audioOutputDeviceId(), _bluetooth.id);
    });
  });
}
