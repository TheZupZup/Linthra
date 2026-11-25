//! The Songs list's order and A–Z sections, the same as
//! `lib/features/library/song_sort.dart` (`sortSongs`), which is the fallback;
//! `test/features/library/song_sort_native_test.dart` compares the two.
//!
//! Text arrives lower-cased by Dart, as for [crate::library_grouping], and is
//! folded and compared the way Dart folds and compares it: [fold] for
//! `foldText`, UTF-16 code units for `compareTo`.

use std::cmp::Ordering;
use std::collections::HashMap;

use crate::library_grouping::{album_ids, dart_trim, fold, GroupingTrack};

/// What the list is sorted by (`SongSortField`, in Dart's order).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
pub enum SortField {
    Title = 0,
    Artist = 1,
    Album = 2,
    DateAdded = 3,
}

impl SortField {
    pub fn from_code(code: u8) -> Option<Self> {
        [
            SortField::Title,
            SortField::Artist,
            SortField::Album,
            SortField::DateAdded,
        ]
        .get(usize::from(code))
        .copied()
    }
}

/// One song as the sort reads it. The text fields other than `title` and
/// `uri` are lower-cased by Dart; `title` is as written (the last tie-break),
/// and `title_lower` is only read when `title` isn't ASCII.
#[derive(Clone, Debug, Default)]
pub struct SortTrack<'a> {
    pub uri: &'a str,
    pub title: &'a str,
    pub title_lower: &'a str,
    pub artist_lower: &'a str,
    pub album_lower: &'a str,
    pub album_artist_lower: &'a str,
    pub album_id: &'a str,
    pub disc: Option<i64>,
    pub track: Option<i64>,
    pub added_at: Option<i64>,
}

/// A section, as its ASCII character, so sections compare the way Dart
/// compares their strings: `#` and `?` before `A`. `A`–`Z`, `#` for anything
/// else, and `?` for a song missing the sorted-by artist or album.
pub const SECTION_OTHER: u8 = b'#';
pub const SECTION_UNKNOWN: u8 = b'?';

/// The sorted list: positions in the input, and each one's section (empty for
/// the date orders, which have none).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Sorted {
    pub order: Vec<u32>,
    pub sections: Vec<u8>,
}

fn utf16_cmp(a: &str, b: &str) -> Ordering {
    // UTF-8 bytes order like code points, and code points like UTF-16 units
    // except past U+FFFF, which ASCII-only text never reaches.
    if a.is_ascii() && b.is_ascii() {
        return a.cmp(b);
    }
    a.encode_utf16().cmp(b.encode_utf16())
}

/// Present values ascending, then the missing ones.
fn nulls_last<T>(a: Option<T>, b: Option<T>, cmp: impl Fn(&T, &T) -> Ordering) -> Ordering {
    match (a, b) {
        (Some(a), Some(b)) => cmp(&a, &b),
        (Some(_), None) => Ordering::Less,
        (None, Some(_)) => Ordering::Greater,
        (None, None) => Ordering::Equal,
    }
}

/// `_SongKey._fold`: trimmed, folded, and none when nothing is left.
fn fold_value(lower: &str) -> Option<String> {
    let folded = fold(dart_trim(lower));
    (!folded.is_empty()).then_some(folded)
}

/// `_sectionOf`: the first letter when it is a–z, else `#`.
fn section_of(folded: &str) -> u8 {
    match folded.bytes().next() {
        Some(b @ b'a'..=b'z') => b.to_ascii_uppercase(),
        _ => SECTION_OTHER,
    }
}

/// Every distinct folded string, numbered, then ranked in Dart's string order
/// once, so the sort compares integers rather than strings.
#[derive(Default)]
struct Ranks {
    numbers: HashMap<String, u32>,
    texts: Vec<String>,
    /// Each number's place in UTF-16 order, filled by [Ranks::finish].
    rank: Vec<u32>,
}

impl Ranks {
    fn number(&mut self, text: String) -> u32 {
        if let Some(&n) = self.numbers.get(&text) {
            return n;
        }
        let n = self.texts.len() as u32;
        self.texts.push(text.clone());
        self.numbers.insert(text, n);
        n
    }

    fn finish(&mut self) {
        let mut order: Vec<u32> = (0..self.texts.len() as u32).collect();
        // All-ASCII text (most libraries) orders by its bytes, without
        // checking each pair again.
        if self.texts.iter().all(|text| text.is_ascii()) {
            order.sort_unstable_by(|&a, &b| self.texts[a as usize].cmp(&self.texts[b as usize]));
        } else {
            order.sort_unstable_by(|&a, &b| {
                utf16_cmp(&self.texts[a as usize], &self.texts[b as usize])
            });
        }
        self.rank = vec![0; order.len()];
        for (place, n) in order.into_iter().enumerate() {
            self.rank[n as usize] = place as u32;
        }
    }

    fn rank(&self, n: Option<u32>) -> Option<u32> {
        n.map(|n| self.rank[n as usize])
    }
}

/// Folds each distinct lower-cased input once.
struct Folder<'a> {
    seen: HashMap<&'a str, Option<u32>>,
}

impl<'a> Folder<'a> {
    fn fold(&mut self, lower: &'a str, ranks: &mut Ranks) -> Option<u32> {
        if let Some(&n) = self.seen.get(lower) {
            return n;
        }
        let n = fold_value(lower).map(|folded| ranks.number(folded));
        self.seen.insert(lower, n);
        n
    }
}

/// The album a song is filed under: one name and one artist for the whole
/// album (as text numbers), so it stays in one piece even when its songs'
/// tags disagree.
#[derive(Clone, Copy)]
struct Album {
    id: u32,
    name: Option<u32>,
    artist: Option<u32>,
}

fn grouping<'a>(t: &SortTrack<'a>) -> GroupingTrack<'a> {
    GroupingTrack {
        album_id: t.album_id,
        album: t.album_lower,
        artist: t.artist_lower,
        album_artist: t.album_artist_lower,
    }
}

/// Keeps the alphabetically first label (text numbers, compared by text).
fn keep_first(labels: &mut HashMap<u32, u32>, album: u32, label: Option<u32>, ranks: &Ranks) {
    let Some(label) = label else {
        return;
    };
    labels
        .entry(album)
        .and_modify(|current| {
            if utf16_cmp(
                &ranks.texts[label as usize],
                &ranks.texts[*current as usize],
            ) == Ordering::Less
            {
                *current = label;
            }
        })
        .or_insert(label);
}

/// One song with what it is ordered by, as ranks.
#[derive(Clone, Copy)]
struct Key {
    title: u32,
    title_section: u8,
    value: Option<u32>,
    section: u8,
    missing: bool,
    album: Option<Album>,
    artist: Option<u32>,
    album_name: Option<u32>,
}

fn nulls_last_u32(a: Option<u32>, b: Option<u32>) -> Ordering {
    nulls_last(a, b, |x, y| x.cmp(y))
}

/// By title section, then folded title, then the title as written.
fn compare_title(a: &Key, ta: &SortTrack, b: &Key, tb: &SortTrack) -> Ordering {
    a.title_section
        .cmp(&b.title_section)
        .then_with(|| a.title.cmp(&b.title))
        .then_with(|| utf16_cmp(ta.title, tb.title))
}

/// By artist, then album.
fn compare_tags(a: &Key, b: &Key) -> Ordering {
    nulls_last_u32(a.artist, b.artist).then_with(|| nulls_last_u32(a.album_name, b.album_name))
}

/// By album id, so two albums sharing a name never interleave, then disc and
/// track, then title.
fn compare_album_order(a: &Key, ta: &SortTrack, b: &Key, tb: &SortTrack) -> Ordering {
    let (aa, ab) = (a.album.unwrap(), b.album.unwrap());
    aa.id
        .cmp(&ab.id)
        .then_with(|| nulls_last(ta.disc, tb.disc, |x, y| x.cmp(y)))
        .then_with(|| nulls_last(ta.track, tb.track, |x, y| x.cmp(y)))
        .then_with(|| compare_title(a, ta, b, tb))
}

/// One song's folded fields, as text numbers before ranking.
struct Raw {
    title: u32,
    artist: Option<u32>,
    album_name: Option<u32>,
}

/// Orders `tracks` by `field`, filing artist and album orders against the
/// albums of `catalog` (the tracks themselves when it is empty).
///
/// A song missing the sorted-by artist, album or date comes last in either
/// direction. Only the sorted-by value follows the direction; ties stay
/// ascending and end on the uri, so the input order never matters.
pub fn sort_songs(
    tracks: &[SortTrack],
    catalog: &[SortTrack],
    field: SortField,
    descending: bool,
) -> Sorted {
    let files_by_album = matches!(field, SortField::Artist | SortField::Album);
    let mut ranks = Ranks::default();
    let mut folder = Folder {
        seen: HashMap::new(),
    };

    // The album every song is filed under, worked out against the catalog.
    let mut albums: Vec<Album> = Vec::new();
    if files_by_album {
        let source = if catalog.is_empty() { tracks } else { catalog };
        let source_ids = album_ids(&source.iter().map(grouping).collect::<Vec<_>>());
        let mut id_by_uri: HashMap<&str, u32> = HashMap::with_capacity(source.len());
        let mut names: HashMap<u32, u32> = HashMap::new();
        let mut album_artists: HashMap<u32, u32> = HashMap::new();
        let mut track_artists: HashMap<u32, u32> = HashMap::new();
        for (track, id) in source.iter().zip(source_ids) {
            let id = ranks.number(id);
            let name = folder.fold(track.album_lower, &mut ranks);
            let album_artist = folder.fold(track.album_artist_lower, &mut ranks);
            let artist = folder.fold(track.artist_lower, &mut ranks);
            keep_first(&mut names, id, name, &ranks);
            keep_first(&mut album_artists, id, album_artist, &ranks);
            keep_first(&mut track_artists, id, artist, &ranks);
            id_by_uri.insert(track.uri, id);
        }
        // A song the catalog doesn't hold falls back on its own tags.
        let own_ids = if catalog.is_empty() {
            Vec::new()
        } else {
            album_ids(&tracks.iter().map(grouping).collect::<Vec<_>>())
        };
        for (i, track) in tracks.iter().enumerate() {
            let id = match id_by_uri.get(track.uri) {
                Some(&id) => id,
                None => ranks.number(own_ids[i].clone()),
            };
            let name = match names.get(&id) {
                Some(&n) => Some(n),
                None => folder.fold(track.album_lower, &mut ranks),
            };
            let artist = match album_artists.get(&id).or_else(|| track_artists.get(&id)) {
                Some(&n) => Some(n),
                None => folder
                    .fold(track.album_artist_lower, &mut ranks)
                    .or_else(|| folder.fold(track.artist_lower, &mut ranks)),
            };
            albums.push(Album { id, name, artist });
        }
    }

    // Fold every song's fields to text numbers, then rank all the text once.
    let empty = ranks.number(String::new());
    let raw: Vec<Raw> = tracks
        .iter()
        .map(|t| Raw {
            // An ASCII title comes without its lower-cased copy: Dart's
            // `toLowerCase` of ASCII is the ASCII lower case.
            title: if t.title.is_ascii() {
                fold_value(&t.title.to_ascii_lowercase()).map_or(empty, |f| ranks.number(f))
            } else {
                folder.fold(t.title_lower, &mut ranks).unwrap_or(empty)
            },
            artist: folder.fold(t.artist_lower, &mut ranks),
            album_name: folder.fold(t.album_lower, &mut ranks),
        })
        .collect();
    let text_sections: Vec<u8> = ranks.texts.iter().map(|text| section_of(text)).collect();
    ranks.finish();

    let keys: Vec<Key> = raw
        .iter()
        .enumerate()
        .map(|(i, r)| {
            let value_number = match field {
                SortField::Artist => r.artist,
                SortField::Album => albums[i].name,
                SortField::Title | SortField::DateAdded => None,
            };
            let missing = match field {
                SortField::Artist | SortField::Album => value_number.is_none(),
                SortField::DateAdded => tracks[i].added_at.is_none(),
                SortField::Title => false,
            };
            let title_section = text_sections[r.title as usize];
            let section = match field {
                SortField::Title | SortField::DateAdded => title_section,
                _ => value_number.map_or(SECTION_UNKNOWN, |n| text_sections[n as usize]),
            };
            Key {
                title: ranks.rank[r.title as usize],
                title_section,
                value: ranks.rank(value_number),
                section,
                missing,
                album: albums.get(i).map(|a| Album {
                    id: ranks.rank[a.id as usize],
                    name: ranks.rank(a.name),
                    artist: ranks.rank(a.artist),
                }),
                artist: ranks.rank(r.artist),
                album_name: ranks.rank(r.album_name),
            }
        })
        .collect();

    let mut order: Vec<usize> = (0..tracks.len()).collect();
    order.sort_by(|&i, &j| {
        let (a, b) = (&keys[i], &keys[j]);
        let (ta, tb) = (&tracks[i], &tracks[j]);
        if a.missing != b.missing {
            return if a.missing {
                Ordering::Greater
            } else {
                Ordering::Less
            };
        }
        if !a.missing {
            let by_value = match field {
                SortField::Title => compare_title(a, ta, b, tb),
                SortField::Artist | SortField::Album => a
                    .section
                    .cmp(&b.section)
                    .then_with(|| a.value.cmp(&b.value)),
                SortField::DateAdded => ta.added_at.cmp(&tb.added_at),
            };
            let by_value = if descending {
                by_value.reverse()
            } else {
                by_value
            };
            if by_value != Ordering::Equal {
                return by_value;
            }
        }
        let ties = match field {
            SortField::Title => compare_tags(a, b),
            SortField::Artist => nulls_last_u32(a.album.unwrap().name, b.album.unwrap().name)
                .then_with(|| compare_album_order(a, ta, b, tb)),
            SortField::Album => nulls_last_u32(a.album.unwrap().artist, b.album.unwrap().artist)
                .then_with(|| compare_album_order(a, ta, b, tb)),
            SortField::DateAdded => compare_title(a, ta, b, tb).then_with(|| compare_tags(a, b)),
        };
        ties.then_with(|| utf16_cmp(ta.uri, tb.uri))
    });

    let sections = if field == SortField::DateAdded {
        Vec::new()
    } else {
        order.iter().map(|&i| keys[i].section).collect()
    };
    Sorted {
        order: order.into_iter().map(|i| i as u32).collect(),
        sections,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn song<'a>(uri: &'a str, title: &'a str, artist: &'a str, album: &'a str) -> SortTrack<'a> {
        SortTrack {
            uri,
            title,
            title_lower: title,
            artist_lower: artist,
            album_lower: album,
            ..SortTrack::default()
        }
    }

    #[test]
    fn sorts_by_title_with_sections() {
        let tracks = [
            song("u:1", "beta", "", ""),
            song("u:2", "1999", "", ""),
            song("u:3", "alpha", "", ""),
        ];
        let sorted = sort_songs(&tracks, &[], SortField::Title, false);
        // '#' sorts before A, as its string does in Dart.
        assert_eq!(sorted.order, [1, 2, 0]);
        assert_eq!(sorted.sections, [SECTION_OTHER, b'A', b'B']);
    }

    #[test]
    fn songs_without_the_value_come_last_both_ways() {
        let tracks = [
            song("u:1", "a", "", ""),
            song("u:2", "b", "zed", ""),
            song("u:3", "c", "abba", ""),
        ];
        for descending in [false, true] {
            let sorted = sort_songs(&tracks, &[], SortField::Artist, descending);
            assert_eq!(*sorted.order.last().unwrap(), 0, "descending={descending}");
            assert_eq!(*sorted.sections.last().unwrap(), SECTION_UNKNOWN);
        }
    }
}

#[cfg(test)]
mod timing {
    use super::*;

    /// How long the Rust side of a title sort of 200 000 songs takes, without
    /// the copy from Dart. Run with `cargo test --release -- --ignored`.
    #[test]
    #[ignore]
    fn title_sort_of_200k() {
        let titles: Vec<String> = (0..200_000)
            .map(|i| format!("T{} Song", (i * 7919) % 200_000))
            .collect();
        let lower: Vec<String> = titles.iter().map(|t| t.to_lowercase()).collect();
        let uris: Vec<String> = (0..200_000).map(|i| format!("jellyfin:{i}")).collect();
        let tracks: Vec<SortTrack> = (0..200_000)
            .map(|i| SortTrack {
                uri: &uris[i],
                title: &titles[i],
                title_lower: &lower[i],
                artist_lower: "artist",
                album_lower: "album",
                ..SortTrack::default()
            })
            .collect();
        let start = std::time::Instant::now();
        let sorted = sort_songs(&tracks, &[], SortField::Title, false);
        eprintln!("rust title sort: {:?}", start.elapsed());
        assert_eq!(sorted.order.len(), 200_000);
    }
}
