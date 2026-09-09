import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/cast_state.dart';
import 'package:linthra/core/services/cast/cast_containment.dart';
import 'package:linthra/core/services/cast/cast_receiver_pinning.dart';
import 'package:linthra/data/repositories/cast_receiver_pin_store_provider.dart';
import 'package:linthra/features/player/cast/cast_devices_sheet.dart';
import 'package:linthra/features/player/cast/cast_providers.dart';

import 'fake_cast_service.dart';

Future<void> _pumpSheet(
  WidgetTester tester,
  FakeCastService service, {
  CastReceiverPinStore? pins,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        castServiceProvider.overrideWithValue(service),
        if (pins != null) castReceiverPinStoreProvider.overrideWithValue(pins),
      ],
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
  group('CastDevicesSheet security containment', () {
    testWidgets('says casting is temporarily off, not unsupported here',
        (tester) async {
      await _pumpSheet(
        tester,
        FakeCastService(initial: CastContainment.state),
      );

      expect(find.text('Casting is temporarily unavailable'), findsOneWidget);
      expect(find.text(CastContainment.userMessage), findsOneWidget);
      // The platform copy would be wrong on the phones this actually affects.
      expect(find.textContaining('needs Android or iOS'), findsNothing);
    });

    testWidgets('starts no discovery while contained', (tester) async {
      final service = FakeCastService(initial: CastContainment.state);
      await _pumpSheet(tester, service);
      await tester.pump(const Duration(seconds: 1));

      // Opening the picker is the UI's one chance to kick off a scan; an
      // unavailable service must never get that call.
      expect(service.discoveryStarts, 0);
      expect(service.connectRequests, isEmpty);
    });

    testWidgets('offers no device to connect to', (tester) async {
      final service = FakeCastService(initial: CastContainment.state);
      await _pumpSheet(tester, service);

      expect(find.byType(ListTile), findsNothing);
      expect(find.text('Search again'), findsNothing);
    });
  });

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

  /// Layer 3 of docs/cast-hardened-design.md reaches the user here. A receiver
  /// that authenticated but is not the one this device was pinned to gets
  /// refused with [CastTrustFailureKind.changedReceiver], whose message tells
  /// the user to forget the device "in the cast list". These tests are about
  /// that sentence being true: the list has to still be on screen, and it has
  /// to carry the action.
  group('CastDevicesSheet forgetting a receiver', () {
    const String changedReceiver =
        "This isn't the same device Linthra cast to before, so it stopped. If "
        'you replaced it, forget it in the cast list and try again.';

    CastState refused() => const CastState(
          availability: CastAvailability.error,
          devices: <CastDevice>[_device],
          message: changedReceiver,
        );

    Future<CastReceiverPinStore> pinned() async {
      final InMemoryCastReceiverPinStore pins = InMemoryCastReceiverPinStore();
      await pins.remember(_device.id, 'sha256aabb');
      return pins;
    }

    testWidgets('a refusal keeps the device list it points the user at',
        (tester) async {
      await _pumpSheet(
        tester,
        FakeCastService(initial: refused()),
        pins: await pinned(),
      );

      expect(find.text(changedReceiver), findsOneWidget);
      expect(find.text('Living Room'), findsOneWidget);
      // The empty state would have replaced the one place the message names.
      expect(find.text('No cast devices'), findsNothing);
    });

    testWidgets('the device can still be retried from the refusal',
        (tester) async {
      final service = FakeCastService(initial: refused());
      await _pumpSheet(tester, service, pins: await pinned());

      await tester.tap(find.text('Living Room'));
      await tester.pump();

      expect(service.connectRequests, <CastDevice>[_device]);
    });

    testWidgets('offers nothing to forget for a device with no pin',
        (tester) async {
      await _pumpSheet(
        tester,
        FakeCastService(initial: refused()),
        pins: InMemoryCastReceiverPinStore(),
      );
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.more_vert), findsNothing);
    });

    testWidgets('forgetting is confirmed before the pin is dropped',
        (tester) async {
      final InMemoryCastReceiverPinStore pins =
          await pinned() as InMemoryCastReceiverPinStore;
      await _pumpSheet(tester, FakeCastService(initial: refused()), pins: pins);
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Forget this device'));
      await tester.pumpAndSettle();

      // The dialog is up and nothing has happened yet: dropping a pin weakens
      // a check the user cannot see, so a stray tap must not be enough.
      expect(find.text('Forget this device?'), findsOneWidget);
      expect(pins.pins[_device.id], 'sha256aabb');

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(pins.pins[_device.id], 'sha256aabb');
    });

    testWidgets('confirming drops the pin and says so', (tester) async {
      final InMemoryCastReceiverPinStore pins =
          await pinned() as InMemoryCastReceiverPinStore;
      await _pumpSheet(tester, FakeCastService(initial: refused()), pins: pins);
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Forget this device'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Forget'));
      await tester.pumpAndSettle();

      expect(pins.pins, isEmpty);
      expect(
        find.textContaining('will check Living Room again'),
        findsOneWidget,
      );
      // The action is gone with the pin it cleared.
      expect(find.byIcon(Icons.more_vert), findsNothing);
    });

    testWidgets('a store that cannot answer still offers the way out',
        (tester) async {
      // Refusing to draw the recovery because the store is unhappy would
      // strand a user whose only way forward is to clear a pin.
      await _pumpSheet(
        tester,
        FakeCastService(initial: refused()),
        pins: _BrokenPinStore(),
      );
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.more_vert), findsOneWidget);
    });

    testWidgets('a forget that fails says so instead of claiming success',
        (tester) async {
      await _pumpSheet(
        tester,
        FakeCastService(initial: refused()),
        pins: _BrokenPinStore(),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Forget this device'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Forget'));
      await tester.pumpAndSettle();

      expect(
          find.textContaining("couldn't forget Living Room"), findsOneWidget);
    });

    testWidgets('the connected device is not offered a forget', (tester) async {
      // The live session already proved itself, so dropping its pin would
      // change nothing now and read as if it had.
      final InMemoryCastReceiverPinStore pins =
          await pinned() as InMemoryCastReceiverPinStore;
      await _pumpSheet(
        tester,
        FakeCastService(
          initial: const CastState(
            availability: CastAvailability.connected,
            devices: <CastDevice>[_device],
            connectedDevice: _device,
          ),
        ),
        pins: pins,
      );
      await tester.pumpAndSettle();

      expect(find.text('Disconnect'), findsOneWidget);
      expect(find.byIcon(Icons.more_vert), findsNothing);
    });
  });
}

/// A pin store that fails at everything, standing in for storage the app cannot
/// reach. The sheet must neither hide the recovery nor pretend it worked.
class _BrokenPinStore implements CastReceiverPinStore {
  @override
  Future<String?> pinFor(String deviceId) async =>
      throw StateError('unavailable');

  @override
  Future<void> remember(String deviceId, String fingerprint) async =>
      throw StateError('unavailable');

  @override
  Future<void> forget(String deviceId) async => throw StateError('unavailable');
}
