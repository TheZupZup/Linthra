import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/local_file_stamp.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/sources/local/folder_scan_exception.dart';
import 'package:linthra/core/sources/local/local_catalog_reconciliation.dart';
import 'package:linthra/core/sources/local/local_library_scanner.dart';
import 'package:linthra/core/sources/local/local_music_source.dart';
import 'package:linthra/core/sources/local/local_scan_report.dart';

Track _track(String path) => Track(id: path, title: path, uri: path);

/// A previously indexed row, as the scan reads them back. The stamp is beside
/// the point in these merge tests, so there isn't one.
StampedTrack _indexed(String path) => StampedTrack(track: _track(path));

/// A walk that returned [paths]. [unreadableDirectories] are the subfolders it
/// could not list, as the desktop walk names them; [unlocatedReadFailures]
/// counts the ones it could not list without naming them, as Android's SAF
/// walk does.
LocalScan _scanOf(
  List<String> paths, {
  List<String> unreadableDirectories = const <String>[],
  int unlocatedReadFailures = 0,
}) {
  return LocalScan(
    tracks: <Track>[for (final String path in paths) _track(path)],
    unreadableDirectories: unreadableDirectories,
    hasUnlocatedReadFailures: unlocatedReadFailures > 0,
    report: LocalScanReport(
      folderSelected: true,
      isContentUri: false,
      filesVisited: paths.length,
      foldersVisited: 1,
      audioCandidates: paths.length,
      importedTracks: paths.length,
      skippedUnsupported: 0,
      readFailures: unreadableDirectories.length + unlocatedReadFailures,
    ),
  );
}

/// A track with tags, which is what gives it an identity a moved file can be
/// recognised by.
Track _tagged(String path) => Track(
      id: path,
      uri: path,
      title: 'Holocene',
      artistName: 'Bon Iver',
      albumName: 'Bon Iver',
      duration: const Duration(milliseconds: 337000),
    );

List<String> _uris(LocalLibraryScan scan) =>
    scan.plainTracks.map((Track t) => t.uri).toList();

/// Answers with canned files per folder, and fails for the folders named in
/// [unavailable] the way a missing drive does.
LocalRootScan _scanner(
  Map<String, List<String>> byRoot, {
  Set<String> unavailable = const <String>{},
}) {
  return (String root) async {
    if (unavailable.contains(root)) {
      throw FolderScanException(
        "Linthra couldn't find the selected folder.",
        folder: root,
      );
    }
    return _scanOf(byRoot[root] ?? const <String>[]);
  };
}

void main() {
  group('LocalLibraryScanner', () {
    test('scans several folders into one library', () async {
      final scanner = LocalLibraryScanner(_scanner(<String, List<String>>{
        '/music': <String>['/music/a.mp3'],
        '/media/usb': <String>['/media/usb/b.mp3', '/media/usb/c.mp3'],
      }));

      final LocalLibraryScan scan = await scanner.scan(
        roots: <String>['/music', '/media/usb'],
      );

      expect(
        scan.plainTracks.map((Track t) => t.uri),
        <String>['/music/a.mp3', '/media/usb/b.mp3', '/media/usb/c.mp3'],
      );
      expect(scan.report.importedTracks, 3);
      expect(scan.report.rootsScanned, 2);
      expect(scan.report.rootsUnavailable, 0);
      expect(scan.report.hadError, isFalse);
      expect(scan.isWritable, isTrue);
    });

    test('an overlapping folder is walked once, not twice', () async {
      final List<String> walked = <String>[];
      final scanner = LocalLibraryScanner((String root) async {
        walked.add(root);
        return _scanOf(<String>['/music/live sets/a.mp3']);
      });

      final LocalLibraryScan scan = await scanner.scan(
        roots: <String>['/music', '/music/live sets'],
      );

      expect(walked, <String>['/music']);
      expect(scan.tracks, hasLength(1));
      expect(scan.report.rootsScanned, 1);
    });

    test('the same file reached from two folders is imported once', () async {
      // Two mounts of the same directory: the folders do not nest, so both are
      // walked, and the uri is what collapses the duplicate.
      final scanner = LocalLibraryScanner(_scanner(<String, List<String>>{
        '/music': <String>['/music/a.mp3'],
        '/media/usb': <String>['/music/a.mp3', '/media/usb/b.mp3'],
      }));

      final LocalLibraryScan scan = await scanner.scan(
        roots: <String>['/music', '/media/usb'],
      );

      expect(
        scan.plainTracks.map((Track t) => t.uri),
        <String>['/music/a.mp3', '/media/usb/b.mp3'],
      );
    });

    test('an unavailable folder keeps the tracks it already had', () async {
      final scanner = LocalLibraryScanner(
        _scanner(
          <String, List<String>>{
            '/music': <String>['/music/a.mp3']
          },
          unavailable: <String>{'/media/usb'},
        ),
      );

      final LocalLibraryScan scan = await scanner.scan(
        roots: <String>['/music', '/media/usb'],
        previousTracks: <StampedTrack>[
          _indexed('/music/gone.mp3'),
          _indexed('/media/usb/kept.mp3'),
        ],
      );

      expect(
        scan.plainTracks.map((Track t) => t.uri),
        <String>['/music/a.mp3', '/media/usb/kept.mp3'],
        reason: 'the unplugged drive keeps its music; the readable folder is '
            'refreshed, so a file deleted there is gone',
      );
      expect(scan.report.rootsUnavailable, 1);
      expect(scan.report.isPartial, isTrue);
      expect(scan.report.hadError, isFalse);
      expect(scan.isWritable, isTrue);
      expect(scan.unavailableRoots, <String>['/media/usb']);
    });

    test('a track no selected folder owns is dropped', () async {
      final scanner = LocalLibraryScanner(
        _scanner(
          <String, List<String>>{
            '/music': <String>['/music/a.mp3']
          },
          unavailable: <String>{'/media/usb'},
        ),
      );

      final LocalLibraryScan scan = await scanner.scan(
        roots: <String>['/music', '/media/usb'],
        previousTracks: <StampedTrack>[
          _indexed('/removed/old.mp3'),
          _indexed('/media/usb/kept.mp3'),
        ],
      );

      expect(
        scan.plainTracks.map((Track t) => t.uri),
        isNot(contains('/removed/old.mp3')),
      );
    });

    test('when no folder can be read, nothing may be written', () async {
      final scanner = LocalLibraryScanner(
        _scanner(
          const <String, List<String>>{},
          unavailable: <String>{'/music', '/media/usb'},
        ),
      );

      final LocalLibraryScan scan = await scanner.scan(
        roots: <String>['/music', '/media/usb'],
        previousTracks: <StampedTrack>[_indexed('/music/a.mp3')],
      );

      expect(scan.everyRootFailed, isTrue);
      expect(scan.isWritable, isFalse);
      expect(scan.report.error, LocalScanError.folderUnavailable);
      expect(scan.report.rootsUnavailable, 2);
      expect(scan.firstFailureMessage, isNotNull);
    });

    test('a failure with no way to retain must not be written', () async {
      final scanner = LocalLibraryScanner(
        _scanner(
          <String, List<String>>{
            '/music': <String>['/music/a.mp3']
          },
          unavailable: <String>{'/media/usb'},
        ),
      );

      // previousTracks omitted: the catalog could not be read back, so the
      // offline folder's music cannot be carried over.
      final LocalLibraryScan scan = await scanner.scan(
        roots: <String>['/music', '/media/usb'],
      );

      expect(scan.retentionUnavailable, isTrue);
      expect(scan.isWritable, isFalse);
    });

    test('no selected folder scans nothing and stays writable', () async {
      final scanner = LocalLibraryScanner(
        _scanner(const <String, List<String>>{}),
      );

      final LocalLibraryScan scan =
          await scanner.scan(roots: <String>['', ' ']);

      expect(scan.tracks, isEmpty);
      expect(scan.roots, isEmpty);
      expect(scan.report.folderSelected, isFalse);
      expect(scan.report.rootsScanned, 0);
      expect(scan.isWritable, isTrue);
    });

    test('one folder that fails is still a plain failure', () async {
      final scanner = LocalLibraryScanner(
        _scanner(
          const <String, List<String>>{},
          unavailable: <String>{'/music'},
        ),
      );

      final LocalLibraryScan scan = await scanner.scan(
        roots: <String>['/music'],
      );

      expect(scan.isWritable, isFalse);
      expect(scan.report.error, LocalScanError.folderUnavailable);
      expect(scan.report.rootsScanned, 1);
    });

    test('per-folder counts add up in the merged report', () async {
      final scanner = LocalLibraryScanner((String root) async {
        return LocalScan(
          tracks: <Track>[_track('$root/a.mp3')],
          report: const LocalScanReport(
            folderSelected: true,
            isContentUri: false,
            filesVisited: 4,
            foldersVisited: 2,
            audioCandidates: 1,
            importedTracks: 1,
            skippedUnsupported: 3,
            readFailures: 1,
          ),
        );
      });

      final LocalLibraryScan scan = await scanner.scan(
        roots: <String>['/music', '/media/usb'],
      );

      expect(scan.report.filesVisited, 8);
      expect(scan.report.foldersVisited, 4);
      expect(scan.report.skippedUnsupported, 6);
      expect(scan.report.readFailures, 2);
      expect(scan.report.importedTracks, 2);
      expect(scan.report.isContentUri, isFalse);
      expect(scan.report.isDeviceLibrary, isFalse);
    });
  });

  group('a walk that could not read part of a folder', () {
    const String tree =
        'content://com.android.externalstorage.documents/tree/primary%3AMusic';

    test('keeps what was indexed under the subfolder it could not list',
        () async {
      final scanner = LocalLibraryScanner((String root) async {
        return _scanOf(
          <String>['/music/A/one.mp3'],
          unreadableDirectories: <String>['/music/B'],
        );
      });
      const StampedTrack kept = StampedTrack(
        track: Track(id: 'kept', title: 'Kept', uri: '/music/B/kept.mp3'),
        stamp: LocalFileStamp(sizeBytes: 300, modifiedAtMs: 3000),
      );

      final LocalLibraryScan scan = await scanner.scan(
        roots: <String>['/music'],
        previousTracks: <StampedTrack>[
          _indexed('/music/A/one.mp3'),
          _indexed('/music/A/gone.mp3'),
          kept,
          _indexed('/music/B/Live/deep.mp3'),
        ],
      );

      expect(
        _uris(scan),
        <String>[
          '/music/A/one.mp3',
          '/music/B/kept.mp3',
          '/music/B/Live/deep.mp3',
        ],
        reason: 'B could not be listed, so nothing under it is known to be '
            'gone; A was read, so a file missing from it is',
      );
      expect(
        scan.tracks.singleWhere(
          (StampedTrack t) => t.track.uri == '/music/B/kept.mp3',
        ),
        same(kept),
        reason: 'carried over stamp and all, like the tracks of a folder that '
            'could not be read at all',
      );
      expect(scan.reconciliation.removedUris, <String>['/music/A/gone.mp3']);
      expect(scan.roots.single.importedTracks, 3);
      expect(scan.roots.single.available, isTrue);
      expect(scan.report.readFailures, 1);
      expect(scan.retentionUnavailable, isFalse);
      expect(scan.isWritable, isTrue);
    });

    test('keeps only what is under it, not a sibling that starts the same',
        () async {
      final scanner = LocalLibraryScanner((String root) async {
        return _scanOf(
          const <String>[],
          unreadableDirectories: <String>['/music/B/Live'],
        );
      });

      final LocalLibraryScan scan = await scanner.scan(
        roots: <String>['/music'],
        previousTracks: <StampedTrack>[
          _indexed('/music/B/Live/encore.mp3'),
          _indexed('/music/B/studio.mp3'),
          _indexed('/music/B/Live.mp3'),
          _indexed('/music/B/Live sets/gone.mp3'),
        ],
      );

      expect(_uris(scan), <String>['/music/B/Live/encore.mp3']);
      expect(
        scan.reconciliation.removedUris,
        unorderedEquals(<String>[
          '/music/B/studio.mp3',
          '/music/B/Live.mp3',
          '/music/B/Live sets/gone.mp3',
        ]),
      );
    });

    test('does not take a kept track for one that moved', () async {
      // A copy of a file under the unreadable subfolder turns up in the part
      // that was read. Taking that for the original having moved would hand
      // the original's play count and heart to the copy, while the original is
      // most likely still where it was.
      final scanner = LocalLibraryScanner((String root) async {
        return LocalScan(
          tracks: <Track>[_tagged('/music/A/copy.flac')],
          unreadableDirectories: const <String>['/music/B'],
          report: const LocalScanReport(
            folderSelected: true,
            isContentUri: false,
            filesVisited: 1,
            audioCandidates: 1,
            importedTracks: 1,
            skippedUnsupported: 0,
            readFailures: 1,
          ),
        );
      });

      final LocalLibraryScan scan = await scanner.scan(
        roots: <String>['/music'],
        previousTracks: <StampedTrack>[
          StampedTrack(track: _tagged('/music/B/original.flac')),
        ],
      );

      expect(scan.reconciliation.moves, isEmpty);
      expect(scan.reconciliation.removedUris, isEmpty);
      expect(
        _uris(scan),
        <String>['/music/A/copy.flac', '/music/B/original.flac'],
      );
    });

    test('keeps the whole folder when the walk cannot say what it missed',
        () async {
      final scanner = LocalLibraryScanner((String root) async {
        return _scanOf(
          <String>['$tree/document/a'],
          unlocatedReadFailures: 2,
        );
      });

      final LocalLibraryScan scan = await scanner.scan(
        roots: <String>[tree],
        previousTracks: <StampedTrack>[
          _indexed('$tree/document/a'),
          _indexed('$tree/document/b'),
          _indexed('$tree/document/c'),
          // Left over from a folder that is no longer selected.
          _indexed('content://com.example.documents/tree/old/document/d'),
        ],
      );

      expect(
        _uris(scan),
        <String>['$tree/document/a', '$tree/document/b', '$tree/document/c'],
      );
      expect(scan.reconciliation, same(LocalCatalogReconciliation.none));
      expect(scan.roots.single.importedTracks, 3);
      expect(scan.report.readFailures, 2);
      expect(scan.isWritable, isTrue);
    });

    test('keeps what a SAF folder walked by its path could not list', () async {
      // Without native SAF traversal, a tree is resolved to a path and walked
      // like a desktop folder, so its tracks are paths that the `content://`
      // selection does not own. The subfolder the walk named is still enough
      // to keep them.
      final scanner = LocalLibraryScanner((String root) async {
        return _scanOf(
          <String>['/storage/emulated/0/Music/A/a.mp3'],
          unreadableDirectories: <String>['/storage/emulated/0/Music/B'],
        );
      });

      final LocalLibraryScan scan = await scanner.scan(
        roots: <String>[tree],
        previousTracks: <StampedTrack>[
          _indexed('/storage/emulated/0/Music/A/a.mp3'),
          _indexed('/storage/emulated/0/Music/B/b.mp3'),
        ],
      );

      expect(
        _uris(scan),
        <String>[
          '/storage/emulated/0/Music/A/a.mp3',
          '/storage/emulated/0/Music/B/b.mp3',
        ],
      );
    });

    test('a complete walk of a SAF folder still concludes what is gone',
        () async {
      final scanner = LocalLibraryScanner((String root) async {
        return _scanOf(<String>['$tree/document/a']);
      });

      final LocalLibraryScan scan = await scanner.scan(
        roots: <String>[tree],
        previousTracks: <StampedTrack>[
          _indexed('$tree/document/a'),
          _indexed('$tree/document/b'),
        ],
      );

      expect(_uris(scan), <String>['$tree/document/a']);
      expect(scan.reconciliation.removedUris, <String>['$tree/document/b']);
    });

    test('keeps both beside a folder that could not be read at all', () async {
      final scanner = LocalLibraryScanner((String root) async {
        if (root == '/media/usb') {
          throw FolderScanException(
            "Linthra couldn't find the selected folder.",
            folder: root,
          );
        }
        return _scanOf(
          <String>['/music/A/one.mp3'],
          unreadableDirectories: <String>['/music/B'],
        );
      });

      final LocalLibraryScan scan = await scanner.scan(
        roots: <String>['/music', '/media/usb'],
        previousTracks: <StampedTrack>[
          _indexed('/music/A/one.mp3'),
          _indexed('/music/B/kept.mp3'),
          _indexed('/media/usb/kept.mp3'),
        ],
      );

      expect(
        _uris(scan),
        <String>[
          '/music/A/one.mp3',
          '/music/B/kept.mp3',
          '/media/usb/kept.mp3',
        ],
      );
      expect(scan.isWritable, isTrue);
    });

    for (final bool named in <bool>[true, false]) {
      test(
          'must not be written when the indexed tracks cannot be read back '
          '(${named ? 'named' : 'unnamed'} subfolders)', () async {
        final scanner = LocalLibraryScanner((String root) async {
          return named
              ? _scanOf(
                  <String>['/music/A/one.mp3'],
                  unreadableDirectories: <String>['/music/B'],
                )
              : _scanOf(
                  <String>['/music/A/one.mp3'],
                  unlocatedReadFailures: 1,
                );
        });

        // previousTracks omitted: the catalog could not be read back, so what
        // was indexed under the unread part cannot be carried over.
        final LocalLibraryScan scan = await scanner.scan(
          roots: <String>['/music'],
        );

        expect(scan.retentionUnavailable, isTrue);
        expect(scan.isWritable, isFalse);
        expect(scan.roots.single.available, isTrue);
      });
    }

    test('a complete walk with nothing to read back is still written',
        () async {
      final scanner = LocalLibraryScanner((String root) async {
        return _scanOf(<String>['/music/A/one.mp3']);
      });

      final LocalLibraryScan scan = await scanner.scan(
        roots: <String>['/music'],
      );

      expect(scan.retentionUnavailable, isFalse);
      expect(scan.isWritable, isTrue);
    });
  });
}
