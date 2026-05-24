import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/lyrics.dart';

void main() {
  group('Lyrics', () {
    test('isSynced is true only when a line carries a timestamp', () {
      const plain = Lyrics(lines: <LyricLine>[
        LyricLine(text: 'a'),
        LyricLine(text: 'b'),
      ]);
      const synced = Lyrics(lines: <LyricLine>[
        LyricLine(text: 'a', start: Duration.zero),
        LyricLine(text: 'b', start: Duration(seconds: 5)),
      ]);
      expect(plain.isSynced, isFalse);
      expect(synced.isSynced, isTrue);
    });

    group('activeLineIndex', () {
      const lyrics = Lyrics(lines: <LyricLine>[
        LyricLine(text: 'one', start: Duration.zero),
        LyricLine(text: 'two', start: Duration(seconds: 10)),
        LyricLine(text: 'three', start: Duration(seconds: 20)),
      ]);

      test('is -1 before the first timed line begins', () {
        const before = Lyrics(lines: <LyricLine>[
          LyricLine(text: 'intro', start: Duration(seconds: 5)),
          LyricLine(text: 'one', start: Duration(seconds: 10)),
        ]);
        expect(before.activeLineIndex(const Duration(seconds: 2)), -1);
      });

      test('returns the last line at or before the position', () {
        expect(lyrics.activeLineIndex(const Duration(seconds: 0)), 0);
        expect(lyrics.activeLineIndex(const Duration(seconds: 9)), 0);
        expect(lyrics.activeLineIndex(const Duration(seconds: 10)), 1);
        expect(lyrics.activeLineIndex(const Duration(seconds: 15)), 1);
        expect(lyrics.activeLineIndex(const Duration(seconds: 25)), 2);
      });

      test('plain (untimed) lyrics never highlight a line', () {
        const plain = Lyrics(lines: <LyricLine>[
          LyricLine(text: 'a'),
          LyricLine(text: 'b'),
        ]);
        expect(plain.activeLineIndex(const Duration(seconds: 30)), -1);
      });
    });
  });
}
