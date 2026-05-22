import 'package:flutter_test/flutter_test.dart';
import 'package:sonara/core/sources/local/audio_file_scanner.dart';
import 'package:sonara/core/sources/local/local_music_source.dart';

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
  });
}
