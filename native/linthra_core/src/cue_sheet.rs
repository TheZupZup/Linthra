//! CUE sheets: the rules of `CueSheet.decode` and `CueSheet.parse`
//! (lib/core/sources/local/cue_sheet.dart), up to the point where a track's
//! FILE name is joined to the sheet's folder. That join, and the end of each
//! track, stay in Dart, which owns the path rules.
//!
//! The Dart parser is a handful of regular expressions, and this module has
//! to match them exactly, down to their corners: `\s` is JavaScript's set
//! (not `trim`'s, which adds U+0085), the keywords ignore ASCII case only,
//! `.` stops at line terminators, and a TITLE whose quotes don't close the
//! line can still match by giving back a space it had already taken.
//! `test/fixtures/cue_sheet_cases.json` holds what the Dart reader gave for
//! tricky and random sheets before it was removed, and
//! `cue_sheet_cases_test.dart` replays it.

use crate::library_grouping::{dart_trim, is_dart_whitespace};

/// One audio track the sheet describes, before its FILE is joined to the
/// sheet's folder.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CueTrack {
    pub number: i64,
    /// The FILE name as written, with `\` turned into `/`.
    pub file: String,
    pub start_ms: i64,
    pub title: Option<String>,
    pub performer: Option<String>,
    pub album: Option<String>,
    pub album_performer: Option<String>,
}

/// `CueSheet.decode`: strict UTF-8, or Windows-1251, which older Cyrillic
/// ripping tools write without saying so. Like Dart's `utf8.decode`, the
/// UTF-8 path drops one leading byte order mark.
pub fn decode(bytes: &[u8]) -> String {
    match std::str::from_utf8(bytes) {
        Ok(text) => text.strip_prefix('\u{FEFF}').unwrap_or(text).to_owned(),
        Err(_) => bytes
            .iter()
            .map(|&b| match b {
                0x00..=0x7F => b as char,
                0xC0..=0xFF => char::from_u32(0x0410 + (b - 0xC0) as u32).unwrap_or('\u{FFFD}'),
                _ => char::from_u32(WINDOWS_1251[(b - 0x80) as usize] as u32).unwrap_or('\u{FFFD}'),
            })
            .collect(),
    }
}

/// Bytes 0x80..=0xBF of Windows-1251, as in the Dart table.
const WINDOWS_1251: [u16; 64] = [
    0x0402, 0x0403, 0x201a, 0x0453, 0x201e, 0x2026, 0x2020, 0x2021, 0x20ac, 0x2030, 0x0409, 0x2039,
    0x040a, 0x040c, 0x040b, 0x040f, 0x0452, 0x2018, 0x2019, 0x201c, 0x201d, 0x2022, 0x2013, 0x2014,
    0x0098, 0x2122, 0x0459, 0x203a, 0x045a, 0x045c, 0x045b, 0x045f, 0x00a0, 0x040e, 0x045e, 0x0408,
    0x00a4, 0x0490, 0x00a6, 0x00a7, 0x0401, 0x00a9, 0x0404, 0x00ab, 0x00ac, 0x00ad, 0x00ae, 0x0407,
    0x00b0, 0x00b1, 0x0406, 0x0456, 0x0491, 0x00b5, 0x00b6, 0x00b7, 0x0451, 0x2116, 0x0454, 0x00bb,
    0x0458, 0x0405, 0x0455, 0x0457,
];

/// The line loop of `CueSheet.parse`.
pub fn parse(contents: &str) -> Vec<CueTrack> {
    let source = contents.strip_prefix('\u{FEFF}').unwrap_or(contents);
    let mut state = State::default();
    for raw in source.split('\n') {
        // `split(RegExp(r'\r?\n'))`: a CR right before the LF goes with it.
        let raw = raw.strip_suffix('\r').unwrap_or(raw);
        state.line(dart_trim(raw));
    }
    state.finish_track();
    state.tracks
}

#[derive(Default)]
struct State {
    file: Option<String>,
    album: Option<String>,
    album_performer: Option<String>,
    title: Option<String>,
    performer: Option<String>,
    number: Option<i64>,
    is_audio: bool,
    start_ms: Option<i64>,
    tracks: Vec<CueTrack>,
}

impl State {
    fn line(&mut self, line: &str) {
        if line.is_empty() || line.starts_with("REM ") || line.starts_with("REM\t") {
            return;
        }
        if let Some(name) = file_name(line) {
            self.finish_track();
            self.file = Some(name.replace('\\', "/"));
            return;
        }
        if let Some((digits, kind)) = track(line) {
            self.finish_track();
            self.number = digits.parse::<i64>().ok();
            self.is_audio = kind.to_uppercase() == "AUDIO";
            return;
        }
        if let Some((minutes, seconds, frames)) = index(line) {
            if self.is_audio && self.number.is_some() {
                if seconds < 60 && frames < 75 {
                    self.start_ms = Some(((minutes * 60 + seconds) * 75 + frames) * 1000 / 75);
                }
                return;
            }
        }
        if let Some(title) = value("TITLE", line) {
            if self.number.is_none() {
                self.album = Some(title);
            } else {
                self.title = Some(title);
            }
            return;
        }
        if let Some(performer) = value("PERFORMER", line) {
            if self.number.is_none() {
                self.album_performer = Some(performer);
            } else {
                self.performer = Some(performer);
            }
        }
    }

    fn finish_track(&mut self) {
        if let (true, Some(number), Some(start_ms), Some(file)) =
            (self.is_audio, self.number, self.start_ms, &self.file)
        {
            self.tracks.push(CueTrack {
                number,
                file: file.clone(),
                start_ms,
                title: self.title.clone(),
                performer: self.performer.clone(),
                album: self.album.clone(),
                album_performer: self.album_performer.clone(),
            });
        }
        self.number = None;
        self.start_ms = None;
        self.title = None;
        self.performer = None;
        self.is_audio = false;
    }
}

/// `\s` in a Dart `RegExp` (JavaScript's set).
fn is_space(ch: char) -> bool {
    matches!(
        ch,
        '\t' | '\n' | '\u{0B}' | '\u{0C}' | '\r' | ' ' | '\u{A0}' | '\u{1680}' | '\u{2000}'
            ..='\u{200A}'
                | '\u{2028}'
                | '\u{2029}'
                | '\u{202F}'
                | '\u{205F}'
                | '\u{3000}'
                | '\u{FEFF}'
    )
}

/// Characters `.` does not match.
fn is_line_terminator(ch: char) -> bool {
    matches!(ch, '\n' | '\r' | '\u{2028}' | '\u{2029}')
}

/// The text after `keyword` at the start of `line`, compared without ASCII
/// case, as a case-insensitive Dart `RegExp` compares letters with no
/// non-ASCII case partner.
fn after_keyword<'a>(line: &'a str, keyword: &str) -> Option<&'a str> {
    let head = line.get(..keyword.len())?;
    head.eq_ignore_ascii_case(keyword)
        .then(|| &line[keyword.len()..])
}

/// The length in bytes of the run of characters at the start of `text` that
/// `keep` accepts.
fn run(text: &str, keep: impl Fn(char) -> bool) -> usize {
    text.char_indices()
        .find(|&(_, ch)| !keep(ch))
        .map_or(text.len(), |(i, _)| i)
}

/// `^FILE\s+(?:"([^"]+)"|(\S+))\s+\S+`: the name.
fn file_name(line: &str) -> Option<&str> {
    let rest = after_keyword(line, "FILE")?;
    let spaces = run(rest, is_space);
    if spaces == 0 {
        return None;
    }
    let rest = &rest[spaces..];
    // `\s+\S+` after the name: some space, then anything that isn't.
    let typed = |after: &str| {
        let spaces = run(after, is_space);
        spaces > 0 && spaces < after.len()
    };
    if let Some(quoted) = rest.strip_prefix('"') {
        if let Some(end) = quoted.find('"') {
            if end > 0 && typed(&quoted[end + 1..]) {
                return Some(&quoted[..end]);
            }
        }
    }
    let name = run(rest, |ch| !is_space(ch));
    (name > 0 && typed(&rest[name..])).then(|| &rest[..name])
}

/// `^TRACK\s+(\d+)\s+(\S+)`: the number's digits and the track's kind.
fn track(line: &str) -> Option<(&str, &str)> {
    let rest = after_keyword(line, "TRACK")?;
    let spaces = run(rest, is_space);
    let rest = &rest[spaces..];
    let digits = run(rest, |ch| ch.is_ascii_digit());
    let after = &rest[digits..];
    let gap = run(after, is_space);
    let kind = &after[gap..];
    let kind_len = run(kind, |ch| !is_space(ch));
    (spaces > 0 && digits > 0 && gap > 0 && kind_len > 0)
        .then(|| (&rest[..digits], &kind[..kind_len]))
}

/// `^INDEX\s+01\s+(\d{1,3}):(\d{2}):(\d{2})\s*$`: minutes, seconds and
/// frames.
fn index(line: &str) -> Option<(i64, i64, i64)> {
    let rest = after_keyword(line, "INDEX")?;
    let spaces = run(rest, is_space);
    let rest = rest[spaces..].strip_prefix("01")?;
    let gap = run(rest, is_space);
    if spaces == 0 || gap == 0 {
        return None;
    }
    let rest = &rest[gap..];
    let minutes = run(rest, |ch| ch.is_ascii_digit());
    if !(1..=3).contains(&minutes) {
        return None;
    }
    let (m, rest) = rest.split_at(minutes);
    let rest = rest.strip_prefix(':')?;
    let (s, rest) = two_digits(rest)?;
    let rest = rest.strip_prefix(':')?;
    let (f, rest) = two_digits(rest)?;
    if !rest.chars().all(is_space) {
        return None;
    }
    Some((m.parse().ok()?, s, f))
}

/// `\d{2}` and what follows it.
fn two_digits(text: &str) -> Option<(i64, &str)> {
    let digits = text.get(..2)?;
    if !digits.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    Some((digits.parse().ok()?, &text[2..]))
}

/// `_value`: `^KEYWORD\s+(?:"([^"]*)"|([^"].*))\s*$`, giving group 1 as is
/// and group 2 with Dart's `trimRight`.
///
/// `\s+` is greedy but may give characters back, and that changes the
/// answer: in `TITLE  "a" b` the quoted form fails, and so does the bare one
/// at the quote, so the regex retries one space shorter and the bare form
/// then matches ` "a" b`. So the alternatives are tried at every split of the
/// spaces, longest first.
fn value(keyword: &str, line: &str) -> Option<String> {
    let rest = after_keyword(line, keyword)?;
    let spaces: Vec<usize> = rest
        .char_indices()
        .take_while(|&(_, ch)| is_space(ch))
        .map(|(i, ch)| i + ch.len_utf8())
        .collect();
    spaces.iter().rev().find_map(|&at| {
        let text = &rest[at..];
        if let Some(quoted) = text.strip_prefix('"') {
            if let Some(end) = quoted.find('"') {
                if quoted[end + 1..].chars().all(is_space) {
                    return Some(quoted[..end].to_owned());
                }
            }
            return None;
        }
        // `[^"]` takes one character (a line terminator too), then `.*`
        // runs to the first line terminator, and only space may follow.
        let first = text.chars().next()?;
        let tail = &text[first.len_utf8()..];
        let line_end = run(tail, |ch| !is_line_terminator(ch));
        tail[line_end..].chars().all(is_space).then(|| {
            // Dart's `trimRight`.
            text[..first.len_utf8() + line_end]
                .trim_end_matches(is_dart_whitespace)
                .to_owned()
        })
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_a_two_track_sheet() {
        let tracks = parse(
            "PERFORMER Album Artist\nTITLE Album Title\nFILE \"CD1\\album.flac\" WAVE\n  TRACK 01 AUDIO\n    TITLE First Song\n    PERFORMER Guest\n    INDEX 01 00:00:00\n  TRACK 02 AUDIO\n    TITLE \"Second Song\"\n    INDEX 01 02:00:00\n",
        );
        assert_eq!(tracks.len(), 2);
        assert_eq!(tracks[0].file, "CD1/album.flac");
        assert_eq!(tracks[0].album.as_deref(), Some("Album Title"));
        assert_eq!(tracks[0].album_performer.as_deref(), Some("Album Artist"));
        assert_eq!(tracks[0].performer.as_deref(), Some("Guest"));
        assert_eq!(tracks[1].title.as_deref(), Some("Second Song"));
        assert_eq!(tracks[1].start_ms, 120_000);
    }

    #[test]
    fn matches_the_regexp_corners() {
        assert_eq!(
            value("TITLE", "TITLE  \"a\" b").as_deref(),
            Some(" \"a\" b")
        );
        assert_eq!(value("TITLE", "TITLE \"a\" b"), None);
        assert_eq!(value("TITLE", "title \"\"").as_deref(), Some(""));
        assert_eq!(value("TITLE", "TITLE a\u{2028}b"), None);
        assert_eq!(value("TITLE", "TITLE a\u{2028} ").as_deref(), Some("a"));
        assert_eq!(file_name("FILE \"a b\""), Some("\"a"));
        assert_eq!(file_name("FILE \"\" WAVE"), Some("\"\""));
        assert_eq!(file_name("FILEx a b"), None);
        assert_eq!(track("TRACK 1x AUDIO"), None);
        assert_eq!(index("INDEX 01 1234:00:00"), None);
        assert_eq!(index("INDEX 01 123:59:74"), Some((123, 59, 74)));
        assert_eq!(index("INDEX 011 00:00:00"), None);
    }

    #[test]
    fn decodes_windows_1251() {
        assert_eq!(decode(&[0xC0, 0xE0, 0xA8, b'x']), "Аа\u{401}x");
        assert_eq!(decode("Ёж".as_bytes()), "Ёж");
        assert_eq!(decode("\u{FEFF}\u{FEFF}a".as_bytes()), "\u{FEFF}a");
    }
}
