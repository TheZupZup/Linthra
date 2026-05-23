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
}
