//! Cross-provider duplicate merging: the rules of `unifyTracks`
//! (lib/core/catalog/track_unifier.dart) and `trackMatchScore`
//! (lib/core/catalog/track_identity.dart), for the whole catalog in one call.
//!
//! The Dart files hold the reasoning behind every rule; this module only has
//! to give the same answer. What makes that hard is text: Dart lower-cases the
//! title, artist and album before they cross (its case table is the one the
//! Dart rules run on), the rest of `foldText` is [fold], and the two
//! featured-artist regexes are matched by hand in [core_title_tokens] with the
//! ASCII word boundary Dart's non-unicode `RegExp` uses.
//!
//! Where the Dart code compares `String`s (the uri tiebreak), Rust compares in
//! UTF-16 code unit order ([dart_compare]) so both sort the same way.
//!
//! `test/core/catalog/track_unifier_native_test.dart` replays random and
//! tricky catalogs through both and fails on any difference.

use std::cmp::Ordering;
use std::collections::{HashMap, HashSet};

use crate::library_grouping::fold;

/// One catalog row as the unifier sees it.
pub struct UnifierTrack<'a> {
    /// The title, lower-cased by Dart's `String.toLowerCase`.
    pub title: &'a str,
    /// The artist, lower-cased the same way (empty when none).
    pub artist: &'a str,
    /// The album, lower-cased the same way (empty when none).
    pub album: &'a str,
    /// The provider-namespaced uri, as the source gave it.
    pub uri: &'a str,
    /// `Duration.inSeconds`.
    pub duration_seconds: i64,
    pub track_number: Option<i64>,
    /// Which provider owns the track. Equal values mean the same provider.
    pub source: u32,
    /// `SourcePriority.rankOf` for that provider, lower is preferred.
    pub rank: u32,
}

const NEAR_DURATION_SECONDS: i64 = 2;
const W_TITLE: f64 = 0.45;
const W_ALBUM: f64 = 0.30;
const W_ARTIST: f64 = 0.25;
const MATCH_SCORE: f64 = 0.9;
const ARTIST_STOPWORDS: [&str; 4] = ["feat", "ft", "featuring", "and"];

/// What scoring needs from a track, worked out once instead of per pair.
/// Tokens are [Interner] ids.
struct Features {
    /// The feat-stripped title tokens, in order.
    title: Vec<u32>,
    /// The same tokens, sorted and deduplicated.
    title_set: Vec<u32>,
    album_set: Vec<u32>,
    /// Artist tokens without the connective stopwords, sorted and deduplicated.
    artist_set: Vec<u32>,
    /// `matchBlockKey` (first artist token, first title token), or None for a
    /// track that can never merge.
    block: Option<(u32, u32)>,
}

/// Numbers each distinct token, so tokens compare as `u32`s and each one is
/// allocated once per call rather than once per track.
#[derive(Default)]
struct Interner {
    ids: HashMap<Box<[u8]>, u32>,
}

impl Interner {
    fn id(&mut self, token: &[u8]) -> u32 {
        if let Some(&id) = self.ids.get(token) {
            return id;
        }
        let id = self.ids.len() as u32;
        self.ids.insert(token.into(), id);
        id
    }

    fn tokens(&mut self, text: &[u8]) -> Vec<u32> {
        tokens(text).map(|t| self.id(t)).collect()
    }
}

/// The logical tracks of `tracks`, each as the positions of its copies,
/// best-first. Logical tracks come in order of first appearance, exactly as
/// `unifyTracks` emits them.
pub fn unify(tracks: &[UnifierTrack]) -> Vec<Vec<usize>> {
    let mut interner = Interner::default();
    let stopwords = ARTIST_STOPWORDS.map(|w| interner.id(w.as_bytes()));
    let features: Vec<Features> = tracks
        .iter()
        .map(|t| features(t, &mut interner, &stopwords))
        .collect();

    // Blocks in order of first appearance, as Dart's insertion-ordered map
    // walks them. The order matters only for duplicate uris, see below.
    let mut block_of: HashMap<(u32, u32), usize> = HashMap::new();
    let mut blocks: Vec<Vec<usize>> = Vec::new();
    for (i, f) in features.iter().enumerate() {
        let Some(key) = f.block else {
            continue;
        };
        let next = blocks.len();
        let at = *block_of.entry(key).or_insert(next);
        if at == next {
            blocks.push(Vec::new());
        }
        blocks[at].push(i);
    }

    // Keyed by uri like Dart's `groupByUri`: a uri that appears twice ends up
    // in whichever group was written last.
    let mut groups: Vec<Vec<usize>> = Vec::new();
    let mut group_by_uri: HashMap<&str, usize> = HashMap::new();
    for block in &blocks {
        for group in group_block(block, tracks, &features) {
            let id = groups.len();
            for &member in &group {
                group_by_uri.insert(tracks[member].uri, id);
            }
            groups.push(group);
        }
    }

    let merges: Vec<bool> = groups
        .iter()
        .map(|g| distinct_sources(g, tracks) >= 2)
        .collect();
    let mut emitted_anchors: HashSet<&str> = HashSet::new();
    let mut result = Vec::with_capacity(tracks.len());
    for (i, track) in tracks.iter().enumerate() {
        match group_by_uri.get(track.uri) {
            Some(&g) if merges[g] => {
                if emitted_anchors.insert(tracks[groups[g][0]].uri) {
                    // Members joined in (rank, uri) order, which is already
                    // the order Dart sorts the candidates into.
                    result.push(groups[g].clone());
                }
            }
            _ => result.push(vec![i]),
        }
    }
    result
}

/// `_groupBlock`: each track, in (rank, uri) order, joins the first group
/// whose anchor it matches and whose provider it does not already have.
fn group_block(block: &[usize], tracks: &[UnifierTrack], features: &[Features]) -> Vec<Vec<usize>> {
    let mut ordered = block.to_vec();
    // Stable, so equal (rank, uri) keep their catalog order, as Dart's
    // insertion sort does for the small lists blocks are.
    ordered.sort_by(|&a, &b| {
        tracks[a]
            .rank
            .cmp(&tracks[b].rank)
            .then_with(|| dart_compare(tracks[a].uri, tracks[b].uri))
    });
    let mut groups: Vec<Vec<usize>> = Vec::new();
    for &i in &ordered {
        let target = groups.iter().position(|group| {
            !group.iter().any(|&m| tracks[m].source == tracks[i].source)
                && is_likely_same(group[0], i, tracks, features)
        });
        match target {
            Some(g) => groups[g].push(i),
            None => groups.push(vec![i]),
        }
    }
    groups
}

fn distinct_sources(group: &[usize], tracks: &[UnifierTrack]) -> usize {
    let source = |k: usize| tracks[group[k]].source;
    (0..group.len())
        .filter(|&k| (0..k).all(|j| source(j) != source(k)))
        .count()
}

fn is_likely_same(a: usize, b: usize, tracks: &[UnifierTrack], features: &[Features]) -> bool {
    match_score(&tracks[a], &features[a], &tracks[b], &features[b]) >= MATCH_SCORE
}

/// `trackMatchScore`, summed in the same order so the doubles agree.
fn match_score(a: &UnifierTrack, fa: &Features, b: &UnifierTrack, fb: &Features) -> f64 {
    if fa.block.is_none() || fb.block.is_none() {
        return 0.0;
    }
    // Dart's int arithmetic wraps; so does this.
    if a.duration_seconds
        .wrapping_sub(b.duration_seconds)
        .wrapping_abs()
        > NEAR_DURATION_SECONDS
    {
        return 0.0;
    }
    if let (Some(na), Some(nb)) = (a.track_number, b.track_number) {
        if na != nb {
            return 0.0;
        }
    }
    let title = if fa.title == fb.title {
        1.0
    } else {
        jaccard(&fa.title_set, &fb.title_set)
    };
    let album = containment(&fa.album_set, &fb.album_set);
    let artist = containment(&fa.artist_set, &fb.artist_set);
    W_TITLE * title + W_ALBUM * album + W_ARTIST * artist
}

fn features(track: &UnifierTrack, interner: &mut Interner, stopwords: &[u32]) -> Features {
    let title = interner.tokens(&core_title(track.title));
    let artist = interner.tokens(fold(track.artist).as_bytes());
    let album = interner.tokens(fold(track.album).as_bytes());
    let eligible =
        track.duration_seconds > 0 && !artist.is_empty() && !album.is_empty() && !title.is_empty();
    let block = eligible.then(|| (artist[0], title[0]));
    let artist_set = sorted_set(
        artist
            .into_iter()
            .filter(|t| !stopwords.contains(t))
            .collect(),
    );
    Features {
        title_set: sorted_set(title.clone()),
        title,
        album_set: sorted_set(album),
        artist_set,
        block,
    }
}

fn sorted_set(mut tokens: Vec<u32>) -> Vec<u32> {
    tokens.sort_unstable();
    tokens.dedup();
    tokens
}

/// `|a ∩ b|` of two sorted, deduplicated token lists.
fn intersection(a: &[u32], b: &[u32]) -> usize {
    let (mut i, mut j, mut n) = (0, 0, 0);
    while i < a.len() && j < b.len() {
        match a[i].cmp(&b[j]) {
            Ordering::Less => i += 1,
            Ordering::Greater => j += 1,
            Ordering::Equal => {
                n += 1;
                i += 1;
                j += 1;
            }
        }
    }
    n
}

fn jaccard(a: &[u32], b: &[u32]) -> f64 {
    if a.is_empty() && b.is_empty() {
        return 1.0;
    }
    if a.is_empty() || b.is_empty() {
        return 0.0;
    }
    let both = intersection(a, b);
    let union = a.len() + b.len() - both;
    both as f64 / union as f64
}

fn containment(a: &[u32], b: &[u32]) -> f64 {
    if a.is_empty() || b.is_empty() {
        return 0.0;
    }
    intersection(a, b) as f64 / a.len().min(b.len()) as f64
}

/// What `_coreTitleTokens` tokenizes: the folded title without `feat.`
/// qualifiers, first the bracketed ones, then a trailing one.
fn core_title(lower_title: &str) -> Vec<u8> {
    let folded = fold(lower_title);
    strip_trailing_feat(strip_bracketed_feat(folded.as_bytes()))
}

/// `\w` in a non-unicode Dart `RegExp`. Every byte of a multi-byte UTF-8
/// character is >= 0x80, so none of them is a word byte, as none of those
/// characters is a word character.
fn is_word(byte: u8) -> bool {
    byte.is_ascii_alphanumeric() || byte == b'_'
}

/// Where `\b(?:feat|ft|featuring)\b` matching at `at` ends, if it does.
fn feat_word_end(text: &[u8], at: usize) -> Option<usize> {
    if at > 0 && is_word(text[at - 1]) {
        return None;
    }
    let rest = &text[at..];
    ["feat", "ft", "featuring"].iter().find_map(|word| {
        let end = at + word.len();
        let bounded = text.get(end).is_none_or(|&b| !is_word(b));
        (rest.starts_with(word.as_bytes()) && bounded).then_some(end)
    })
}

/// `replaceAll(RegExp(r'[\(\[][^\)\]]*\b(?:feat|ft|featuring)\b[^\)\]]*[\)\]]'), ' ')`.
///
/// Neither run in the pattern may cross a closing bracket, so a match from
/// an opener always ends at the first closer after it, and it matches when a
/// feat word sits somewhere in between.
fn strip_bracketed_feat(text: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(text.len());
    let mut i = 0;
    while i < text.len() {
        if matches!(text[i], b'(' | b'[') {
            let closer = text[i + 1..]
                .iter()
                .position(|&b| matches!(b, b')' | b']'))
                .map(|p| i + 1 + p);
            if let Some(closer) = closer {
                if (i + 1..closer).any(|k| feat_word_end(text, k).is_some()) {
                    out.push(b' ');
                    i = closer + 1;
                    continue;
                }
            }
        }
        out.push(text[i]);
        i += 1;
    }
    out
}

/// `replaceAll(RegExp(r'\b(?:feat|ft|featuring)\b[^\(\[]*$'), ' ')`: from the
/// first feat word with no opening bracket after it, to the end.
fn strip_trailing_feat(mut text: Vec<u8>) -> Vec<u8> {
    let from = text
        .iter()
        .rposition(|&b| matches!(b, b'(' | b'['))
        .map_or(0, |p| p + 1);
    if let Some(at) = (from..text.len()).find(|&k| feat_word_end(&text, k).is_some()) {
        text.truncate(at);
        text.push(b' ');
    }
    text
}

/// `_tokenize`: the runs of `[a-z0-9]`.
fn tokens(text: &[u8]) -> impl Iterator<Item = &[u8]> {
    text.split(|b| !matches!(b, b'a'..=b'z' | b'0'..=b'9'))
        .filter(|t| !t.is_empty())
}

/// Dart's `String.compareTo`: UTF-16 code unit order. It differs from code
/// point order only where a character above U+FFFF (a surrogate pair,
/// D800..DBFF first) meets one in U+E000..U+FFFF.
pub fn dart_compare(a: &str, b: &str) -> Ordering {
    fn unit_order(ch: char) -> u32 {
        let c = ch as u32;
        if (0xE000..=0xFFFF).contains(&c) {
            c + 0x11_0000
        } else {
            c
        }
    }
    a.chars().map(unit_order).cmp(b.chars().map(unit_order))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn track<'a>(
        uri: &'a str,
        title: &'a str,
        artist: &'a str,
        album: &'a str,
        source: u32,
    ) -> UnifierTrack<'a> {
        UnifierTrack {
            title,
            artist,
            album,
            uri,
            duration_seconds: 180,
            track_number: None,
            source,
            rank: source,
        }
    }

    fn core_title_tokens(lower_title: &str) -> Vec<String> {
        let title = core_title(lower_title);
        tokens(&title)
            .map(|t| String::from_utf8(t.to_vec()).unwrap())
            .collect()
    }

    #[test]
    fn strips_featured_artists_from_titles() {
        assert_eq!(core_title_tokens("careful"), ["careful"]);
        assert_eq!(core_title_tokens("careful feat. cordae"), ["careful"]);
        assert_eq!(core_title_tokens("careful (feat. cordae)"), ["careful"]);
        assert_eq!(
            core_title_tokens("careful [ft cordae] (live)"),
            ["careful", "live"]
        );
        assert_eq!(core_title_tokens("hello (live)"), ["hello", "live"]);
        // A word that only starts with feat is no qualifier.
        assert_eq!(core_title_tokens("feature film"), ["feature", "film"]);
        // `_` is a word character for the boundary but not for tokens.
        assert_eq!(core_title_tokens("x_feat y"), ["x", "feat", "y"]);
        // A trailing feat with a bracket after it is left alone.
        assert_eq!(
            core_title_tokens("a feat b (live"),
            ["a", "feat", "b", "live"]
        );
        assert_eq!(core_title_tokens("söng feat. x"), ["song"]);
    }

    #[test]
    fn merges_copies_from_two_providers_only() {
        let tracks = [
            track("jellyfin:1", "careful", "nf", "the search", 0),
            track(
                "subsonic:9",
                "careful feat. cordae",
                "nf, cordae",
                "the search (deluxe)",
                1,
            ),
            track("jellyfin:2", "careful", "nf", "the search", 0),
        ];
        assert_eq!(unify(&tracks), vec![vec![0, 1], vec![2]]);
    }

    #[test]
    fn keeps_versions_and_ineligible_tracks_apart() {
        let mut short = track("subsonic:2", "hello", "adele", "25", 1);
        short.duration_seconds = 0;
        let tracks = [
            track("jellyfin:1", "hello", "adele", "25", 0),
            track("subsonic:1", "hello (live)", "adele", "25", 1),
            short,
        ];
        assert_eq!(unify(&tracks), vec![vec![0], vec![1], vec![2]]);
    }

    #[test]
    fn compares_like_dart_strings() {
        assert_eq!(dart_compare("a", "b"), Ordering::Less);
        assert_eq!(dart_compare("ab", "a"), Ordering::Greater);
        // U+1F600 is D83D DE00 in UTF-16, before U+FF01.
        assert_eq!(dart_compare("\u{1F600}", "\u{FF01}"), Ordering::Less);
        assert_eq!(dart_compare("\u{D7FF}", "\u{1F600}"), Ordering::Less);
    }
}
