import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/app/application_container.dart';
import 'package:linthra/core/models/cast_state.dart';
import 'package:linthra/core/models/theme_mode_preference.dart';
import 'package:linthra/core/platform/host_platform.dart';
import 'package:linthra/core/services/cast/cast_containment.dart';
import 'package:linthra/core/services/cast/cast_receiver_pinning.dart';
import 'package:linthra/core/services/cast/cast_service.dart';
import 'package:linthra/core/services/cast/default_cast_service.dart';
import 'package:linthra/core/services/cast/unavailable_cast_service.dart';
import 'package:linthra/data/repositories/cast_receiver_pin_store_provider.dart';
import 'package:linthra/data/repositories/shared_preferences_cast_receiver_pin_store.dart';
import 'package:linthra/features/player/cast/cast_providers.dart';

/// What a *shipped* build gets for casting, walked through the real production
/// override list rather than a test's own wiring.
///
/// Casting is withheld from production while a reported security issue is
/// resolved (see [CastContainment]). The regression this guards against is the
/// quiet one: a provider revert, a platform branch reintroduced "just for
/// Android", a test-only injection reaching production. Each platform is checked
/// individually because a branch is precisely what containment must not have.
///
/// This walks the real production override list and drives the service it
/// returns, so it is behavioural evidence rather than a source-pattern check.
void main() {
  ProviderContainer productionContainer(HostPlatform host) {
    final container = ProviderContainer(
      overrides: productionApplicationOverrides(
        storedThemeMode: ThemeModePreference.system,
        host: host,
      ),
    );
    addTearDown(container.dispose);
    return container;
  }

  for (final HostPlatform host in <HostPlatform>[
    HostPlatform.android,
    HostPlatform.ios,
    HostPlatform.linux,
    HostPlatform.macOS,
    HostPlatform.windows,
    HostPlatform.other,
  ]) {
    group('production build on ${host.name}', () {
      test('binds the unavailable cast service, never a live backend', () {
        final CastService service =
            productionContainer(host).read(castServiceProvider);

        expect(service, isA<UnavailableCastService>());
        expect(service, isNot(isA<DefaultCastService>()));
        expect(service.state.isAvailable, isFalse);
      });

      test('tells the user casting is temporarily off', () {
        final CastService service =
            productionContainer(host).read(castServiceProvider);

        expect(service.state.message, CastContainment.userMessage);
      });

      test('the state stream reports the same containment', () async {
        final CastService service =
            productionContainer(host).read(castServiceProvider);

        await expectLater(
          service.stateStream,
          emits(
            predicate<CastState>(
              (CastState s) =>
                  !s.isAvailable && s.message == CastContainment.userMessage,
              'an unavailable state carrying the containment message',
            ),
          ),
        );
      });

      test('direct service calls cannot discover, connect, or hand off',
          () async {
        final CastService service =
            productionContainer(host).read(castServiceProvider);

        // Straight at the service, the way application code would if the UI
        // were bypassed entirely — the containment is not a UI decision.
        await service.startDiscovery();
        await service.connect(const CastDevice(id: 'r1', name: 'Living room'));
        await service.play();
        await service.seek(const Duration(minutes: 1));
        await service.setVolume(1.0);
        await service.refresh();
        await service.disconnect();
        await service.stopDiscovery();

        expect(service.state.isAvailable, isFalse);
        expect(service.state.isCasting, isFalse);
        expect(service.state.connectedDevice, isNull);
        expect(service.state.devices, isEmpty);
        expect(service.playbackStatus.status.name, 'idle');
      });

      test('remembers receivers in a store that outlives the app', () {
        // Pinning is only worth having if it survives a restart: an in-memory
        // store makes every launch a first use, so a swapped receiver is
        // caught for one session and then forgotten. Wired while casting is
        // contained on purpose, because the pins a restored cast feature will
        // check have to predate the release that restores it.
        final CastReceiverPinStore pins =
            productionContainer(host).read(castReceiverPinStoreProvider);

        expect(pins, isA<SharedPreferencesCastReceiverPinStore>());
        expect(pins, isNot(isA<InMemoryCastReceiverPinStore>()));
      });

      test('repeated startup and disposal stay contained', () async {
        for (int run = 0; run < 3; run++) {
          final ProviderContainer container = ProviderContainer(
            overrides: productionApplicationOverrides(
              storedThemeMode: ThemeModePreference.system,
              host: host,
            ),
          );
          final CastService service = container.read(castServiceProvider);
          await service.startDiscovery();
          expect(service.state.isAvailable, isFalse);
          container.dispose();
        }
      });
    });
  }

  test('the production override list applies the containment binding', () {
    // Belt and braces with the CI guard: if the override is dropped from the
    // list, production silently falls back to the default provider.
    final List<Override> overrides = productionApplicationOverrides(
      storedThemeMode: ThemeModePreference.system,
      host: HostPlatform.android,
    );

    expect(overrides, contains(containedCastServiceOverride));
    expect(overrides, contains(sharedPreferencesCastReceiverPinStoreOverride));
  });

  test('an unavailable service without a message keeps the platform wording',
      () {
    // The Linux/desktop fallback predates containment and must survive it: no
    // message means the sheet uses its own "not on this platform" copy.
    final service = UnavailableCastService();
    addTearDown(service.dispose);

    expect(service.state.message, isNull);
    expect(service.state.isAvailable, isFalse);
  });
}
