import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/cast_state.dart';
import 'package:linthra/core/services/cast/unavailable_cast_service.dart';

void main() {
  group('UnavailableCastService', () {
    test('reports the unavailable state', () {
      final service = UnavailableCastService();
      addTearDown(service.dispose);

      expect(service.state, CastState.unavailable);
      expect(service.state.isAvailable, isFalse);
      expect(service.state.isConnected, isFalse);
      expect(service.state.devices, isEmpty);
    });

    test('the stream emits the unavailable state', () async {
      final service = UnavailableCastService();
      addTearDown(service.dispose);

      await expectLater(service.stateStream, emits(CastState.unavailable));
    });

    test('every command is a safe no-op (never fakes a connection)', () async {
      final service = UnavailableCastService();
      addTearDown(service.dispose);

      await service.startDiscovery();
      await service.connect(const CastDevice(id: 'x', name: 'Nope'));
      await service.disconnect();
      await service.stopDiscovery();

      // Nothing changed: still unavailable, still nothing connected.
      expect(service.state, CastState.unavailable);
      expect(service.state.connectedDevice, isNull);
    });
  });
}
