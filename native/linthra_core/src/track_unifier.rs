//! Merging one song's copies from different servers into one library row.
//!
//! The same rules as `lib/core/catalog/track_identity.dart` and
//! `track_unifier.dart`, which are the fallback; `track_unifier_native_test`
//! on the Dart side compares the two. Conservative by design: two rows stay
//! apart unless their title, album and artist agree closely, their lengths
//! are within two seconds, their track numbers don't conflict, and they come
//! from different servers.
//!
//! Text is read with the search tokenizer ([crate::normalize]), which keeps
//! the letters of every script, so a song tagged in Cyrillic, Greek or CJK
//! merges like a Latin-tagged one.

use std::collections::{HashMap, HashSet};

use crate::normalize::normalized_tokens;

/// What the unifier needs to know about one catalog row.
#[derive(Clone, Debug)]
pub struct UnifyTrack<'a> {
    pub uri: &'a str,
    /// The server it comes from; two copies from one server never merge.
    pub source: u32,
    /// Its server's place in the listener's preference, lower first.
    pub rank: u32,
    pub title: &'a str,
    pub artist: &'a str,
    pub album: &'a str,
    pub duration_secs: i64,
    pub track_number: Option<i64>,
}

/// Copies whose lengths differ by more than this are different songs (a radio
/// edit and an extended mix); a re-encode can move a length by a second.
const NEAR_DURATION_SECS: i64 = 2;
const W_TITLE: f64 = 0.45;
const W_ALBUM: f64 = 0.30;
const W_ARTIST: f64 = 0.25;
/// The score two copies must reach to merge: high, so a single strong field
/// disagreeing keeps them apart.
pub const MATCH_SCORE: f64 = 0.9;

const FEAT_WORDS: [&str; 3] = ["feat", "ft", "featuring"];
const ARTIST_STOPWORDS: [&str; 4] = ["feat", "ft", "featuring", "and"];

/// One row's tokens, worked out once.
struct Identity {
    title: Vec<String>,
    album: HashSet<String>,
    artist: HashSet<String>,
    block: Option<String>,
}

impl Identity {
    fn of(track: &UnifyTrack) -> Self {
        let artist_tokens = normalized_tokens(track.artist);
        let album_tokens = normalized_tokens(track.album);
        let title = core_title_tokens(track.title);
        let block = (track.duration_secs > 0
            && !artist_tokens.is_empty()
            && !album_tokens.is_empty()
            && !title.is_empty())
        .then(|| format!("{}|{}", artist_tokens[0], title[0]));
        Identity {
            artist: artist_tokens
                .into_iter()
                .filter(|t| !ARTIST_STOPWORDS.contains(&t.as_str()))
                .collect(),
            album: album_tokens.into_iter().collect(),
            title,
            block,
        }
    }
}

/// `\w` in a Dart regular expression: ASCII letters, digits and `_`.
fn is_word(c: Option<char>) -> bool {
    c.is_some_and(|c| c.is_ascii_alphanumeric() || c == '_')
}

/// Where a whole word `feat`, `ft` or `featuring` starts in `chars` at or
/// after `from`, and its length: `\b(?:feat|ft|featuring)\b`.
fn feat_word_at(chars: &[char], at: usize) -> Option<usize> {
    if is_word(at.checked_sub(1).and_then(|i| chars.get(i).copied())) {
        return None;
    }
    // The alternation tries `feat` before `featuring`, then backtracks when
    // no boundary follows, as the regex does.
    FEAT_WORDS.iter().find_map(|word| {
        let len = word.chars().count();
        let matches = word.chars().enumerate().all(|(k, w)| {
            chars
                .get(at + k)
                .is_some_and(|c| c.eq_ignore_ascii_case(&w))
        });
        (matches && !is_word(chars.get(at + len).copied())).then_some(len)
    })
}

/// The title with featured-artist qualifiers taken out, matched without
/// regard to ASCII case:
/// `[\(\[][^\)\]]*\b(?:feat|ft|featuring)\b[^\)\]]*[\)\]]` anywhere, then
/// `\b(?:feat|ft|featuring)\b[^\(\[]*$` at the end, each replaced with a
/// space. So `Careful (feat. Cordae)` and `CAREFUL feat. Cordae` both read as
/// `careful`, while `Hello (Live)` keeps its version marker. Case is left to
/// the tokenizer: lower-casing here would apply Rust's final-sigma rule,
/// which Dart's `toLowerCase` doesn't.
fn strip_featured(title: &str) -> String {
    let chars: Vec<char> = title.chars().collect();
    let mut kept = String::with_capacity(chars.len());
    let mut i = 0;
    while i < chars.len() {
        if matches!(chars[i], '(' | '[') {
            if let Some(close) = chars[i + 1..].iter().position(|c| matches!(c, ')' | ']')) {
                let end = i + 1 + close;
                if (i + 1..end).any(|k| feat_word_at(&chars, k).is_some_and(|len| k + len <= end)) {
                    kept.push(' ');
                    i = end + 1;
                    continue;
                }
            }
        }
        kept.push(chars[i]);
        i += 1;
    }
    let chars: Vec<char> = kept.chars().collect();
    for at in 0..chars.len() {
        if let Some(len) = feat_word_at(&chars, at) {
            if !chars[at + len..].iter().any(|c| matches!(c, '(' | '[')) {
                let mut out: String = chars[..at].iter().collect();
                out.push(' ');
                return out;
            }
        }
    }
    kept
}

fn core_title_tokens(title: &str) -> Vec<String> {
    normalized_tokens(&strip_featured(title))
}

fn jaccard(a: &HashSet<&String>, b: &HashSet<&String>) -> f64 {
    if a.is_empty() && b.is_empty() {
        return 1.0;
    }
    if a.is_empty() || b.is_empty() {
        return 0.0;
    }
    let intersection = a.iter().filter(|t| b.contains(*t)).count();
    let union = a.len() + b.len() - intersection;
    if union == 0 {
        0.0
    } else {
        intersection as f64 / union as f64
    }
}

fn containment(a: &HashSet<String>, b: &HashSet<String>) -> f64 {
    if a.is_empty() || b.is_empty() {
        return 0.0;
    }
    let intersection = a.iter().filter(|t| b.contains(*t)).count();
    intersection as f64 / a.len().min(b.len()) as f64
}

/// How confidently two eligible rows are the same song, in [0, 1]; 0 for a
/// veto (lengths more than two seconds apart, or conflicting track numbers).
fn score(a: &UnifyTrack, ia: &Identity, b: &UnifyTrack, ib: &Identity) -> f64 {
    if (a.duration_secs - b.duration_secs).abs() > NEAR_DURATION_SECS {
        return 0.0;
    }
    if let (Some(na), Some(nb)) = (a.track_number, b.track_number) {
        if na != nb {
            return 0.0;
        }
    }
    let title = if ia.title == ib.title {
        1.0
    } else {
        jaccard(&ia.title.iter().collect(), &ib.title.iter().collect())
    };
    W_TITLE * title
        + W_ALBUM * containment(&ia.album, &ib.album)
        + W_ARTIST * containment(&ia.artist, &ib.artist)
}

/// Dart orders strings by UTF-16 code units.
fn utf16_cmp(a: &str, b: &str) -> std::cmp::Ordering {
    a.encode_utf16().cmp(b.encode_utf16())
}

/// The library rows `tracks` make: each a list of indices into `tracks`. A
/// row of one for a track that merges with nothing; for a song found on two
/// or more servers, every copy, best-preferred first. Rows come in the order
/// of each one's first track.
pub fn unify(tracks: &[UnifyTrack]) -> Vec<Vec<u32>> {
    let identities: Vec<Identity> = tracks.iter().map(Identity::of).collect();

    // Block: only rows that share an artist's first word and a title's first
    // word are ever compared.
    let mut blocks: HashMap<&str, Vec<usize>> = HashMap::new();
    let mut block_order: Vec<&str> = Vec::new();
    for (i, identity) in identities.iter().enumerate() {
        if let Some(key) = identity.block.as_deref() {
            blocks
                .entry(key)
                .or_insert_with(|| {
                    block_order.push(key);
                    Vec::new()
                })
                .push(i);
        }
    }

    let by_preference = |&a: &usize, &b: &usize| {
        tracks[a]
            .rank
            .cmp(&tracks[b].rank)
            .then_with(|| utf16_cmp(tracks[a].uri, tracks[b].uri))
    };

    // Within a block: each row joins the first group whose anchor (its most
    // preferred copy) it confidently matches and whose server it doesn't
    // already have, else starts its own.
    let mut group_of_uri: HashMap<&str, usize> = HashMap::new();
    let mut groups: Vec<Vec<usize>> = Vec::new();
    for key in block_order {
        let mut members = blocks.remove(key).unwrap_or_default();
        members.sort_by(by_preference);
        let first_group = groups.len();
        for i in members {
            let target = (first_group..groups.len()).find(|&g| {
                let group = &groups[g];
                let anchor = group[0];
                !group.iter().any(|&m| tracks[m].source == tracks[i].source)
                    && score(
                        &tracks[anchor],
                        &identities[anchor],
                        &tracks[i],
                        &identities[i],
                    ) >= MATCH_SCORE
            });
            match target {
                Some(g) => groups[g].push(i),
                None => groups.push(vec![i]),
            }
        }
        for (g, group) in groups.iter().enumerate().skip(first_group) {
            for &m in group {
                group_of_uri.insert(tracks[m].uri, g);
            }
        }
    }

    let mut emitted: HashSet<usize> = HashSet::new();
    let mut rows = Vec::new();
    for (i, track) in tracks.iter().enumerate() {
        let group = group_of_uri.get(track.uri).map(|&g| (g, &groups[g]));
        let merges = group.is_some_and(|(_, members)| {
            members
                .iter()
                .map(|&m| tracks[m].source)
                .collect::<HashSet<_>>()
                .len()
                >= 2
        });
        match group {
            Some((g, members)) if merges => {
                if emitted.insert(g) {
                    let mut ordered = members.clone();
                    ordered.sort_by(by_preference);
                    rows.push(ordered.into_iter().map(|m| m as u32).collect());
                }
            }
            _ => rows.push(vec![i as u32]),
        }
    }
    rows
}

#[cfg(test)]
mod tests {
    use super::*;

    fn track<'a>(
        uri: &'a str,
        source: u32,
        title: &'a str,
        artist: &'a str,
        album: &'a str,
    ) -> UnifyTrack<'a> {
        UnifyTrack {
            uri,
            source,
            rank: source,
            title,
            artist,
            album,
            duration_secs: 200,
            track_number: None,
        }
    }

    #[test]
    fn strips_featured_artists_but_keeps_versions() {
        assert_eq!(core_title_tokens("Careful (feat. Cordae)"), ["careful"]);
        assert_eq!(core_title_tokens("CAREFUL feat. Cordae"), ["careful"]);
        assert_eq!(core_title_tokens("Song [ft. X] (Live)"), ["song", "live"]);
        assert_eq!(core_title_tokens("Hello (Live)"), ["hello", "live"]);
        // A word that only starts with "feat" is not one.
        assert_eq!(core_title_tokens("Feather"), ["feather"]);
        // A trailing feat before a bracket keeps the bracket.
        assert_eq!(
            core_title_tokens("A feat. B (Remix)"),
            ["a", "feat", "b", "remix"]
        );
    }

    #[test]
    fn merges_copies_from_two_servers_only() {
        let tracks = [
            track("jellyfin:1", 0, "Careful", "NF", "Hope"),
            track(
                "subsonic:9",
                1,
                "Careful (feat. Cordae)",
                "NF, Cordae",
                "Hope (Deluxe)",
            ),
            track("jellyfin:2", 0, "Careful", "NF", "Hope"),
        ];
        // The two Jellyfin rows never merge with each other; the Subsonic one
        // joins the first.
        assert_eq!(unify(&tracks), vec![vec![0, 1], vec![2]]);
    }

    #[test]
    fn issue_877_non_latin_songs_merge_too() {
        let tracks = [
            track("jellyfin:1", 0, "Группа крови", "Кино", "Группа крови"),
            track("subsonic:1", 1, "Группа крови", "Кино", "Группа крови"),
            track("jellyfin:2", 0, "夜に駆ける", "YOASOBI", "THE BOOK"),
            track("subsonic:2", 1, "夜に駆ける", "YOASOBI", "THE BOOK"),
        ];
        assert_eq!(unify(&tracks), vec![vec![0, 1], vec![2, 3]]);
    }

    #[test]
    fn vetoes_keep_different_songs_apart() {
        let mut a = track("jellyfin:1", 0, "Song", "Artist", "Album");
        let mut b = track("subsonic:1", 1, "Song", "Artist", "Album");
        b.duration_secs = 260;
        assert_eq!(unify(&[a.clone(), b.clone()]), vec![vec![0], vec![1]]);
        b.duration_secs = 201;
        a.track_number = Some(1);
        b.track_number = Some(2);
        assert_eq!(unify(&[a, b]), vec![vec![0], vec![1]]);
    }
}
