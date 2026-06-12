import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/lyrics.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/local_lyrics_provider.dart';
import 'package:linthra/core/sources/local/local_lyrics_reader.dart';

/// A [LocalLyricsReader] that serves canned sidecar text by extension and
/// records what it was asked for — so order, short-circuit, and "never asked"
/// behaviour can be asserted. Can be made to throw to model a read failure.
class _FakeLocalLyricsReader implements LocalLyricsReader {
  _FakeLocalLyricsReader(
      {this.byExtension = const <String, String>{}, this.error});

  final Map<String, String> byExtension;
  final Object? error;
  final List<String> requestedExtensions = <String>[];
  String? lastUri;

  @override
  Future<String?> readSidecar(String trackUri, String extension) async {
    lastUri = trackUri;
    requestedExtensions.add(extension);
    if (error != null) throw error!;
    return byExtension[extension];
  }
}

const _localUri = 'content://com.android.externalstorage.documents'
    '/tree/primary%3AMusic/document/primary%3AMusic%2FSong.mp3';

Track _local() => const Track(id: _localUri, title: 'Song', uri: _localUri);

void main() {
  group('LocalLyricsProvider', () {
    test('declares the local source id the resolver routes by', () {
      expect(LocalLyricsProvider(_FakeLocalLyricsReader()).sourceId, 'local');
    });

    test('reads a synced .lrc sidecar for a local track', () async {
      final reader = _FakeLocalLyricsReader(byExtension: <String, String>{
        'lrc': '[00:00.00]first\n[00:05.00]second\n',
      });
      final provider = LocalLyricsProvider(reader);

      final Lyrics? lyrics = await provider.lyricsFor(_local());

      expect(lyrics, isNotNull);
      expect(lyrics!.isSynced, isTrue);
      expect(lyrics.lines, <LyricLine>[
        const LyricLine(text: 'first', start: Duration.zero),
        const LyricLine(text: 'second', start: Duration(seconds: 5)),
      ]);
      expect(reader.lastUri, _localUri);
    });

    test('reads a plain .txt sidecar when there is no .lrc', () async {
      final reader = _FakeLocalLyricsReader(byExtension: <String, String>{
        'txt': 'plain one\nplain two\n',
      });
      final provider = LocalLyricsProvider(reader);

      final Lyrics? lyrics = await provider.lyricsFor(_local());

      expect(lyrics, isNotNull);
      expect(lyrics!.isSynced, isFalse);
      expect(
        lyrics.lines.map((LyricLine l) => l.text).toList(),
        <String>['plain one', 'plain two'],
      );
      // It tried the synced .lrc first, then fell back to the plain .txt.
      expect(reader.requestedExtensions, <String>['lrc', 'txt']);
    });

    test('prefers the synced .lrc over a .txt when both exist', () async {
      final reader = _FakeLocalLyricsReader(byExtension: <String, String>{
        'lrc': '[00:01.00]synced\n',
        'txt': 'plain\n',
      });
      final provider = LocalLyricsProvider(reader);

      final Lyrics? lyrics = await provider.lyricsFor(_local());

      expect(lyrics!.isSynced, isTrue);
      expect(lyrics.lines.single.text, 'synced');
      // The .txt is never even read once the .lrc answered.
      expect(reader.requestedExtensions, <String>['lrc']);
    });

    test('returns null (no lyrics) when there is no sidecar', () async {
      final reader = _FakeLocalLyricsReader();
      final provider = LocalLyricsProvider(reader);

      expect(await provider.lyricsFor(_local()), isNull);
      // Both candidate sidecars were tried before giving up.
      expect(reader.requestedExtensions, <String>['lrc', 'txt']);
    });

    test('fails silently (null) when the reader throws', () async {
      final reader = _FakeLocalLyricsReader(error: Exception('I/O error'));
      final provider = LocalLyricsProvider(reader);

      // No throw escapes — a read failure is just "no lyrics".
      expect(await provider.lyricsFor(_local()), isNull);
    });

    test('treats an empty/metadata-only sidecar as no lyrics', () async {
      final reader = _FakeLocalLyricsReader(byExtension: <String, String>{
        'lrc': '[ar:Artist]\n[ti:Title]\n', // metadata only -> empty
        'txt': '   \n\n',
      });
      final provider = LocalLyricsProvider(reader);

      expect(await provider.lyricsFor(_local()), isNull);
    });

    test('handles a plain file:// path track (desktop case)', () async {
      final reader = _FakeLocalLyricsReader(byExtension: <String, String>{
        'lrc': '[00:02.00]from a file path\n',
      });
      final provider = LocalLyricsProvider(reader);

      final Lyrics? lyrics = await provider.lyricsFor(
        const Track(id: '1', title: 'Song', uri: 'file:///music/Song.mp3'),
      );

      expect(lyrics!.lines.single.text, 'from a file path');
    });

    test('never surfaces the track path/name in the rendered lyrics', () async {
      // A revealing URI: a private folder + file name. The displayed lyrics must
      // come only from the sidecar's content, never echo the path.
      const String revealing = 'content://com.android.externalstorage.documents'
          '/tree/primary%3AMusic/document'
          '/primary%3AMusic%2FPrivate%20Folder%2FMy%20Secret%20Song.mp3';
      final reader = _FakeLocalLyricsReader(byExtension: <String, String>{
        'txt': 'la la la\nfade out\n',
      });
      final provider = LocalLyricsProvider(reader);

      final Lyrics lyrics = (await provider.lyricsFor(
        const Track(id: revealing, title: 'Song', uri: revealing),
      ))!;

      for (final LyricLine line in lyrics.lines) {
        expect(line.text, isNot(contains('Secret')));
        expect(line.text, isNot(contains('Private')));
        expect(line.text, isNot(contains('primary')));
        expect(line.text, isNot(contains('content://')));
      }
      expect(
        lyrics.lines.map((LyricLine l) => l.text).toList(),
        <String>['la la la', 'fade out'],
      );
    });
  });
}
