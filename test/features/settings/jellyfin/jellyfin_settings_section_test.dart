import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/sources/jellyfin/jellyfin_exception.dart';
import 'package:linthra/data/repositories/in_memory_jellyfin_session_store.dart';
import 'package:linthra/data/repositories/jellyfin_session_store_provider.dart';
import 'package:linthra/features/settings/jellyfin/jellyfin_settings_providers.dart';
import 'package:linthra/features/settings/jellyfin/jellyfin_settings_section.dart';

import '../../../core/sources/jellyfin/fake_jellyfin_client.dart';
import 'fake_jellyfin_authenticator.dart';

Future<void> _pumpSection(
  WidgetTester tester, {
  required FakeJellyfinAuthenticator authenticator,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        jellyfinAuthenticatorProvider.overrideWithValue(authenticator),
        jellyfinSessionStoreProvider
            .overrideWithValue(InMemoryJellyfinSessionStore()),
        jellyfinClientProvider.overrideWithValue(FakeJellyfinClient()),
      ],
      child: const MaterialApp(
        home: Scaffold(body: JellyfinSettingsSection()),
      ),
    ),
  );
  // Let the controller's initial (empty) load settle.
  await tester.pump();
}

Future<void> _fillForm(
  WidgetTester tester, {
  required String url,
  String? username,
  String? password,
}) async {
  final Finder fields = find.byType(TextField);
  await tester.enterText(fields.at(0), url);
  if (username != null) {
    await tester.enterText(fields.at(1), username);
  }
  if (password != null) {
    await tester.enterText(fields.at(2), password);
  }
  await tester.pump();
}

void main() {
  group('JellyfinSettingsSection', () {
    testWidgets('shows the connection form when disconnected', (tester) async {
      await _pumpSection(tester, authenticator: FakeJellyfinAuthenticator());

      expect(find.text('Jellyfin'), findsOneWidget);
      expect(find.text('Test connection'), findsOneWidget);
      expect(find.text('Sign in'), findsOneWidget);
      expect(find.byType(TextField), findsNWidgets(3));
    });

    testWidgets('test connection shows the reached server', (tester) async {
      await _pumpSection(tester, authenticator: FakeJellyfinAuthenticator());
      await _fillForm(tester, url: 'music.example.com');

      await tester.tap(find.text('Test connection'));
      await tester.pump();
      await tester.pump();

      expect(find.textContaining('My Server'), findsOneWidget);
    });

    testWidgets('signing in shows the connected view', (tester) async {
      await _pumpSection(tester, authenticator: FakeJellyfinAuthenticator());
      await _fillForm(
        tester,
        url: 'music.example.com',
        username: 'alice',
        password: 'pw',
      );

      await tester.tap(find.text('Sign in'));
      await tester.pump();
      await tester.pump();

      expect(find.text('Sign out & clear'), findsOneWidget);
      // Shown both as the connected-view subtitle and the confirmation line.
      expect(find.textContaining('Signed in as alice'), findsWidgets);
    });

    testWidgets('signing out returns to the form', (tester) async {
      await _pumpSection(tester, authenticator: FakeJellyfinAuthenticator());
      await _fillForm(
        tester,
        url: 'music.example.com',
        username: 'alice',
        password: 'pw',
      );
      await tester.tap(find.text('Sign in'));
      await tester.pump();
      await tester.pump();

      await tester.tap(find.text('Sign out & clear'));
      await tester.pump();
      await tester.pump();

      expect(find.text('Sign in'), findsOneWidget);
      expect(find.text('Test connection'), findsOneWidget);
    });

    testWidgets('a failed sign-in shows a friendly error', (tester) async {
      await _pumpSection(
        tester,
        authenticator: FakeJellyfinAuthenticator(
          signInError: JellyfinException.unauthorized(),
        ),
      );
      await _fillForm(
        tester,
        url: 'music.example.com',
        username: 'alice',
        password: 'bad',
      );

      await tester.tap(find.text('Sign in'));
      await tester.pump();
      await tester.pump();

      expect(find.textContaining('not accepted'), findsOneWidget);
    });

    testWidgets('copies a secret-free diagnostics report to the clipboard',
        (tester) async {
      final List<MethodCall> clipboardCalls = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (MethodCall call) async {
          if (call.method == 'Clipboard.setData') {
            clipboardCalls.add(call);
          }
          return null;
        },
      );
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null));

      await _pumpSection(tester, authenticator: FakeJellyfinAuthenticator());
      await _fillForm(
        tester,
        url: 'music.example.com',
        username: 'alice',
        password: 'pw',
      );
      await tester.tap(find.text('Sign in'));
      await tester.pump();
      await tester.pump();

      // The diagnostics action appears once connected.
      expect(find.text('Copy Jellyfin diagnostics'), findsOneWidget);

      await tester.tap(find.text('Copy Jellyfin diagnostics'));
      await tester.pump();

      expect(clipboardCalls, hasLength(1));
      final Map<dynamic, dynamic> args =
          clipboardCalls.single.arguments as Map<dynamic, dynamic>;
      final String copied = args['text'] as String;
      expect(copied, contains('Linthra Jellyfin diagnostics'));
      expect(copied, contains('App version:'));
      // The fake session's token must never reach the clipboard.
      expect(copied, isNot(contains('fake-token')));
      expect(copied, isNot(contains('api_key')));

      // Let the confirmation SnackBar's auto-dismiss timer fire so the test
      // ends with no pending timers.
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
    });
  });
}
