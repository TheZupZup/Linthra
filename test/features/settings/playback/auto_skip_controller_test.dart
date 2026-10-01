import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/data/repositories/in_memory_playback_preferences.dart';
import 'package:linthra/data/repositories/playback_preferences_provider.dart';
import 'package:linthra/features/settings/playback/auto_skip_controller.dart';

/// Preferences whose automatic-skip save waits on [gate], and fails instead
/// when [fail] is set, like a slow or full disk.
class _Preferences extends InMemoryPlaybackPreferences {
  _Preferences({super.autoSkipUnplayable});

  Completer<void>? gate;
  bool fail = false;

  @override
  Future<void> setAutoSkipUnplayable(bool value) async {
    await gate?.future;
    if (fail) throw StateError('disk full');
    await super.setAutoSkipUnplayable(value);
  }
}

void main() {
  /// A container reading [preferences], with a listener standing in for the
  /// app's lifecycle wiring, which hands every change to the controller.
  (ProviderContainer, List<bool?>) build(_Preferences preferences) {
    final ProviderContainer container = ProviderContainer(
      overrides: <Override>[
        playbackPreferencesProvider.overrideWithValue(preferences),
      ],
    );
    addTearDown(container.dispose);
    final List<bool?> seen = <bool?>[];
    container.listen<AsyncValue<bool?>>(
      autoSkipControllerProvider,
      (_, AsyncValue<bool?> next) {
        if (next.hasValue) seen.add(next.value);
      },
    );
    return (container, seen);
  }

  test('switching it off reaches playback before a slow save comes back',
      () async {
    final _Preferences preferences = _Preferences(autoSkipUnplayable: true)
      ..gate = Completer<void>();
    final (ProviderContainer container, List<bool?> seen) = build(preferences);
    await container.read(autoSkipControllerProvider.future);
    seen.clear();

    final Future<void> saving =
        container.read(autoSkipControllerProvider.notifier).setEnabled(false);

    // A countdown must stop now, not when the disk answers.
    expect(seen, <bool?>[false]);
    expect(container.read(autoSkipControllerProvider).value, isFalse);
    expect(await preferences.autoSkipUnplayable(), isTrue,
        reason: 'not written yet');

    preferences.gate!.complete();
    await saving;
    expect(await preferences.autoSkipUnplayable(), isFalse);
  });

  test('a save that fails puts the choice back and says so', () async {
    final _Preferences preferences = _Preferences()..fail = true;
    final (ProviderContainer container, List<bool?> seen) = build(preferences);
    await container.read(autoSkipControllerProvider.future);
    seen.clear();

    await expectLater(
      container.read(autoSkipControllerProvider.notifier).setEnabled(true),
      throwsStateError,
    );

    expect(seen, <bool?>[true, null],
        reason: 'playback follows what is stored, so it goes back too');
    expect(container.read(autoSkipControllerProvider).value, isNull);
    expect(await preferences.autoSkipUnplayable(), isNull);
  });
}
