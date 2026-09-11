// A memory measurement harness, not a regression test.
//
// It drives the real Library UI over a large synthetic catalog and records the
// process's resident set size at labelled points, then writes the series to
// JSON for tools/large_library/memory_report.py to analyse. Nothing here
// decides whether a number is good: the point of #463 is that no single RSS
// figure is comparable across machines, so the verdict is about the *shape* of
// the series and lives in one place, the analyser.
//
// Deliberately named `_bench.dart`, not `_test.dart`, so `flutter test` does
// not pick it up: it is slow, the numbers are machine-dependent, and it would
// make a flaky CI gate.
//
// Run it through tools/large_library/run_memory_check.sh, which runs it twice
// (clean, and with a deliberate leak) and checks that the analyser tells them
// apart. To run it by hand:
//
//     LINTHRA_MEMORY_OUT=/tmp/clean.json \
//       flutter test test/benchmarks/large_library_memory_bench.dart
//     python3 tools/large_library/memory_report.py /tmp/clean.json
//
// Environment:
//   LINTHRA_MEMORY_OUT     where to write the JSON (default build/memory.json)
//   LINTHRA_MEMORY_TRACKS  synthetic library size (default 12000)
//   LINTHRA_MEMORY_CYCLES  navigation cycles to repeat (default 8)
//   LINTHRA_MEMORY_LEAK    "1" to retain objects on purpose, so the method can
//                          be shown to catch a real retained-object regression
//
// **No production code knows this exists.** There is no profiling hook, no
// debug flag and no instrumented build: the harness is a test that reads
// ProcessInfo.currentRss, so nothing here can reach a release artifact.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:linthra/app/routes.dart';
import 'package:linthra/core/models/album.dart';
import 'package:linthra/core/models/artist.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/repositories/music_library_repository.dart';
import 'package:linthra/data/repositories/in_memory_playlist_store.dart';
import 'package:linthra/data/repositories/music_library_repository_provider.dart';
import 'package:linthra/data/repositories/playlist_repository_provider.dart';
import 'package:linthra/features/library/album_detail_screen.dart';
import 'package:linthra/features/library/artist_detail_screen.dart';
import 'package:linthra/features/library/library_screen.dart';
import 'package:linthra/features/player/player_providers.dart';
import 'package:linthra/features/player/player_screen.dart';

import '../features/player/fake_playback_controller.dart';

int _envInt(String name, int fallback) {
  final String? raw = Platform.environment[name];
  return raw == null ? fallback : (int.tryParse(raw) ?? fallback);
}

final int _trackCount = _envInt('LINTHRA_MEMORY_TRACKS', 12000);
final int _cycleCount = _envInt('LINTHRA_MEMORY_CYCLES', 8);
final bool _leak = Platform.environment['LINTHRA_MEMORY_LEAK'] == '1';
final String _outPath =
    Platform.environment['LINTHRA_MEMORY_OUT'] ?? 'build/memory.json';

/// Where a deliberately introduced regression parks its objects.
///
/// This is what "a retained-object leak" means in practice: something the app
/// keeps a reference to per navigation, that nothing ever drops. Making the
/// harness able to produce one on demand is the only way to show the method can
/// actually catch one, rather than asserting that it would.
final List<List<int>> _deliberatelyRetained = <List<int>>[];

/// A catalog served from memory, sized to order.
///
/// Not the shared FakeMusicLibraryRepository: that one filters every read
/// against a removed-uris list, which is fine for a handful of tracks and is
/// not the shape a memory measurement wants between it and the UI.
class _SyntheticLibrary implements MusicLibraryRepository {
  _SyntheticLibrary(this.tracks);

  final List<Track> tracks;

  @override
  Future<List<Track>> getAllTracks() async => tracks;

  @override
  Future<List<Album>> getAllAlbums() async => const <Album>[];

  @override
  Future<List<Artist>> getAllArtists() async => const <Artist>[];

  @override
  Future<Track?> getTrackByUri(String uri) async {
    for (final Track track in tracks) {
      if (track.uri == uri) return track;
    }
    return null;
  }

  @override
  Future<void> upsertCatalog({
    required String sourceId,
    required List<Track> tracks,
    required List<Album> albums,
    required List<Artist> artists,
  }) async {}

  @override
  Future<void> removeTracks(List<String> trackUris) async {}
}

/// A 1x1 PNG, written to disk once per album so artwork rendering does real
/// file reads and real decodes.
///
/// Real covers rather than nulls matter here: Flutter's image cache is one of
/// the biggest things holding memory during a scroll, and a run with no artwork
/// would miss exactly the retention this is looking for. Tiny ones, because the
/// question is how many are held, not how large each is.
const List<int> _pngBytes = <int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
  0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
  0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
  0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
  0x42, 0x60, 0x82,
];

/// One sample: what the process weighed at a named point.
class _Sample {
  _Sample(this.name, this.rssBytes, this.elapsedMs, {this.cycle});

  final String name;
  final int rssBytes;
  final int elapsedMs;
  final int? cycle;

  Map<String, Object?> toJson() => <String, Object?>{
        'name': name,
        'rss_bytes': rssBytes,
        'elapsed_ms': elapsedMs,
        if (cycle != null) 'cycle': cycle,
      };
}

final List<_Sample> _phases = <_Sample>[];
final List<_Sample> _cycles = <_Sample>[];
final Stopwatch _clock = Stopwatch()..start();

void _record(String name, {int? cycle}) {
  final _Sample sample = _Sample(
    name,
    ProcessInfo.currentRss,
    _clock.elapsedMilliseconds,
    cycle: cycle,
  );
  (cycle == null ? _phases : _cycles).add(sample);
}

/// Builds the synthetic library: 12 tracks per album, 8 albums per artist, one
/// cover file per album. Shaped like a real collection so album and artist
/// grouping does the work it would really do.
List<Track> _buildLibrary(Directory artworkDir) {
  const int tracksPerAlbum = 12;
  const int albumsPerArtist = 8;
  final int albumCount = (_trackCount / tracksPerAlbum).ceil();

  final List<Uri> covers = <Uri>[];
  for (int album = 0; album < albumCount; album++) {
    final File file = File('${artworkDir.path}/cover_$album.png');
    file.writeAsBytesSync(_pngBytes);
    covers.add(file.uri);
  }

  return <Track>[
    for (int i = 0; i < _trackCount; i++)
      () {
        final int album = i ~/ tracksPerAlbum;
        final int artist = album ~/ albumsPerArtist;
        return Track(
          id: 'local:$i',
          uri: '/music/Artist $artist/Album $album/${i % tracksPerAlbum} '
              'Track $i.flac',
          title: 'Track $i Midnight Signal',
          artistName: 'Artist $artist',
          albumName: 'Album $album',
          albumArtistName: 'Artist $artist',
          trackNumber: (i % tracksPerAlbum) + 1,
          duration: Duration(seconds: 120 + (i % 180)),
          artworkUri: covers[album],
        );
      }(),
  ];
}

GoRouter _router() {
  return GoRouter(
    initialLocation: AppRoutes.library,
    routes: <RouteBase>[
      GoRoute(
        path: AppRoutes.library,
        builder: (_, __) => const LibraryScreen(),
      ),
      GoRoute(
        path: '/library/album/:id',
        builder: (_, GoRouterState s) =>
            AlbumDetailScreen(albumId: s.pathParameters['id']!),
      ),
      GoRoute(
        path: '/library/artist/:id',
        builder: (_, GoRouterState s) =>
            ArtistDetailScreen(artistId: s.pathParameters['id']!),
      ),
      GoRoute(path: AppRoutes.player, builder: (_, __) => const PlayerScreen()),
    ],
  );
}

/// Scrolls the visible list a long way, the way someone hunting for a track
/// does. Each drag is a frame's worth of work: new rows built, new covers
/// decoded, old ones evicted.
Future<void> _scroll(WidgetTester tester, {required int drags}) async {
  final Finder scrollable = find.byType(Scrollable).first;
  for (int i = 0; i < drags; i++) {
    await tester.drag(scrollable, const Offset(0, -600));
    await tester.pump(const Duration(milliseconds: 16));
  }
  await tester.pumpAndSettle();
}

/// Scrolls down and all the way back to the top.
///
/// This is what makes a repeated cycle *repeatable*, and it took a run to
/// notice. A tab keeps its scroll offset, so a cycle that only scrolls down
/// starts each pass where the last one stopped: it visits rows and covers it
/// has never seen, Flutter's image cache keeps filling toward its 1000-image
/// bound, and the series climbs for reasons that are not a leak. Returning to
/// the top means every cycle touches the same working set, which is the only
/// way "the same navigation, repeated" means anything.
Future<void> _scrollRoundTrip(WidgetTester tester, {required int drags}) async {
  await _scroll(tester, drags: drags);
  final Finder scrollable = find.byType(Scrollable).first;
  // Generously more than went down, so the list is definitely back at zero
  // however far the flings actually carried it.
  for (int i = 0; i < drags + 10; i++) {
    await tester.drag(scrollable, const Offset(0, 600));
    await tester.pump(const Duration(milliseconds: 16));
  }
  await tester.pumpAndSettle();
}

Future<void> _openTab(WidgetTester tester, String label) async {
  await tester.tap(find.text(label));
  await tester.pumpAndSettle();
}

/// Opens the first item on the current tab and comes back. Detail screens are
/// where a retained route or a cached header image would show up.
Future<void> _openFirstAndBack(WidgetTester tester) async {
  final Finder tiles = find.byType(InkWell);
  if (tiles.evaluate().isEmpty) return;
  await tester.tap(tiles.first, warnIfMissed: false);
  await tester.pumpAndSettle();
  final Finder back = find.byType(BackButton);
  if (back.evaluate().isNotEmpty) {
    await tester.tap(back.first);
    await tester.pumpAndSettle();
  }
}

void main() {
  testWidgets('large-library memory profile', (WidgetTester tester) async {
    // A phone-sized viewport builds more rows per screen than the default
    // 800x600 test window, which is what a scroll should be paying for.
    tester.view.physicalSize = const Size(1280, 2400);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final Directory artworkDir =
        Directory.systemTemp.createTempSync('linthra_memory_art_');
    addTearDown(() => artworkDir.deleteSync(recursive: true));

    _record('baseline');

    final List<Track> tracks = _buildLibrary(artworkDir);
    _record('library_built');

    final FakePlaybackController playback = FakePlaybackController();
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          musicLibraryRepositoryProvider
              .overrideWithValue(_SyntheticLibrary(tracks)),
          playlistStoreProvider.overrideWithValue(InMemoryPlaylistStore()),
          playbackControllerProvider.overrideWithValue(playback),
        ],
        child: MaterialApp.router(routerConfig: _router()),
      ),
    );
    await tester.pumpAndSettle();
    _record('startup');

    await _scroll(tester, drags: 120);
    _record('songs_scrolled');

    await _openTab(tester, 'Albums');
    await _scroll(tester, drags: 60);
    _record('albums_browsed');

    await _openFirstAndBack(tester);
    _record('album_navigated');

    await _openTab(tester, 'Artists');
    await _scroll(tester, drags: 60);
    _record('artists_browsed');

    await _openFirstAndBack(tester);
    _record('artist_navigated');

    await playback.playTracks(tracks.take(200).toList(), startIndex: 0);
    await tester.pumpAndSettle();
    for (int i = 0; i < 40; i++) {
      await playback.skipToNext();
    }
    await tester.pumpAndSettle();
    _record('playback_queue');

    // The part that actually detects a leak: the same navigation, over and
    // over. A healthy app settles into a flat line here once its caches have
    // filled; anything that retains per navigation shows up as a slope.
    for (int cycle = 0; cycle < _cycleCount; cycle++) {
      await _openTab(tester, 'Songs');
      await _scrollRoundTrip(tester, drags: 40);
      await _openTab(tester, 'Albums');
      await _scrollRoundTrip(tester, drags: 30);
      await _openFirstAndBack(tester);
      await _openTab(tester, 'Artists');
      await _scrollRoundTrip(tester, drags: 30);
      await _openFirstAndBack(tester);

      if (_leak) {
        // 2 MiB retained per cycle (a Dart int list costs 8 bytes an element).
        // Small enough that it has to be found in the trend rather than by
        // staring at the total, which is the whole point of the exercise.
        _deliberatelyRetained.add(List<int>.filled(256 * 1024, cycle));
      }

      await tester.pumpAndSettle();
      _record('cycle', cycle: cycle);
    }

    final File out = File(_outPath);
    out.parent.createSync(recursive: true);
    out.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(<String, Object?>{
        'scenario': _leak ? 'leak' : 'clean',
        'library': <String, Object?>{
          'tracks': tracks.length,
          'albums': (tracks.length / 12).ceil(),
          'covers_on_disk': (tracks.length / 12).ceil(),
        },
        'cycles_run': _cycleCount,
        'dart_version': Platform.version,
        'phases': <Object?>[for (final _Sample s in _phases) s.toJson()],
        'cycle_samples': <Object?>[for (final _Sample s in _cycles) s.toJson()],
        // Kept so a reader can see the harness was not quietly no-op'ing.
        'retained_chunks': _deliberatelyRetained.length,
      }),
    );
    // ignore: avoid_print
    print('memory samples written to ${out.path}');
  }, timeout: const Timeout(Duration(minutes: 30)));
}
