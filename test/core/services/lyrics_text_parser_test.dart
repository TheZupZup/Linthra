import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/lyrics.dart';
import 'package:linthra/core/services/lyrics_text_parser.dart';

void main() {
  group('LyricsTextParser.parseLrc', () {
    test('reads timestamped lines into synced lyrics', () {
      final Lyrics? lyrics = LyricsTextParser.parseLrc(
        '[00:00.00]First line\n'
        '[00:12.34]Second line\n'
        '[01:02.50]Third line\n',
      );

      expect(lyrics, isNotNull);
      expect(lyrics!.isSynced, isTrue);
      expect(lyrics.lines, <LyricLine>[
        const LyricLine(text: 'First line', start: Duration.zero),
        const LyricLine(
          text: 'Second line',
          start: Duration(seconds: 12, milliseconds: 340),
        ),
        const LyricLine(
          text: 'Third line',
          start: Duration(minutes: 1, seconds: 2, milliseconds: 500),
        ),
      ]);
    });

    test('scales the fraction by its digit count (tenths/centis/millis)', () {
      final Lyrics lyrics = LyricsTextParser.parseLrc(
        '[00:01.5]tenths\n' // 1 digit -> 500ms
        '[00:02.05]centis\n' // 2 digits -> 50ms
        '[00:03.250]millis\n' // 3 digits -> 250ms
        '[00:04]whole\n', // no fraction -> 0ms
      )!;

      expect(lyrics.lines.map((LyricLine l) => l.start).toList(), <Duration>[
        const Duration(seconds: 1, milliseconds: 500),
        const Duration(seconds: 2, milliseconds: 50),
        const Duration(seconds: 3, milliseconds: 250),
        const Duration(seconds: 4),
      ]);
    });

    test('repeats a line for each of its leading timestamps', () {
      final Lyrics lyrics = LyricsTextParser.parseLrc(
        '[00:05.00][00:10.00]Chorus\n',
      )!;

      expect(lyrics.lines, <LyricLine>[
        const LyricLine(text: 'Chorus', start: Duration(seconds: 5)),
        const LyricLine(text: 'Chorus', start: Duration(seconds: 10)),
      ]);
    });

    test('orders lines by time even when listed out of order', () {
      final Lyrics lyrics = LyricsTextParser.parseLrc(
        '[00:20.00]late\n'
        '[00:05.00]early\n'
        '[00:10.00]middle\n',
      )!;

      expect(
        lyrics.lines.map((LyricLine l) => l.text).toList(),
        <String>['early', 'middle', 'late'],
      );
    });

    test('ignores ID/metadata tags rather than rendering them', () {
      final Lyrics lyrics = LyricsTextParser.parseLrc(
        '[ar:Some Artist]\n'
        '[ti:Some Title]\n'
        '[offset:+250]\n'
        '[00:01.00]Only real line\n',
      )!;

      expect(lyrics.lines, <LyricLine>[
        const LyricLine(text: 'Only real line', start: Duration(seconds: 1)),
      ]);
    });

    test('falls back to plain lines for a timestamp-free .lrc', () {
      final Lyrics lyrics = LyricsTextParser.parseLrc(
        'Just some lyrics\n'
        'with no timing\n',
      )!;

      expect(lyrics.isSynced, isFalse);
      expect(
        lyrics.lines.map((LyricLine l) => l.text).toList(),
        <String>['Just some lyrics', 'with no timing'],
      );
    });

    test('returns null for blank or metadata-only text', () {
      expect(LyricsTextParser.parseLrc(''), isNull);
      expect(LyricsTextParser.parseLrc('   \n\n  '), isNull);
      expect(LyricsTextParser.parseLrc('[ar:Artist]\n[ti:Title]\n'), isNull);
    });

    test('normalizes CRLF line endings', () {
      final Lyrics lyrics = LyricsTextParser.parseLrc(
        '[00:01.00]one\r\n[00:02.00]two\r\n',
      )!;

      expect(lyrics.lines.length, 2);
      expect(lyrics.lines.last.text, 'two');
    });
  });

  group('LyricsTextParser.parsePlain', () {
    test('reads every line as an untimed lyric line', () {
      final Lyrics? lyrics = LyricsTextParser.parsePlain(
        'line one\n'
        'line two\n'
        'line three\n',
      );

      expect(lyrics, isNotNull);
      expect(lyrics!.isSynced, isFalse);
      expect(lyrics.lines, <LyricLine>[
        const LyricLine(text: 'line one'),
        const LyricLine(text: 'line two'),
        const LyricLine(text: 'line three'),
      ]);
    });

    test('keeps interior blank lines but trims leading/trailing blanks', () {
      final Lyrics lyrics = LyricsTextParser.parsePlain(
        '\n\n'
        'verse one\n'
        '\n'
        'verse two\n'
        '\n\n',
      )!;

      expect(
        lyrics.lines.map((LyricLine l) => l.text).toList(),
        <String>['verse one', '', 'verse two'],
      );
    });

    test('does not parse timestamps — text is literal', () {
      final Lyrics lyrics = LyricsTextParser.parsePlain('[00:01.00]Hello')!;

      expect(lyrics.isSynced, isFalse);
      expect(lyrics.lines.single.text, '[00:01.00]Hello');
    });

    test('returns null for blank text', () {
      expect(LyricsTextParser.parsePlain(''), isNull);
      expect(LyricsTextParser.parsePlain('   \n  \n'), isNull);
    });
  });
}
