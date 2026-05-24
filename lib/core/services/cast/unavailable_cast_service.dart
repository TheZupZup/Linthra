import 'dart:async';

import '../../models/cast_state.dart';
import 'cast_service.dart';

/// The shipped [CastService]: casting is **not implemented** in this build, so
/// it honestly reports [CastAvailability.unavailable] and no-ops every command.
///
/// It exists so the now-playing screen can show a real cast button backed by a
/// real (if inert) service today, and so swapping in a Chromecast/Cast SDK
/// implementation later is a one-line provider change with no UI edits. It never
/// invents devices or pretends to connect.
class UnavailableCastService implements CastService {
  final StreamController<CastState> _states =
      StreamController<CastState>.broadcast();

  @override
  CastState get state => CastState.unavailable;

  @override
  Stream<CastState> get stateStream =>
      Stream<CastState>.value(state).asBroadcastStream();

  @override
  Future<void> startDiscovery() async {}

  @override
  Future<void> stopDiscovery() async {}

  @override
  Future<void> connect(CastDevice device) async {}

  @override
  Future<void> disconnect() async {}

  @override
  Future<void> dispose() async {
    await _states.close();
  }
}
