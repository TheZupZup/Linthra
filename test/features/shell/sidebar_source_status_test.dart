import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/jellyfin_session.dart';
import 'package:linthra/core/models/plex_session.dart';
import 'package:linthra/core/sources/music_provider.dart';
import 'package:linthra/core/sources/source_availability.dart';
import 'package:linthra/data/repositories/in_memory_jellyfin_session_store.dart';
import 'package:linthra/data/repositories/jellyfin_session_store_provider.dart';
import 'package:linthra/features/library/source_availability_providers.dart';
import 'package:linthra/features/settings/jellyfin/jellyfin_settings_providers.dart';
import 'package:linthra/features/settings/plex/plex_settings_controller.dart';
import 'package:linthra/features/settings/plex/plex_settings_state.dart';
import 'package:linthra/features/settings/subsonic/subsonic_settings_controller.dart';
import 'package:linthra/features/settings/subsonic/subsonic_settings_state.dart';
import 'package:linthra/features/shell/sidebar_source_status.dart';

import '../../core/sources/jellyfin/fake_jellyfin_client.dart';

/// The sidebar's source indicators as a user meets them (#425).
///
/// The rules pinned here are the ones that decide whether these are worth
/// having on screen at all: a healthy install stays quiet, a broken source says
/// which one and what kind of broken, one server's trouble never smears onto
/// another, nothing announced could be a secret, and drawing a row costs no
/// network.

final StateProvider<Map<String, SourceAvailability>> _probed =
    StateProvider<Map<String, SourceAvailability>>(
  (ref) => const <String, SourceAvailability>{},
);

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

/// Pumps the strip on its own. Returns how many times the connection settings
/// were asked for, so a test can assert the routing without a router.
Future<List<int>> _pumpStrip(
  WidgetTester tester, {
  Map<String, SourceAvailability> probed = const <String, SourceAvailability>{},
  bool subsonicConfigured = false,
  bool plexConfigured = false,
}) async {
  final List<int> opened = <int>[];
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        _probed.overrideWith((ref) => probed),
        sourceAvailabilityProvider.overrideWith((ref) => ref.watch(_probed)),
        subsonicSettingsControllerProvider.overrideWith(
          () => _StubSubsonicSettings(connected: subsonicConfigured),
        ),
        plexSettingsControllerProvider.overrideWith(
          () => _StubPlexSettings(connected: plexConfigured),
        ),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: SidebarSourceStatusStrip(
            onOpenConnections: () => opened.add(1),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return opened;
}

void main() {
  testWidgets('a local-only install grows no section about servers',
      (WidgetTester tester) async {
    await _pumpStrip(tester);
    expect(find.byType(SidebarSourceStatusTile), findsNothing);
    expect(find.byType(Divider), findsNothing);
  });

  testWidgets('a connected source names itself and stays quiet',
      (WidgetTester tester) async {
    await _pumpStrip(
      tester,
      probed: <String, SourceAvailability>{
        MusicProviders.jellyfin.sourceId: SourceAvailability.available,
      },
    );
    expect(find.text('Jellyfin'), findsOneWidget);
    expect(find.byTooltip('Jellyfin connected'), findsOneWidget);
    expect(find.byIcon(Icons.cloud_done_outlined), findsOneWidget);
  });

  testWidgets('a first probe reads as checking', (WidgetTester tester) async {
    await _pumpStrip(
      tester,
      probed: <String, SourceAvailability>{
        MusicProviders.jellyfin.sourceId: SourceAvailability.checking,
      },
    );
    expect(find.byTooltip('Checking Jellyfin'), findsOneWidget);
    expect(find.byIcon(Icons.cloud_sync_outlined), findsOneWidget);
  });

  testWidgets('an unreachable server is drawn in the error colour',
      (WidgetTester tester) async {
    await _pumpStrip(
      tester,
      probed: <String, SourceAvailability>{
        MusicProviders.jellyfin.sourceId: SourceAvailability.unreachable,
      },
    );
    expect(find.byTooltip('Jellyfin unavailable'), findsOneWidget);

    final BuildContext context = tester.element(find.byType(Icon).first);
    final Icon icon = tester.widget<Icon>(
      find.byIcon(Icons.cloud_off_outlined),
    );
    expect(icon.color, Theme.of(context).colorScheme.error);
  });

  testWidgets('a rejected session says so, not "unreachable"',
      (WidgetTester tester) async {
    await _pumpStrip(
      tester,
      probed: <String, SourceAvailability>{
        MusicProviders.jellyfin.sourceId:
            SourceAvailability.authenticationError,
      },
    );
    expect(find.byTooltip('Jellyfin sign-in needed'), findsOneWidget);
    expect(find.byIcon(Icons.cloud_off_outlined), findsNothing);
  });

  testWidgets('a server coming back updates the row in place, no restart',
      (WidgetTester tester) async {
    final List<int> opened = <int>[];
    final ProviderContainer container = ProviderContainer(
      overrides: <Override>[
        _probed.overrideWith(
          (ref) => <String, SourceAvailability>{
            MusicProviders.jellyfin.sourceId: SourceAvailability.unreachable,
          },
        ),
        sourceAvailabilityProvider.overrideWith((ref) => ref.watch(_probed)),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: SidebarSourceStatusStrip(
              onOpenConnections: () => opened.add(1),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.byTooltip('Jellyfin unavailable'), findsOneWidget);

    container.read(_probed.notifier).state = <String, SourceAvailability>{
      MusicProviders.jellyfin.sourceId: SourceAvailability.available,
    };
    await tester.pump();

    expect(find.byTooltip('Jellyfin connected'), findsOneWidget);
    expect(find.byTooltip('Jellyfin unavailable'), findsNothing);
  });

  testWidgets('one server going offline leaves the other rows alone',
      (WidgetTester tester) async {
    final ProviderContainer container = ProviderContainer(
      overrides: <Override>[
        _probed.overrideWith(
          (ref) => <String, SourceAvailability>{
            MusicProviders.jellyfin.sourceId: SourceAvailability.available,
          },
        ),
        sourceAvailabilityProvider.overrideWith((ref) => ref.watch(_probed)),
        subsonicSettingsControllerProvider.overrideWith(
          () => _StubSubsonicSettings(connected: true),
        ),
        plexSettingsControllerProvider.overrideWith(
          () => _StubPlexSettings(connected: true),
        ),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: SidebarSourceStatusStrip(onOpenConnections: () {}),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.byTooltip('Navidrome connected'), findsOneWidget);
    expect(find.byTooltip('Plex connected'), findsOneWidget);

    container.read(_probed.notifier).state = <String, SourceAvailability>{
      MusicProviders.jellyfin.sourceId: SourceAvailability.unreachable,
    };
    await tester.pump();

    expect(find.byTooltip('Jellyfin unavailable'), findsOneWidget);
    // The point of the test: Jellyfin's trouble is Jellyfin's alone.
    expect(find.byTooltip('Navidrome connected'), findsOneWidget);
    expect(find.byTooltip('Plex connected'), findsOneWidget);
    expect(find.byIcon(Icons.cloud_off_outlined), findsOneWidget);
  });

  testWidgets('a row is one control a screen reader reads once',
      (WidgetTester tester) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    await _pumpStrip(
      tester,
      probed: <String, SourceAvailability>{
        MusicProviders.jellyfin.sourceId: SourceAvailability.unreachable,
      },
    );

    expect(find.bySemanticsLabel('Jellyfin unavailable'), findsOneWidget);
    // The visible name is inside the excluded subtree, so it is not a second
    // stop that says "Jellyfin" again on its own.
    expect(find.bySemanticsLabel('Jellyfin'), findsNothing);

    final SemanticsNode node = tester.getSemantics(
      find.bySemanticsLabel('Jellyfin unavailable'),
    );
    expect(node.flagsCollection.isButton, isTrue);
    // A button a screen reader cannot press is worse than no button: the
    // excluded subtree drops the InkWell's action, so the node declares its
    // own.
    expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
    expect(node.label, 'Jellyfin unavailable');
    expect(node.hint, 'Opens connection settings');
    handle.dispose();
  });

  testWidgets('nothing on screen is a URL, a user, or an error string',
      (WidgetTester tester) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    await _pumpStrip(
      tester,
      probed: <String, SourceAvailability>{
        MusicProviders.jellyfin.sourceId:
            SourceAvailability.authenticationError,
      },
      subsonicConfigured: true,
      plexConfigured: true,
    );

    final Iterable<String> visible = tester
        .widgetList<Text>(find.byType(Text))
        .map((Text text) => text.data ?? '');
    final Iterable<String> tooltips = tester
        .widgetList<Tooltip>(find.byType(Tooltip))
        .map((Tooltip tooltip) => tooltip.message ?? '');
    final Iterable<String> announced = tester
        .widgetList<Semantics>(find.byType(Semantics))
        .map((Semantics semantics) => semantics.properties.label ?? '');

    for (final String text in <String>[...visible, ...tooltips, ...announced]) {
      expect(text, isNot(contains('http')));
      expect(text, isNot(contains('://')));
      expect(text, isNot(contains('192.168')));
      expect(text, isNot(contains('.local')));
      expect(text.toLowerCase(), isNot(contains('token')));
      expect(text.toLowerCase(), isNot(contains('password')));
      expect(text.toLowerCase(), isNot(contains('exception')));
    }
    handle.dispose();
  });

  testWidgets('a problem row opens the existing connection settings',
      (WidgetTester tester) async {
    final List<int> opened = await _pumpStrip(
      tester,
      probed: <String, SourceAvailability>{
        MusicProviders.jellyfin.sourceId: SourceAvailability.unreachable,
      },
    );

    await tester.tap(find.byType(SidebarSourceStatusTile));
    await tester.pump();

    expect(opened, hasLength(1));
  });

  testWidgets('drawing the rows costs no network', (WidgetTester tester) async {
    // The real availability controller, with a real session and a client that
    // counts. Whatever the sidebar does, it must not add a request on top of
    // the probe the app was already going to make.
    final FakeJellyfinClient client = FakeJellyfinClient();
    final ProviderContainer container = ProviderContainer(
      overrides: <Override>[
        jellyfinClientProvider.overrideWithValue(client),
        jellyfinSessionStoreProvider.overrideWithValue(
          InMemoryJellyfinSessionStore(
            initialSession: const JellyfinSession(
              baseUrl: 'https://example.invalid',
              userId: 'u1',
              accessToken: 'secret-token',
              deviceId: 'd1',
            ),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    // Let the app's own startup probe happen first.
    container.read(sourceAvailabilityProvider);
    await tester.pumpAndSettle();
    final int beforeRender = client.verifyCount;

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: SidebarSourceStatusStrip(onOpenConnections: () {}),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(client.verifyCount, beforeRender);
    // And rebuilding it again still asks nothing.
    await tester.pump();
    expect(client.verifyCount, beforeRender);
  });
}
