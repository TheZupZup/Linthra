// Library watching (#409), against a synthetic filesystem.
//
// Every case here is about *when* a refresh happens, never about what the
// refresh does: the watcher deliberately owns no catalog logic, it just asks
// the incremental scan to run. So the assertions are refresh counts and
// watch lifetimes.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/sources/local/local_directory_watch.dart';
import 'package:linthra/core/sources/local/local_library_watcher.dart';

/// A filesystem a test drives by hand: it hands out one controller per watched
/// folder, so a case can emit a change, blow the watch up, or close it, and can
/// see when a watch is actually released.
class _FakeWatchFactory implements DirectoryWatchFactory {
  final Map<String, StreamController<LocalDirectoryChange>> controllers =
      <String, StreamController<LocalDirectoryChange>>{};

  /// Folders that refuse to be watched at all, the way a missing directory or
  /// an exhausted inotify budget does.
  final Set<String> refuse = <String>{};

  /// Folders whose watch has been cancelled, in order.
  final List<String> cancelled = <String>[];

  /// Every folder a watch was opened for, including re-opens.
  final List<String> opened = <String>[];

  @override
  Stream<LocalDirectoryChange> watch(String root) {
    opened.add(root);
    if (refuse.contains(root)) {
      throw StateError('no watch descriptors left for $root');
    }
    final controller = StreamController<LocalDirectoryChange>(
      onCancel: () => cancelled.add(root),
    );
    controllers[root] = controller;
    return controller.stream;
  }

  void emit(String root, String path) =>
      controllers[root]!.add(LocalDirectoryChange(path));

  void fail(String root, Object error) =>
      controllers[root]!.addError(error, StackTrace.empty);

  Future<void> close(String root) => controllers[root]!.close();
}

/// Counts refreshes and lets a test await the next one, so nothing here has to
/// guess at a sleep long enough to be safe.
class _RefreshRecorder {
  int count = 0;
  Completer<void> _next = Completer<void>();

  /// The work the watcher asks for. [hold] lets a case keep a refresh running
  /// while more events arrive.
  Future<void> Function() call({Future<void>? hold}) {
    return () async {
      count++;
      if (!_next.isCompleted) _next.complete();
      if (hold != null) await hold;
    };
  }

  /// Waits for one more refresh than have already happened.
  Future<void> get next {
    if (_next.isCompleted) _next = Completer<void>();
    return _next.future;
  }

  void arm() => _next = Completer<void>();
}

/// Short enough that a test finishes quickly, long enough that a burst emitted
/// in one go lands inside the same quiet period.
const Duration _quiet = Duration(milliseconds: 40);

void main() {
  late _FakeWatchFactory fs;
  late _RefreshRecorder refreshes;

  setUp(() {
    fs = _FakeWatchFactory();
    refreshes = _RefreshRecorder();
  });

  LocalLibraryWatcher build({
    Duration quietPeriod = _quiet,
    Duration maxCoalesceWindow = const Duration(seconds: 15),
    Future<void>? hold,
    void Function(String root, Object error)? onWatchFailed,
  }) {
    final watcher = LocalLibraryWatcher(
      watchFactory: fs,
      onLibraryChanged: refreshes.call(hold: hold),
      onWatchFailed: onWatchFailed,
      quietPeriod: quietPeriod,
      maxCoalesceWindow: maxCoalesceWindow,
    );
    addTearDown(watcher.dispose);
    return watcher;
  }

  group('watching what is selected, and nothing else', () {
    test('opens a watch per selected folder', () async {
      final watcher = build();

      await watcher.syncRoots(<String>['/music', '/media/usb']);

      expect(watcher.watchedRoots, <String>{'/music', '/media/usb'});
      expect(fs.opened, <String>['/music', '/media/usb']);
    });

    test('a folder inside another is not watched twice', () async {
      final watcher = build();

      await watcher.syncRoots(<String>['/music', '/music/live sets']);

      expect(
        watcher.watchedRoots,
        <String>{'/music'},
        reason: 'the inner folder is already covered, exactly as the scan '
            'treats it',
      );
    });

    test('re-syncing the same selection opens nothing new', () async {
      final watcher = build();
      await watcher.syncRoots(<String>['/music']);

      await watcher.syncRoots(<String>['/music']);

      expect(
        fs.opened,
        <String>['/music'],
        reason: 're-opening a recursive watch costs a walk and a descriptor '
            'per directory; adding a folder is no reason to pay it for the '
            'ones already watched',
      );
    });

    test('an unselected folder is released', () async {
      final watcher = build();
      await watcher.syncRoots(<String>['/music', '/media/usb']);

      await watcher.syncRoots(<String>['/music']);

      expect(watcher.watchedRoots, <String>{'/music'});
      expect(fs.cancelled, <String>['/media/usb']);
    });

    test('an event from a released folder changes nothing', () async {
      final watcher = build();
      await watcher.syncRoots(<String>['/media/usb']);
      final controller = fs.controllers['/media/usb']!;
      await watcher.syncRoots(<String>[]);

      // The stream is cancelled, so nothing downstream should see this.
      if (!controller.isClosed) {
        controller.add(const LocalDirectoryChange('/x'));
      }
      await Future<void>.delayed(_quiet * 3);

      expect(refreshes.count, 0);
    });
  });

  group('what a change triggers', () {
    test('a new track refreshes the library once', () async {
      final watcher = build();
      await watcher.syncRoots(<String>['/music']);

      fs.emit('/music', '/music/Album/01 New.flac');
      await refreshes.next;

      expect(refreshes.count, 1);
    });

    test('a deleted track does too', () async {
      final watcher = build();
      await watcher.syncRoots(<String>['/music']);

      fs.emit('/music', '/music/Album/02 Gone.mp3');
      await refreshes.next;

      expect(refreshes.count, 1);
    });

    test('a rename shows up as changes at both paths, and still one scan',
        () async {
      final watcher = build();
      await watcher.syncRoots(<String>['/music']);

      fs.emit('/music', '/music/inbox/track.flac');
      fs.emit('/music', '/music/Artist/Album/05 Track.flac');
      await refreshes.next;
      await Future<void>.delayed(_quiet * 3);

      expect(refreshes.count, 1);
    });

    test('a renamed folder is noticed', () async {
      final watcher = build();
      await watcher.syncRoots(<String>['/music']);

      // Directory events carry no extension, and must not be filtered out:
      // renaming an album folder is exactly the change a user expects to see.
      fs.emit('/music', '/music/Artist/Old Album Name');
      await refreshes.next;

      expect(refreshes.count, 1);
    });

    test('a metadata-only change (a re-tag) is noticed', () async {
      final watcher = build();
      await watcher.syncRoots(<String>['/music']);

      fs.emit('/music', '/music/Artist/Album/05 Retagged.flac');
      await refreshes.next;

      expect(refreshes.count, 1);
    });

    test('changes in either folder refresh the one library', () async {
      final watcher = build();
      await watcher.syncRoots(<String>['/music', '/media/usb']);

      fs.emit('/media/usb', '/media/usb/a.flac');
      await refreshes.next;
      refreshes.arm();
      await Future<void>.delayed(_quiet * 3);
      fs.emit('/music', '/music/b.flac');
      await refreshes.next;

      expect(refreshes.count, 2);
    });
  });

  group('noise that must not trigger a scan', () {
    test('a downloader writing .part files', () async {
      final watcher = build();
      await watcher.syncRoots(<String>['/music']);

      for (int i = 0; i < 50; i++) {
        fs.emit('/music', '/music/Album/track.flac.part');
      }
      await Future<void>.delayed(_quiet * 4);

      expect(refreshes.count, 0);
    });

    test('cover art, sidecars and editor droppings', () async {
      final watcher = build();
      await watcher.syncRoots(<String>['/music']);

      for (final String path in <String>[
        '/music/Album/cover.jpg',
        '/music/Album/album.nfo',
        '/music/Album/rip.log',
        '/music/Album/album.cue',
        '/music/Album/.track.flac.swp',
        '/music/Album/lyrics.lrc',
      ]) {
        fs.emit('/music', path);
      }
      await Future<void>.delayed(_quiet * 4);

      expect(refreshes.count, 0);
    });

    test('the relevance rule itself', () {
      expect(LocalLibraryWatcher.isRelevant('/music/a/01 Track.flac'), isTrue);
      expect(LocalLibraryWatcher.isRelevant('/music/a/01 Track.FLAC'), isTrue);
      expect(LocalLibraryWatcher.isRelevant('/music/Artist/Album'), isTrue);
      expect(LocalLibraryWatcher.isRelevant('/music/a/cover.jpg'), isFalse);
      expect(LocalLibraryWatcher.isRelevant('/music/a/x.flac.part'), isFalse);
      // A dotfile is not an album folder called ".DS_Store", and a sync
      // tool's bookkeeping folder is not an album either.
      expect(LocalLibraryWatcher.isRelevant('/music/.DS_Store'), isFalse);
      expect(LocalLibraryWatcher.isRelevant('/music/.stfolder'), isFalse);
    });
  });

  group('a burst', () {
    test('copying an album is one scan, not one per file', () async {
      final watcher = build();
      await watcher.syncRoots(<String>['/music']);

      // What copying a 12-track album actually produces: a directory event,
      // then a create and a couple of modifies per file.
      fs.emit('/music', '/music/Artist/New Album');
      for (int track = 1; track <= 12; track++) {
        for (int i = 0; i < 3; i++) {
          fs.emit('/music', '/music/Artist/New Album/$track Track.flac');
        }
      }
      await refreshes.next;
      await Future<void>.delayed(_quiet * 3);

      expect(refreshes.count, 1, reason: '37 events, one scan');
    });

    test('a burst that never goes quiet still refreshes while it runs',
        () async {
      // A copy over a slow network link: events keep arriving, so the quiet
      // period never elapses. Waiting for silence would mean the library shows
      // nothing until the copy finishes.
      final watcher = build(
        quietPeriod: const Duration(seconds: 30),
        maxCoalesceWindow: const Duration(milliseconds: 30),
      );
      await watcher.syncRoots(<String>['/music']);

      fs.emit('/music', '/music/a.flac');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      fs.emit('/music', '/music/b.flac');
      await refreshes.next;

      expect(refreshes.count, 1);
    });

    test('events during a refresh schedule exactly one more', () async {
      final Completer<void> holdRefresh = Completer<void>();
      final watcher = build(hold: holdRefresh.future);
      await watcher.syncRoots(<String>['/music']);

      fs.emit('/music', '/music/a.flac');
      await refreshes.next;
      // The first refresh is now in flight and will not finish until released.
      for (int i = 0; i < 20; i++) {
        fs.emit('/music', '/music/b$i.flac');
      }
      refreshes.arm();
      holdRefresh.complete();
      await refreshes.next;
      await Future<void>.delayed(_quiet * 3);

      expect(refreshes.count, 2, reason: '20 events during a scan, one rescan');
    });
  });

  group('when watching is not available', () {
    test('a folder that refuses is reported and left out', () async {
      final List<String> failures = <String>[];
      fs.refuse.add('/media/usb');
      final watcher = build(
        onWatchFailed: (String root, Object _) => failures.add(root),
      );

      await watcher.syncRoots(<String>['/music', '/media/usb']);

      expect(watcher.watchedRoots, <String>{'/music'});
      expect(watcher.unwatchableRoots, <String>{'/media/usb'});
      expect(watcher.isDegraded, isTrue);
      expect(failures, <String>['/media/usb']);
    });

    test('the folders that can be watched still are', () async {
      fs.refuse.add('/media/usb');
      final watcher = build();
      await watcher.syncRoots(<String>['/music', '/media/usb']);

      fs.emit('/music', '/music/a.flac');
      await refreshes.next;

      expect(refreshes.count, 1);
    });

    test('a watch that blows up later is a failure, not a silence', () async {
      final List<Object> errors = <Object>[];
      final watcher = build(
        onWatchFailed: (String _, Object error) => errors.add(error),
      );
      await watcher.syncRoots(<String>['/music']);

      // What running out of inotify watch descriptors looks like mid-session.
      fs.fail('/music', StateError('inotify: no space left on device'));
      await Future<void>.delayed(_quiet * 3);

      expect(watcher.unwatchableRoots, <String>{'/music'});
      expect(errors, hasLength(1));
    });

    test('a watch that just ends is treated as a failure too', () async {
      // Nothing under that folder will ever be reported again, so calling it
      // "still watching" would be a lie the user cannot see through.
      final watcher = build();
      await watcher.syncRoots(<String>['/music']);

      await fs.close('/music');
      await Future<void>.delayed(_quiet * 3);

      expect(watcher.isDegraded, isTrue);
    });

    test('re-syncing retries a folder that failed', () async {
      fs.refuse.add('/media/usb');
      final watcher = build();
      await watcher.syncRoots(<String>['/music', '/media/usb']);
      expect(watcher.isDegraded, isTrue);

      // The drive is plugged back in.
      fs.refuse.clear();
      await watcher.syncRoots(<String>['/music', '/media/usb']);

      expect(watcher.isDegraded, isFalse);
      expect(watcher.watchedRoots, <String>{'/music', '/media/usb'});
    });

    test('deselecting an unwatchable folder clears it', () async {
      fs.refuse.add('/media/usb');
      final watcher = build();
      await watcher.syncRoots(<String>['/music', '/media/usb']);

      await watcher.syncRoots(<String>['/music']);

      expect(watcher.unwatchableRoots, isEmpty);
      expect(watcher.isDegraded, isFalse);
    });

    test('a refresh that throws does not end live updates', () async {
      final watcher = LocalLibraryWatcher(
        watchFactory: fs,
        onLibraryChanged: () async {
          refreshes.count++;
          if (refreshes.count == 1) throw StateError('scan failed');
        },
        quietPeriod: _quiet,
      );
      addTearDown(watcher.dispose);
      await watcher.syncRoots(<String>['/music']);

      fs.emit('/music', '/music/a.flac');
      await Future<void>.delayed(_quiet * 3);
      fs.emit('/music', '/music/b.flac');
      await Future<void>.delayed(_quiet * 3);

      expect(refreshes.count, 2);
    });
  });

  group('disposal', () {
    test('releases every watch', () async {
      final watcher = build();
      await watcher.syncRoots(<String>['/music', '/media/usb']);

      await watcher.dispose();

      expect(watcher.watchedRoots, isEmpty);
      expect(fs.cancelled..sort(), <String>['/media/usb', '/music']);
    });

    test('a scheduled refresh never fires afterwards', () async {
      final watcher = build();
      await watcher.syncRoots(<String>['/music']);
      fs.emit('/music', '/music/a.flac');
      // Stream delivery is asynchronous, so let the event actually arrive
      // before asking whether it scheduled anything.
      await pumpEventQueue();
      expect(watcher.hasPendingRefresh, isTrue);

      await watcher.dispose();
      await Future<void>.delayed(_quiet * 4);

      expect(refreshes.count, 0);
    });

    test('is idempotent', () async {
      final watcher = build();
      await watcher.syncRoots(<String>['/music']);

      await watcher.dispose();
      await watcher.dispose();

      expect(fs.cancelled, <String>['/music']);
    });

    test('a later syncRoots opens nothing', () async {
      final watcher = build();
      await watcher.dispose();

      await watcher.syncRoots(<String>['/music']);

      expect(fs.opened, isEmpty);
    });
  });
}
