import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/data/repositories/in_memory_playback_preferences.dart';
import 'package:linthra/data/repositories/playback_preferences_provider.dart';
import 'package:linthra/features/settings/playback/auto_skip_controller.dart';

/// Preferences whose automatic-skip save waits on [gate], and fails instead
/// when [fail] is set, like a slow or full disk. [gates] and [failures], when
/// given, apply to the saves in turn, so each one can be slow or fail on its
/// own; [order] records the values written, in the order they landed.
class _Preferences extends InMemoryPlaybackPreferences {
  _Preferences({super.autoSkipUnplayable});

  Completer<void>? gate;
  bool fail = false;
  bool failRead = false;
  final List<Completer<void>?> gates = <Completer<void>?>[];
  final List<bool> failures = <bool>[];
  final List<bool> order = <bool>[];
  int _saves = 0;

  @override
  Future<bool?> autoSkipUnplayable() async {
    if (failRead) throw StateError('unreadable');
    return super.autoSkipUnplayable();
  }

  @override
  Future<void> setAutoSkipUnplayable(bool value) async {
    final int save = _saves++;
    await (save < gates.length ? gates[save] : gate)?.future;
    if (save < failures.length ? failures[save] : fail) {
      throw StateError('disk full');
    }
    order.add(value);
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

  test('two quick choices store the last one, whichever save is slower',
      () async {
    final Completer<void> slowFirst = Completer<void>();
    final _Preferences preferences = _Preferences()
      ..gates.addAll(<Completer<void>?>[slowFirst, null]);
    final (ProviderContainer container, List<bool?> _) = build(preferences);
    await container.read(autoSkipControllerProvider.future);
    final AutoSkipController choice =
        container.read(autoSkipControllerProvider.notifier);

    final Future<void> on = choice.setEnabled(true);
    final Future<void> off = choice.setEnabled(false);
    expect(container.read(autoSkipControllerProvider).value, isFalse);
    slowFirst.complete();
    await Future.wait(<Future<void>>[on, off]);

    expect(preferences.order, <bool>[true, false],
        reason: 'one at a time, in the order they were made');
    expect(await preferences.autoSkipUnplayable(), isFalse);
    expect(container.read(autoSkipControllerProvider).value, isFalse);
  });

  test('an older save that fails leaves the newer choice in place', () async {
    final _Preferences preferences = _Preferences()
      ..failures.addAll(<bool>[true, false]);
    final (ProviderContainer container, List<bool?> _) = build(preferences);
    await container.read(autoSkipControllerProvider.future);
    final AutoSkipController choice =
        container.read(autoSkipControllerProvider.notifier);

    final Future<void> on = choice.setEnabled(true);
    final Future<void> off = choice.setEnabled(false);
    await expectLater(on, throwsStateError);
    await off;

    expect(container.read(autoSkipControllerProvider).value, isFalse,
        reason: 'the newer choice was saved; the old failure must not undo '
            'it');
    expect(await preferences.autoSkipUnplayable(), isFalse);
  });

  test('a failed save that cannot be read back either fails closed', () async {
    final _Preferences preferences = _Preferences()..fail = true;
    final (ProviderContainer container, List<bool?> _) = build(preferences);
    await container.read(autoSkipControllerProvider.future);
    preferences.failRead = true;

    await expectLater(
      container.read(autoSkipControllerProvider.notifier).setEnabled(true),
      throwsA(
        isA<StateError>().having(
          (StateError e) => e.message,
          'message',
          'disk full',
        ),
      ),
      reason: "the save's own error, not the read's",
    );

    expect(container.read(autoSkipControllerProvider).value, isFalse,
        reason: 'not the unsaved choice: off, which only ever stops');
  });
}
