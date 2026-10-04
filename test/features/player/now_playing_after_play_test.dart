import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/features/player/now_playing_after_play.dart';

void main() {
  testWidgets('only a phone opens Now Playing when playback starts',
      (tester) async {
    late bool opens;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (BuildContext context) {
            opens = opensNowPlayingOnPlay(context);
            return const SizedBox();
          },
        ),
      ),
    );

    final bool desktop = <TargetPlatform>{
      TargetPlatform.linux,
      TargetPlatform.macOS,
      TargetPlatform.windows,
    }.contains(defaultTargetPlatform);
    expect(opens, !desktop);
  }, variant: TargetPlatformVariant.all());
}
