import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/features/player/widgets/now_playing_actions.dart';

void main() {
  testWidgets('Now Playing actions include Add to playlist', (tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: NowPlayingActions(
              track: Track(id: '1', title: 'Song One', uri: 'jellyfin:1'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byTooltip('Add to playlist'), findsOneWidget);
  });
}
