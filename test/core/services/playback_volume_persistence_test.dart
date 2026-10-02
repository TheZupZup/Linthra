import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/repositories/playback_preferences.dart';
import 'package:linthra/core/services/playback_volume_persistence.dart';
import 'package:linthra/data/repositories/in_memory_playback_preferences.dart';

import '../../features/player/fake_playback_controller.dart';

/// Preferences that hand back exactly what a test put in the store, including
/// the values a healthy app would never write — that is the point.
class _RawPreferences implements PlaybackPreferences {
  _RawPreferences(this.stored);

  double stored;
  final List<double> writes = <double>[];
  bool throwOnRead = false;

  /// When set, a write parks here until the test completes it — so a test can
  /// hold a save in flight and prove shutdown waits for it.
  Completer<void>? writeGate;

  @override
  Future<bool> normalizeVolume() async => false;

  @override
  Future<void> setNormalizeVolume(bool value) async {}

  @override
  Future<double> volume() async {
    if (throwOnRead) throw StateError('unreadable');
    return stored;
  }

  @override
  Future<String?> audioOutputDeviceId() async => null;

  @override
  Future<void> setAudioOutputDeviceId(String? id) async {}

  @override
  Future<bool?> autoSkipUnplayable() async => null;

  @override
  Future<void> setAutoSkipUnplayable(bool value) async {}

  @override
  Future<void> setVolume(double value) async {
    final Completer<void>? gate = writeGate;
    if (gate != null) await gate.future;
    stored = value;
    writes.add(value);
  }
}

void main() {
  const Duration debounce = Duration(milliseconds: 10);
  Future<void> pastDebounce() =>
      Future<void>.delayed(const Duration(milliseconds: 40));

  PlaybackVolumePersistence attach(
    PlaybackPreferences preferences,
    FakePlaybackController controller,
  ) {
    final PlaybackVolumePersistence persistence = PlaybackVolumePersistence(
      preferences: preferences,
      controller: controller,
      playbackStates: controller.stateStream,
      saveDebounce: debounce,
    );
    addTearDown(persistence.dispose);
    return persistence;
  }

  test('restores the stored level onto the controller', () async {
    final controller = FakePlaybackController();
    addTearDown(controller.dispose);
    final persistence =
        attach(InMemoryPlaybackPreferences(volume: 0.3), controller);

    await persistence.restore();

    expect(controller.state.volume, 0.3);
  });

  test('an out-of-range stored level is corrected, never applied raw',
      () async {
    final controller = FakePlaybackController();
    addTearDown(controller.dispose);
    final preferences = _RawPreferences(9.5);
    final persistence = attach(preferences, controller);

    await persistence.restore();

    expect(controller.state.volume, 1.0);
  });

  test('a non-finite stored level falls back to full volume', () async {
    final controller = FakePlaybackController();
    addTearDown(controller.dispose);
    final persistence = attach(_RawPreferences(double.nan), controller);

    await persistence.restore();

    expect(controller.state.volume, 1.0);
  });

  test('a store that throws leaves playback at full volume', () async {
    final controller = FakePlaybackController();
    addTearDown(controller.dispose);
    final preferences = _RawPreferences(0.5)..throwOnRead = true;
    final persistence = attach(preferences, controller);

    await persistence.restore();

    expect(controller.state.volume, 1.0);
  });

  test('never restores a mute', () async {
    final controller = FakePlaybackController();
    addTearDown(controller.dispose);
    final persistence =
        attach(InMemoryPlaybackPreferences(volume: 0.4), controller);

    await persistence.restore();

    expect(controller.state.muted, isFalse);
  });

  test('a level change is persisted once the burst settles', () async {
    final controller = FakePlaybackController();
    addTearDown(controller.dispose);
    final preferences = _RawPreferences(1.0);
    attach(preferences, controller);

    // A drag: several states in quick succession, one write.
    controller.setVolume(0.9);
    controller.setVolume(0.7);
    controller.setVolume(0.6);
    await pastDebounce();

    expect(preferences.writes, <double>[0.6]);
  });

  test('muting does not overwrite the stored level', () async {
    final controller = FakePlaybackController();
    addTearDown(controller.dispose);
    final preferences = _RawPreferences(1.0);
    attach(preferences, controller);

    controller.setVolume(0.5);
    await pastDebounce();
    controller.setMuted(true);
    await pastDebounce();

    expect(preferences.stored, 0.5);
  });

  test('dispose flushes a level changed just before shutdown', () async {
    final controller = FakePlaybackController();
    addTearDown(controller.dispose);
    final preferences = _RawPreferences(1.0);
    final persistence = attach(preferences, controller);

    controller.setVolume(0.2);
    // Long enough for the state to arrive, not long enough for the debounce:
    // the write is still pending when shutdown starts.
    await Future<void>.delayed(Duration.zero);
    await persistence.dispose();

    expect(preferences.stored, 0.2);
  });

  test('dispose waits for a write already in flight', () async {
    final controller = FakePlaybackController();
    addTearDown(controller.dispose);
    final preferences = _RawPreferences(1.0);
    final persistence = attach(preferences, controller);

    // Hold the write open, then let the debounce fire so a save is genuinely
    // in flight with no timer left pending.
    preferences.writeGate = Completer<void>();
    controller.setVolume(0.3);
    await pastDebounce();
    expect(preferences.writes, isEmpty, reason: 'the write is parked');

    bool disposed = false;
    final Future<void> shutdown =
        persistence.dispose().then((_) => disposed = true);
    await Future<void>.delayed(Duration.zero);
    expect(disposed, isFalse,
        reason: 'shutdown must not finish while the level is still being '
            'written');

    preferences.writeGate!.complete();
    await shutdown;

    expect(disposed, isTrue);
    expect(preferences.stored, 0.3);
  });

  test('stops listening once disposed', () async {
    final controller = FakePlaybackController();
    addTearDown(controller.dispose);
    final preferences = _RawPreferences(1.0);
    final persistence = attach(preferences, controller);

    await persistence.dispose();
    final int writesAtShutdown = preferences.writes.length;
    controller.setVolume(0.1);
    await pastDebounce();

    expect(preferences.writes.length, writesAtShutdown);
  });

  test('the shared state model is what both sides agree on', () {
    // A guard on the contract the two halves share: the persisted number and
    // the state field are the same sanitized level.
    expect(PlaybackState.sanitizeVolume(0.42), 0.42);
  });

  test('the in-memory preferences sanitize what they are given', () async {
    final preferences = InMemoryPlaybackPreferences(volume: 3);
    expect(await preferences.volume(), 1.0);

    await preferences.setVolume(-1);
    expect(await preferences.volume(), 0.0);
  });

  test('a restore does not immediately write the value back', () async {
    final controller = FakePlaybackController();
    addTearDown(controller.dispose);
    final preferences = _RawPreferences(0.35);
    final persistence = attach(preferences, controller);

    await persistence.restore();
    await pastDebounce();

    expect(preferences.writes, isEmpty,
        reason: 'restoring is not a change worth writing back');
  });
}
