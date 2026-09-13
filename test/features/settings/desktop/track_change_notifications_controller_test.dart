import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/repositories/desktop_notification_preferences.dart';
import 'package:linthra/data/repositories/desktop_notification_preferences_provider.dart';
import 'package:linthra/features/settings/desktop/track_change_notifications_controller.dart';

/// Preferences whose writes the test decides when, and whether, to finish,
/// standing in for the platform round-trip `shared_preferences` makes. One
/// gate per call, so two overlapping writes can settle in either order.
class _GatedPreferences implements DesktopNotificationPreferences {
  _GatedPreferences({this.stored = false});

  bool stored;
  final List<Completer<void>> writes = <Completer<void>>[];

  @override
  Future<bool> trackChangeNotifications() async => stored;

  @override
  Future<void> setTrackChangeNotifications(bool enabled) async {
    final Completer<void> gate = Completer<void>();
    writes.add(gate);
    await gate.future;
    stored = enabled;
  }
}

/// Preferences that cannot persist anything, standing in for a plugin hiccup.
class _ThrowingPreferences implements DesktopNotificationPreferences {
  @override
  Future<bool> trackChangeNotifications() async => false;

  @override
  Future<void> setTrackChangeNotifications(bool enabled) async =>
      throw StateError('write failed');
}

void main() {
  group('TrackChangeNotificationsController', () {
    test('loads the stored choice', () async {
      final container = ProviderContainer(
        overrides: <Override>[
          desktopNotificationPreferencesProvider
              .overrideWithValue(_GatedPreferences(stored: true)),
        ],
      );
      addTearDown(container.dispose);

      expect(
        await container.read(trackChangeNotificationsControllerProvider.future),
        isTrue,
      );
    });

    test('applies the choice before the write has landed', () async {
      final _GatedPreferences preferences = _GatedPreferences();
      final container = ProviderContainer(
        overrides: <Override>[
          desktopNotificationPreferencesProvider.overrideWithValue(preferences),
        ],
      );
      addTearDown(container.dispose);
      await container.read(trackChangeNotificationsControllerProvider.future);

      final Future<void> pending = container
          .read(trackChangeNotificationsControllerProvider.notifier)
          .setEnabled(true);

      // The notification path reads this live on every track change, so it has
      // to be true the moment the switch is flipped, not once the platform has
      // finished writing.
      expect(
        container.read(trackChangeNotificationsControllerProvider).valueOrNull,
        isTrue,
      );
      expect(preferences.writes, hasLength(1));

      preferences.writes.single.complete();
      await pending;
      expect(
        container.read(trackChangeNotificationsControllerProvider).valueOrNull,
        isTrue,
      );
      expect(preferences.stored, isTrue);
    });

    test('a write that fails puts the switch back', () async {
      final container = ProviderContainer(
        overrides: <Override>[
          desktopNotificationPreferencesProvider
              .overrideWithValue(_ThrowingPreferences()),
        ],
      );
      addTearDown(container.dispose);
      await container.read(trackChangeNotificationsControllerProvider.future);

      await container
          .read(trackChangeNotificationsControllerProvider.notifier)
          .setEnabled(true);

      // A switch left on would disagree with the next launch.
      expect(
        container.read(trackChangeNotificationsControllerProvider).valueOrNull,
        isFalse,
      );
    });

    test('a failed write never undoes a choice made after it', () async {
      final _GatedPreferences preferences = _GatedPreferences();
      final container = ProviderContainer(
        overrides: <Override>[
          desktopNotificationPreferencesProvider.overrideWithValue(preferences),
        ],
      );
      addTearDown(container.dispose);
      await container.read(trackChangeNotificationsControllerProvider.future);

      final TrackChangeNotificationsController controller =
          container.read(trackChangeNotificationsControllerProvider.notifier);
      final Future<void> first = controller.setEnabled(true);
      // Flipped back before the first write settles.
      final Future<void> second = controller.setEnabled(false);
      expect(preferences.writes, hasLength(2));

      // The older write fails, the newer one lands. Rolling the first one back
      // would put the switch on again, against what was chosen last.
      preferences.writes[0].completeError(StateError('write failed'));
      preferences.writes[1].complete();
      await first;
      await second;

      expect(
        container.read(trackChangeNotificationsControllerProvider).valueOrNull,
        isFalse,
      );
      expect(preferences.stored, isFalse);
    });
  });
}
