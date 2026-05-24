import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/cast_state.dart';

void main() {
  group('CastState', () {
    test('the default is the honest unavailable state', () {
      const state = CastState.unavailable;
      expect(state.availability, CastAvailability.unavailable);
      expect(state.isAvailable, isFalse);
      expect(state.isConnected, isFalse);
      expect(state.isConnecting, isFalse);
      expect(state.isDiscovering, isFalse);
      expect(state.hasError, isFalse);
      expect(state.devices, isEmpty);
      expect(state.message, isNull);
      expect(state.isCasting, isFalse);
    });

    test('isCasting marks an active handoff and rides copyWith/equality', () {
      const idle = CastState(availability: CastAvailability.connected);
      final casting = idle.copyWith(isCasting: true);
      expect(idle.isCasting, isFalse);
      expect(casting.isCasting, isTrue);
      // Differing only by isCasting must break equality, so the controller
      // sees the handoff transition.
      expect(casting, isNot(equals(idle)));
    });

    test('availability helpers map to the right value', () {
      expect(
        const CastState(availability: CastAvailability.idle).isAvailable,
        isTrue,
      );
      expect(
        const CastState(availability: CastAvailability.discovering)
            .isDiscovering,
        isTrue,
      );
      expect(
        const CastState(availability: CastAvailability.connecting).isConnecting,
        isTrue,
      );
      expect(
        const CastState(availability: CastAvailability.connected).isConnected,
        isTrue,
      );
      expect(
        const CastState(availability: CastAvailability.error).hasError,
        isTrue,
      );
    });

    test('an error state carries a friendly message', () {
      const state = CastState(
        availability: CastAvailability.error,
        message: 'No cast devices found.',
      );
      expect(state.hasError, isTrue);
      expect(state.message, 'No cast devices found.');
    });

    test('equality compares availability, devices, connected device, message',
        () {
      const a = CastDevice(id: 'a', name: 'Living Room');
      const s1 = CastState(
        availability: CastAvailability.connected,
        devices: <CastDevice>[a],
        connectedDevice: a,
        message: 'note',
      );
      const s2 = CastState(
        availability: CastAvailability.connected,
        devices: <CastDevice>[a],
        connectedDevice: a,
        message: 'note',
      );
      const different = CastState(
        availability: CastAvailability.connected,
        devices: <CastDevice>[a],
        connectedDevice: a,
        message: 'other note',
      );

      expect(s1, equals(s2));
      expect(s1.hashCode, s2.hashCode);
      expect(s1, isNot(equals(different)));
    });

    test('CastDevice identity is its id, so list reordering is stable', () {
      const a1 = CastDevice(id: 'x', name: 'Kitchen');
      const a2 = CastDevice(id: 'x', name: 'Kitchen (renamed)');
      const b = CastDevice(id: 'y', name: 'Kitchen');
      expect(a1, equals(a2));
      expect(a1, isNot(equals(b)));
    });
  });
}
