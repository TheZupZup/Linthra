import 'dart:async';

import 'package:linthra/core/models/cast_state.dart';
import 'package:linthra/core/services/cast/cast_service.dart';

/// In-memory [CastService] for widget tests: starts in a caller-supplied state,
/// records the commands it receives, and lets a test push new [CastState]s. It
/// stands in for a future real backend so the cast UI can be exercised across
/// availability/connected states without any SDK.
class FakeCastService implements CastService {
  FakeCastService({CastState initial = CastState.unavailable})
      : _state = initial;

  final StreamController<CastState> _states =
      StreamController<CastState>.broadcast();
  CastState _state;

  int discoveryStarts = 0;
  int discoveryStops = 0;
  final List<CastDevice> connectRequests = <CastDevice>[];
  int disconnects = 0;

  void emit(CastState next) {
    _state = next;
    _states.add(next);
  }

  @override
  CastState get state => _state;

  @override
  Stream<CastState> get stateStream => _states.stream;

  @override
  Future<void> startDiscovery() async => discoveryStarts++;

  @override
  Future<void> stopDiscovery() async => discoveryStops++;

  @override
  Future<void> connect(CastDevice device) async => connectRequests.add(device);

  @override
  Future<void> disconnect() async => disconnects++;

  @override
  Future<void> dispose() async {
    await _states.close();
  }
}
