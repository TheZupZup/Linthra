import 'dart:async';

import 'package:linthra/core/models/cast_playback_status.dart';
import 'package:linthra/core/models/cast_state.dart';
import 'package:linthra/core/services/cast/cast_service.dart';

/// In-memory [CastService] for widget/router tests: starts in a caller-supplied
/// state, records the commands it receives, and lets a test push new
/// [CastState]s and [CastPlaybackStatus] updates. It stands in for the real
/// backend so the cast UI and the [ActivePlaybackController] can be exercised
/// across availability/connected/casting states without any SDK.
class FakeCastService implements CastService {
  FakeCastService({
    CastState initial = CastState.unavailable,
    CastPlaybackStatus initialPlayback = CastPlaybackStatus.idle,
  })  : _state = initial,
        _playback = initialPlayback;

  final StreamController<CastState> _states =
      StreamController<CastState>.broadcast();
  final StreamController<CastPlaybackStatus> _playbackStates =
      StreamController<CastPlaybackStatus>.broadcast();
  CastState _state;
  CastPlaybackStatus _playback;

  int discoveryStarts = 0;
  int discoveryStops = 0;
  final List<CastDevice> connectRequests = <CastDevice>[];
  int disconnects = 0;
  int playCount = 0;
  int pauseCount = 0;
  final List<Duration> seeks = <Duration>[];
  int refreshCount = 0;

  void emit(CastState next) {
    _state = next;
    _states.add(next);
  }

  void emitPlayback(CastPlaybackStatus next) {
    _playback = next;
    _playbackStates.add(next);
  }

  @override
  CastState get state => _state;

  @override
  Stream<CastState> get stateStream => _states.stream;

  @override
  CastPlaybackStatus get playbackStatus => _playback;

  @override
  Stream<CastPlaybackStatus> get playbackStream => _playbackStates.stream;

  @override
  Future<void> startDiscovery() async => discoveryStarts++;

  @override
  Future<void> stopDiscovery() async => discoveryStops++;

  @override
  Future<void> connect(CastDevice device) async => connectRequests.add(device);

  @override
  Future<void> disconnect() async => disconnects++;

  @override
  Future<void> play() async => playCount++;

  @override
  Future<void> pause() async => pauseCount++;

  @override
  Future<void> seek(Duration position) async => seeks.add(position);

  @override
  Future<void> refresh() async => refreshCount++;

  @override
  Future<void> dispose() async {
    await _states.close();
    await _playbackStates.close();
  }
}
