import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/sources/local/folder_scan_exception.dart';
import 'package:linthra/core/sources/local/local_library_scanner.dart';
import 'package:linthra/core/sources/local/local_music_source.dart';
import 'package:linthra/core/sources/local/local_scan_report.dart';

Track _track(String path) => Track(id: path, title: path, uri: path);

LocalScan _scanOf(List<String> paths) {
  return LocalScan(
    tracks: <Track>[for (final String path in paths) _track(path)],
    report: LocalScanReport(
      folderSelected: true,
      isContentUri: false,
      filesVisited: paths.length,
      foldersVisited: 1,
      audioCandidates: paths.length,
      importedTracks: paths.length,
      skippedUnsupported: 0,
      readFailures: 0,
    ),
  );
}

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
        scan.tracks.map((Track t) => t.uri),
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
        scan.tracks.map((Track t) => t.uri),
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
        previousTracks: <Track>[
          _track('/music/gone.mp3'),
          _track('/media/usb/kept.mp3'),
        ],
      );

      expect(
        scan.tracks.map((Track t) => t.uri),
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
        previousTracks: <Track>[
          _track('/removed/old.mp3'),
          _track('/media/usb/kept.mp3'),
        ],
      );

      expect(
        scan.tracks.map((Track t) => t.uri),
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
        previousTracks: <Track>[_track('/music/a.mp3')],
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
}
