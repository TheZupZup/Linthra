import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/app/external_link_launcher_provider.dart';
import 'package:linthra/core/services/external_link_launcher.dart';
import 'package:linthra/core/sources/plex/plex_api.dart';
import 'package:linthra/core/sources/plex/plex_pin_auth.dart';
import 'package:linthra/data/repositories/in_memory_plex_session_store.dart';
import 'package:linthra/data/repositories/plex_session_store_provider.dart';
import 'package:linthra/features/settings/plex/plex_settings_providers.dart';
import 'package:linthra/features/settings/plex/plex_settings_section.dart';

import '../../../core/sources/plex/fake_plex_client.dart';
import '../../../core/sources/plex/fake_plex_tv_client.dart';

// The Plex token field has an eye toggle, and while the token is revealed the
// field is an ordinary text field as far as the keyboard is concerned: an
// obscured field is a password field to the IME, a revealed one is not. The
// section therefore turns suggestions and autocorrect off explicitly, so the
// token stays out of the keyboard's suggestion strip and learning store even
// while it is shown. This pins that, both on the widget and in the
// configuration actually sent to the platform text input, before and after
// the reveal.

const String _token = 'super-secret-plex-token';

class _NoopLauncher implements ExternalLinkLauncher {
  @override
  Future<bool> open(Uri url) async => true;
}

Future<void> _pump(WidgetTester tester) async {
  final FakePlexClient client = FakePlexClient(
    sections: const <PlexDirectory>[
      PlexDirectory(key: '5', title: 'Music', type: 'artist'),
    ],
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        plexClientProvider.overrideWithValue(client),
        plexSessionStoreProvider.overrideWithValue(InMemoryPlexSessionStore()),
        plexPinAuthProvider.overrideWith(
          (ref) => PlexPinAuth(
            tvClient: FakePlexTvClient(),
            serverClient: client,
            identity: ref.watch(plexClientIdentityProvider),
            wait: (_) async {},
          ),
        ),
        externalLinkLauncherProvider.overrideWithValue(_NoopLauncher()),
      ],
      child: const MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: PlexSettingsSection()),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.tap(find.text('Manual setup (advanced)'));
  await tester.pump();
}

Finder get _tokenField => find.widgetWithText(TextField, 'Plex token');

void _expectKeyboardKeptOut(
  WidgetTester tester, {
  required bool obscured,
}) {
  final TextField field = tester.widget<TextField>(_tokenField);
  expect(field.obscureText, obscured);
  expect(field.enableSuggestions, isFalse);
  expect(field.autocorrect, isFalse);

  // What the platform keyboard is actually told, which is what decides
  // whether it suggests or learns.
  final Map<String, dynamic> config = tester.testTextInput.setClientArgs!;
  expect(config['obscureText'], obscured);
  expect(config['enableSuggestions'], isFalse);
  expect(config['autocorrect'], isFalse);
}

void main() {
  testWidgets('the obscured token field keeps suggestions and autocorrect off',
      (tester) async {
    await _pump(tester);

    await tester.enterText(_tokenField, _token);
    await tester.pump();

    _expectKeyboardKeptOut(tester, obscured: true);
  });

  testWidgets('revealing the token keeps suggestions and autocorrect off',
      (tester) async {
    await _pump(tester);
    await tester.enterText(_tokenField, _token);
    await tester.pump();

    await tester.tap(find.byTooltip('Show token'));
    await tester.pump();

    expect(find.byTooltip('Hide token'), findsOneWidget);
    // The reveal reconfigures the live connection rather than opening a new
    // one, so this is the update the keyboard receives.
    expect(
      tester.testTextInput.log.map((MethodCall call) => call.method),
      contains('TextInput.updateConfig'),
    );
    _expectKeyboardKeptOut(tester, obscured: false);
  });
}
