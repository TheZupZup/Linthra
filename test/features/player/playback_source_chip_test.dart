import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/playback_source.dart';
import 'package:linthra/features/player/widgets/track_metadata.dart';

Future<void> _pumpChip(
  WidgetTester tester,
  PlaybackSource source, {
  TargetPlatform? platform,
}) {
  return tester.pumpWidget(
    MaterialApp(
      theme: platform == null ? null : ThemeData(platform: platform),
      home: Scaffold(
        body: PlaybackSourceChip(source: source, trackUri: '/music/one.mp3'),
      ),
    ),
  );
}

void main() {
  testWidgets('a phone shows local music as on the phone', (tester) async {
    await _pumpChip(tester, PlaybackSource.localFile);

    expect(find.byIcon(Icons.smartphone_outlined), findsOneWidget);
  });

  testWidgets('a desktop shows local music as on the computer', (tester) async {
    await _pumpChip(
      tester,
      PlaybackSource.localFile,
      platform: TargetPlatform.linux,
    );

    expect(find.byIcon(Icons.computer_outlined), findsOneWidget);
    expect(find.byIcon(Icons.smartphone_outlined), findsNothing);
  });

  testWidgets('streams and the cache look the same on a desktop',
      (tester) async {
    await _pumpChip(
      tester,
      PlaybackSource.streamingDirect,
      platform: TargetPlatform.linux,
    );
    expect(find.byIcon(Icons.cloud_outlined), findsOneWidget);

    await _pumpChip(
      tester,
      PlaybackSource.offlineCache,
      platform: TargetPlatform.linux,
    );
    expect(find.byIcon(Icons.offline_pin_outlined), findsOneWidget);
  });
}
