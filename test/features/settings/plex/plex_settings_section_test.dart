import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/plex_session.dart';
import 'package:linthra/core/sources/plex/plex_api.dart';
import 'package:linthra/core/sources/plex/plex_exception.dart';
import 'package:linthra/data/repositories/in_memory_plex_session_store.dart';
import 'package:linthra/data/repositories/plex_session_store_provider.dart';
import 'package:linthra/features/settings/plex/plex_settings_providers.dart';
import 'package:linthra/features/settings/plex/plex_settings_section.dart';

import '../../../core/sources/plex/fake_plex_client.dart';

const String _token = 'super-secret-plex-token';

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

Future<void> _pump(
  WidgetTester tester, {
  FakePlexClient? client,
  InMemoryPlexSessionStore? store,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        plexClientProvider.overrideWithValue(
          client ??
              FakePlexClient(sections: const [_movieSection, _musicSection]),
        ),
        plexSessionStoreProvider
            .overrideWithValue(store ?? InMemoryPlexSessionStore()),
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

Future<void> _connect(WidgetTester tester) async {
  await tester.enterText(
      find.byType(TextField).at(0), 'https://plex.example.com:32400');
  await tester.enterText(find.byType(TextField).at(1), _token);
  await tester.pump();
  await tester.tap(find.text('Connect'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('renders the connection form marked Experimental',
      (tester) async {
    await _pump(tester);

    expect(find.text('Plex'), findsOneWidget);
    expect(find.text('Experimental'), findsOneWidget);
    expect(find.text('Server URL'), findsOneWidget);
    expect(find.text('Plex token'), findsOneWidget);
    expect(find.text('Test connection'), findsOneWidget);
    expect(find.text('Connect'), findsOneWidget);
  });

  testWidgets('shows capability chips only for implemented features',
      (tester) async {
    await _pump(tester);

    // Phase 1 is stream-only → only Streaming appears.
    expect(find.text('Streaming'), findsOneWidget);
    expect(find.text('Offline'), findsNothing);
    expect(find.text('Cast'), findsNothing);
    expect(find.text('Favorites'), findsNothing);
    expect(find.text('Lyrics'), findsNothing);
  });

  testWidgets('Connect is disabled until both fields are filled',
      (tester) async {
    await _pump(tester);

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

  testWidgets('disconnect returns to an empty form', (tester) async {
    final store = InMemoryPlexSessionStore(initialSession: _restoredSession);
    await _pump(tester, store: store);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Disconnect Plex'));
    await tester.pumpAndSettle();

    expect(await store.read(), isNull);
    expect(find.text('Plex token'), findsOneWidget);
    expect(find.textContaining('Disconnected'), findsOneWidget);
    // Both fields come back empty — nothing of the old session lingers.
    for (final TextField field
        in tester.widgetList<TextField>(find.byType(TextField))) {
      expect(field.controller!.text, isEmpty);
    }
  });

  testWidgets('a rejected token shows a friendly, token-free error',
      (tester) async {
    await _pump(
      tester,
      client: FakePlexClient(
        identityError: PlexException.unauthorized(),
      ),
    );

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
}
