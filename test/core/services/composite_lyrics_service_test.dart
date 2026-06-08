import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/lyrics.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/composite_lyrics_service.dart';
import 'package:linthra/core/services/lyrics_service.dart';

/// A [LyricsService] that returns canned lyrics (or throws), and records whether
/// it was asked — so order/short-circuit behaviour can be asserted.
class _StubLyricsService implements LyricsService {
  _StubLyricsService({this.lyrics, this.error});

  final Lyrics? lyrics;
  final Object? error;
  bool called = false;

  @override
  Future<Lyrics?> lyricsFor(Track track) async {
    called = true;
    if (error != null) throw error!;
    return lyrics;
  }
}

const _track = Track(id: '1', title: 'Song', uri: 'subsonic:1');
const _lyrics = Lyrics(lines: <LyricLine>[LyricLine(text: 'hi')]);

void main() {
  group('CompositeLyricsService', () {
    test('returns the first backend with lyrics and stops there', () async {
      final first = _StubLyricsService(lyrics: _lyrics);
      final second = _StubLyricsService(lyrics: const Lyrics(lines: []));
      final service = CompositeLyricsService(<LyricsService>[first, second]);

      final lyrics = await service.lyricsFor(_track);

      expect(lyrics, _lyrics);
      expect(first.called, isTrue);
      // Short-circuits: a later backend isn't asked once one answers.
      expect(second.called, isFalse);
    });

    test('falls through backends that decline (null)', () async {
      final first = _StubLyricsService(); // null
      final second = _StubLyricsService(lyrics: _lyrics);
      final service = CompositeLyricsService(<LyricsService>[first, second]);

      final lyrics = await service.lyricsFor(_track);

      expect(lyrics, _lyrics);
      expect(first.called, isTrue);
      expect(second.called, isTrue);
    });

    test('returns null when every backend declines', () async {
      final service = CompositeLyricsService(<LyricsService>[
        _StubLyricsService(),
        _StubLyricsService(),
      ]);

      expect(await service.lyricsFor(_track), isNull);
    });

    test('propagates an error from a backend (so the UI can show '
        '"couldn\'t load")', () async {
      final service = CompositeLyricsService(<LyricsService>[
        _StubLyricsService(error: StateError('offline')),
      ]);

      expect(() => service.lyricsFor(_track), throwsA(isA<StateError>()));
    });

    test('with no backends, resolves to null', () async {
      final service = CompositeLyricsService(const <LyricsService>[]);
      expect(await service.lyricsFor(_track), isNull);
    });
  });
}
