//! Turning a scanned file into a track's names and numbers: the rules of
//! `LocalTrackMapper` (lib/core/sources/local/local_track_mapper.dart), where
//! the reasoning lives. Tags win; without them the title comes from the file
//! name (a leading "01 - " read as the track number) and the artist and album
//! from the folders below the selected one.

use crate::library_grouping::{dart_trim, is_dart_whitespace};
use crate::scan::files::{is_within, normalize};

/// What a tag read found, as `LocalAudioMetadata` holds it. All `None` when
/// the file wasn't read or held nothing.
#[derive(Debug, Clone, Copy, Default)]
pub struct Metadata<'a> {
    pub title: Option<&'a str>,
    pub artist: Option<&'a str>,
    pub album: Option<&'a str>,
    pub album_artist: Option<&'a str>,
    pub album_id: Option<&'a str>,
    pub track_number: Option<i64>,
    pub duration_us: Option<i64>,
}

/// One track of a CUE sheet, as `CueSheetTrack` holds it.
#[derive(Debug, Clone, Copy)]
pub struct CueTrack<'a> {
    pub number: i64,
    pub audio_path: &'a str,
    pub start_us: i64,
    pub end_us: Option<i64>,
    pub title: Option<&'a str>,
    pub performer: Option<&'a str>,
    pub album: Option<&'a str>,
    pub album_performer: Option<&'a str>,
}

/// The names and numbers of a track; its id, uri and cover stay with the
/// caller.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Mapped {
    pub title: String,
    pub artist: Option<String>,
    pub album: Option<String>,
    pub album_id: Option<String>,
    pub album_artist: Option<String>,
    pub track_number: Option<i64>,
    pub duration_us: i64,
    /// Where a CUE track ends, when it is known to end after it starts.
    pub cue_end_us: Option<i64>,
}

/// `LocalTrackMapper.fromPath`.
pub fn from_path(path: &str, scan_root: Option<&str>, meta: &Metadata) -> Mapped {
    let (artist, album) = folder_names(path, scan_root);
    build(&basename_without_extension(path), meta, artist, album)
}

/// `LocalTrackMapper.fromSafDocument`: a document's display name, and no
/// folders.
pub fn from_document(name: &str, meta: &Metadata) -> Mapped {
    build(&basename_without_extension(name), meta, None, None)
}

/// `LocalTrackMapper.fromCueTrack`.
pub fn from_cue(cue: &CueTrack, meta: &Metadata, scan_root: &str) -> Mapped {
    let possible_end = cue.end_us.or(meta.duration_us);
    let end = possible_end.filter(|end| *end > cue.start_us);
    let (folder_artist, folder_album) = folder_names(cue.audio_path, Some(scan_root));
    let fallback_title = format!("Track {:0>2}", cue.number.to_string());
    Mapped {
        title: first_non_blank(&[cue.title, Some(&fallback_title)])
            .unwrap_or_else(|| format!("Track {}", cue.number)),
        artist: first_non_blank(&[
            cue.performer,
            cue.album_performer,
            meta.album_artist,
            meta.artist,
            folder_artist.as_deref(),
        ]),
        album: first_non_blank(&[cue.album, meta.album, folder_album.as_deref()]),
        album_id: blank_to_null(meta.album_id),
        album_artist: first_non_blank(&[cue.album_performer, meta.album_artist]),
        track_number: Some(cue.number),
        duration_us: end.map_or(0, |end| end - cue.start_us),
        cue_end_us: end,
    }
}

/// `_build`.
fn build(
    name_without_extension: &str,
    meta: &Metadata,
    folder_artist: Option<String>,
    folder_album: Option<String>,
) -> Mapped {
    let (number, title) = name_parts(name_without_extension);
    Mapped {
        title: first_non_blank(&[meta.title, Some(&title)]).unwrap_or(title.clone()),
        artist: first_non_blank(&[meta.album_artist, meta.artist, folder_artist.as_deref()]),
        album: first_non_blank(&[meta.album, folder_album.as_deref()]),
        album_id: blank_to_null(meta.album_id),
        album_artist: blank_to_null(meta.album_artist),
        track_number: meta.track_number.or(number),
        duration_us: meta.duration_us.unwrap_or(0),
        cue_end_us: None,
    }
}

/// `_parseName`: a leading track number and the title after it, matched as
/// the Dart expression `^(\d{1,3})[\s._\-)\]]+(.+)$` does (JavaScript
/// `\s`, and a `.` that stops at line terminators); otherwise the trimmed
/// name, or the name as it was when nothing is left of it.
pub fn name_parts(name: &str) -> (Option<i64>, String) {
    let trimmed = dart_trim(name);
    if let Some((digits, rest)) = leading_track_number(trimmed) {
        let rest = dart_trim(rest);
        if !rest.is_empty() {
            return (digits.parse().ok(), rest.to_owned());
        }
    }
    let title = if trimmed.is_empty() { name } else { trimmed };
    (None, title.to_owned())
}

/// The two groups of the track number expression, or `None` when it doesn't
/// match.
fn leading_track_number(text: &str) -> Option<(&str, &str)> {
    let digits = text.len() - text.trim_start_matches(|c: char| c.is_ascii_digit()).len();
    // `\d{1,3}` followed by a separator: a longer run of digits never is.
    if digits == 0 || digits > 3 {
        return None;
    }
    let after = &text[digits..];
    let separators = after.len() - after.trim_start_matches(is_separator).len();
    if separators == 0 {
        return None;
    }
    let rest = &after[separators..];
    if !rest.is_empty() {
        // `(.+)$`: the rest must hold no line terminator.
        return (!rest.chars().any(is_line_terminator)).then_some((&text[..digits], rest));
    }
    // Nothing but separators: the expression backs off one, which `.+`
    // takes, unless it is a line terminator or the only one.
    let last = after.chars().next_back()?;
    let last_start = after.len() - last.len_utf8();
    (last_start > 0 && !is_line_terminator(last)).then_some((&text[..digits], &after[last_start..]))
}

/// `[\s._\-)\]]`.
fn is_separator(c: char) -> bool {
    is_js_whitespace(c) || matches!(c, '.' | '_' | '-' | ')' | ']')
}

/// JavaScript's `\s`: Dart's trim whitespace without U+0085.
fn is_js_whitespace(c: char) -> bool {
    c != '\u{85}' && is_dart_whitespace(c)
}

fn is_line_terminator(c: char) -> bool {
    matches!(c, '\n' | '\r' | '\u{2028}' | '\u{2029}')
}

/// `_folderNamesFor`: the folder holding the file is the album, the one
/// above it the artist, both below `scan_root`.
fn folder_names(path: &str, scan_root: Option<&str>) -> (Option<String>, Option<String>) {
    let Some(root) = scan_root.filter(|root| !root.is_empty()) else {
        return (None, None);
    };
    let root = normalize(root);
    let full = normalize(path);
    if !is_within(&root, &full) {
        return (None, None);
    }
    let relative = relative_within(&root, &full);
    let mut folders: Vec<&str> = relative.split('/').collect();
    folders.pop();
    let album = folders.last().and_then(|f| blank_to_null(Some(f)));
    let artist = (folders.len() >= 2)
        .then(|| blank_to_null(Some(folders[folders.len() - 2])))
        .flatten();
    (artist, album)
}

/// `p.relative(full, from: root)` for a `full` strictly inside `root`, both
/// normalized, taken from the current directory when relative as
/// [is_within] takes them.
fn relative_within(root: &str, full: &str) -> String {
    let root = absolute(root);
    let full = absolute(full);
    let skip = if root == "/" { 1 } else { root.len() + 1 };
    full[skip..].to_owned()
}

fn absolute(path: &str) -> String {
    if path.starts_with('/') {
        return path.to_owned();
    }
    let cwd = std::env::current_dir()
        .map(|d| d.to_string_lossy().into_owned())
        .unwrap_or_else(|_| "/".to_owned());
    normalize(&format!("{cwd}/{path}"))
}

/// `p.basenameWithoutExtension` on POSIX: the last non-empty part, without
/// what follows its last dot unless that dot starts it.
pub fn basename_without_extension(path: &str) -> String {
    let Some(file) = path.split('/').rfind(|part| !part.is_empty()) else {
        return String::new();
    };
    if file == ".." {
        return file.to_owned();
    }
    match file.rfind('.') {
        Some(dot) if dot > 0 => file[..dot].to_owned(),
        _ => file.to_owned(),
    }
}

fn first_non_blank(values: &[Option<&str>]) -> Option<String> {
    values.iter().find_map(|value| blank_to_null(*value))
}

fn blank_to_null(value: Option<&str>) -> Option<String> {
    let trimmed = dart_trim(value?);
    (!trimmed.is_empty()).then(|| trimmed.to_owned())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn splits_a_leading_track_number() {
        for (name, number, title) in [
            ("01 - Intro (Live)", Some(1), "Intro (Live)"),
            ("03. Song", Some(3), "Song"),
            ("4 Song", Some(4), "Song"),
            ("05_Song", Some(5), "Song"),
            ("1984", None, "1984"),
            ("1234 Song", None, "1234 Song"),
            ("12) Song", Some(12), "Song"),
            ("01 -", Some(1), "-"),
            ("01 - ", Some(1), "-"),
            ("01 ", None, "01"),
            ("01 a\nb", None, "01 a\nb"),
            ("01\nab", Some(1), "ab"),
            ("01 \u{85}x", Some(1), "x"),
            ("   ", None, "   "),
            ("", None, ""),
            ("a.b.c", None, "a.b.c"),
        ] {
            assert_eq!(name_parts(name), (number, title.to_owned()), "{name:?}");
        }
    }

    #[test]
    fn strips_the_last_extension_only() {
        for (path, expected) in [
            ("/music/a.b.c.opus", "a.b.c"),
            ("/music/.hidden", ".hidden"),
            ("/music/dir/", "dir"),
            ("/", ""),
            ("", ""),
            ("..", ".."),
            ("/a/..", ".."),
            ("name.", "name"),
        ] {
            assert_eq!(basename_without_extension(path), expected, "{path:?}");
        }
    }

    #[test]
    fn takes_artist_and_album_from_the_folders_below_the_root() {
        let none = Metadata::default();
        let flume = from_path(
            "/music/Bon Iver/For Emma/01 - Flume.mp3",
            Some("/music"),
            &none,
        );
        assert_eq!(flume.artist.as_deref(), Some("Bon Iver"));
        assert_eq!(flume.album.as_deref(), Some("For Emma"));
        assert_eq!(flume.title, "Flume");
        assert_eq!(flume.track_number, Some(1));
        let single = from_path("/music/Album/a.flac", Some("/music/"), &none);
        assert_eq!(
            (single.artist, single.album.as_deref()),
            (None, Some("Album"))
        );
        let outside = from_path("/other/A/B/a.flac", Some("/music"), &none);
        assert_eq!((outside.artist, outside.album), (None, None));
    }

    #[test]
    fn tags_win_over_names() {
        let meta = Metadata {
            title: Some("  Real  "),
            artist: Some("Artist"),
            album_artist: Some(" "),
            album: Some("Album"),
            track_number: Some(7),
            duration_us: Some(1_500_000),
            ..Metadata::default()
        };
        let mapped = from_path("/m/X/Y/01 - Name.flac", Some("/m"), &meta);
        assert_eq!(mapped.title, "Real");
        assert_eq!(mapped.artist.as_deref(), Some("Artist"));
        assert_eq!(mapped.album_artist, None);
        assert_eq!(mapped.track_number, Some(7));
        assert_eq!(mapped.duration_us, 1_500_000);
    }

    #[test]
    fn ends_a_cue_track_only_after_it_starts() {
        let cue = CueTrack {
            number: 3,
            audio_path: "/m/A/B/disc.flac",
            start_us: 60_000_000,
            end_us: None,
            title: None,
            performer: None,
            album: None,
            album_performer: Some("Band"),
        };
        let meta = Metadata {
            duration_us: Some(90_000_000),
            ..Metadata::default()
        };
        let mapped = from_cue(&cue, &meta, "/m");
        assert_eq!(mapped.title, "Track 03");
        assert_eq!(mapped.artist.as_deref(), Some("Band"));
        assert_eq!(mapped.album.as_deref(), Some("B"));
        assert_eq!(mapped.cue_end_us, Some(90_000_000));
        assert_eq!(mapped.duration_us, 30_000_000);
        let late = CueTrack {
            end_us: Some(60_000_000),
            ..cue
        };
        let mapped = from_cue(&late, &meta, "");
        assert_eq!((mapped.cue_end_us, mapped.duration_us), (None, 0));
        assert_eq!(mapped.album, None);
    }
}
