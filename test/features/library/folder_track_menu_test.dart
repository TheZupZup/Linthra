import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:linthra/core/models/music_folder.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/folder_browsable_music_source.dart';
import 'package:linthra/features/library/folder_browser_providers.dart';
import 'package:linthra/features/library/folders_screen.dart';
import 'package:linthra/features/library/unified_library_providers.dart';
import 'package:linthra/features/library/widgets/track_tile.dart';
import 'package:linthra/features/player/player_providers.dart';

import '../player/fake_playback_controller.dart';

/// "Show album" has to lead somewhere (#386).
///
/// The folder browser lists a server's tree on demand, so it happily shows a
/// well-tagged track the flat catalog has never seen — browsed before a sync,
/// or from a library the user never synced at all. The album page resolves its
/// id against that catalog alone, so offering the action there drops the user
/// on "Album not found" straight after they picked a song that plays fine.
const Track _track = Track(
  id: 'f1',
  title: 'One More Time',
  uri: 'subsonic:f1',
  artistName: 'Daft Punk',
  albumName: 'Discovery',
);

class _FakeFolderSource implements FolderBrowsableMusicSource {
  @override
  String get id => 'subsonic';

  @override
  String get displayName => 'Navidrome';

  @override
  Future<List<MusicFolder>> fetchRootFolders() async =>
      const <MusicFolder>[MusicFolder(id: 'r1', name: 'Music')];

  @override
  Future<MusicFolderListing> fetchFolder(String folderId) async =>
      const MusicFolderListing(tracks: <Track>[_track]);
}

/// Pumps the folder browser one level in, over a catalog holding [catalog].
Future<void> _pumpInFolder(
  WidgetTester tester, {
  required List<Track> catalog,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        folderBrowsableSourcesProvider
            .overrideWithValue(<FolderBrowsableMusicSource>[
          _FakeFolderSource(),
        ]),
        libraryUnifiedTracksProvider.overrideWithValue(catalog),
        playbackControllerProvider.overrideWithValue(FakePlaybackController()),
      ],
      child: MaterialApp.router(
        routerConfig: GoRouter(
          routes: <RouteBase>[
            GoRoute(path: '/', builder: (_, __) => const FoldersScreen()),
          ],
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();

  await tester.tap(find.text('Music'));
  await tester.pumpAndSettle();
  expect(find.byType(TrackTile), findsOneWidget);
}

Future<void> _rightClickTrack(WidgetTester tester) async {
  final TestGesture gesture = await tester.startGesture(
    tester.getCenter(find.byType(TrackTile)),
    kind: PointerDeviceKind.mouse,
    buttons: kSecondaryMouseButton,
  );
  await gesture.up();
  await tester.pumpAndSettle();
}

void main() {
  group('a browsed track that the catalog does not have', () {
    testWidgets('is not offered a collection page it cannot open',
        (tester) async {
      await _pumpInFolder(tester, catalog: const <Track>[]);
      await _rightClickTrack(tester);

      // Everything that acts on the track itself still works from here.
      expect(find.text('Play next'), findsOneWidget);
      expect(find.text('Add to queue'), findsOneWidget);
      // The two that would navigate into the catalog are the ones withheld.
      expect(find.text('Show album'), findsNothing);
      expect(find.text('Show artist'), findsNothing);
    });

    testWidgets('gets both back once the catalog knows the track',
        (tester) async {
      await _pumpInFolder(tester, catalog: const <Track>[_track]);
      await _rightClickTrack(tester);

      expect(find.text('Show album'), findsOneWidget);
      expect(find.text('Show artist'), findsOneWidget);
    });
  });
}
