import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/subsonic_session.dart';
import 'package:linthra/data/repositories/in_memory_subsonic_session_store.dart';
import 'package:linthra/data/repositories/subsonic_session_store_provider.dart';
import 'package:linthra/features/settings/subsonic/subsonic_settings_providers.dart';
import 'package:linthra/features/settings/subsonic/subsonic_settings_section.dart';

import '../../../core/sources/subsonic/fake_subsonic_client.dart';

Future<void> _pump(WidgetTester tester, {SubsonicSession? saved}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        subsonicClientProvider.overrideWithValue(FakeSubsonicClient()),
        subsonicSessionStoreProvider.overrideWithValue(
            InMemorySubsonicSessionStore(initialSession: saved)),
      ],
      child: const MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: SubsonicSettingsSection()),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('renders the connection form with all three fields',
      (tester) async {
    await _pump(tester);

    expect(find.text('Navidrome / Subsonic'), findsOneWidget);
    expect(find.text('Server URL'), findsOneWidget);
    expect(find.text('Username'), findsOneWidget);
    expect(find.text('Password'), findsOneWidget);
    expect(find.text('Sign in'), findsOneWidget);
    expect(find.text('Test connection'), findsOneWidget);
  });

  testWidgets('shows capability chips only for implemented features',
      (tester) async {
    await _pump(tester);

    // Implemented → shown.
    expect(find.text('Streaming'), findsOneWidget);
    expect(find.text('Offline'), findsOneWidget);
    expect(find.text('Cast'), findsOneWidget);
    expect(find.text('Lyrics'), findsOneWidget);
    // Favorites (star/unstar) and playlist sync are now implemented → shown.
    expect(find.text('Favorites'), findsOneWidget);
    expect(find.text('Playlists'), findsOneWidget);
  });

  testWidgets('Sign in is disabled until all three fields are filled',
      (tester) async {
    await _pump(tester);

    FilledButton signIn() => tester.widget<FilledButton>(
          find.widgetWithText(FilledButton, 'Sign in'),
        );
    expect(signIn().onPressed, isNull);

    await tester.enterText(find.byType(TextField).at(0), 'music.example.com');
    await tester.enterText(find.byType(TextField).at(1), 'alice');
    await tester.enterText(find.byType(TextField).at(2), 'hunter2');
    await tester.pump();

    expect(signIn().onPressed, isNotNull);
  });

  testWidgets('ticking legacy sign-in changes what the card promises',
      (tester) async {
    await _pump(tester);
    expect(
        find.textContaining('Your password is never stored'), findsOneWidget);

    await tester.tap(find.text('Legacy sign-in (https only)'));
    await tester.pump();

    expect(find.textContaining('Your password is never stored'), findsNothing);
    expect(
      find.textContaining('your password is kept encrypted on this device'),
      findsOneWidget,
    );
  });

  testWidgets('a restored legacy session says how it signed in',
      (tester) async {
    await _pump(
      tester,
      saved: const SubsonicSession(
        baseUrl: 'https://cloud.example.com',
        username: 'alice',
        isLegacy: true,
        password: 'api-key',
      ),
    );
    await tester.pump();

    expect(find.text('Signed in with legacy sign-in'), findsOneWidget);
    expect(find.textContaining('Your password is never stored'), findsNothing);
  });
}
