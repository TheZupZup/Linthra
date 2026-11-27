//! What a Subsonic server answered: the `subsonic-response` envelope and the
//! lists Linthra reads out of it, for `HttpSubsonicClient` and
//! `SubsonicFolderBrowserSource` (lib/core/sources/subsonic/).
//!
//! A value of an unexpected type is left out rather than failing the answer:
//! one odd record must not fail a whole sync, which the next launch would
//! walk into again. Each read below says which of the readers it uses, since
//! they differ on purpose (a song's numbers may come as strings, a lyric
//! line's may not; folder names are trimmed, song titles are not).

use super::json::{self, Value};

/// The envelope's verdict.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Outcome {
    /// Not JSON, not an object, no `subsonic-response` object, or a status
    /// that isn't a string.
    NotSubsonic,
    /// `status` other than `ok`: a Subsonic error inside a 200.
    Failed,
    Ok,
}

/// The envelope, with the server's identity and its error code.
#[derive(Debug, Clone, PartialEq)]
pub struct Envelope<'a> {
    pub outcome: Outcome,
    pub error_code: Option<i64>,
    pub version: Option<String>,
    pub server_type: Option<String>,
    pub server_version: Option<String>,
    /// The `subsonic-response` object, when there is one.
    pub root: Option<&'a Value>,
}

/// Reads the envelope of a parsed body.
pub fn envelope(body: Option<&Value>) -> Envelope<'_> {
    let not_subsonic = Envelope {
        outcome: Outcome::NotSubsonic,
        error_code: None,
        version: None,
        server_type: None,
        server_version: None,
        root: None,
    };
    let Some(root) = body
        .and_then(|b| b.get("subsonic-response"))
        .filter(|r| r.is_object())
    else {
        return not_subsonic;
    };
    let Some(status) = root.get("status").and_then(Value::as_str) else {
        return not_subsonic;
    };
    let error = root.get("error").filter(|e| e.is_object());
    Envelope {
        outcome: if status == "ok" {
            Outcome::Ok
        } else {
            Outcome::Failed
        },
        error_code: error.and_then(|e| e.get("code")).and_then(loose_int),
        version: string(root.get("version")),
        server_type: string(root.get("type")),
        server_version: string(root.get("serverVersion")),
        root: Some(root),
    }
}

/// Parses `bytes` and reads its envelope; the parsed body is kept in `slot`.
pub fn read<'a>(bytes: &[u8], slot: &'a mut Option<Value>) -> Envelope<'a> {
    *slot = json::parse_bytes(bytes).filter(Value::is_object);
    envelope(slot.as_ref())
}

#[derive(Debug, Clone, PartialEq)]
pub struct Artist {
    pub id: String,
    pub name: String,
    pub album_count: i64,
    pub cover_art: Option<String>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Album {
    pub id: String,
    pub name: String,
    pub artist: Option<String>,
    pub song_count: i64,
    pub year: Option<i64>,
    /// `created` as the server wrote it; Dart reads the date.
    pub created: Option<String>,
    pub cover_art: Option<String>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Song {
    pub id: String,
    pub title: String,
    pub album: Option<String>,
    pub album_id: Option<String>,
    pub artist: Option<String>,
    pub track: Option<i64>,
    pub duration_seconds: Option<i64>,
    /// `created` as the server wrote it; Dart reads the date.
    pub created: Option<String>,
    pub cover_art: Option<String>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Playlist {
    pub id: String,
    pub name: String,
}

/// A folder of the folder browser, its id and name trimmed.
#[derive(Debug, Clone, PartialEq)]
pub struct Folder {
    pub id: String,
    pub name: String,
}

/// One lyric line; `start_ms` is None for an untimed line.
#[derive(Debug, Clone, PartialEq)]
pub struct LyricLine {
    pub text: String,
    pub start_ms: Option<i64>,
}

/// `artists.index[].artist[]` (`getArtists`).
pub fn artists(root: &Value) -> Vec<Artist> {
    let mut out = Vec::new();
    for index in entries(root.get("artists").and_then(|a| a.get("index"))) {
        for entry in entries(index.get("artist")) {
            if let Some(artist) = artist(entry) {
                out.push(artist);
            }
        }
    }
    out
}

/// `albumList2.album[]` (`getAlbumList2`), and how many entries the page
/// had, mappable or not: paging stops on that count.
pub fn album_page(root: &Value) -> (Vec<Album>, usize) {
    let value = root.get("albumList2").and_then(|a| a.get("album"));
    let count = match value {
        Some(Value::Array(items)) => items.len(),
        Some(Value::Object(_)) => 1,
        _ => 0,
    };
    (
        entries(value).into_iter().filter_map(album).collect(),
        count,
    )
}

/// `album.song[]` (`getAlbum`).
pub fn album_songs(root: &Value) -> Vec<Song> {
    entries(root.get("album").and_then(|a| a.get("song")))
        .into_iter()
        .filter_map(song)
        .collect()
}

/// `starred2.song[].id` (`getStarred2`), each once, first seen first.
pub fn starred_song_ids(root: &Value) -> Vec<String> {
    let mut ids: Vec<String> = Vec::new();
    for id in entry_ids(root.get("starred2").and_then(|s| s.get("song"))) {
        if !ids.contains(&id) {
            ids.push(id);
        }
    }
    ids
}

/// `playlists.playlist[]` (`getPlaylists`).
pub fn playlists(root: &Value) -> Vec<Playlist> {
    entries(root.get("playlists").and_then(|p| p.get("playlist")))
        .into_iter()
        .filter_map(|p| {
            let id = non_empty(string(p.get("id")))?;
            let name = non_empty(string(p.get("name"))).unwrap_or_else(|| id.clone());
            Some(Playlist { id, name })
        })
        .collect()
}

/// `playlist.entry[].id` (`getPlaylist`), in server order.
pub fn playlist_song_ids(root: &Value) -> Vec<String> {
    entry_ids(root.get("playlist").and_then(|p| p.get("entry")))
}

/// `playlist.id`, the playlist `createPlaylist` made, when the server says.
pub fn created_playlist_id(root: &Value) -> Option<String> {
    non_empty(string(
        root.get("playlist")
            .filter(|p| p.is_object())
            .and_then(|p| p.get("id")),
    ))
}

/// Whether `openSubsonicExtensions` lists `formPost` version 1.
pub fn takes_form_posts(root: &Value) -> bool {
    let Some(Value::Array(extensions)) = root.get("openSubsonicExtensions") else {
        return false;
    };
    extensions.iter().any(|e| {
        e.get("name").and_then(Value::as_str) == Some("formPost")
            && matches!(e.get("versions"), Some(Value::Array(v))
                if v.iter().any(|n| matches!(n, Value::Int(1)) || matches!(n, Value::Float(f) if *f == 1.0)))
    })
}

/// The first `lyricsList.structuredLyrics[]` set with a usable line
/// (`getLyricsBySongId`). A set flagged `synced: false` has untimed lines;
/// otherwise each line's `start` plus the set's `offset` times it (added as
/// Dart adds, wrapping), never below zero.
pub fn structured_lyrics(root: &Value) -> Option<Vec<LyricLine>> {
    let Some(Value::Array(sets)) = root
        .get("lyricsList")
        .filter(|l| l.is_object())
        .and_then(|l| l.get("structuredLyrics"))
    else {
        return None;
    };
    for set in sets.iter().filter(|s| s.is_object()) {
        let Some(Value::Array(raw)) = set.get("line") else {
            continue;
        };
        if raw.is_empty() {
            continue;
        }
        let unsynced = set.get("synced") == Some(&Value::Bool(false));
        let offset = set.get("offset").and_then(number_int).unwrap_or(0);
        let lines: Vec<LyricLine> = raw
            .iter()
            .filter(|line| line.is_object())
            .filter_map(|line| {
                let text = line.get("value").and_then(Value::as_str)?.to_string();
                let start = if unsynced {
                    None
                } else {
                    line.get("start").and_then(number_int)
                };
                Some(LyricLine {
                    text,
                    start_ms: start.map(|s| s.wrapping_add(offset).max(0)),
                })
            })
            .collect();
        if !lines.is_empty() {
            return Some(lines);
        }
    }
    None
}

/// `lyrics.value` (`getLyrics`), the text Dart then reads as LRC or plain.
pub fn legacy_lyrics(root: &Value) -> Option<String> {
    string(
        root.get("lyrics")
            .filter(|l| l.is_object())
            .and_then(|l| l.get("value")),
    )
}

/// `musicFolders.musicFolder[]` (`getMusicFolders`): a list only, names
/// and ids trimmed.
pub fn music_folders(root: &Value) -> Vec<Folder> {
    list(root.get("musicFolders").and_then(|m| m.get("musicFolder")))
        .iter()
        .filter_map(|f| folder(f.get("id"), f.get("name")))
        .collect()
}

/// `indexes.index[].artist[]` (`getIndexes`): lists only.
pub fn indexes(root: &Value) -> Vec<Folder> {
    let mut out = Vec::new();
    for index in list(root.get("indexes").and_then(|i| i.get("index"))) {
        for artist in list(index.get("artist")) {
            out.extend(folder(artist.get("id"), artist.get("name")));
        }
    }
    out
}

/// `directory.child[]` (`getMusicDirectory`): the subfolders (`isDir`
/// true, named by `title`, else `name`) and the songs.
pub fn directory(root: &Value) -> (Vec<Folder>, Vec<Song>) {
    let mut folders = Vec::new();
    let mut songs = Vec::new();
    for child in list(root.get("directory").and_then(|d| d.get("child"))) {
        if child.get("isDir") == Some(&Value::Bool(true)) {
            let name = trimmed(child.get("title")).or_else(|| trimmed(child.get("name")));
            if let (Some(id), Some(name)) = (trimmed(child.get("id")), name) {
                folders.push(Folder { id, name });
            }
            continue;
        }
        songs.extend(song(child));
    }
    (folders, songs)
}

fn artist(v: &Value) -> Option<Artist> {
    Some(Artist {
        id: non_empty(string(v.get("id")))?,
        name: string(v.get("name"))?,
        album_count: v.get("albumCount").and_then(loose_int).unwrap_or(0),
        cover_art: string(v.get("coverArt")),
    })
}

fn album(v: &Value) -> Option<Album> {
    Some(Album {
        id: non_empty(string(v.get("id")))?,
        name: string(v.get("name"))?,
        artist: string(v.get("artist")),
        song_count: v.get("songCount").and_then(loose_int).unwrap_or(0),
        year: v.get("year").and_then(loose_int),
        created: string(v.get("created")),
        cover_art: string(v.get("coverArt")),
    })
}

fn song(v: &Value) -> Option<Song> {
    if !v.is_object() {
        return None;
    }
    Some(Song {
        id: non_empty(string(v.get("id")))?,
        title: string(v.get("title"))?,
        album: string(v.get("album")),
        album_id: string(v.get("albumId")),
        artist: string(v.get("artist")),
        track: v.get("track").and_then(loose_int),
        duration_seconds: v.get("duration").and_then(loose_int),
        created: string(v.get("created")),
        cover_art: string(v.get("coverArt")),
    })
}

fn folder(id: Option<&Value>, name: Option<&Value>) -> Option<Folder> {
    Some(Folder {
        id: trimmed(id)?,
        name: trimmed(name)?,
    })
}

/// The ids of a list of entries, skipping any without one, in order.
fn entry_ids(value: Option<&Value>) -> Vec<String> {
    entries(value)
        .into_iter()
        .filter_map(|e| non_empty(string(e.get("id"))))
        .collect()
}

/// The objects of a list, or of a single object standing in for a list of
/// one: older servers build their JSON from XML, where that's what a list of
/// one turns into. Anything else holds none.
fn entries(value: Option<&Value>) -> Vec<&Value> {
    match value {
        Some(Value::Array(items)) => items.iter().filter(|i| i.is_object()).collect(),
        Some(one @ Value::Object(_)) => vec![one],
        _ => Vec::new(),
    }
}

/// The objects of a list, where the folder browser takes nothing else.
fn list(value: Option<&Value>) -> Vec<&Value> {
    match value {
        Some(Value::Array(items)) => items.iter().filter(|i| i.is_object()).collect(),
        _ => Vec::new(),
    }
}

fn string(value: Option<&Value>) -> Option<String> {
    value.and_then(Value::as_str).map(str::to_string)
}

fn non_empty(value: Option<String>) -> Option<String> {
    value.filter(|s| !s.is_empty())
}

/// A string trimmed as Dart's `trim` does, None when nothing is left.
fn trimmed(value: Option<&Value>) -> Option<String> {
    let text = dart_trim(value.and_then(Value::as_str)?);
    (!text.is_empty()).then(|| text.to_string())
}

/// A whole number from a JSON number (a lyric line's reader): truncated,
/// None when not finite.
fn number_int(value: &Value) -> Option<i64> {
    match value {
        Value::Int(n) => Some(*n),
        Value::Float(f) => finite_int(*f),
        _ => None,
    }
}

/// A whole number from a JSON number or a numeric string, as the song and
/// album readers take one: `num.tryParse` of the trimmed string, decimal or
/// `0x` hex, truncated, and clamped where Dart's `toInt` clamps.
fn loose_int(value: &Value) -> Option<i64> {
    match value {
        Value::String(s) => dart_num_parse(dart_trim(s)),
        other => number_int(other),
    }
}

/// `f` truncated toward zero and clamped to `i64`, as Dart's `toInt` does;
/// None for NaN and infinities.
fn finite_int(f: f64) -> Option<i64> {
    f.is_finite().then_some(f as i64)
}

/// `num.tryParse(text)` turned into a whole number: `int.tryParse` first
/// (an optional sign, then decimal digits, or `0x` and hex digits up to 64
/// bits, read as two's complement), then `double.tryParse`.
pub(crate) fn dart_num_parse(text: &str) -> Option<i64> {
    let (negative, unsigned) = match text.as_bytes().first() {
        Some(b'-') => (true, text.get(1..)?),
        Some(b'+') => (false, text.get(1..)?),
        _ => (false, text),
    };
    if let Some(hex) = unsigned
        .strip_prefix("0x")
        .or_else(|| unsigned.strip_prefix("0X"))
    {
        if hex.is_empty() || !hex.bytes().all(|b| b.is_ascii_hexdigit()) {
            return None;
        }
        let value = u64::from_str_radix(hex, 16).ok()?;
        return if negative {
            match value {
                0..=0x7FFF_FFFF_FFFF_FFFF => Some(-(value as i64)),
                0x8000_0000_0000_0000 => Some(i64::MIN),
                _ => None,
            }
        } else {
            Some(value as i64)
        };
    }
    if !unsigned.is_empty() && unsigned.bytes().all(|b| b.is_ascii_digit()) {
        if let Ok(n) = text.parse::<i64>() {
            return Some(n);
        }
    }
    dart_double(text).and_then(finite_int)
}

/// `double.tryParse(text)` for decimal text: an optional sign, digits with
/// an optional fraction (either side of the point may be empty, not both),
/// an optional exponent. `NaN` and `Infinity` are left out: no whole number
/// comes of them.
fn dart_double(text: &str) -> Option<f64> {
    let b = text.as_bytes();
    let mut i = usize::from(matches!(b.first(), Some(b'+' | b'-')));
    let int_start = i;
    while b.get(i).is_some_and(u8::is_ascii_digit) {
        i += 1;
    }
    let mut digits = i - int_start;
    if b.get(i) == Some(&b'.') {
        i += 1;
        let frac_start = i;
        while b.get(i).is_some_and(u8::is_ascii_digit) {
            i += 1;
        }
        digits += i - frac_start;
    }
    if digits == 0 {
        return None;
    }
    if matches!(b.get(i), Some(b'e' | b'E')) {
        i += 1;
        if matches!(b.get(i), Some(b'+' | b'-')) {
            i += 1;
        }
        let exp_start = i;
        while b.get(i).is_some_and(u8::is_ascii_digit) {
            i += 1;
        }
        if i == exp_start {
            return None;
        }
    }
    if i != b.len() {
        return None;
    }
    text.parse::<f64>().ok()
}

/// Dart's `String.trim`: Unicode White_Space (6.2, so not U+180E) and the
/// byte order mark.
pub(crate) fn dart_trim(text: &str) -> &str {
    text.trim_matches(|c: char| c == '\u{FEFF}' || (c.is_whitespace() && c != '\u{180E}'))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn numeric_strings_read_as_num_try_parse_reads_them() {
        let cases: &[(&str, Option<i64>)] = &[
            ("12", Some(12)),
            ("0x10", Some(16)),
            ("-0x10", Some(-16)),
            ("+0x10", Some(16)),
            ("0X1f", Some(31)),
            ("+5", Some(5)),
            ("1e3", Some(1000)),
            ("12.9", Some(12)),
            ("-12.9", Some(-12)),
            (".5", Some(0)),
            ("5.", Some(5)),
            ("-.5", Some(0)),
            ("1e300", Some(i64::MAX)),
            ("-1e300", Some(i64::MIN)),
            ("0xFFFFFFFFFFFFFFFF", Some(-1)),
            ("-0x8000000000000000", Some(i64::MIN)),
            ("-0xFFFFFFFFFFFFFFFF", None),
            ("0x10000000000000000", None),
            ("99999999999999999999", Some(i64::MAX)),
            ("-9223372036854775809", Some(i64::MIN)),
            ("00012", Some(12)),
            ("1e-400", Some(0)),
            ("Infinity", None),
            ("NaN", None),
            ("1_0", None),
            ("١٢", None),
            ("--1", None),
            ("", None),
            ("0x", None),
            ("0x-1", None),
            (".e1", None),
            ("1e+", None),
            ("0b1", None),
        ];
        for (text, want) in cases {
            assert_eq!(dart_num_parse(text), *want, "{text:?}");
        }
    }

    #[test]
    fn trim_is_darts() {
        assert_eq!(dart_trim("\u{a0}\u{feff} x \u{3000}"), "x");
        assert_eq!(dart_trim("\u{180e}x"), "\u{180e}x");
        assert_eq!(dart_trim("\u{200b}x"), "\u{200b}x");
        assert_eq!(dart_trim("\u{1c}x"), "\u{1c}x");
    }

    #[test]
    fn a_non_subsonic_body_is_said_to_be_one() {
        for body in [
            &b"<html>"[..],
            b"[]",
            b"{\"subsonic-response\":\"x\"}",
            b"{\"subsonic-response\":{\"status\":1}}",
        ] {
            let mut slot = None;
            assert_eq!(read(body, &mut slot).outcome, Outcome::NotSubsonic);
        }
    }

    #[test]
    fn an_error_code_reads_like_a_song_number() {
        let mut slot = None;
        let e = read(
            br#"{"subsonic-response":{"status":"failed","error":{"code":" 41 "}}}"#,
            &mut slot,
        );
        assert_eq!((e.outcome, e.error_code), (Outcome::Failed, Some(41)));
    }

    #[test]
    fn a_single_entry_stands_for_a_list_of_one() {
        let v = json::parse(r#"{"album":{"song":{"id":"s","title":"T"}}}"#).unwrap();
        assert_eq!(album_songs(&v).len(), 1);
        // Not in the folder browser, which takes lists only.
        let v = json::parse(r#"{"musicFolders":{"musicFolder":{"id":"1","name":"M"}}}"#).unwrap();
        assert!(music_folders(&v).is_empty());
    }

    #[test]
    fn a_page_counts_entries_it_could_not_read() {
        let v =
            json::parse(r#"{"albumList2":{"album":[{"id":"a","name":"A"},1,{"id":""}]}}"#).unwrap();
        let (albums, count) = album_page(&v);
        assert_eq!((albums.len(), count), (1, 3));
    }

    #[test]
    fn form_post_needs_version_one() {
        let yes =
            json::parse(r#"{"openSubsonicExtensions":[{"name":"formPost","versions":[1.0]}]}"#)
                .unwrap();
        let no =
            json::parse(r#"{"openSubsonicExtensions":[{"name":"formPost","versions":["1"]}]}"#)
                .unwrap();
        assert!(takes_form_posts(&yes));
        assert!(!takes_form_posts(&no));
    }

    #[test]
    fn a_lyric_offset_never_times_a_line_below_zero() {
        let v = json::parse(
            r#"{"lyricsList":{"structuredLyrics":[{"offset":-500,"line":[{"value":"a","start":100},{"value":"b"}]}]}}"#,
        )
        .unwrap();
        assert_eq!(
            structured_lyrics(&v),
            Some(vec![
                LyricLine {
                    text: "a".into(),
                    start_ms: Some(0)
                },
                LyricLine {
                    text: "b".into(),
                    start_ms: None
                },
            ])
        );
    }
}
