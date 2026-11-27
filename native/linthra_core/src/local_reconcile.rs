//! Which local files moved and which are gone after a scan: the rules of
//! `LocalCatalogReconciliation.resolve`
//! (lib/core/sources/local/local_catalog_reconciliation.dart), with the
//! identity of `LocalTrackIdentity.of`
//! (lib/core/sources/local/local_track_identity.dart).
//!
//! The Dart files hold the reasoning. What matters here is giving the same
//! answer: a wrong move hands one song's play count and heart to another.
//! Dart lower-cases every tag before it crosses (its case table is the one
//! the identity is built with); trimming and the whitespace collapse happen
//! here, with Dart's `trim` and `RegExp(r'\s+')` character sets.
//!
//! `test/fixtures/local_reconcile_cases.txt` holds what the Dart rules gave
//! for tricky and random libraries before they were removed, and
//! `local_catalog_reconciliation_cases_test.dart` replays it.

use std::collections::{HashMap, HashSet};

use crate::library_grouping::dart_trim;

/// One local track as the reconciliation sees it.
pub struct ReconcileTrack<'a> {
    /// The track's uri (its path), as the scan gave it.
    pub uri: &'a str,
    /// The tags, lower-cased by Dart's `String.toLowerCase`; empty when
    /// missing.
    pub title: &'a str,
    pub artist: &'a str,
    pub album: &'a str,
    pub album_artist: &'a str,
    pub album_id: &'a str,
    /// `Duration.inMicroseconds`.
    pub duration_micros: i64,
    pub track_number: Option<i64>,
}

/// The answer, as positions into the lists [resolve] was given.
#[derive(Debug, Default, PartialEq, Eq)]
pub struct Reconciliation {
    /// (previous, scanned) pairs: the file at `previous` now sits at `scanned`.
    pub moves: Vec<(usize, usize)>,
    /// Previous tracks that are confirmed gone, in catalog order.
    pub removed: Vec<usize>,
}

/// `LocalCatalogReconciliation.resolve`. `refreshed[i]` is whether the scan
/// read the folder that holds `previous[i]` (`wasRefreshed`).
pub fn resolve(
    previous: &[ReconcileTrack],
    refreshed: &[bool],
    scanned: &[ReconcileTrack],
) -> Reconciliation {
    if previous.is_empty() {
        return Reconciliation::default();
    }
    let scanned_uris: HashSet<&str> = scanned.iter().map(|t| t.uri).collect();
    // Only under a folder the scan read: not found is not the same as gone.
    let disappeared: Vec<usize> = (0..previous.len())
        .filter(|&i| !scanned_uris.contains(previous[i].uri) && refreshed[i])
        .collect();
    if disappeared.is_empty() {
        return Reconciliation::default();
    }
    let previous_uris: HashSet<&str> = previous.iter().map(|t| t.uri).collect();
    let appeared: Vec<usize> = (0..scanned.len())
        .filter(|&i| !previous_uris.contains(scanned[i].uri))
        .collect();

    let gone = UniqueByIdentity::of(&disappeared, previous);
    let found = UniqueByIdentity::of(&appeared, scanned);

    let mut moves = Vec::new();
    let mut moved_from: HashSet<&str> = HashSet::new();
    for key in &gone.order {
        // None on either side means two files share the identity: no move.
        let (Some(from), Some(Some(to))) = (gone.by_key[key], found.by_key.get(key)) else {
            continue;
        };
        moves.push((from, *to));
        moved_from.insert(previous[from].uri);
    }
    let removed = disappeared
        .into_iter()
        .filter(|&i| !moved_from.contains(previous[i].uri))
        .collect();
    Reconciliation { moves, removed }
}

/// `_uniqueByIdentity`: each identity's one track, or None when more than
/// one track claims it, keeping the order Dart's map would iterate in.
struct UniqueByIdentity {
    order: Vec<String>,
    by_key: HashMap<String, Option<usize>>,
}

impl UniqueByIdentity {
    fn of(positions: &[usize], tracks: &[ReconcileTrack]) -> Self {
        let mut order = Vec::new();
        let mut by_key: HashMap<String, Option<usize>> = HashMap::new();
        for &i in positions {
            let Some(key) = identity(&tracks[i]) else {
                continue;
            };
            match by_key.get_mut(&key) {
                Some(slot) => *slot = None,
                None => {
                    order.push(key.clone());
                    by_key.insert(key, Some(i));
                }
            }
        }
        UniqueByIdentity { order, by_key }
    }
}

/// `LocalTrackIdentity.of`: the same fields joined by NUL, so two tracks
/// collide here exactly when they collide in Dart. None without a decoded
/// duration or a title.
pub fn identity(track: &ReconcileTrack) -> Option<String> {
    if track.duration_micros <= 0 {
        return None;
    }
    let title = normalize(track.title);
    if title.is_empty() {
        return None;
    }
    Some(
        [
            (track.duration_micros / 1000).to_string(),
            title,
            normalize(track.artist),
            normalize(track.album),
            normalize(track.album_artist),
            track
                .track_number
                .map(|n| n.to_string())
                .unwrap_or_default(),
            normalize(track.album_id),
        ]
        .join("\0"),
    )
}

/// `_normalize` after `toLowerCase`: Dart's `trim`, then every run of
/// `RegExp(r'\s+')` whitespace as one space.
fn normalize(lower: &str) -> String {
    let mut out = String::with_capacity(lower.len());
    let mut in_space = false;
    for ch in dart_trim(lower).chars() {
        if is_regexp_space(ch) {
            if !in_space {
                out.push(' ');
                in_space = true;
            }
        } else {
            out.push(ch);
            in_space = false;
        }
    }
    out
}

/// `\s` in a Dart `RegExp`, which follows JavaScript: unlike `trim`, it does
/// not include U+0085.
fn is_regexp_space(ch: char) -> bool {
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

#[cfg(test)]
mod tests {
    use super::*;

    fn track<'a>(uri: &'a str, title: &'a str) -> ReconcileTrack<'a> {
        ReconcileTrack {
            uri,
            title,
            artist: "artist",
            album: "album",
            album_artist: "",
            album_id: "",
            duration_micros: 180_000_000,
            track_number: Some(1),
        }
    }

    #[test]
    fn finds_a_moved_file_and_a_deleted_one() {
        let previous = [track("/a/1.flac", "one"), track("/a/2.flac", "two")];
        let scanned = [track("/b/1.flac", "one")];
        let r = resolve(&previous, &[true, true], &scanned);
        assert_eq!(r.moves, [(0, 0)]);
        assert_eq!(r.removed, [1]);
    }

    #[test]
    fn leaves_an_unread_folder_alone() {
        let previous = [track("/usb/1.flac", "one")];
        let r = resolve(&previous, &[false], &[]);
        assert_eq!(r, Reconciliation::default());
    }

    #[test]
    fn refuses_an_identity_two_files_share() {
        let previous = [track("/a/1.flac", "one")];
        let scanned = [track("/b/1.flac", "one"), track("/c/1.flac", "one")];
        let r = resolve(&previous, &[true], &scanned);
        assert!(r.moves.is_empty());
        assert_eq!(r.removed, [0]);
    }

    #[test]
    fn normalizes_like_dart() {
        assert_eq!(normalize("  a \t\u{3000} b  "), "a b");
        // Trimmed at the ends, but not whitespace for the regexp.
        assert_eq!(normalize("\u{85}a\u{85}b\u{85}"), "a\u{85}b");
        let mut untagged = track("/a/1.flac", "one");
        untagged.duration_micros = 0;
        assert_eq!(identity(&untagged), None);
        assert_eq!(identity(&track("/a/1.flac", " \u{A0} ")), None);
    }
}
