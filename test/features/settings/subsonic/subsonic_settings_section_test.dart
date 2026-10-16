import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/data/repositories/in_memory_subsonic_session_store.dart';
import 'package:linthra/data/repositories/subsonic_session_store_provider.dart';
import 'package:linthra/features/settings/subsonic/subsonic_settings_providers.dart';
import 'package:linthra/features/settings/subsonic/subsonic_settings_section.dart';

import '../../../core/sources/subsonic/fake_subsonic_client.dart';

Future<void> _pump(WidgetTester tester, {FakeSubsonicClient? client}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        subsonicClientProvider
            .overrideWithValue(client ?? FakeSubsonicClient()),
        subsonicSessionStoreProvider
            .overrideWithValue(InMemorySubsonicSessionStore()),
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

  // Opt-in legacy password sign-in.
  group('legacy password sign-in', () {
    final Finder toggle =
        find.byKey(const Key('subsonic_legacy_password_signin'));

    Future<void> fillForm(WidgetTester tester, String url) async {
      await tester.enterText(find.byType(TextField).at(0), url);
      await tester.enterText(find.byType(TextField).at(1), 'alice');
      await tester.enterText(find.byType(TextField).at(2), 'app-password');
      await tester.pump();
    }

    testWidgets('is off by default, and the card says the password is not kept',
        (tester) async {
      await _pump(tester);

      expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
      expect(find.textContaining('password is never stored'), findsOneWidget);
    });

    testWidgets('turned on, the card says what it costs and sign-in uses it',
        (tester) async {
      final FakeSubsonicClient client = FakeSubsonicClient();
      await _pump(tester, client: client);
      await fillForm(tester, 'https://cloud.example.com');

      await tester.ensureVisible(toggle);
      await tester.tap(toggle);
      await tester.pump();
      expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
      expect(find.textContaining('password is never stored'), findsNothing);
      expect(
        find.textContaining('kept encrypted on this device'),
        findsOneWidget,
      );

      await tester.ensureVisible(find.widgetWithText(FilledButton, 'Sign in'));
      await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
      await tester.pumpAndSettle();

      expect(client.lastCredentials!.password, 'app-password');
      expect(find.text('Legacy password sign-in'), findsOneWidget);
      expect(
          find.textContaining('kept encrypted on this device'), findsOneWidget);
    });

    testWidgets('sign-out turns it back off', (tester) async {
      await _pump(tester);
      await fillForm(tester, 'https://cloud.example.com');
      await tester.ensureVisible(toggle);
      await tester.tap(toggle);
      await tester.pump();
      await tester.ensureVisible(find.widgetWithText(FilledButton, 'Sign in'));
      await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
      await tester.pumpAndSettle();

      final Finder signOut = find.text('Sign out & clear');
      await tester.ensureVisible(signOut);
      await tester.tap(signOut);
      await tester.pumpAndSettle();

      expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
      expect(find.textContaining('password is never stored'), findsOneWidget);
    });

    testWidgets('a token session does not claim to keep the password',
        (tester) async {
      final FakeSubsonicClient client = FakeSubsonicClient();
      await _pump(tester, client: client);
      await fillForm(tester, 'music.example.com');
      await tester.ensureVisible(find.widgetWithText(FilledButton, 'Sign in'));
      await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
      await tester.pumpAndSettle();

      expect(client.lastCredentials!.password, isNull);
      expect(find.text('Legacy password sign-in'), findsNothing);
      expect(find.textContaining('password is never stored'), findsOneWidget);
    });
  });
}
