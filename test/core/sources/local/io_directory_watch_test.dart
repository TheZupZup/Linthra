// The one test here that touches a real filesystem and a real kernel watch.
//
// Everything else about watching is exercised against a synthetic filesystem,
// which is right: the debounce, failure and disposal rules are Linthra's, and
// pinning them to inotify's timing would make them flaky. But the seam that
// actually calls `Directory.watch` has to be tried against the real thing at
// least once, or a wrong assumption about it survives every test in the suite.
//
// It uses a temp directory the OS chooses, never a distro-specific path: a
// music folder lives wherever the user put it, and CI has no `~/Music`.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/sources/local/local_directory_watch.dart';
import 'package:linthra/core/sources/local/local_library_watcher.dart';

/// Waits for [check] to hold, polling, so nothing here guesses at how long the
/// kernel takes to deliver an event.
Future<void> until(
  bool Function() check, {
  Duration timeout = const Duration(seconds: 10),
}) async {
  final Stopwatch elapsed = Stopwatch()..start();
  while (elapsed.elapsed < timeout) {
    if (check()) return;
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
  fail('condition never held within $timeout');
}

void main() {
  // Watching is a platform capability, not a guarantee. Where the host cannot
  // watch (some CI sandboxes, some filesystems), skipping is the honest
  // outcome: the behaviour under test is the OS's, and the app already falls
  // back to manual refresh there.
  final bool supported = FileSystemEntity.isWatchSupported;

  group('IoDirectoryWatchFactory', () {
    late Directory root;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('linthra_watch_');
    });

    tearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });

    test('a real file creation reaches a real watcher', () async {
      int refreshes = 0;
      final watcher = LocalLibraryWatcher(
        watchFactory: const IoDirectoryWatchFactory(),
        onLibraryChanged: () async => refreshes++,
        quietPeriod: const Duration(milliseconds: 100),
      );
      addTearDown(watcher.dispose);
      await watcher.syncRoots(<String>[root.path]);
      expect(watcher.watchedRoots, <String>{root.path});

      await File('${root.path}/song.flac').writeAsString('not really audio');

      await until(() => refreshes >= 1);
      expect(refreshes, 1);
    });

    test('a whole album copied in is still one refresh', () async {
      int refreshes = 0;
      final watcher = LocalLibraryWatcher(
        watchFactory: const IoDirectoryWatchFactory(),
        onLibraryChanged: () async => refreshes++,
        quietPeriod: const Duration(milliseconds: 200),
      );
      addTearDown(watcher.dispose);
      await watcher.syncRoots(<String>[root.path]);

      final Directory album = Directory('${root.path}/Artist/Album');
      await album.create(recursive: true);
      for (int i = 1; i <= 12; i++) {
        await File('${album.path}/$i Track.flac').writeAsString('x' * 1024);
      }

      await until(() => refreshes >= 1);
      // Let anything still in flight land before counting.
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(
        refreshes,
        1,
        reason: 'a directory plus twelve files is one user action',
      );
    });

    test('a folder that does not exist fails rather than throwing out',
        () async {
      final List<String> failed = <String>[];
      final watcher = LocalLibraryWatcher(
        watchFactory: const IoDirectoryWatchFactory(),
        onLibraryChanged: () async {},
        onWatchFailed: (String r, Object _) => failed.add(r),
      );
      addTearDown(watcher.dispose);

      await watcher.syncRoots(<String>['${root.path}/not-here']);

      expect(watcher.watchedRoots, isEmpty);
      expect(watcher.isDegraded, isTrue);
      expect(failed, hasLength(1));
    });

    test('disposal really releases the kernel watch', () async {
      int refreshes = 0;
      final watcher = LocalLibraryWatcher(
        watchFactory: const IoDirectoryWatchFactory(),
        onLibraryChanged: () async => refreshes++,
        quietPeriod: const Duration(milliseconds: 50),
      );
      await watcher.syncRoots(<String>[root.path]);
      await watcher.dispose();

      await File('${root.path}/after.flac').writeAsString('x');
      await Future<void>.delayed(const Duration(milliseconds: 500));

      expect(refreshes, 0);
    });
  },
      skip: supported
          ? false
          : 'this host cannot watch a filesystem; the app falls back to '
              'manual refresh there');
}
