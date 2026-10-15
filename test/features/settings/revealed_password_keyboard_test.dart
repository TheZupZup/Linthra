// A revealed password stays out of the keyboard's suggestions.
//
// The Plex token field keeps suggestions and autocorrect off even while it
// is revealed with the eye toggle. The Jellyfin, Subsonic and Audiobookshelf
// password fields had the same toggle but set only obscureText, so once
// revealed the platform text input was reconfigured with suggestions and
// autocorrect on, and on Android the keyboard got an ordinary auto-correcting
// field that may suggest from and learn what is typed in it.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/sources/audiobookshelf/audiobookshelf_api.dart';
import 'package:linthra/data/repositories/audiobookshelf_session_store_provider.dart';
import 'package:linthra/data/repositories/in_memory_audiobookshelf_session_store.dart';
import 'package:linthra/data/repositories/in_memory_jellyfin_session_store.dart';
import 'package:linthra/data/repositories/in_memory_subsonic_session_store.dart';
import 'package:linthra/data/repositories/jellyfin_session_store_provider.dart';
import 'package:linthra/data/repositories/subsonic_session_store_provider.dart';
import 'package:linthra/features/settings/audiobookshelf/audiobookshelf_settings_providers.dart';
import 'package:linthra/features/settings/audiobookshelf/audiobookshelf_settings_section.dart';
import 'package:linthra/features/settings/jellyfin/jellyfin_settings_providers.dart';
import 'package:linthra/features/settings/jellyfin/jellyfin_settings_section.dart';
import 'package:linthra/features/settings/subsonic/subsonic_settings_providers.dart';
import 'package:linthra/features/settings/subsonic/subsonic_settings_section.dart';

import '../../core/sources/audiobookshelf/fake_audiobookshelf_client.dart';
import '../../core/sources/jellyfin/fake_jellyfin_client.dart';
import '../../core/sources/subsonic/fake_subsonic_client.dart';
import 'jellyfin/fake_jellyfin_authenticator.dart';

const String _password = 'hunter2-do-not-learn';

Future<void> _pumpJellyfin(WidgetTester tester) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        jellyfinAuthenticatorProvider
            .overrideWithValue(FakeJellyfinAuthenticator()),
        jellyfinSessionStoreProvider
            .overrideWithValue(InMemoryJellyfinSessionStore()),
        jellyfinClientProvider.overrideWithValue(FakeJellyfinClient()),
      ],
      child: const MaterialApp(
        home: Scaffold(body: JellyfinSettingsSection()),
      ),
    ),
  );
  await tester.pump();
}

Future<void> _pumpSubsonic(WidgetTester tester) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        subsonicClientProvider.overrideWithValue(FakeSubsonicClient()),
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
  await tester.pumpAndSettle();
}

Future<void> _pumpAudiobookshelf(WidgetTester tester) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        audiobookshelfClientProvider.overrideWithValue(
          FakeAudiobookshelfClient(
            serverStatus: const AudiobookshelfServerStatus(
              serverVersion: '2.17.0',
              isInitialized: true,
            ),
            authResult: const AudiobookshelfAuthResult(
              userId: 'user-1',
              accessToken: 'tok-1',
            ),
          ),
        ),
        audiobookshelfSessionStoreProvider.overrideWithValue(
          InMemoryAudiobookshelfSessionStore(),
        ),
      ],
      child: const MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: AudiobookshelfSettingsSection()),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _revealPassword(WidgetTester tester) async {
  final Finder field = find.widgetWithText(TextField, 'Password');
  await tester.enterText(field, _password);
  await tester.pump();
  await tester.tap(find.byTooltip('Show password'));
  await tester.pump();
  expect(find.byTooltip('Hide password'), findsOneWidget);
}

/// The keyboard-facing flags of the revealed password field, from the widget
/// and from the configuration last sent to the platform text input.
Map<String, Object?> _revealedKeyboardFlags(WidgetTester tester) {
  final TextField field =
      tester.widget<TextField>(find.widgetWithText(TextField, 'Password'));
  final Map<String, dynamic> config = tester.testTextInput.setClientArgs!;
  return <String, Object?>{
    'widget.enableSuggestions': field.enableSuggestions,
    'widget.autocorrect': field.autocorrect,
    'platform.enableSuggestions': config['enableSuggestions'],
    'platform.autocorrect': config['autocorrect'],
  };
}

const Map<String, Object?> _plexParity = <String, Object?>{
  'widget.enableSuggestions': false,
  'widget.autocorrect': false,
  'platform.enableSuggestions': false,
  'platform.autocorrect': false,
};

void main() {
  testWidgets(
      'Jellyfin: a revealed password keeps suggestions and autocorrect off',
      (tester) async {
    await _pumpJellyfin(tester);
    await _revealPassword(tester);

    expect(_revealedKeyboardFlags(tester), _plexParity);
  });

  testWidgets(
      'Subsonic: a revealed password keeps suggestions and autocorrect off',
      (tester) async {
    await _pumpSubsonic(tester);
    await _revealPassword(tester);

    expect(_revealedKeyboardFlags(tester), _plexParity);
  });

  testWidgets(
      'Audiobookshelf: a revealed password keeps suggestions and autocorrect '
      'off', (tester) async {
    await _pumpAudiobookshelf(tester);
    await _revealPassword(tester);

    expect(_revealedKeyboardFlags(tester), _plexParity);
  });
}
