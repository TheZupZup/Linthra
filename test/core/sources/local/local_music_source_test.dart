import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/sources/local/audio_file_scanner.dart';
import 'package:linthra/core/sources/local/folder_scan_exception.dart';
import 'package:linthra/core/sources/local/local_music_source.dart';
import 'package:linthra/core/sources/local/saf_document_lister.dart';

import 'fake_saf_document_lister.dart';

const _safFolder = 'content://com.android.externalstorage.documents/tree/x';

/// Returns a fixed list of paths and records the folder it was asked to scan,
/// so the source can be tested without touching a real file system.
class _FakeScanner implements AudioFileScanner {
  _FakeScanner(this._files);

  final List<String> _files;
  String? requestedFolder;

  @override
  Future<List<String>> listFiles(String folderPath) async {
    requestedFolder = folderPath;
    return _files;
  }
}

void main() {
  group('LocalMusicSource', () {
    test('identifies itself as the local source', () {
      const source = LocalMusicSource(folderPath: '/music');
      expect(source.id, 'local');
      expect(source.displayName, isNotEmpty);
    });

    test('returns no tracks when no folder is set', () async {
      final scanner = _FakeScanner(<String>['/music/song.mp3']);
      final source = LocalMusicSource(folderPath: null, scanner: scanner);

      expect(await source.fetchTracks(), isEmpty);
      expect(scanner.requestedFolder, isNull);
    });

    test('returns no tracks for an empty folder path', () async {
      final scanner = _FakeScanner(<String>['/music/song.mp3']);
      final source = LocalMusicSource(folderPath: '', scanner: scanner);

      expect(await source.fetchTracks(), isEmpty);
      expect(scanner.requestedFolder, isNull);
    });

    test('keeps audio files and ignores the rest', () async {
      final scanner = _FakeScanner(<String>[
        '/music/Track One.mp3',
        '/music/cover.jpg',
        '/music/Track Two.flac',
        '/music/notes.txt',
        '/music/Track Three.WAV',
        '/music/.DS_Store',
      ]);
      final source = LocalMusicSource(folderPath: '/music', scanner: scanner);

      final tracks = await source.fetchTracks();

      expect(tracks.map((track) => track.title).toList(), <String>[
        'Track One',
        'Track Two',
        'Track Three',
      ]);
      expect(scanner.requestedFolder, '/music');
    });

    test('maps each kept file to a track uri', () async {
      final scanner = _FakeScanner(<String>['/music/song.opus']);
      final source = LocalMusicSource(folderPath: '/music', scanner: scanner);

      final tracks = await source.fetchTracks();

      expect(tracks, hasLength(1));
      expect(tracks.single.uri, '/music/song.opus');
      expect(tracks.single.title, 'song');
    });

    test('exposes no albums or artists yet', () async {
      final scanner = _FakeScanner(<String>['/music/song.mp3']);
      final source = LocalMusicSource(folderPath: '/music', scanner: scanner);

      expect(await source.fetchAlbums(), isEmpty);
      expect(await source.fetchArtists(), isEmpty);
    });

    test('resolves a track to a file uri', () async {
      final scanner = _FakeScanner(<String>['/music/song.mp3']);
      final source = LocalMusicSource(folderPath: '/music', scanner: scanner);
      final tracks = await source.fetchTracks();

      final uri = await source.resolvePlayableUri(tracks.single);

      expect(uri, Uri.file('/music/song.mp3'));
    });

    test('resolves a content URI track to a content URI', () async {
      const source = LocalMusicSource(folderPath: '/music');
      const track = Track(id: 'c', title: 'C', uri: 'content://doc/9');

      final uri = await source.resolvePlayableUri(track);

      expect(uri, Uri.parse('content://doc/9'));
    });

    test('scans a content URI through the SAF lister', () async {
      final saf = FakeSafDocumentLister(
        documents: const <SafAudioDocument>[
          SafAudioDocument(uri: 'content://doc/1', name: 'One.mp3'),
          SafAudioDocument(uri: 'content://doc/2', name: 'cover.jpg'),
          SafAudioDocument(uri: 'content://doc/3', name: 'Two.flac'),
        ],
      );
      final source = LocalMusicSource(
        folderPath: _safFolder,
        scanner: _FakeScanner(const <String>[]),
        safDocumentLister: saf,
      );

      final tracks = await source.fetchTracks();

      expect(saf.requestedTreeUri, _safFolder);
      // The non-audio document is dropped; titles come from the display names.
      expect(tracks.map((track) => track.title).toList(), <String>[
        'One',
        'Two',
      ]);
      expect(tracks.first.uri, 'content://doc/1');
    });

    test('falls back to the path scanner when SAF is unsupported', () async {
      final scanner = _FakeScanner(<String>['/storage/emulated/0/Music/A.mp3']);
      final source = LocalMusicSource(
        folderPath: _safFolder,
        scanner: scanner,
        safDocumentLister: FakeSafDocumentLister(unsupported: true),
      );

      final tracks = await source.fetchTracks();

      // The legacy filesystem scanner ran on the content URI string.
      expect(scanner.requestedFolder, _safFolder);
      expect(tracks.single.title, 'A');
    });

    test('surfaces a SAF traversal failure', () async {
      final source = LocalMusicSource(
        folderPath: _safFolder,
        scanner: _FakeScanner(const <String>[]),
        safDocumentLister: FakeSafDocumentLister(
          error: const FolderScanException('nope'),
        ),
      );

      await expectLater(
        source.fetchTracks(),
        throwsA(isA<FolderScanException>()),
      );
    });
  });

  group('LocalMusicSource.scanTracks reports', () {
    test('reports the counts for a filesystem scan', () async {
      final scanner = _FakeScanner(<String>[
        '/music/One.mp3',
        '/music/cover.jpg',
        '/music/Two.flac',
        '/music/notes.txt',
      ]);
      final source = LocalMusicSource(folderPath: '/music', scanner: scanner);

      final scan = await source.scanTracks();

      expect(scan.tracks.map((track) => track.title), <String>['One', 'Two']);
      expect(scan.report.folderSelected, isTrue);
      expect(scan.report.isContentUri, isFalse);
      expect(scan.report.filesVisited, 4);
      expect(scan.report.audioCandidates, 2);
      expect(scan.report.skippedUnsupported, 2);
      expect(scan.report.readFailures, 0);
      expect(scan.report.error, isNull);
    });

    test('counts every recursively discovered file as visited', () async {
      final scanner = _FakeScanner(<String>[
        '/music/A.mp3',
        '/music/Album/B.flac',
        '/music/Album/Disc 2/C.ogg',
      ]);
      final source = LocalMusicSource(folderPath: '/music', scanner: scanner);

      final scan = await source.scanTracks();

      expect(scan.tracks, hasLength(3));
      expect(scan.report.filesVisited, 3);
      expect(scan.report.audioCandidates, 3);
      expect(scan.report.skippedUnsupported, 0);
    });

    test('no folder selected reports folderSelected = false', () async {
      const source = LocalMusicSource(folderPath: null);

      final scan = await source.scanTracks();

      expect(scan.tracks, isEmpty);
      expect(scan.report.folderSelected, isFalse);
      expect(scan.report.filesVisited, 0);
      expect(scan.report.hadError, isFalse);
    });

    test('an empty SAF folder returns a clear, error-free empty result',
        () async {
      final source = LocalMusicSource(
        folderPath: _safFolder,
        scanner: _FakeScanner(const <String>[]),
        safDocumentLister: FakeSafDocumentLister(),
      );

      final scan = await source.scanTracks();

      expect(scan.tracks, isEmpty);
      expect(scan.report.folderSelected, isTrue);
      expect(scan.report.isContentUri, isTrue);
      expect(scan.report.filesVisited, 0);
      expect(scan.report.audioCandidates, 0);
      expect(scan.report.skippedUnsupported, 0);
      expect(scan.report.readFailures, 0);
      expect(scan.report.hadError, isFalse);
    });

    test('keeps a SAF document with a valid extension but unknown MIME',
        () async {
      final saf = FakeSafDocumentLister(
        documents: const <SafAudioDocument>[
          SafAudioDocument(
            uri: 'content://doc/1',
            name: 'Song.mp3',
            mimeType: 'application/octet-stream',
          ),
        ],
        filesVisited: 1,
      );
      final source = LocalMusicSource(
        folderPath: _safFolder,
        scanner: _FakeScanner(const <String>[]),
        safDocumentLister: saf,
      );

      final scan = await source.scanTracks();

      expect(scan.tracks.single.title, 'Song');
      expect(scan.report.audioCandidates, 1);
      expect(scan.report.skippedUnsupported, 0);
    });

    test('keeps a SAF document with an audio MIME but no known extension',
        () async {
      final saf = FakeSafDocumentLister(
        documents: const <SafAudioDocument>[
          // No recognised extension, but the provider reported audio content,
          // so it must not be dropped.
          SafAudioDocument(
            uri: 'content://doc/9',
            name: 'recording',
            mimeType: 'audio/mpeg',
          ),
        ],
        filesVisited: 1,
      );
      final source = LocalMusicSource(
        folderPath: _safFolder,
        scanner: _FakeScanner(const <String>[]),
        safDocumentLister: saf,
      );

      final scan = await source.scanTracks();

      expect(scan.tracks, hasLength(1));
      expect(scan.tracks.single.uri, 'content://doc/9');
      expect(scan.report.audioCandidates, 1);
    });

    test('an unreadable subtree is skipped, counted, and never fatal',
        () async {
      // The native walk found one good audio document but also reported a
      // subtree it could not read; the scan must still return the track and
      // record the failure rather than throwing.
      final saf = FakeSafDocumentLister(
        documents: const <SafAudioDocument>[
          SafAudioDocument(uri: 'content://doc/1', name: 'Good.mp3'),
        ],
        filesVisited: 1,
        readFailures: 2,
      );
      final source = LocalMusicSource(
        folderPath: _safFolder,
        scanner: _FakeScanner(const <String>[]),
        safDocumentLister: saf,
      );

      final scan = await source.scanTracks();

      expect(scan.tracks.single.title, 'Good');
      expect(scan.report.readFailures, 2);
      expect(scan.report.audioCandidates, 1);
      expect(scan.report.hadError, isFalse);
    });
  });
}
