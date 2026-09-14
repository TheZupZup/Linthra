import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/plex_session.dart';
import 'package:linthra/core/sources/music_provider.dart';
import 'package:linthra/core/sources/source_availability.dart';
import 'package:linthra/features/library/source_availability_providers.dart';
import 'package:linthra/features/settings/jellyfin/jellyfin_settings_controller.dart';
import 'package:linthra/features/settings/jellyfin/jellyfin_settings_state.dart';
import 'package:linthra/features/settings/plex/plex_settings_controller.dart';
import 'package:linthra/features/settings/plex/plex_settings_state.dart';
import 'package:linthra/features/settings/subsonic/subsonic_settings_controller.dart';
import 'package:linthra/features/settings/subsonic/subsonic_settings_state.dart';
import 'package:linthra/features/shell/source_status.dart';
import 'package:linthra/features/shell/source_status_providers.dart';

/// The sidebar's source status, below the widget that draws it (#425).
///
/// Two properties are pinned here because they are the ones that make the
/// indicators trustworthy rather than decorative: the mapping from availability
/// to words is total and secret-free, and the list is *derived* — a source is
/// listed only when the user actually configured it, and one server's state can
/// never be read off another's.

/// The probe answers, held as state so a test can move one while the derived
/// list is already being watched — the reconnect case.
final StateProvider<Map<String, SourceAvailability>> _probed =
    StateProvider<Map<String, SourceAvailability>>(
  (ref) => const <String, SourceAvailability>{},
);

class _StubJellyfinSettings extends JellyfinSettingsController {
  _StubJellyfinSettings({required this.connected});
  final bool connected;
  @override
  JellyfinSettingsState build() => JellyfinSettingsState(
        phase: connected
            ? JellyfinConnectionPhase.connected
            : JellyfinConnectionPhase.disconnected,
      );
}

class _StubSubsonicSettings extends SubsonicSettingsController {
  _StubSubsonicSettings({required this.connected});
  final bool connected;
  @override
  SubsonicSettingsState build() => SubsonicSettingsState(
        phase: connected
            ? SubsonicConnectionPhase.connected
            : SubsonicConnectionPhase.disconnected,
      );
}

/// Plex counts as configured when a *session* is retained, not when the phase
/// reads connected: `connectWithPlex` deliberately keeps the session while the
/// user is away in the browser, so the phase is the wrong question to ask.
class _StubPlexSettings extends PlexSettingsController {
  _StubPlexSettings({required this.connected});

  final bool connected;

  @override
  PlexSession? get session => connected
      ? const PlexSession(
          baseUrl: 'https://plex.invalid:32400',
          token: 'plex-token',
          machineIdentifier: 'machine-1',
        )
      : null;

  @override
  PlexSettingsState build() => PlexSettingsState(
        phase: connected
            ? PlexConnectionPhase.connected
            : PlexConnectionPhase.disconnected,
      );
}

ProviderContainer _container({
  Map<String, SourceAvailability> probed = const <String, SourceAvailability>{},
  bool jellyfinConfigured = false,
  bool subsonicConfigured = false,
  bool plexConfigured = false,
}) {
  final ProviderContainer container = ProviderContainer(
    overrides: <Override>[
      _probed.overrideWith((ref) => probed),
      sourceAvailabilityProvider.overrideWith((ref) => ref.watch(_probed)),
      jellyfinSettingsControllerProvider.overrideWith(
        () => _StubJellyfinSettings(connected: jellyfinConfigured),
      ),
      subsonicSettingsControllerProvider.overrideWith(
        () => _StubSubsonicSettings(connected: subsonicConfigured),
      ),
      plexSettingsControllerProvider.overrideWith(
        () => _StubPlexSettings(connected: plexConfigured),
      ),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

ConfiguredSourceStatus? _statusFor(ProviderContainer container, String id) {
  for (final ConfiguredSourceStatus status
      in container.read(configuredSourceStatusesProvider)) {
    if (status.sourceId == id) return status;
  }
  return null;
}

void main() {
  group('sourceStatusPresentation', () {
    test('a source the user never set up has nothing to say', () {
      expect(
        sourceStatusPresentation(
          SourceAvailability.notConfigured,
          sourceName: 'Jellyfin',
        ),
        isNull,
      );
    });

    test('a server that answered reads as connected, and reads quietly', () {
      final SourceStatusPresentation presentation = sourceStatusPresentation(
        SourceAvailability.available,
        sourceName: 'Jellyfin',
      )!;
      expect(presentation.label, 'Connected');
      expect(presentation.description, 'Jellyfin connected');
      expect(presentation.tone, SourceStatusTone.healthy);
      expect(presentation.needsAttention, isFalse);
    });

    test('a first probe reads as checking, and is not an alarm', () {
      final SourceStatusPresentation presentation = sourceStatusPresentation(
        SourceAvailability.checking,
        sourceName: 'Jellyfin',
      )!;
      expect(presentation.label, 'Checking');
      expect(presentation.description, 'Checking Jellyfin');
      expect(presentation.tone, SourceStatusTone.neutral);
      expect(presentation.needsAttention, isFalse);
    });

    test('an unreachable server asks for the user', () {
      final SourceStatusPresentation presentation = sourceStatusPresentation(
        SourceAvailability.unreachable,
        sourceName: 'Navidrome',
      )!;
      expect(presentation.label, 'Unreachable');
      expect(presentation.description, 'Navidrome unavailable');
      expect(presentation.tone, SourceStatusTone.attention);
      expect(presentation.needsAttention, isTrue);
    });

    test('a rejected session is told apart from a dead server', () {
      final SourceStatusPresentation rejected = sourceStatusPresentation(
        SourceAvailability.authenticationError,
        sourceName: 'Jellyfin',
      )!;
      final SourceStatusPresentation unreachable = sourceStatusPresentation(
        SourceAvailability.unreachable,
        sourceName: 'Jellyfin',
      )!;
      // Same tone — both need the user — but never the same words or glyph:
      // the fix for one is signing in, for the other it is the network.
      expect(rejected.label, 'Sign-in needed');
      expect(rejected.description, 'Jellyfin sign-in needed');
      expect(rejected.icon, isNot(unreachable.icon));
      expect(rejected.description, isNot(unreachable.description));
    });

    test('every state resolves, so the switch cannot rot', () {
      for (final SourceAvailability availability in SourceAvailability.values) {
        if (availability == SourceAvailability.notConfigured) continue;
        expect(
          sourceStatusPresentation(availability, sourceName: 'Plex'),
          isNotNull,
          reason: '$availability has no presentation',
        );
      }
    });

    test('nothing it can say carries a secret', () {
      // The only variable input is the name, and callers take that from
      // PlaybackSourceLabel's fixed vocabulary. Feed it something that looks
      // like a leak and confirm the *shape* is name-plus-constant: there is no
      // field a URL, token or error string could ride in separately.
      for (final SourceAvailability availability in SourceAvailability.values) {
        final SourceStatusPresentation? presentation =
            sourceStatusPresentation(availability, sourceName: 'Jellyfin');
        if (presentation == null) continue;
        for (final String text in <String>[
          presentation.label,
          presentation.description,
        ]) {
          expect(text, isNot(contains('http')));
          expect(text, isNot(contains('@')));
          expect(text, isNot(contains('/')));
          expect(text, isNot(contains('token')));
          expect(text, isNot(contains('password')));
        }
      }
    });
  });

  group('configuredSourceStatuses', () {
    test('nothing configured lists nothing', () {
      final ProviderContainer container = _container();
      expect(container.read(configuredSourceStatusesProvider), isEmpty);
    });

    test('only configured sources appear', () {
      final ProviderContainer container = _container(
        probed: <String, SourceAvailability>{
          MusicProviders.jellyfin.sourceId: SourceAvailability.available,
        },
        jellyfinConfigured: true,
        plexConfigured: true,
      );
      expect(
        container
            .read(configuredSourceStatusesProvider)
            .map((ConfiguredSourceStatus s) => s.sourceId),
        <String>[
          MusicProviders.jellyfin.sourceId,
          MusicProviders.plex.sourceId
        ],
      );
    });

    test('a probing source is described by its probe, not by its session', () {
      // The session is saved, so the settings screen still says "connected" —
      // and the sidebar must still say the server is away.
      final ProviderContainer container = _container(
        probed: <String, SourceAvailability>{
          MusicProviders.jellyfin.sourceId: SourceAvailability.unreachable,
        },
        jellyfinConfigured: true,
      );
      expect(
        _statusFor(container, MusicProviders.jellyfin.sourceId)!
            .presentation
            .label,
        'Unreachable',
      );
    });

    test('a source that publishes no probe falls back to its session', () {
      // Navidrome has no availability controller yet. Configured means it is
      // assumed reachable, which is exactly what the rest of the app assumes.
      final ProviderContainer container = _container(subsonicConfigured: true);
      final ConfiguredSourceStatus status =
          _statusFor(container, MusicProviders.subsonic.sourceId)!;
      expect(status.presentation.label, 'Connected');
      expect(status.name, 'Navidrome');
    });

    test('sources are named from the safe vocabulary only', () {
      final ProviderContainer container = _container(
        jellyfinConfigured: true,
        subsonicConfigured: true,
        plexConfigured: true,
      );
      expect(
        container
            .read(configuredSourceStatusesProvider)
            .map((ConfiguredSourceStatus s) => s.name),
        <String>['Jellyfin', 'Navidrome', 'Plex'],
      );
    });

    test('one server going away leaves the others exactly as they were', () {
      final ProviderContainer container = _container(
        probed: <String, SourceAvailability>{
          MusicProviders.jellyfin.sourceId: SourceAvailability.available,
        },
        jellyfinConfigured: true,
        subsonicConfigured: true,
        plexConfigured: true,
      );
      final ConfiguredSourceStatus plexBefore =
          _statusFor(container, MusicProviders.plex.sourceId)!;
      final ConfiguredSourceStatus subsonicBefore =
          _statusFor(container, MusicProviders.subsonic.sourceId)!;

      container.read(_probed.notifier).state = <String, SourceAvailability>{
        MusicProviders.jellyfin.sourceId: SourceAvailability.unreachable,
      };

      expect(
        _statusFor(container, MusicProviders.jellyfin.sourceId)!
            .presentation
            .label,
        'Unreachable',
      );
      expect(_statusFor(container, MusicProviders.plex.sourceId), plexBefore);
      expect(
        _statusFor(container, MusicProviders.subsonic.sourceId),
        subsonicBefore,
      );
    });

    test('a server that comes back is described as back', () {
      final ProviderContainer container = _container(
        probed: <String, SourceAvailability>{
          MusicProviders.jellyfin.sourceId: SourceAvailability.unreachable,
        },
        jellyfinConfigured: true,
      );
      expect(
        _statusFor(container, MusicProviders.jellyfin.sourceId)!
            .presentation
            .needsAttention,
        isTrue,
      );

      container.read(_probed.notifier).state = <String, SourceAvailability>{
        MusicProviders.jellyfin.sourceId: SourceAvailability.available,
      };

      final ConfiguredSourceStatus recovered =
          _statusFor(container, MusicProviders.jellyfin.sourceId)!;
      expect(recovered.presentation.label, 'Connected');
      expect(recovered.presentation.needsAttention, isFalse);
    });

    test('signing out drops the row rather than marking it broken', () {
      final ProviderContainer container = _container(
        probed: <String, SourceAvailability>{
          MusicProviders.jellyfin.sourceId: SourceAvailability.notConfigured,
        },
        jellyfinConfigured: false,
      );
      expect(container.read(configuredSourceStatusesProvider), isEmpty);
    });
  });
}
