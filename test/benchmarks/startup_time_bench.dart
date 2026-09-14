// A startup measurement harness, not a regression test.
//
// It answers the question #462 exists for: **how long after launch is Linthra
// actually usable**, and does that number fall off a cliff when the catalog is
// large? "Usable" is not "the process started" and not "a frame was painted":
// both happen while the Library is still a spinner. The milestone here is the
// first frame that shows the user their library: real track rows for a
// catalog that has any, the "pick a folder" empty state for one that doesn't.
//
// Three workloads, one per library size that behaves differently:
//
//   empty  0 tracks       an initialized catalog with nothing scanned yet
//   small  1,000 tracks   an ordinary personal collection
//   large  20,000 tracks  a collection large enough to change the shape
//
// Each is a real on-disk SQLite catalog in the production Drift schema, read
// back through the production repository binding, so the measured startup pays
// the real database open, the real query and the real row-to-model mapping at
// that size. Nothing here needs a Jellyfin, Plex or Navidrome server, and
// nothing here opens a socket: the fixtures are generated locally and the app's
// session stores are the empty in-memory defaults, so no source has anything to
// sync from. Fixture generation happens with the clock stopped, and is reported
// separately, so the measurement is startup and not setup.
//
// Deliberately named `_bench.dart`, not `_test.dart`, so `flutter test` does
// not pick it up: the numbers are machine-, load- and build-mode-dependent and
// would make a flaky CI gate. The verdict lives in
// tools/startup/startup_report.py, which compares two runs rather than checking
// a number against a threshold.
//
// Run it through tools/startup/run_startup_benchmark.sh, which records a
// baseline, a control and a deliberately slowed run and checks that the
// reporter tells them apart. To run it by hand:
//
//     LINTHRA_STARTUP_OUT=/tmp/startup.json \
//       flutter test test/benchmarks/startup_time_bench.dart
//     python3 tools/startup/startup_report.py /tmp/startup.json
//
// Environment:
//   LINTHRA_STARTUP_OUT             where to write the JSON
//                                   (default build/startup.json)
//   LINTHRA_STARTUP_LABEL           free-form name for the run, carried into
//                                   the report (default "run")
//   LINTHRA_STARTUP_ITERATIONS      launches per workload (default 5)
//   LINTHRA_STARTUP_WARMUP          leading launches the reporter ignores
//                                   (default 1)
//   LINTHRA_STARTUP_WORKLOADS       comma-separated subset of empty,small,large
//   LINTHRA_STARTUP_SMALL_TRACKS    size of the small library (default 1000)
//   LINTHRA_STARTUP_LARGE_TRACKS    size of the large library (default 20000)
//   LINTHRA_STARTUP_SLOW_CATALOG_MS delays every catalog read by this many
//                                   milliseconds, so the method can be shown to
//                                   catch a real startup regression rather than
//                                   asserted to
//
// **No production code knows this exists.** There is no startup hook, no trace
// event and no instrumented build: the harness pumps the real widget tree and
// watches it with the ordinary test finders, so nothing here can reach a
// release artifact or change how the app starts for a user.
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/app/linthra_app.dart';
import 'package:linthra/core/lifecycle/async_disposal_registry.dart';
import 'package:linthra/core/models/album.dart';
import 'package:linthra/core/models/artist.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/repositories/music_library_repository.dart';
import 'package:linthra/data/database/linthra_database.dart';
import 'package:linthra/data/database/linthra_database_provider.dart';
import 'package:linthra/data/repositories/drift_music_library_repository.dart';
import 'package:linthra/data/repositories/library_added_store_provider.dart';
import 'package:linthra/data/repositories/music_library_repository_provider.dart';
import 'package:linthra/data/repositories/recording_music_library_repository.dart';
import 'package:linthra/features/library/widgets/track_tile.dart';
import 'package:linthra/features/player/player_providers.dart';

import '../features/player/fake_playback_controller.dart';
import '../support/onboarding_test_overrides.dart';

int _envInt(String name, int fallback) {
  final String? raw = Platform.environment[name];
  return raw == null ? fallback : (int.tryParse(raw) ?? fallback);
}

final String _outPath =
    Platform.environment['LINTHRA_STARTUP_OUT'] ?? 'build/startup.json';
final String _label = Platform.environment['LINTHRA_STARTUP_LABEL'] ?? 'run';
final int _iterations = _envInt('LINTHRA_STARTUP_ITERATIONS', 5);
final int _warmup = _envInt('LINTHRA_STARTUP_WARMUP', 1);
final int _smallTracks = _envInt('LINTHRA_STARTUP_SMALL_TRACKS', 1000);
final int _largeTracks = _envInt('LINTHRA_STARTUP_LARGE_TRACKS', 20000);
final int _slowCatalogMs = _envInt('LINTHRA_STARTUP_SLOW_CATALOG_MS', 0);

/// The empty state the Library shows with nothing scanned, and the signal
/// that an empty-catalog launch has finished starting. Asserted by
/// test/app_smoke_test.dart too, so a reworded onboarding prompt breaks a test
/// rather than silently making this harness measure the wrong frame.
const String _emptyStateTitle = 'No music folder selected';

/// The desktop window the measurement assumes.
///
/// Recorded in the output because it is part of the workload: a taller window
/// builds more rows into the first usable frame, so two runs at different sizes
/// are not comparable. 1600x1000 at a device pixel ratio of 1 is an ordinary
/// Linux desktop window rather than the 800x600 the test binding defaults to.
const Size _windowSize = Size(1600, 1000);
const double _devicePixelRatio = 1.0;

/// Simulated frame interval for the pump loop, and the unit of the second
/// clock the harness records.
///
/// `testWidgets` drives time itself: `tester.pump(d)` advances the binding's
/// *fake* clock by `d` and runs one frame, it does not wait `d` of real time.
/// That splits startup cost in two, and both halves matter:
///
///  * work the CPU actually does (the SQLite query, the row mapping, building
///    the widgets) costs real time, and the stopwatch sees it;
///  * time the app spends *awaiting* something (a timer, a delayed future, a
///    retry backoff) costs simulated time, and the stopwatch does not see it
///    at all: it only shows up as more trips round the pump loop.
///
/// So the harness records both, and the reporter judges both. A regression
/// that adds a 250 ms await is invisible to a wall clock here and obvious in
/// simulated time; a regression that adds real work is the other way round.
const int _pumpIntervalMs = 4;

/// How many frames a single launch may take before the harness gives up.
///
/// A launch that never reaches the milestone is a bug worth failing on, not a
/// number worth recording. At [_pumpIntervalMs] of simulated frame time this
/// is 80 seconds of simulated waiting, which is generous.
const int _frameBudget = 20000;

const bool _isProduct = bool.fromEnvironment('dart.vm.product');
const bool _isProfile = bool.fromEnvironment('dart.vm.profile');

/// What the app under measurement was compiled as.
///
/// `flutter test` runs the JIT VM, so in practice this says "debug" and the
/// numbers are debug numbers: useful for comparing two commits, useless for
/// predicting what a user of a `--release` build sees. Recorded rather than
/// assumed so a report can never be read as something it isn't, and so the
/// reporter can refuse to compare runs that were not built the same way.
String get _buildMode {
  if (_isProduct) return 'release';
  if (_isProfile) return 'profile';
  return 'debug';
}

/// One library size the app is measured against.
class _Workload {
  const _Workload(this.name, this.tracks);

  final String name;
  final int tracks;

  /// 12 tracks to an album, the same shape the other large-library harnesses
  /// use, so "20,000 tracks" also means a realistic number of albums to group.
  int get albums => tracks == 0 ? 0 : (tracks / _tracksPerAlbum).ceil();

  /// 8 albums to an artist. Recorded for the same reason [albums] is: the
  /// Library groups and sorts artists during startup, so the same rows spread
  /// over a different number of artists is a different amount of work, and two
  /// runs that disagree about it are not measuring the same thing.
  int get artists => albums == 0 ? 0 : (albums / _albumsPerArtist).ceil();
}

const int _tracksPerAlbum = 12;
const int _albumsPerArtist = 8;
const String _sourceId = 'local';

/// One launch: what the clock said at each milestone.
class _Launch {
  const _Launch({
    required this.iteration,
    required this.warmup,
    required this.firstFrameMs,
    required this.firstUsableFrameMs,
    required this.frames,
    required this.rowsRendered,
  });

  final int iteration;
  final bool warmup;
  final double firstFrameMs;
  final double firstUsableFrameMs;
  final int frames;
  final int rowsRendered;

  /// Simulated time between the first frame and the first usable one.
  ///
  /// The pump loop advances the binding's clock by [_pumpIntervalMs] a frame,
  /// so this is what the app spent *waiting* rather than working: awaited
  /// timers and delayed futures, which a wall clock in a widget test cannot
  /// see. Derived rather than read off the binding so it stays exactly the
  /// quantity the reporter compares.
  double get simulatedMs => (frames - 1) * _pumpIntervalMs.toDouble();

  Map<String, Object?> toJson() => <String, Object?>{
        'iteration': iteration,
        'warmup': warmup,
        'first_frame_ms': firstFrameMs,
        'first_usable_frame_ms': firstUsableFrameMs,
        'simulated_ms': simulatedMs,
        'frames': frames,
        'rows_rendered': rowsRendered,
      };
}

/// Wraps the real catalog and makes every read take [delay] longer.
///
/// The false-negative control. A check that only ever says "no regression" is
/// indistinguishable from one that has quietly stopped measuring, and the only
/// way to tell those apart is to hand it something it *must* catch. A slow
/// catalog read is the most likely real startup regression there is, so the
/// canary injects exactly that, through a provider override, from the test
/// side, with no production code involved.
class _SlowCatalog implements MusicLibraryRepository {
  _SlowCatalog(this._inner, this._delay);

  final MusicLibraryRepository _inner;
  final Duration _delay;

  @override
  Future<List<Track>> getAllTracks() async {
    await Future<void>.delayed(_delay);
    return _inner.getAllTracks();
  }

  @override
  Future<List<Album>> getAllAlbums() => _inner.getAllAlbums();

  @override
  Future<List<Artist>> getAllArtists() => _inner.getAllArtists();

  @override
  Future<Track?> getTrackByUri(String uri) => _inner.getTrackByUri(uri);

  @override
  Future<void> upsertCatalog({
    required String sourceId,
    required List<Track> tracks,
    required List<Album> albums,
    required List<Artist> artists,
  }) {
    return _inner.upsertCatalog(
      sourceId: sourceId,
      tracks: tracks,
      albums: albums,
      artists: artists,
    );
  }

  @override
  Future<void> removeTracks(List<String> trackUris) =>
      _inner.removeTracks(trackUris);
}

/// A synthetic catalog shaped like a real collection: `Artist N / Album N /
/// NN Title.flac`, 12 tracks an album, 8 albums an artist.
///
/// Titles are zero-padded so the Library's alphabetical order is stable, which
/// keeps "which rows the first usable frame builds" the same on every launch.
List<Track> _buildTracks(int count) {
  return <Track>[
    for (int i = 0; i < count; i++)
      () {
        final int album = i ~/ _tracksPerAlbum;
        final int artist = album ~/ _albumsPerArtist;
        final String number = i.toString().padLeft(6, '0');
        return Track(
          id: 'local:$i',
          uri: '/music/Artist $artist/Album $album/'
              '${i % _tracksPerAlbum} Track $number.flac',
          title: 'Track $number',
          artistName: 'Artist $artist',
          albumName: 'Album $album',
          albumArtistName: 'Artist $artist',
          trackNumber: (i % _tracksPerAlbum) + 1,
          duration: Duration(seconds: 120 + (i % 180)),
        );
      }(),
  ];
}

/// Writes [workload]'s catalog to its own SQLite file and returns it.
///
/// Deliberately outside every timed region: this is setup, and a startup number
/// that included generating the library would measure the generator. The cost
/// is reported separately as `fixture_build_ms` so a reader can see it was not
/// folded in.
Future<File> _buildFixture(Directory dir, _Workload workload) async {
  final File file = File('${dir.path}/${workload.name}.sqlite');
  final LinthraDatabase db =
      LinthraDatabase.forTesting(NativeDatabase(file, logStatements: false));
  try {
    if (workload.tracks > 0) {
      await DriftMusicLibraryRepository(db).upsertCatalog(
        sourceId: _sourceId,
        tracks: _buildTracks(workload.tracks),
        albums: const <Album>[],
        artists: const <Artist>[],
      );
    } else {
      // Still open and migrate the file, so an empty catalog is a real empty
      // database rather than a missing one: the app pays the same open cost.
      //
      // This is why `empty` is an *initialized* empty catalog and not a
      // first-ever launch. Creating the schema happens here, before any
      // stopwatch starts, so every judged launch reopens a database that is
      // already at the current version: `onCreate` lands in `fixture_build_ms`,
      // which no verdict reads, and `onUpgrade` never runs at all. Migration
      // cost is out of scope for a startup number that has to be comparable
      // between runs (it is paid once per install, not once per launch), and
      // the README lists it under what this does not measure.
      await db.select(db.tracks).get();
    }
  } finally {
    await db.close();
  }
  return file;
}

/// The production catalog binding, over [file].
///
/// `recordingDriftMusicLibraryRepositoryOverride` is what `main()` applies, so
/// this is the same repository stack the app really starts with; only the
/// database file is the harness's. With the canary armed, the same stack is
/// wrapped so reads are slow.
///
/// **The one place this is not production's shape**: production opens SQLite
/// with `NativeDatabase.createInBackground` (see `linthra_database.dart`),
/// which runs the database on its own isolate; this opens it in-process.
/// That is forced rather than chosen. `createInBackground` waits on a message
/// from that isolate, and the widget-test binding drives the clock and the
/// event loop itself, so under `testWidgets` the open never completes and the
/// test hangs until it times out (`TimeoutException ...
/// _RawReceivePort._handleMessage`) rather than measuring anything.
///
/// What it costs the measurement, in both directions:
///  * the isolate spawn and the message round-trip per query are real startup
///    costs a user pays and this does not measure;
///  * the query itself runs on the UI isolate here and off it in production,
///    so the catalog's share of the number is a conservative *upper* bound.
///
/// It is why this benchmark compares a commit against a commit rather than
/// predicting what a user sees. A number for the real thing needs a profile
/// build and a clock outside the process; see tools/startup/README.md.
List<Override> _overrides(File file) {
  return <Override>[
    ...completedOnboardingOverrides(),
    linthraDatabaseExecutorProvider
        .overrideWith((Ref ref) => NativeDatabase(file, logStatements: false)),
    if (_slowCatalogMs <= 0)
      recordingDriftMusicLibraryRepositoryOverride
    else
      musicLibraryRepositoryProvider.overrideWith(
        (Ref ref) => _SlowCatalog(
          RecordingMusicLibraryRepository(
            delegate:
                DriftMusicLibraryRepository(ref.watch(linthraDatabaseProvider)),
            addedStore: ref.watch(libraryAddedStoreProvider),
          ),
          Duration(milliseconds: _slowCatalogMs),
        ),
      ),
    // The persistent shell hosts the mini-player, which reads the playback
    // controller. The fake keeps the audio plugin (and libmpv) out of a
    // measurement that is about the library, not the engine.
    playbackControllerProvider.overrideWithValue(FakePlaybackController()),
  ];
}

/// Whether the Library has reached the point where the user can use it.
///
/// Two shapes, because "usable" means different things to a catalog that has
/// songs and one that doesn't:
///  * a catalog with tracks is usable when real rows are on screen. The Library
///    shows its tabs and its song list in the same frame, so the first frame
///    holding a [TrackTile] is the first frame a user could scroll or tap.
///  * an empty catalog is usable when the onboarding prompt is up, which is the
///    whole of what a library with nothing in it has to show.
///
/// Both are read with ordinary finders against the real widget tree. Nothing in
/// the app reports a milestone, so nothing in the app had to change to be
/// measured.
bool _usable(_Workload workload) {
  if (workload.tracks == 0) {
    return find.text(_emptyStateTitle).evaluate().isNotEmpty;
  }
  return find.byType(TrackTile).evaluate().isNotEmpty;
}

/// One launch, from `runApp` to the first usable frame.
Future<_Launch> _launch(
  WidgetTester tester,
  _Workload workload,
  File file, {
  required int iteration,
}) async {
  final Stopwatch clock = Stopwatch()..start();

  // `UncontrolledProviderScope` rather than `ProviderScope` so this function
  // owns the container: unmounting a `ProviderScope` disposes its container,
  // which *starts* `db.close()` and returns, and there is then no handle left
  // to await it through. Building the container is inside the timed region
  // because `ProviderScope` builds its own there too; it allocates only, since
  // providers build lazily on first read.
  final ProviderContainer container = ProviderContainer(
    overrides: _overrides(file),
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(container: container, child: const LinthraApp()),
  );
  final int firstFrameUs = clock.elapsedMicroseconds;

  int frames = 1;
  while (!_usable(workload)) {
    if (frames >= _frameBudget) {
      clock.stop();
      fail(
        'the ${workload.name} workload never reached a usable frame in '
        '$_frameBudget frames. Either startup is broken or the milestone '
        'finder no longer matches the Library screen.',
      );
    }
    await tester.pump(const Duration(milliseconds: _pumpIntervalMs));
    frames++;
  }
  final int usableUs = clock.elapsedMicroseconds;
  clock.stop();

  final int rows = find.byType(TrackTile).evaluate().length;

  // Every launch opens the same SQLite file, so the previous connection has to
  // be *closed*, not merely told to close, before the next one opens it. That
  // is the race `linthraDatabaseProvider` registers its close with
  // `onDisposeAsync` to avoid: `ProviderContainer.dispose()` runs the callback
  // and returns, leaving `db.close()` in flight. Pumping does not help, because
  // `tester.pump()` advances the fake clock rather than waiting on real work.
  // So: unmount, dispose, then await the registry the container's own teardown
  // parked that close in.
  await tester.pumpWidget(const SizedBox.shrink());
  final AsyncDisposalRegistry disposals = container.read(
    asyncDisposalRegistryProvider,
  );
  container.dispose();
  await disposals.settle();

  return _Launch(
    iteration: iteration,
    warmup: iteration < _warmup,
    firstFrameMs: firstFrameUs / 1000,
    firstUsableFrameMs: usableUs / 1000,
    frames: frames,
    rowsRendered: rows,
  );
}

List<_Workload> _selectedWorkloads() {
  final Map<String, _Workload> all = <String, _Workload>{
    'empty': const _Workload('empty', 0),
    'small': _Workload('small', _smallTracks),
    'large': _Workload('large', _largeTracks),
  };
  final String? requested = Platform.environment['LINTHRA_STARTUP_WORKLOADS'];
  if (requested == null || requested.trim().isEmpty) {
    return all.values.toList();
  }
  return <_Workload>[
    for (final String raw in requested.split(','))
      if (all[raw.trim()] case final _Workload workload)
        workload
      else
        // A typo here would silently measure fewer workloads than asked for,
        // and the report would look complete. Fail instead.
        throw ArgumentError(
          'unknown workload "${raw.trim()}" in LINTHRA_STARTUP_WORKLOADS; '
          'expected one of ${all.keys.join(", ")}',
        ),
  ];
}

void main() {
  testWidgets('startup to first usable frame', (WidgetTester tester) async {
    tester.view.physicalSize = _windowSize * _devicePixelRatio;
    tester.view.devicePixelRatio = _devicePixelRatio;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final Directory fixtures =
        Directory.systemTemp.createTempSync('linthra_startup_');
    addTearDown(() => fixtures.deleteSync(recursive: true));

    final List<_Workload> workloads = _selectedWorkloads();
    expect(workloads, isNotEmpty, reason: 'no known workload was selected');

    final List<Map<String, Object?>> reported = <Map<String, Object?>>[];

    for (final _Workload workload in workloads) {
      final Stopwatch setup = Stopwatch()..start();
      final File file = await _buildFixture(fixtures, workload);
      setup.stop();

      final List<_Launch> launches = <_Launch>[
        for (int i = 0; i < _iterations; i++)
          await _launch(tester, workload, file, iteration: i),
      ];

      reported.add(<String, Object?>{
        'name': workload.name,
        // The fixture's whole shape, not just its size. The reporter compares
        // every one of these between two runs, so a change to the generator
        // that alters what the Library has to group is refused rather than
        // charged to the app.
        'tracks': workload.tracks,
        'albums': workload.albums,
        'artists': workload.artists,
        'fixture_build_ms': setup.elapsedMicroseconds / 1000,
        'fixture_bytes': file.lengthSync(),
        'usable_signal': workload.tracks == 0
            ? 'empty state: "$_emptyStateTitle"'
            : 'first track row painted',
        'samples': <Object?>[for (final _Launch l in launches) l.toJson()],
      });
    }

    final File out = File(_outPath);
    out.parent.createSync(recursive: true);
    out.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(<String, Object?>{
        'schema': 'linthra.startup.v1',
        'label': _label,
        'milestone': 'first_usable_frame',
        'build_mode': _buildMode,
        'runtime': 'flutter test (Dart VM, JIT)',
        'dart_version': Platform.version,
        'operating_system': Platform.operatingSystem,
        'operating_system_version': Platform.operatingSystemVersion,
        'cpu_cores': Platform.numberOfProcessors,
        'iterations': _iterations,
        'warmup': _warmup,
        // The unit of `simulated_ms`, so a reader (and the reporter) can tell
        // how finely awaited time was resolved.
        'pump_interval_ms': _pumpIntervalMs,
        'window': <String, Object?>{
          'width': _windowSize.width,
          'height': _windowSize.height,
          'device_pixel_ratio': _devicePixelRatio,
        },
        // Part of the measurement's identity: a run with the canary armed is
        // not comparable to one without it, and the reporter says so.
        'slow_catalog_ms': _slowCatalogMs,
        // Nothing here talks to a server. Recorded so a report can be read
        // without having to take the harness's word for it.
        'network_sources': 0,
        'workloads': reported,
      }),
    );
    // ignore: avoid_print
    print('startup samples written to ${out.path}');
  }, timeout: const Timeout(Duration(minutes: 30)));
}
