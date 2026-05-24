import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/data/repositories/download_repository_provider.dart';
import 'package:linthra/features/library/widgets/track_tile.dart';

import 'fake_remote_track_downloader.dart';

Future<void> _pump(WidgetTester tester, List<Track> tracks) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        remoteTrackDownloaderProvider
            .overrideWithValue(FakeRemoteTrackDownloader()),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: ListView(
            children: [
              for (var i = 0; i < tracks.length; i++)
                TrackTile(tracks: tracks, index: i),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('TrackTile', () {
    testWidgets('shows the title and a clean artist • album subtitle', (
      tester,
    ) async {
      await _pump(tester, const <Track>[
        Track(
          id: '1',
          title: 'Song One',
          uri: 'file:///s1.mp3',
          artistName: 'Artist A',
          albumName: 'Album X',
        ),
      ]);

      expect(find.text('Song One'), findsOneWidget);
      expect(find.text('Artist A • Album X'), findsOneWidget);
    });

    testWidgets('falls back to the uri when metadata is missing', (
      tester,
    ) async {
      await _pump(tester, const <Track>[
        Track(id: '2', title: 'Song Two', uri: 'file:///s2.mp3'),
      ]);

      expect(find.text('Song Two'), findsOneWidget);
      expect(find.text('file:///s2.mp3'), findsOneWidget);
    });

    testWidgets('exposes a trailing overflow menu', (tester) async {
      await _pump(tester, const <Track>[
        Track(id: '1', title: 'Song One', uri: 'file:///s1.mp3'),
      ]);

      expect(find.byTooltip('More actions'), findsOneWidget);
      // No dedicated, always-visible download button on the row anymore.
      expect(find.byTooltip('Download'), findsNothing);
    });
  });
}
