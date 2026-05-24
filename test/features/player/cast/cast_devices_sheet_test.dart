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
}
