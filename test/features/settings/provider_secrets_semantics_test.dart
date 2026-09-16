import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/jellyfin_session.dart';
import 'package:linthra/data/repositories/in_memory_jellyfin_session_store.dart';
import 'package:linthra/data/repositories/in_memory_subsonic_session_store.dart';
import 'package:linthra/data/repositories/jellyfin_session_store_provider.dart';
import 'package:linthra/data/repositories/subsonic_session_store_provider.dart';
import 'package:linthra/features/settings/jellyfin/jellyfin_settings_providers.dart';
import 'package:linthra/features/settings/jellyfin/jellyfin_settings_section.dart';
import 'package:linthra/features/settings/subsonic/subsonic_settings_providers.dart';
import 'package:linthra/features/settings/subsonic/subsonic_settings_section.dart';

import '../../core/sources/jellyfin/fake_jellyfin_client.dart';
import '../../core/sources/subsonic/fake_subsonic_client.dart';
import 'jellyfin/fake_jellyfin_authenticator.dart';

/// Semantics is an easy place to leak a secret: a label built from a token is
/// invisible on screen and read out loud (#90). The Plex section — the one with
/// a bare access token — is already held to this next door; this covers the
/// other two connection surfaces, where the token is a saved session the user
/// never types.
///
/// What is *not* asserted: the absence of the server URL and username. A
/// connection form shows those on purpose — the user typed them and has to be
/// able to check them — so a test forbidding them would be testing against the
/// product. The line is the credential.

const String _accessToken = 'jf-secret-access-token';
const String _password = 'hunter2-not-for-speaking';

/// Every string a screen reader could read out of the tree.
List<String> _spoken(WidgetTester tester) {
  final List<String> spoken = <String>[];
  void walk(SemanticsNode node) {
    final SemanticsData data = node.getSemanticsData();
    spoken
      ..add(data.label)
      ..add(data.value)
      ..add(data.hint)
      ..add(data.tooltip)
      ..add(data.increasedValue)
      ..add(data.decreasedValue);
    node.visitChildren((SemanticsNode child) {
      walk(child);
      return true;
    });
  }

  // Walked from the app's own node rather than the binding's semantics
  // owner, which is deprecated.
  walk(tester.getSemantics(find.byType(MaterialApp)));
  return spoken.where((String s) => s.isNotEmpty).toList();
}

void _expectNothingLeaks(WidgetTester tester, List<String> secrets) {
  final List<String> spoken = _spoken(tester);
  expect(spoken, isNotEmpty, reason: 'nothing was read at all — bad harness');
  for (final String text in spoken) {
    for (final String secret in secrets) {
      expect(
        text,
        isNot(contains(secret)),
        reason: 'a screen reader would say a secret: "$text"',
      );
    }
  }
}

Future<void> _pumpJellyfinConnected(WidgetTester tester) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        jellyfinAuthenticatorProvider
            .overrideWithValue(FakeJellyfinAuthenticator()),
        jellyfinSessionStoreProvider.overrideWithValue(
          InMemoryJellyfinSessionStore(
            initialSession: const JellyfinSession(
              baseUrl: 'http://192.168.22.1:8096',
              userId: 'user-1',
              accessToken: _accessToken,
              deviceId: 'device-1',
              userName: 'alice',
            ),
          ),
        ),
        jellyfinClientProvider.overrideWithValue(FakeJellyfinClient()),
      ],
      child: const MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: JellyfinSettingsSection()),
        ),
      ),
    ),
  );
  for (int i = 0; i < 8; i++) {
    await tester.pump();
  }
}

Future<void> _pumpSubsonicForm(WidgetTester tester) async {
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
  await tester.pump();
}

void main() {
  testWidgets('a saved Jellyfin token is never spoken', (tester) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    await _pumpJellyfinConnected(tester);

    _expectNothingLeaks(tester, <String>[_accessToken]);
    handle.dispose();
  });

  testWidgets('a typed Jellyfin password is obscured in semantics too',
      (tester) async {
    final SemanticsHandle handle = tester.ensureSemantics();
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
          home: Scaffold(
            body: SingleChildScrollView(child: JellyfinSettingsSection()),
          ),
        ),
      ),
    );
    await tester.pump();

    final Finder fields = find.byType(TextField);
    await tester.enterText(fields.at(0), 'http://192.168.22.1:8096');
    await tester.enterText(fields.at(1), 'alice');
    await tester.enterText(fields.at(2), _password);
    await tester.pump();

    _expectNothingLeaks(tester, <String>[_password]);
    handle.dispose();
  });

  testWidgets('a typed Navidrome password is obscured in semantics too',
      (tester) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    await _pumpSubsonicForm(tester);

    final Finder fields = find.byType(TextField);
    await tester.enterText(fields.at(0), 'http://192.168.22.1:4533');
    await tester.enterText(fields.at(1), 'alice');
    await tester.enterText(fields.at(2), _password);
    await tester.pump();

    _expectNothingLeaks(tester, <String>[_password]);
    handle.dispose();
  });

  testWidgets('the password field says what it is, and that it is obscured',
      (tester) async {
    // The other half of the rule: hiding the value must not leave the field
    // nameless, or it is unusable rather than merely safe.
    final SemanticsHandle handle = tester.ensureSemantics();
    await _pumpSubsonicForm(tester);

    final SemanticsNode password = tester.getSemantics(
      find.byType(EditableText).at(2),
    );
    final SemanticsData data = password.getSemanticsData();

    expect(data.label, contains('Password'));
    expect(
      password.flagsCollection.isObscured,
      isTrue,
      reason: 'an obscured field is what keeps the typed value out of the '
          'semantics value in the first place',
    );

    handle.dispose();
  });
}
