import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/app/linthra_app.dart';
import 'package:linthra/features/player/player_providers.dart';

import 'features/player/fake_playback_controller.dart';

void main() {
  testWidgets('App boots to the Library screen', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          // The persistent shell hosts the mini-player, which reads the
          // playback controller; use the fake so the smoke test never touches
          // the audio plugin.
          playbackControllerProvider
              .overrideWithValue(FakePlaybackController()),
        ],
        child: const LinthraApp(),
      ),
    );
    await tester.pumpAndSettle();

    // The persistent shell and its bottom navigation render.
    expect(find.byType(NavigationBar), findsOneWidget);

    // The initial route is the Library tab. With no folder selected yet, the
    // empty state invites the user to choose one.
    expect(find.text('No music folder selected'), findsOneWidget);
  });
}
