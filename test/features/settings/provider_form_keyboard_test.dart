import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/data/repositories/in_memory_jellyfin_session_store.dart';
import 'package:linthra/data/repositories/jellyfin_session_store_provider.dart';
import 'package:linthra/features/settings/jellyfin/jellyfin_settings_providers.dart';
import 'package:linthra/features/settings/jellyfin/jellyfin_settings_section.dart';

import '../../core/sources/jellyfin/fake_jellyfin_client.dart';
import 'jellyfin/fake_jellyfin_authenticator.dart';

/// Connecting a music provider without a mouse (#390).
///
/// A provider card is the one place in Linthra where a keyboard user has to
/// type as well as navigate, which makes it the surface where "keyboard
/// navigation" is easiest to break: a stray shortcut above the page would eat a
/// character or move focus mid-word. The rules here are the plain ones: Tab
/// walks the fields in the order they read, typing is typing, and Enter on the
/// last field submits the form.

Future<FakeJellyfinAuthenticator> _pumpSection(WidgetTester tester) async {
  final FakeJellyfinAuthenticator authenticator = FakeJellyfinAuthenticator();
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
  await tester.pump();
  return authenticator;
}

/// The label of the field that currently holds the keyboard, or null when the
/// focus is not in one.
String? _focusedField(WidgetTester tester) {
  final BuildContext? context = FocusManager.instance.primaryFocus?.context;
  if (context == null) return null;
  final EditableText? field =
      context.findAncestorWidgetOfExactType<EditableText>();
  if (field == null) return null;
  for (final TextField candidate in tester.widgetList<TextField>(
    find.byType(TextField),
  )) {
    if (candidate.controller == field.controller) {
      return (candidate.decoration?.labelText);
    }
  }
  return null;
}

Future<void> _tab(WidgetTester tester) async {
  await tester.sendKeyEvent(LogicalKeyboardKey.tab);
  await tester.pump();
}

void main() {
  testWidgets('Tab walks the form in the order it reads', (tester) async {
    await _pumpSection(tester);

    await tester.tap(find.byType(TextField).first);
    await tester.pump();
    expect(_focusedField(tester), 'Server URL');

    await _tab(tester);
    expect(_focusedField(tester), 'Username');

    await _tab(tester);
    expect(_focusedField(tester), 'Password');
  });

  testWidgets('Shift+Tab retraces it', (tester) async {
    await _pumpSection(tester);
    await tester.tap(find.byType(TextField).at(2));
    await tester.pump();
    expect(_focusedField(tester), 'Password');

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shift);
    await _tab(tester);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shift);

    expect(_focusedField(tester), 'Username');
  });

  testWidgets('typing and editing are untouched', (tester) async {
    await _pumpSection(tester);
    final Finder url = find.byType(TextField).first;

    await tester.enterText(url, 'https://music.example.com');
    await tester.pump();

    // The arrow keys move the caret rather than the focus: nothing added for
    // lists or panes reaches into a field.
    final EditableTextState state = tester.state(
      find.byType(EditableText).first,
    );
    expect(state.textEditingValue.text, 'https://music.example.com');
    state.userUpdateTextEditingValue(
      state.textEditingValue.copyWith(
        selection: const TextSelection.collapsed(offset: 8),
      ),
      SelectionChangedCause.keyboard,
    );
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();

    expect(_focusedField(tester), 'Server URL');
    expect(state.textEditingValue.selection.baseOffset, 7);
  });

  testWidgets('Enter on the last field signs in', (tester) async {
    final FakeJellyfinAuthenticator authenticator = await _pumpSection(tester);

    await tester.enterText(
      find.byType(TextField).at(0),
      'https://music.example.com',
    );
    await tester.enterText(find.byType(TextField).at(1), 'alice');
    await tester.enterText(find.byType(TextField).at(2), 'secret');
    await tester.pump();

    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    // No trip to the Sign in button needed: the form submits from the field
    // the user is already in, which is what every desktop login does.
    expect(authenticator.lastSignInUrl, 'https://music.example.com');
    expect(authenticator.lastUsername, 'alice');
  });
}
