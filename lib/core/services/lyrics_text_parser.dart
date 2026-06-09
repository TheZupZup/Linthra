import '../models/lyrics.dart';

/// Turns raw sidecar text into the source-agnostic [Lyrics] model the player
/// renders — the local counterpart to the structured lyrics the Jellyfin and
/// Subsonic clients build from their servers' JSON.
///
/// Two shapes, matching the two sidecar kinds a local track can carry:
///  - [parseLrc] reads an `.lrc` file: `[mm:ss.xx]` timestamp tags become timed
///    [LyricLine]s (the synced view, with the same model the remote sources
///    feed), and a timestamp-free `.lrc` degrades to plain lines. Non-timing ID
///    tags (`[ar:…]`, `[ti:…]`, `[offset:…]`, …) are ignored rather than shown.
///  - [parsePlain] reads a `.txt` file: every line is a plain, untimed
///    [LyricLine] — no timestamp parsing — so it renders in the static view.
///
/// Both return `null` when the text carries no usable line, so the caller can
/// fall through to the next sidecar (or the calm "no lyrics" state) instead of
/// showing an empty box. Pure and total: malformed input never throws — an
/// unparseable timestamp just leaves that line untimed.
abstract final class LyricsTextParser {
  /// A leading `[mm:ss]`, `[mm:ss.xx]`, or `[mm:ss.xxx]` timestamp tag. Minutes
  /// are unbounded (a long track can exceed 99), seconds are 1–2 digits, and the
  /// optional fraction is 1–3 digits (tenths / centiseconds / milliseconds).
  static final RegExp _timeTag =
      RegExp(r'\[(\d+):(\d{1,2})(?:[.:](\d{1,3}))?\]');

  /// An LRC ID/metadata tag like `[ar:Artist]` or `[offset:+250]`: a leading
  /// alpha key, a colon, then a value. Distinguished from a timestamp (whose key
  /// is digits) so it can be dropped rather than rendered as a lyric line.
  static final RegExp _idTag = RegExp(r'^\[[a-zA-Z][a-zA-Z0-9_]*:.*\]$');

  /// Parses `.lrc` text. Timed lines win: when any `[mm:ss]` tag is present the
  /// result is synced (lines ordered by time, untimed leftovers dropped);
  /// otherwise the non-tag lines become plain lyrics. `null` when nothing usable
  /// remains.
  static Lyrics? parseLrc(String text) {
    final List<LyricLine> timed = <LyricLine>[];
    final List<LyricLine> plain = <LyricLine>[];
    for (final String raw in _splitLines(text)) {
      final _LrcLine parsed = _parseLrcLine(raw);
      if (parsed.timestamps.isNotEmpty) {
        // `[t1][t2]Text` repeats the same line at each timestamp.
        for (final Duration start in parsed.timestamps) {
          timed.add(LyricLine(text: parsed.text, start: start));
        }
      } else if (!parsed.isMetadata) {
        plain.add(LyricLine(text: parsed.text));
      }
    }
    if (timed.isNotEmpty) {
      // Order by time so the model's active-line search (which assumes ascending
      // order) holds even when stamps are listed out of order or repeated.
      timed.sort((LyricLine a, LyricLine b) => a.start!.compareTo(b.start!));
      return Lyrics(lines: timed);
    }
    return _plainOrNull(plain);
  }

  /// Parses `.txt` text as plain, untimed lyrics: every line becomes a
  /// [LyricLine] (interior blank lines kept for stanza rhythm), with no
  /// timestamp parsing. `null` when the text is blank.
  static Lyrics? parsePlain(String text) {
    final List<LyricLine> lines = _splitLines(text)
        .map((String line) => LyricLine(text: line.trimRight()))
        .toList();
    return _plainOrNull(lines);
  }

  /// Splits [text] into lines, normalizing CRLF/CR so a Windows-authored sidecar
  /// parses identically.
  static List<String> _splitLines(String text) =>
      text.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n');

  /// Parses one `.lrc` line into its leading timestamps and remaining text, or
  /// flags it as an ID/metadata tag to be ignored.
  static _LrcLine _parseLrcLine(String raw) {
    final String line = raw.trim();
    final List<Duration> stamps = <Duration>[];
    int index = 0;
    while (true) {
      final Match? match = _timeTag.matchAsPrefix(line, index);
      if (match == null) break;
      stamps.add(_durationOf(match));
      index = match.end;
    }
    if (stamps.isNotEmpty) {
      return _LrcLine(timestamps: stamps, text: line.substring(index).trim());
    }
    return _LrcLine(
      timestamps: const <Duration>[],
      text: line,
      isMetadata: _idTag.hasMatch(line),
    );
  }

  /// The [Duration] for a `[mm:ss(.fff)]` match. The fraction's digit count sets
  /// its scale: 1 digit → tenths, 2 → centiseconds, 3 → milliseconds.
  static Duration _durationOf(Match match) {
    final int minutes = int.parse(match.group(1)!);
    final int seconds = int.parse(match.group(2)!);
    final String? fraction = match.group(3);
    int milliseconds = 0;
    if (fraction != null) {
      final int value = int.parse(fraction);
      milliseconds = switch (fraction.length) {
        1 => value * 100,
        2 => value * 10,
        _ => value,
      };
    }
    return Duration(
      minutes: minutes,
      seconds: seconds,
      milliseconds: milliseconds,
    );
  }

  /// [lines] with fully-blank leading/trailing lines trimmed (interior blanks
  /// kept), or `null` when nothing but blanks remain.
  static Lyrics? _plainOrNull(List<LyricLine> lines) {
    int start = 0;
    int end = lines.length;
    while (start < end && lines[start].text.trim().isEmpty) {
      start++;
    }
    while (end > start && lines[end - 1].text.trim().isEmpty) {
      end--;
    }
    if (start >= end) return null;
    return Lyrics(lines: lines.sublist(start, end));
  }
}

/// One parsed `.lrc` line: its (zero or more) leading [timestamps], the [text]
/// after them, and whether the whole line was an ID/metadata tag to ignore.
class _LrcLine {
  const _LrcLine({
    required this.timestamps,
    required this.text,
    this.isMetadata = false,
  });

  final List<Duration> timestamps;
  final String text;
  final bool isMetadata;
}
