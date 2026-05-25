import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/cast_state.dart';
import 'package:linthra/features/player/cast/cast_devices_sheet.dart';
import 'package:linthra/features/player/cast/cast_providers.dart';

import 'fake_cast_service.dart';

Future<void> _pumpSheet(WidgetTester tester, FakeCastService service) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [castServiceProvider.overrideWithValue(service)],
      child: const MaterialApp(home: Scaffold(body: CastDevicesSheet())),
    ),
  );
  // A single extra frame runs the post-frame discovery kickoff. We avoid
  // pumpAndSettle because the searching/connecting states show a
  // CircularProgressIndicator, whose animation never settles.
  await tester.pump();
}

const _device = CastDevice(id: 'd1', name: 'Living Room');

void main() {
  group('CastDevicesSheet states', () {
    testWidgets('searching: shows a spinner and a friendly message',
        (tester) async {
      await _pumpSheet(
        tester,
        FakeCastService(
          initial: const CastState(availability: CastAvailability.discovering),
        ),
      );

      expect(find.text('Searching for devices…'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('available devices render as a list', (tester) async {
      await _pumpSheet(
        tester,
        FakeCastService(
          initial: const CastState(
            availability: CastAvailability.idle,
            devices: <CastDevice>[_device],
          ),
        ),
      );

      expect(find.text('Living Room'), findsOneWidget);
    });

    testWidgets('connecting: shows progress and the target device name',
        (tester) async {
      await _pumpSheet(
        tester,
        FakeCastService(
          initial: const CastState(
            availability: CastAvailability.connecting,
            connectedDevice: _device,
          ),
        ),
      );

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('Connecting to Living Room…'), findsOneWidget);
    });

    testWidgets('connected with a notice shows the limitation message',
        (tester) async {
      await _pumpSheet(
        tester,
        FakeCastService(
          initial: const CastState(
            availability: CastAvailability.connected,
            devices: <CastDevice>[_device],
            connectedDevice: _device,
            message: 'This track is a local file.',
          ),
        ),
      );

      expect(find.text('This track is a local file.'), findsOneWidget);
      expect(find.text('Disconnect'), findsOneWidget);
    });

    testWidgets('disconnect delegates to the service', (tester) async {
      final service = FakeCastService(
        initial: const CastState(
          availability: CastAvailability.connected,
          devices: <CastDevice>[_device],
          connectedDevice: _device,
        ),
      );
      await _pumpSheet(tester, service);

      await tester.tap(find.text('Disconnect'));
      await tester.pump();

      expect(service.disconnects, 1);
    });

    testWidgets('no devices: shows a friendly empty state', (tester) async {
      await _pumpSheet(
        tester,
        FakeCastService(
          initial: const CastState(availability: CastAvailability.idle),
        ),
      );

      expect(find.text('No devices found'), findsOneWidget);
      expect(
        find.textContaining('same Wi-Fi network'),
        findsOneWidget,
      );
    });

    testWidgets('error: shows the message and a Search again retry',
        (tester) async {
      final service = FakeCastService(
        initial: const CastState(
          availability: CastAvailability.error,
          message: "Couldn't search for cast devices. Check your Wi-Fi.",
        ),
      );
      await _pumpSheet(tester, service);

      expect(
        find.textContaining("Couldn't search for cast devices"),
        findsOneWidget,
      );

      final before = service.discoveryStarts;
      await tester.tap(find.text('Search again'));
      await tester.pump();

      expect(service.discoveryStarts, before + 1);
    });
  });

  group('Cast volume controls', () {
    CastState connected({
      double? volume,
      bool muted = false,
      bool supportsVolumeControl = false,
    }) =>
        CastState(
          availability: CastAvailability.connected,
          devices: const <CastDevice>[_device],
          connectedDevice: _device,
          volume: volume,
          muted: muted,
          supportsVolumeControl: supportsVolumeControl,
        );

    testWidgets('hidden when no device is connected', (tester) async {
      await _pumpSheet(
        tester,
        FakeCastService(
          initial: const CastState(
            availability: CastAvailability.idle,
            devices: <CastDevice>[_device],
          ),
        ),
      );

      expect(find.text('Cast volume'), findsNothing);
      expect(find.byType(Slider), findsNothing);
    });

    testWidgets('renders a slider when connected and supported',
        (tester) async {
      await _pumpSheet(
        tester,
        FakeCastService(
          initial: connected(volume: 0.4, supportsVolumeControl: true),
        ),
      );

      expect(find.text('Cast volume'), findsOneWidget);
      final slider = tester.widget<Slider>(find.byType(Slider));
      expect(slider.value, 0.4);
      expect(slider.onChanged, isNotNull);
    });

    testWidgets('slider release calls CastService.setVolume', (tester) async {
      final service = FakeCastService(
        initial: connected(volume: 0.2, supportsVolumeControl: true),
      );
      await _pumpSheet(tester, service);

      // Invoke the slider's commit callback directly — a deterministic stand-in
      // for a drag-and-release at that level.
      tester.widget<Slider>(find.byType(Slider)).onChangeEnd!(0.75);
      await tester.pump();

      expect(service.volumeRequests, <double>[0.75]);
    });

    testWidgets('mute button calls CastService.setMuted', (tester) async {
      final service = FakeCastService(
        initial: connected(volume: 0.5, supportsVolumeControl: true),
      );
      await _pumpSheet(tester, service);

      await tester.tap(find.byIcon(Icons.volume_up));
      await tester.pump();

      expect(service.muteRequests, <bool>[true]);
    });

    testWidgets('unsupported control shows a friendly disabled state',
        (tester) async {
      await _pumpSheet(
        tester,
        FakeCastService(initial: connected(supportsVolumeControl: false)),
      );

      // The section is still present and stable, but the slider is disabled and
      // an honest note explains why.
      expect(find.text('Cast volume'), findsOneWidget);
      expect(
        find.textContaining("doesn't support volume control"),
        findsOneWidget,
      );
      expect(tester.widget<Slider>(find.byType(Slider)).onChanged, isNull);
    });

    testWidgets('a CastState volume update refreshes the slider',
        (tester) async {
      final service = FakeCastService(
        initial: connected(volume: 0.3, supportsVolumeControl: true),
      );
      await _pumpSheet(tester, service);
      expect(tester.widget<Slider>(find.byType(Slider)).value, 0.3);

      service.emit(connected(volume: 0.9, supportsVolumeControl: true));
      // One frame for the StreamProvider to deliver the event, one to rebuild.
      await tester.pump();
      await tester.pump();

      expect(tester.widget<Slider>(find.byType(Slider)).value, 0.9);
    });

    testWidgets('a muted receiver shows the muted icon and a zeroed slider',
        (tester) async {
      await _pumpSheet(
        tester,
        FakeCastService(
          initial:
              connected(volume: 0.6, muted: true, supportsVolumeControl: true),
        ),
      );

      expect(find.byIcon(Icons.volume_off), findsOneWidget);
      expect(tester.widget<Slider>(find.byType(Slider)).value, 0.0);
    });
  });
}
