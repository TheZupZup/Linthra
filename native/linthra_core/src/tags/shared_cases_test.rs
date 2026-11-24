//! Replays test/fixtures/tags/cases.txt, which the Dart reader replays too
//! (test/core/sources/local/tag_shared_cases_test.dart): every file in that
//! folder, read with its cover, must give the line written for it.

use std::path::PathBuf;

use super::{read_file, AudioTags};

fn fixtures() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../test/fixtures/tags")
}

/// The line cases.txt writes for `file`, from what Rust read.
fn line(file: &str, tags: Option<AudioTags>) -> String {
    let Some(tags) = tags else {
        return format!("{file}\tNONE");
    };
    let field = |value: Option<String>| value.unwrap_or_else(|| "-".to_owned());
    [
        file.to_owned(),
        field(tags.title),
        field(tags.artist),
        field(tags.album_artist),
        field(tags.album),
        field(tags.track_number.map(|n| n.to_string())),
        field(tags.duration_micros.map(|n| n.to_string())),
        field(
            tags.cover
                .map(|cover| cover.iter().map(|b| format!("{b:02x}")).collect()),
        ),
    ]
    .join("\t")
}

#[test]
fn tags_match_the_shared_cases() {
    let cases = std::fs::read_to_string(fixtures().join("cases.txt")).unwrap();
    let mut seen = 0;
    for expected in cases
        .lines()
        .filter(|line| !line.is_empty() && !line.starts_with('#'))
    {
        let file = expected.split('\t').next().unwrap();
        let tags = read_file(&fixtures().join(file), true).unwrap();
        assert_eq!(line(file, tags), expected, "file {file}");
        seen += 1;
    }
    assert_eq!(seen, 17);
}

#[test]
fn a_missing_file_is_an_error_not_a_none() {
    assert!(read_file(&fixtures().join("gone.flac"), true).is_err());
}

#[test]
fn without_a_cover_none_is_read() {
    let tags = read_file(&fixtures().join("flac_tagged.flac"), false)
        .unwrap()
        .unwrap();
    assert_eq!(tags.cover, None);
    assert_eq!(tags.title.as_deref(), Some("Hello"));
    let tags = read_file(&fixtures().join("vorbis_tagged.ogg"), false)
        .unwrap()
        .unwrap();
    assert_eq!(tags.cover, None);
}

/// Files from anywhere get read, and a panic aborts the app: every fixture,
/// cut at every length and with every byte flipped in turn, must read as tags,
/// `None` or an error, never a panic.
#[test]
fn damaged_files_never_panic() {
    let mut damaged = 0;
    for entry in std::fs::read_dir(fixtures()).unwrap() {
        let path = entry.unwrap().path();
        if path.extension().is_some_and(|e| e == "txt") {
            continue;
        }
        let bytes = std::fs::read(&path).unwrap();
        for cut in 0..bytes.len() {
            let _ = super::read(&mut std::io::Cursor::new(&bytes[..cut]), true);
            damaged += 1;
        }
        for at in 0..bytes.len() {
            for flip in [0xFFu8, 0x80, 0x01] {
                let mut copy = bytes.clone();
                copy[at] ^= flip;
                let _ = super::read(&mut std::io::Cursor::new(&copy), true);
                damaged += 1;
            }
        }
    }
    assert!(damaged > 10_000);
}
