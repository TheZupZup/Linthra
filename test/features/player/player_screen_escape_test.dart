import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/features/player/player_providers.dart';
import 'package:linthra/features/player/player_screen.dart';

import 'fake_playback_controller.dart';

const Track _track = Track(id: '1', title: 'Song One', uri: '/music/one.mp3');

/// A page that opens Now Playing on top of itself, the way the bottom bar and
/// the mini-player do.
Future<void> _openNowPlaying(
  WidgetTester tester, {
  TargetPlatform? platform,
}) async {
  final FakePlaybackController controller = FakePlaybackController(
    initial: const PlaybackState(
      status: PlaybackStatus.paused,
      currentTrack: _track,
    ),
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        playbackControllerProvider.overrideWithValue(controller),
      ],
      child: MaterialApp(
        theme: platform == null ? null : ThemeData(platform: platform),
        home: Builder(
          builder: (BuildContext context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const PlayerScreen(),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  expect(find.byType(PlayerScreen), findsOneWidget);
}

void main() {
  testWidgets('Escape leaves Now Playing on a desktop', (tester) async {
    await _openNowPlaying(tester, platform: TargetPlatform.linux);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(find.byType(PlayerScreen), findsNothing);
    expect(find.text('open'), findsOneWidget);
  });

  testWidgets('adds no stop of its own to the Tab order', (tester) async {
    await _openNowPlaying(tester, platform: TargetPlatform.linux);
    final FocusNode? holder = FocusManager.instance.primaryFocus;

    // The first Tab lands on the close button, as it always did.
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    final BuildContext? focused = FocusManager.instance.primaryFocus?.context;
    expect(focused, isNotNull);
    expect(
      find.ancestor(
        of: find.byWidget(focused!.widget),
        matching: find.byTooltip('Close'),
      ),
      findsOneWidget,
    );

    // And Shift+Tab from there goes round to the last control rather than
    // back to the node that took the keyboard when the screen opened.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shift);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shift);
    await tester.pump();
    expect(FocusManager.instance.primaryFocus, isNot(holder));
  });

  testWidgets('a dialog over Now Playing keeps Escape to itself',
      (tester) async {
    await _openNowPlaying(tester, platform: TargetPlatform.linux);
    unawaited(showDialog<void>(
      context: tester.element(find.byType(PlayerScreen)),
      builder: (_) => const AlertDialog(content: Text('a dialog')),
    ));
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(find.text('a dialog'), findsNothing);
    expect(find.byType(PlayerScreen), findsOneWidget);

    // And the screen has the key back once the dialog is gone.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(PlayerScreen), findsNothing);
  });

  testWidgets('a phone leaves Escape alone', (tester) async {
    await _openNowPlaying(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(find.byType(PlayerScreen), findsOneWidget);
  });
}
