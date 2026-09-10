import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/audio_output_device.dart';
import 'package:linthra/core/services/audio_output_device_service.dart';
import 'package:linthra/data/repositories/audio_output_device_service_provider.dart';
import 'package:linthra/data/repositories/in_memory_playback_preferences.dart';
import 'package:linthra/data/repositories/playback_preferences_provider.dart';
import 'package:linthra/features/settings/playback/audio_output_settings_section.dart';

class _FakeService implements AudioOutputDeviceService {
  _FakeService({this.isSupported = true, List<AudioOutputDevice>? devices})
      : available = devices ?? <AudioOutputDevice>[];

  @override
  final bool isSupported;

  final List<AudioOutputDevice> available;
  final List<AudioOutputDevice> routed = <AudioOutputDevice>[];
  bool routingSucceeds = true;

  @override
  Future<List<AudioOutputDevice>> devices() async => available;

  @override
  Future<bool> select(AudioOutputDevice device) async {
    if (!routingSucceeds) return false;
    routed.add(device);
    return true;
  }

  final StreamController<List<AudioOutputDevice>> changes =
      StreamController<List<AudioOutputDevice>>.broadcast();

  @override
  Stream<List<AudioOutputDevice>> get deviceChanges => changes.stream;
}

void main() {
  const AudioOutputDevice headset = AudioOutputDevice(
    id: 'pipewire/alsa_output.usb-headset',
    label: 'USB Headset',
  );
  const AudioOutputDevice unstable = AudioOutputDevice(
    id: 'alsa/hw:2,0',
    label: 'Second card',
  );

  Future<InMemoryPlaybackPreferences> pump(
    WidgetTester tester,
    _FakeService service, {
    String? savedDeviceId,
  }) async {
    final InMemoryPlaybackPreferences preferences =
        InMemoryPlaybackPreferences(audioOutputDeviceId: savedDeviceId);
    final ProviderContainer container = ProviderContainer(
      overrides: <Override>[
        audioOutputDeviceServiceProvider.overrideWithValue(service),
        playbackPreferencesProvider.overrideWithValue(preferences),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(body: AudioOutputSettingsSection()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return preferences;
  }

  testWidgets('renders nothing where the system owns output routing',
      (WidgetTester tester) async {
    await pump(tester, _FakeService(isSupported: false));

    expect(find.text('Audio output'), findsNothing);
    expect(find.byType(Card), findsNothing);
  });

  testWidgets('lists the host outputs once the page is opened',
      (WidgetTester tester) async {
    final _FakeService service = _FakeService(
      devices: <AudioOutputDevice>[AudioOutputDevice.systemDefault, headset],
    );

    await pump(tester, service);

    expect(find.text('Audio output'), findsOneWidget);
    // The dropdown renders its selected item, so "System default" is on screen.
    expect(find.text('System default'), findsWidgets);
    expect(find.byType(DropdownButton<String>), findsOneWidget);
  });

  testWidgets('choosing a device routes playback and stores it',
      (WidgetTester tester) async {
    final _FakeService service = _FakeService(
      devices: <AudioOutputDevice>[AudioOutputDevice.systemDefault, headset],
    );
    final InMemoryPlaybackPreferences preferences = await pump(tester, service);

    await tester.tap(find.byType(DropdownButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('USB Headset').last);
    await tester.pumpAndSettle();

    expect(service.routed, <AudioOutputDevice>[headset]);
    expect(await preferences.audioOutputDeviceId(), headset.id);
  });

  testWidgets('says so when a device cannot be remembered',
      (WidgetTester tester) async {
    final _FakeService service = _FakeService(
      devices: <AudioOutputDevice>[AudioOutputDevice.systemDefault, unstable],
    );
    await pump(tester, service);

    await tester.tap(find.byType(DropdownButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Second card').last);
    await tester.pumpAndSettle();

    expect(find.textContaining('this session'), findsOneWidget);
  });

  testWidgets('warns when the saved device is not available',
      (WidgetTester tester) async {
    final _FakeService service = _FakeService(
      devices: <AudioOutputDevice>[AudioOutputDevice.systemDefault],
    );

    await pump(tester, service, savedDeviceId: headset.id);

    expect(
      find.textContaining('saved output is not available'),
      findsOneWidget,
    );
  });

  testWidgets('is honest when the backend reports no outputs',
      (WidgetTester tester) async {
    await pump(tester, _FakeService());

    expect(find.textContaining('No outputs were reported'), findsOneWidget);
    expect(find.byType(DropdownButton<String>), findsNothing);
  });

  testWidgets('says so when the backend refuses the switch',
      (WidgetTester tester) async {
    final _FakeService service = _FakeService(
      devices: <AudioOutputDevice>[AudioOutputDevice.systemDefault, headset],
    )..routingSucceeds = false;
    final InMemoryPlaybackPreferences preferences = await pump(tester, service);

    await tester.tap(find.byType(DropdownButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('USB Headset').last);
    await tester.pumpAndSettle();

    expect(find.textContaining('could not be used'), findsOneWidget);
    expect(await preferences.audioOutputDeviceId(), isNull);
  });

  group('an output that went away (#403)', () {
    testWidgets('a fallback the backend refused is surfaced with a way out',
        (tester) async {
      final _FakeService service = _FakeService(
        devices: const <AudioOutputDevice>[
          AudioOutputDevice.systemDefault,
          headset,
        ],
      );
      addTearDown(() => service.changes.close());
      await pump(tester, service);

      // The listener is on the headset, then it is unplugged and the backend
      // refuses the system default too.
      await tester.tap(find.text('System default'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(headset.label).last);
      await tester.pumpAndSettle();

      service.routingSucceeds = false;
      service.changes.add(const <AudioOutputDevice>[
        AudioOutputDevice.systemDefault,
      ]);
      await tester.pumpAndSettle();

      expect(find.textContaining('playback may be silent'), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);

      // The retry re-enumerates and re-applies, which is what a recovered
      // backend needs.
      service.routingSucceeds = true;
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();
      expect(find.textContaining('playback may be silent'), findsNothing);
    });

    testWidgets('a plain dropout says the output will be used again',
        (tester) async {
      final _FakeService service = _FakeService(
        devices: const <AudioOutputDevice>[
          AudioOutputDevice.systemDefault,
          headset,
        ],
      );
      addTearDown(() => service.changes.close());
      await pump(tester, service);

      await tester.tap(find.text('System default'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(headset.label).last);
      await tester.pumpAndSettle();

      service.changes.add(const <AudioOutputDevice>[
        AudioOutputDevice.systemDefault,
      ]);
      await tester.pumpAndSettle();

      expect(
        find.textContaining('as soon as it is back'),
        findsOneWidget,
      );
      expect(find.text('Try again'), findsNothing);
    });
  });
}
