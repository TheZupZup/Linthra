import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/app/external_link_launcher_provider.dart';
import 'package:linthra/core/models/plex_session.dart';
import 'package:linthra/core/services/external_link_launcher.dart';
import 'package:linthra/core/sources/plex/plex_api.dart';
import 'package:linthra/core/sources/plex/plex_exception.dart';
import 'package:linthra/core/sources/plex/plex_pin_auth.dart';
import 'package:linthra/core/sources/plex/plex_tv_api.dart';
import 'package:linthra/data/repositories/in_memory_plex_session_store.dart';
import 'package:linthra/data/repositories/plex_session_store_provider.dart';
import 'package:linthra/features/settings/plex/plex_settings_providers.dart';
import 'package:linthra/features/settings/plex/plex_settings_section.dart';

import '../../../core/sources/plex/fake_plex_client.dart';
import '../../../core/sources/plex/fake_plex_tv_client.dart';

const String _token = 'super-secret-plex-token';
const String _accountToken = 'super-secret-account-token';

const PlexDirectory _musicSection =
    PlexDirectory(key: '5', title: 'Music', type: 'artist');
const PlexDirectory _movieSection =
    PlexDirectory(key: '1', title: 'Movies', type: 'movie');

const PlexSession _restoredSession = PlexSession(
  baseUrl: 'https://plex.example.com:32400',
  token: _token,
  machineIdentifier: 'machine-abc',
  serverVersion: '1.40.1',
  clientIdentifier: 'install-1',
  selectedSectionKeys: <String>['5'],
);

const PlexResource _officeResource = PlexResource(
  name: 'Office Server',
  clientIdentifier: 'fake-machine-id',
  provides: 'server',
  accessToken: 'super-secret-server-scoped-token',
  productVersion: '1.41.0',
  connections: <PlexResourceConnection>[
    PlexResourceConnection(uri: 'https://office.abc.plex.direct:32400'),
  ],
);

const PlexResource _atticResource = PlexResource(
  name: 'Attic NAS',
  clientIdentifier: 'machine-attic',
  provides: 'server',
  accessToken: 'super-secret-attic-token',
  owned: false,
  connections: <PlexResourceConnection>[
    PlexResourceConnection(uri: 'https://attic.abc.plex.direct:32400'),
  ],
);

/// A [FakePlexClient] whose sections listing blocks until [gate] completes,
/// so the picker's loading state can be observed deterministically.
class _GatedSectionsClient extends FakePlexClient {
  _GatedSectionsClient({super.sections});

  final Completer<void> gate = Completer<void>();

  @override
  Future<List<PlexDirectory>> fetchSections({
    required String baseUrl,
    required String token,
  }) async {
    await gate.future;
    return super.fetchSections(baseUrl: baseUrl, token: token);
  }
}

/// A [FakePlexTvClient] whose PIN polls block until [gate] completes, so the
/// "waiting for the browser" view can be observed deterministically.
class _GatedPinTvClient extends FakePlexTvClient {
  _GatedPinTvClient();

  final Completer<void> gate = Completer<void>();

  @override
  Future<String?> checkPin(int pinId) async {
    await gate.future;
    return super.checkPin(pinId);
  }
}

/// An [ExternalLinkLauncher] that records launches instead of opening a
/// real browser.
class _RecordingLauncher implements ExternalLinkLauncher {
  final List<Uri> opened = <Uri>[];

  @override
  Future<bool> open(Uri url) async {
    opened.add(url);
    return true;
  }
}

Future<void> _pump(
  WidgetTester tester, {
  FakePlexClient? client,
  InMemoryPlexSessionStore? store,
  FakePlexTvClient? tvClient,
  ExternalLinkLauncher? launcher,
}) async {
  final FakePlexClient plexClient =
      client ?? FakePlexClient(sections: const [_movieSection, _musicSection]);
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        plexClientProvider.overrideWithValue(plexClient),
        plexSessionStoreProvider
            .overrideWithValue(store ?? InMemoryPlexSessionStore()),
        plexPinAuthProvider.overrideWith(
          (ref) => PlexPinAuth(
            tvClient: tvClient ?? FakePlexTvClient(),
            serverClient: plexClient,
            identity: ref.watch(plexClientIdentityProvider),
            wait: (_) async {},
          ),
        ),
        externalLinkLauncherProvider
            .overrideWithValue(launcher ?? _RecordingLauncher()),
      ],
      child: const MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: PlexSettingsSection()),
        ),
      ),
    ),
  );
  await tester.pump();
}

/// Opens the advanced manual form (hidden by default behind the primary
/// "Connect with Plex" action).
Future<void> _openManualSetup(WidgetTester tester) async {
  await tester.tap(find.text('Manual setup (advanced)'));
  await tester.pump();
}

Future<void> _connect(WidgetTester tester) async {
  await _openManualSetup(tester);
  await tester.enterText(
      find.byType(TextField).at(0), 'https://plex.example.com:32400');
  await tester.enterText(find.byType(TextField).at(1), _token);
  await tester.pump();
  await tester.tap(find.text('Connect'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
      'leads with Connect with Plex and keeps the manual form behind '
      'Advanced', (tester) async {
    await _pump(tester);

    expect(find.text('Plex'), findsOneWidget);
    expect(find.text('Experimental'), findsOneWidget);
    expect(find.text('Connect with Plex'), findsOneWidget);
    expect(find.text('Manual setup (advanced)'), findsOneWidget);
    // No token hunting up front: the manual fields are hidden by default.
    expect(find.text('Server URL'), findsNothing);
    expect(find.text('Plex token'), findsNothing);

    await _openManualSetup(tester);

    expect(find.text('Server URL'), findsOneWidget);
    expect(find.text('Plex token'), findsOneWidget);
    expect(find.text('Test connection'), findsOneWidget);
    expect(find.text('Connect'), findsOneWidget);

    // The toggle collapses it again.
    await tester.tap(find.text('Manual setup (advanced)'));
    await tester.pump();
    expect(find.text('Server URL'), findsNothing);
  });

  testWidgets('shows capability chips only for implemented features',
      (tester) async {
    await _pump(tester);

    // Phase 1 implements streaming + lyrics + offline caching → those chips
    // appear; cast and favorites stay declared unsupported, so they don't.
    expect(find.text('Streaming'), findsOneWidget);
    expect(find.text('Lyrics'), findsOneWidget);
    expect(find.text('Offline'), findsOneWidget);
    expect(find.text('Cast'), findsNothing);
    expect(find.text('Favorites'), findsNothing);
  });

  testWidgets('Connect is disabled until both manual fields are filled',
      (tester) async {
    await _pump(tester);
    await _openManualSetup(tester);

    FilledButton connect() => tester.widget<FilledButton>(
          find.widgetWithText(FilledButton, 'Connect'),
        );
    expect(connect().onPressed, isNull);

    await tester.enterText(
        find.byType(TextField).at(0), 'plex.example.com:32400');
    await tester.pump();
    expect(connect().onPressed, isNull);

    await tester.enterText(find.byType(TextField).at(1), _token);
    await tester.pump();
    expect(connect().onPressed, isNotNull);
  });

  testWidgets(
      'connecting shows the picker with music libraries only and never '
      'renders the token again', (tester) async {
    final store = InMemoryPlexSessionStore();
    await _pump(tester, store: store);

    await _connect(tester);

    // Connected view with the library picker: the music section is offered,
    // the movie one is not.
    expect(find.text('Music libraries'), findsOneWidget);
    expect(find.byType(CheckboxListTile), findsOneWidget);
    expect(find.text('Music'), findsOneWidget);
    expect(find.text('Movies'), findsNothing);
    expect(find.text('Disconnect Plex'), findsOneWidget);
    // Connected, nothing selected yet — the picker says so.
    expect(find.textContaining('No libraries selected yet'), findsOneWidget);

    // The session was persisted (token included, encrypted in production)…
    expect((await store.read())!.token, _token);
    // …but the token never appears anywhere in the UI again.
    expect(find.text(_token), findsNothing);
    expect(find.textContaining(_token), findsNothing);
  });

  testWidgets('toggling a library persists the selection', (tester) async {
    final store = InMemoryPlexSessionStore();
    await _pump(tester, store: store);
    await _connect(tester);

    await tester.tap(find.byType(CheckboxListTile));
    await tester.pumpAndSettle();

    expect((await store.read())!.selectedSectionKeys, <String>['5']);
    expect(find.textContaining('No libraries selected yet'), findsNothing);

    await tester.tap(find.byType(CheckboxListTile));
    await tester.pumpAndSettle();

    // Deselecting persists too: connected with an empty selection.
    expect((await store.read())!.selectedSectionKeys, isEmpty);
    expect(find.text('Disconnect Plex'), findsOneWidget);
  });

  testWidgets('a restored session opens connected and loads the picker',
      (tester) async {
    await _pump(
      tester,
      store: InMemoryPlexSessionStore(initialSession: _restoredSession),
    );
    // Let the persisted-session load and the automatic section fetch settle.
    await tester.pumpAndSettle();

    expect(find.text('Plex token'), findsNothing);
    expect(find.text('https://plex.example.com:32400'), findsOneWidget);
    expect(find.text('Plex Media Server 1.40.1'), findsOneWidget);
    // The restored selection pre-checks its library.
    final CheckboxListTile checkbox =
        tester.widget<CheckboxListTile>(find.byType(CheckboxListTile));
    expect(checkbox.value, isTrue);
    expect(find.text(_token), findsNothing);
  });

  testWidgets('disconnect returns to the signed-out card', (tester) async {
    final store = InMemoryPlexSessionStore(initialSession: _restoredSession);
    await _pump(tester, store: store);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Disconnect Plex'));
    await tester.pumpAndSettle();

    expect(await store.read(), isNull);
    expect(find.text('Connect with Plex'), findsOneWidget);
    expect(find.textContaining('Disconnected'), findsOneWidget);
    // The manual form folds back behind Advanced…
    expect(find.text('Plex token'), findsNothing);

    // …and comes back empty — nothing of the old session lingers.
    await _openManualSetup(tester);
    for (final TextField field
        in tester.widgetList<TextField>(find.byType(TextField))) {
      expect(field.controller!.text, isEmpty);
    }
  });

  testWidgets('shows a labelled loading state while libraries are fetched',
      (tester) async {
    final client =
        _GatedSectionsClient(sections: const [_movieSection, _musicSection]);
    await _pump(
      tester,
      client: client,
      store: InMemoryPlexSessionStore(initialSession: _restoredSession),
    );
    // Let the restore land and the post-frame section load start (held at
    // the gate) — explicit pumps, since the spinner animates forever.
    await tester.pump();
    await tester.pump();

    expect(find.text('Loading music libraries…'), findsOneWidget);
    expect(find.textContaining('No music libraries found'), findsNothing);

    client.gate.complete();
    await tester.pumpAndSettle();
    expect(find.text('Loading music libraries…'), findsNothing);
    expect(find.byType(CheckboxListTile), findsOneWidget);
  });

  testWidgets('a failed library listing offers Try again and recovers',
      (tester) async {
    final client = FakePlexClient(
      sectionsError: PlexException.serverError(503),
      sections: const [_movieSection, _musicSection],
    );
    await _pump(
      tester,
      client: client,
      store: InMemoryPlexSessionStore(initialSession: _restoredSession),
    );
    await tester.pumpAndSettle();

    // A failed load must NOT claim the server has no music libraries; it
    // offers a retry, with the specific reason in the error line below.
    expect(
        find.text("Your music libraries haven't loaded yet."), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
    expect(find.textContaining('No music libraries found'), findsNothing);
    expect(find.textContaining('HTTP 503'), findsOneWidget);

    client.sectionsError = null;
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();

    expect(find.byType(CheckboxListTile), findsOneWidget);
    expect(find.textContaining('HTTP 503'), findsNothing);
  });

  testWidgets('a server without music libraries says so, with a refresh',
      (tester) async {
    await _pump(
      tester,
      client: FakePlexClient(sections: const [_movieSection]),
      store: InMemoryPlexSessionStore(initialSession: _restoredSession),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('No music libraries found on this server'),
        findsOneWidget);
    expect(find.text('Refresh'), findsOneWidget);
    expect(find.byType(CheckboxListTile), findsNothing);
  });

  testWidgets(
      'selecting a library syncs it automatically and the manual sync '
      'button stays available', (tester) async {
    final client = FakePlexClient(
      sections: const [_movieSection, _musicSection],
      itemsByType: const <PlexMetadataType, List<PlexMetadata>>{
        PlexMetadataType.track: <PlexMetadata>[
          PlexMetadata(ratingKey: '101', type: 'track', title: 'Aurora'),
        ],
      },
    );
    await _pump(tester, client: client);
    await _connect(tester);

    expect(find.text('Sync Plex library'), findsOneWidget);

    await tester.tap(find.byType(CheckboxListTile));
    await tester.pumpAndSettle();

    // The background sync kicked by the selection landed and reported.
    expect(find.textContaining('Synced 1 track'), findsOneWidget);

    // The manual action reruns it on demand; with nothing changed since the
    // selection-driven sync, it reports the library is already current rather
    // than rebuilding it.
    await tester.tap(find.text('Sync Plex library'));
    await tester.pumpAndSettle();
    expect(find.textContaining('already up to date'), findsOneWidget);
  });

  testWidgets('a rejected token shows a friendly, token-free error',
      (tester) async {
    await _pump(
      tester,
      client: FakePlexClient(
        identityError: PlexException.unauthorized(),
      ),
    );
    await _openManualSetup(tester);

    await tester.enterText(find.byType(TextField).at(0), 'plex.example.com');
    await tester.enterText(find.byType(TextField).at(1), 'wrong-token');
    await tester.pump();
    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();

    expect(find.textContaining('was not accepted'), findsOneWidget);
    // The (token-free) error is the only place the failure is described; the
    // typed token stays only inside the obscured input field, never in any
    // rendered text.
    for (final Text text in tester.widgetList<Text>(find.byType(Text))) {
      expect(text.data ?? '', isNot(contains('wrong-token')));
    }
    // Still on the form, ready to retry.
    expect(find.text('Connect'), findsOneWidget);
  });

  testWidgets(
      'Connect with Plex opens the browser and shows the waiting view, '
      'and Cancel backs out of it', (tester) async {
    final launcher = _RecordingLauncher();
    final tvClient = _GatedPinTvClient();
    await _pump(tester, tvClient: tvClient, launcher: launcher);

    await tester.tap(find.text('Connect with Plex'));
    // Explicit pumps — the waiting spinner animates forever.
    await tester.pump();
    await tester.pump();

    expect(find.text('Waiting for your Plex sign-in…'), findsOneWidget);
    expect(find.text('Open the sign-in page again'), findsOneWidget);
    expect(find.text('Cancel'), findsOneWidget);
    // The browser was handed the hosted plex.tv page.
    expect(launcher.opened.single.host, 'app.plex.tv');
    expect(launcher.opened.single.fragment, contains('code=fake-pin-code'));

    await tester.tap(find.text('Cancel'));
    await tester.pump();

    expect(find.text('Connect with Plex'), findsOneWidget);
    expect(find.text('Waiting for your Plex sign-in…'), findsNothing);

    // Release the gated poll so the abandoned flow finishes quietly.
    tvClient.gate.complete();
    await tester.pumpAndSettle();
    expect(find.text('Connect with Plex'), findsOneWidget);
  });

  testWidgets(
      'a single-server account connects straight through to the library '
      'picker, never showing a token', (tester) async {
    final store = InMemoryPlexSessionStore();
    await _pump(
      tester,
      store: store,
      tvClient: FakePlexTvClient(
        checkPinScript: <Object?>[null, _accountToken],
        resources: const <PlexResource>[_officeResource],
      ),
    );

    await tester.tap(find.text('Connect with Plex'));
    await tester.pumpAndSettle();

    // Connected, named after the picked server (card header + connected
    // view), with the library picker up.
    expect(find.text('Plex · Office Server'), findsNWidgets(2));
    expect(find.text('Music libraries'), findsOneWidget);
    expect(find.text('Music'), findsOneWidget);
    expect(find.text('Disconnect Plex'), findsOneWidget);

    // The server-scoped token was persisted (encrypted in production)…
    expect((await store.read())!.token, 'super-secret-server-scoped-token');
    // …and no token of any kind was ever rendered.
    for (final Text text in tester.widgetList<Text>(find.byType(Text))) {
      expect(text.data ?? '', isNot(contains('super-secret')));
      expect(text.data ?? '', isNot(contains(_accountToken)));
    }
  });

  testWidgets('a multi-server account picks from the server list',
      (tester) async {
    final store = InMemoryPlexSessionStore();
    await _pump(
      tester,
      client: FakePlexClient(
        identity: const PlexServerIdentity(machineIdentifier: 'machine-attic'),
        sections: const [_musicSection],
      ),
      store: store,
      tvClient: FakePlexTvClient(
        checkPinScript: <Object?>[_accountToken],
        resources: const <PlexResource>[_officeResource, _atticResource],
      ),
    );

    await tester.tap(find.text('Connect with Plex'));
    await tester.pumpAndSettle();

    expect(find.text('Choose your Plex server'), findsOneWidget);
    expect(find.text('Office Server'), findsOneWidget);
    expect(find.text('Attic NAS'), findsOneWidget);
    // The shared server says so; versions show when known.
    expect(find.textContaining('Shared with you'), findsOneWidget);
    expect(find.textContaining('1.41.0'), findsOneWidget);

    await tester.tap(find.text('Attic NAS'));
    await tester.pumpAndSettle();

    expect(find.text('Plex · Attic NAS'), findsNWidgets(2));
    expect((await store.read())!.token, 'super-secret-attic-token');
  });

  testWidgets('a multi-profile account picks from the user list first',
      (tester) async {
    final store = InMemoryPlexSessionStore();
    await _pump(
      tester,
      client: FakePlexClient(sections: const [_musicSection]),
      store: store,
      tvClient: FakePlexTvClient(
        checkPinScript: <Object?>[_accountToken],
        homeUsers: const <PlexHomeUser>[
          PlexHomeUser(uuid: 'uuid-owner', title: 'Dad', admin: true),
          PlexHomeUser(uuid: 'uuid-kid', title: 'Kids', restricted: true),
        ],
        resources: const <PlexResource>[_officeResource],
      ),
    );

    await tester.tap(find.text('Connect with Plex'));
    await tester.pumpAndSettle();

    // The user picker leads, before any server or library step.
    expect(find.text('Choose your Plex user'), findsOneWidget);
    expect(find.text('Dad'), findsOneWidget);
    expect(find.text('Kids'), findsOneWidget);
    expect(find.textContaining('Account owner'), findsOneWidget);
    expect(find.textContaining('Managed profile'), findsOneWidget);
    // Not connected yet — onboarding paused on the picker, no library sync.
    expect(find.text('Music libraries'), findsNothing);

    await tester.tap(find.text('Kids'));
    await tester.pumpAndSettle();

    // Picking the profile carries the flow through to the connected card.
    expect(find.text('Music libraries'), findsOneWidget);
    expect(find.text('Disconnect Plex'), findsOneWidget);
  });

  testWidgets('a protected profile reveals an inline PIN entry to continue',
      (tester) async {
    final tvClient = FakePlexTvClient(
      checkPinScript: <Object?>[_accountToken],
      homeUsers: const <PlexHomeUser>[
        PlexHomeUser(uuid: 'uuid-owner', title: 'Dad', admin: true),
        PlexHomeUser(uuid: 'uuid-teen', title: 'Teen', protected: true),
      ],
      resources: const <PlexResource>[_officeResource],
    );
    await _pump(
      tester,
      client: FakePlexClient(sections: const [_musicSection]),
      tvClient: tvClient,
    );

    await tester.tap(find.text('Connect with Plex'));
    await tester.pumpAndSettle();

    // The protected profile is flagged and, when tapped, asks for its PIN
    // inline (part of the card, not a dialog) instead of switching at once.
    expect(find.textContaining('PIN protected'), findsOneWidget);
    await tester.tap(find.text('Teen'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Enter the PIN for Teen'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '4242');
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();

    // The PIN was forwarded to the switch, and the flow connected.
    expect(tvClient.lastSwitchPin, '4242');
    expect(find.text('Disconnect Plex'), findsOneWidget);
  });

  testWidgets('an account with no servers shows a clean empty state',
      (tester) async {
    await _pump(
      tester,
      tvClient: FakePlexTvClient(
        checkPinScript: <Object?>[_accountToken],
        resources: const <PlexResource>[],
      ),
    );

    await tester.tap(find.text('Connect with Plex'));
    await tester.pumpAndSettle();

    expect(find.text('No Plex Media Server found'), findsOneWidget);
    expect(find.textContaining('no Plex Media Server linked'), findsOneWidget);

    await tester.tap(find.text('Back'));
    await tester.pump();
    expect(find.text('Connect with Plex'), findsOneWidget);
  });

  testWidgets('an expired sign-in shows a friendly error on the card',
      (tester) async {
    await _pump(
      tester,
      tvClient: FakePlexTvClient(
        checkPinScript: <Object?>[PlexException.signInExpired()],
      ),
    );

    await tester.tap(find.text('Connect with Plex'));
    await tester.pumpAndSettle();

    expect(find.textContaining('sign-in expired'), findsOneWidget);
    // Back on the signed-out card, ready to retry.
    expect(find.text('Connect with Plex'), findsOneWidget);
  });

  testWidgets(
      'a rejected session offers Reconnect with Plex on the connected card',
      (tester) async {
    // The saved token stopped working: the server rejects the library
    // listing with a 401.
    await _pump(
      tester,
      client: FakePlexClient(sectionsError: PlexException.unauthorized()),
      store: InMemoryPlexSessionStore(initialSession: _restoredSession),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('was not accepted'), findsOneWidget);
    expect(find.text('Reconnect with Plex'), findsOneWidget);
    // Still connected behind the error — disconnecting stays possible too.
    expect(find.text('Disconnect Plex'), findsOneWidget);
  });
}
