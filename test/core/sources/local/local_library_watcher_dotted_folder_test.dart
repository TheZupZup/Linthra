// Live updates notice an album folder moved into (or out of) the library when
// its name contains a dot.
//
// Folder names with dots are everywhere in a real library ("Greatest Hits Vol.
// 2", "R.E.M.", "Dr. Dre", "St. Vincent", "Live 12.08.1990"), and moving a
// folder within one disk is a single rename: the kernel reports the folder and
// nothing inside it. LocalLibraryWatcher.isRelevant must not take such a name
// for a file with an extension that isn't audio, or the moved-in album never
// appears and a moved-out one stays listed and fails to play.
//
// One real kernel watch, like io_directory_watch_test.dart. No sleeping: the
// test waits for the event the kernel reports for the folder itself, then for
// a marker written after it, so every event the move produced has been handled
// by the watcher before the assertion.
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/sources/local/local_directory_watch.dart';
import 'package:linthra/core/sources/local/local_library_watcher.dart';

/// The real factory, with a way to wait for a given path to be reported. The
/// watcher's listener runs right after this one, for the same event.
class _Tee implements DirectoryWatchFactory {
  final List<String> seen = <String>[];
  final Map<String, Completer<void>> _waiting = <String, Completer<void>>{};

  /// The next report of [path]. Ask before the change is made (the rename and
  /// the marker write are synchronous, and events are delivered later), so
  /// the report cannot slip past.
  Future<void> reported(String path) =>
      (_waiting[path] ??= Completer<void>()).future;

  @override
  Stream<LocalDirectoryChange> watch(String root) {
    return const IoDirectoryWatchFactory()
        .watch(root)
        .map((LocalDirectoryChange change) {
      seen.add(change.path);
      final Completer<void>? waiting = _waiting.remove(change.path);
      if (waiting != null) scheduleMicrotask(waiting.complete);
      return change;
    });
  }
}

void main() {
  final bool supported = FileSystemEntity.isWatchSupported;

  group('a folder moved within the disk', () {
    late Directory sandbox;
    late Directory music;
    late Directory downloads;
    late _Tee tee;
    late LocalLibraryWatcher watcher;
    late int refreshes;

    setUp(() async {
      sandbox = await Directory.systemTemp.createTemp('linthra_dotted_');
      music = Directory('${sandbox.path}/Music')..createSync();
      downloads = Directory('${sandbox.path}/Downloads')..createSync();
      tee = _Tee();
      refreshes = 0;
      watcher = LocalLibraryWatcher(
        watchFactory: tee,
        onLibraryChanged: () async => refreshes++,
      );
      await watcher.syncRoots(<String>[music.path]);
      expect(watcher.watchedRoots, <String>{music.path});
    });

    tearDown(() async {
      await watcher.dispose();
      await sandbox.delete(recursive: true);
    });

    /// Waits for [report] (the report of a change already made), then for a
    /// marker written after it.
    Future<void> settled(Future<void> report) async {
      await report;
      final String marker = '${music.path}/marker-${tee.seen.length}.txt';
      final Future<void> markerReported = tee.reported(marker);
      File(marker).writeAsStringSync('x');
      await markerReported;
    }

    test('a folder with no dot is noticed', () async {
      final Directory album = Directory('${downloads.path}/Greatest Hits')
        ..createSync();
      File('${album.path}/01 Intro.flac').writeAsStringSync('x');

      final String moved = '${music.path}/Greatest Hits';
      final Future<void> report = tee.reported(moved);
      album.renameSync(moved);
      await settled(report);

      expect(watcher.hasPendingRefresh || refreshes > 0, isTrue);
    }, skip: supported ? false : 'filesystem watching is not supported here');

    test('into the library is noticed', () async {
      final Directory album =
          Directory('${downloads.path}/Greatest Hits Vol. 2')..createSync();
      File('${album.path}/01 Intro.flac').writeAsStringSync('x');

      final String moved = '${music.path}/Greatest Hits Vol. 2';
      final Future<void> report = tee.reported(moved);
      album.renameSync(moved);
      await settled(report);

      expect(
        watcher.hasPendingRefresh || refreshes > 0,
        isTrue,
        reason: 'a new album folder arrived, and its folder is the only '
            'event the move produced',
      );
    }, skip: supported ? false : 'filesystem watching is not supported here');

    test('out of the library is noticed', () async {
      // The album is already in the library when the watch starts.
      await watcher.dispose();
      final Directory album = Directory('${music.path}/R.E.M.')..createSync();
      File('${album.path}/01 Losing My Religion.flac').writeAsStringSync('x');
      watcher = LocalLibraryWatcher(
        watchFactory: tee,
        onLibraryChanged: () async => refreshes++,
      );
      await watcher.syncRoots(<String>[music.path]);
      expect(watcher.watchedRoots, <String>{music.path});

      final Future<void> report = tee.reported('${music.path}/R.E.M.');
      album.renameSync('${downloads.path}/R.E.M.');
      await settled(report);

      expect(
        watcher.hasPendingRefresh || refreshes > 0,
        isTrue,
        reason: 'the folder and its tracks left the library; without a '
            'refresh they stay listed and fail to play',
      );
    }, skip: supported ? false : 'filesystem watching is not supported here');
  });

  test('isRelevant keeps directory names that contain dots', () {
    for (final String folder in <String>[
      '/music/Greatest Hits Vol. 2',
      '/music/R.E.M.',
      '/music/Dr. Dre',
      '/music/St. Vincent',
      '/music/Live 12.08.1990',
    ]) {
      expect(LocalLibraryWatcher.isRelevant(folder), isTrue, reason: folder);
    }
  });
}
