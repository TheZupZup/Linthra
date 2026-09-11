// The scanner's half of "moved and deleted local tracks" (#410): what a scan
// concludes about files the catalog knew about that a folder no longer holds.
//
// The merge rules themselves live in local_library_scanner_test.dart; the
// matching rules live in local_catalog_reconciliation_test.dart. This is the
// seam between them.
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/sources/local/folder_scan_exception.dart';
import 'package:linthra/core/sources/local/local_catalog_reconciliation.dart';
import 'package:linthra/core/sources/local/local_library_scanner.dart';
import 'package:linthra/core/sources/local/local_music_source.dart';
import 'package:linthra/core/sources/local/local_scan_report.dart';

Track _tagged(String path, {String title = 'Holocene', int ms = 337000}) {
  return Track(
    id: path,
    uri: path,
    title: title,
    artistName: 'Bon Iver',
    albumName: 'Bon Iver',
    duration: Duration(milliseconds: ms),
    trackNumber: 5,
  );
}

LocalScan _scanOf(List<Track> tracks) {
  return LocalScan(
    tracks: tracks,
    report: LocalScanReport(
      folderSelected: true,
      isContentUri: false,
      filesVisited: tracks.length,
      foldersVisited: 1,
      audioCandidates: tracks.length,
      importedTracks: tracks.length,
      skippedUnsupported: 0,
      readFailures: 0,
    ),
  );
}

LocalRootScan _scanner(
  Map<String, List<Track>> byRoot, {
  Set<String> unavailable = const <String>{},
}) {
  return (String root) async {
    if (unavailable.contains(root)) {
      throw FolderScanException(
        "Linthra couldn't find the selected folder.",
        folder: root,
      );
    }
    return _scanOf(byRoot[root] ?? const <Track>[]);
  };
}

void main() {
  group('LocalLibraryScanner lifecycle', () {
    test('a deleted file leaves the catalog and is reported as removed',
        () async {
      final scanner = LocalLibraryScanner(_scanner(<String, List<Track>>{
        '/music': <Track>[_tagged('/music/a.flac')],
      }));

      final LocalLibraryScan scan = await scanner.scan(
        roots: <String>['/music'],
        previousTracks: <Track>[
          _tagged('/music/a.flac'),
          _tagged('/music/gone.flac', title: 'Perth', ms: 250000),
        ],
      );

      expect(scan.tracks.map((Track t) => t.uri), <String>['/music/a.flac']);
      expect(scan.reconciliation.removedUris, <String>['/music/gone.flac']);
      expect(scan.reconciliation.moves, isEmpty);
      expect(scan.isWritable, isTrue);
    });

    test('a proven move is reported so history can follow the file', () async {
      final scanner = LocalLibraryScanner(_scanner(<String, List<Track>>{
        '/music': <Track>[_tagged('/music/Bon Iver/05 Holocene.flac')],
      }));

      final LocalLibraryScan scan = await scanner.scan(
        roots: <String>['/music'],
        previousTracks: <Track>[_tagged('/music/inbox/track.flac')],
      );

      expect(
        scan.reconciliation.moves,
        <LocalTrackMove>[
          const LocalTrackMove(
            from: '/music/inbox/track.flac',
            to: '/music/Bon Iver/05 Holocene.flac',
          ),
        ],
      );
      expect(scan.reconciliation.removedUris, isEmpty);
    });

    test('an unavailable root reports no deletions at all', () async {
      final scanner = LocalLibraryScanner(
        _scanner(
          <String, List<Track>>{
            '/music': <Track>[_tagged('/music/a.flac')],
          },
          unavailable: <String>{'/media/usb'},
        ),
      );

      final LocalLibraryScan scan = await scanner.scan(
        roots: <String>['/music', '/media/usb'],
        previousTracks: <Track>[
          _tagged('/music/a.flac'),
          _tagged('/media/usb/kept.flac', title: 'Perth', ms: 250000),
        ],
      );

      expect(
        scan.tracks.map((Track t) => t.uri),
        containsAll(<String>['/music/a.flac', '/media/usb/kept.flac']),
      );
      expect(scan.reconciliation.isEmpty, isTrue);
      expect(scan.isWritable, isTrue);
    });

    test('a scan that read nothing concludes nothing', () async {
      final scanner = LocalLibraryScanner(
        _scanner(
          const <String, List<Track>>{},
          unavailable: <String>{'/music'},
        ),
      );

      final LocalLibraryScan scan = await scanner.scan(
        roots: <String>['/music'],
        previousTracks: <Track>[_tagged('/music/a.flac')],
      );

      expect(scan.isWritable, isFalse);
      expect(
        scan.reconciliation.isEmpty,
        isTrue,
        reason: 'a folder that could not be read cannot prove a deletion',
      );
    });

    test('without a previous catalog nothing is concluded', () async {
      final scanner = LocalLibraryScanner(_scanner(<String, List<Track>>{
        '/music': <Track>[_tagged('/music/a.flac')],
      }));

      final LocalLibraryScan scan =
          await scanner.scan(roots: <String>['/music']);

      expect(scan.reconciliation.isEmpty, isTrue);
    });

    test('removing a folder is not a deletion of its tracks', () async {
      // The user dropped /media/usb from their selection. Its tracks leave the
      // catalog (they are no longer part of the library), but nothing was
      // deleted from disk and no folder was read to prove otherwise.
      final scanner = LocalLibraryScanner(_scanner(<String, List<Track>>{
        '/music': <Track>[_tagged('/music/a.flac')],
      }));

      final LocalLibraryScan scan = await scanner.scan(
        roots: <String>['/music'],
        previousTracks: <Track>[
          _tagged('/music/a.flac'),
          _tagged('/media/usb/b.flac', title: 'Perth', ms: 250000),
        ],
      );

      expect(
        scan.tracks.map((Track t) => t.uri),
        <String>['/music/a.flac'],
      );
      expect(
        scan.reconciliation.removedUris,
        isEmpty,
        reason: "a de-selected folder was never scanned, so its files' "
            'history stays put in case the folder comes back',
      );
    });
  });
}
