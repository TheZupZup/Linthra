//! Album and artist grouping for the Library, the same rules as
//! `lib/core/catalog/library_grouping.dart`.
//!
//! The ids made here are the ids the app routes on and hands to Android Auto,
//! and the Dart side keeps computing them one track at a time
//! (`albumIdForTrack`, `artistIdForTrack`), so they have to match byte for
//! byte. Three Dart behaviours are reproduced on purpose:
//!
//! - Text arrives already lower-cased by Dart's `String.toLowerCase`. Dart's
//!   case table is not Rust's (it maps `İ` to a plain `i`, and leaves some
//!   newer Unicode letters alone), so lower-casing here would split albums
//!   the Dart side keeps together. [fold] does the rest of `foldText`.
//! - Trimming uses the characters Dart's `String.trim` removes, which include
//!   U+FEFF, unlike [char::is_whitespace].
//! - Strings compare by UTF-16 code unit, and lengths count UTF-16 code units,
//!   the way Dart's `compareTo` and `length` do.

use std::cmp::Ordering;
use std::collections::HashMap;

/// Display label for tracks with no album metadata, folded.
const UNKNOWN_ALBUM_FOLDED: &str = "unknown album";
/// Display label for tracks with no artist metadata, folded.
const UNKNOWN_ARTIST_FOLDED: &str = "unknown artist";
const UNKNOWN_ARTIST_ID: &str = "unknown-artist";

/// One track as grouping sees it. The three names are lower-cased by Dart;
/// `album_id` is the source's raw album id, empty when it has none.
#[derive(Clone, Copy, Debug, Default)]
pub struct GroupingTrack<'a> {
    pub album_id: &'a str,
    pub album: &'a str,
    pub artist: &'a str,
    pub album_artist: &'a str,
}

/// One album, with the tracks that label it named by their position in the
/// input, so the caller reads the display strings from its own copy.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AlbumGroup {
    pub id: String,
    /// First track with a non-empty album title.
    pub title_track: Option<usize>,
    /// First track with a non-blank album artist.
    pub album_artist_track: Option<usize>,
    /// First track with a non-blank artist.
    pub artist_track: Option<usize>,
    pub track_count: usize,
}

/// One artist, labelled like [AlbumGroup].
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ArtistGroup {
    pub id: String,
    /// First track with a non-empty artist.
    pub name_track: Option<usize>,
    pub album_count: usize,
    pub track_count: usize,
}

/// Albums and artists in display order, and where each input track landed.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct LibraryGroups {
    pub albums: Vec<AlbumGroup>,
    pub artists: Vec<ArtistGroup>,
    /// For each input track, its album's position in [LibraryGroups::albums].
    pub track_album: Vec<u32>,
    /// For each input track, its artist's position in [LibraryGroups::artists].
    pub track_artist: Vec<u32>,
}

/// Groups `tracks` into albums sorted by title, artist, then id, and artists
/// sorted by name, then id.
pub fn group(tracks: &[GroupingTrack]) -> LibraryGroups {
    let mut names = Names::default();
    let folded: Vec<FoldedTrack> = tracks.iter().map(|t| names.track(t)).collect();

    let mut album_slots: HashMap<AlbumKey, usize> = HashMap::new();
    let mut albums: Vec<AlbumBuild> = Vec::new();
    let mut track_album = Vec::with_capacity(tracks.len());
    for (i, track) in folded.iter().enumerate() {
        let key = track.album_key(&names);
        let slot = *album_slots.entry(key).or_insert_with(|| {
            albums.push(AlbumBuild::new(key));
            albums.len() - 1
        });
        albums[slot].add(i, track);
        track_album.push(slot);
    }

    // Artists are keyed by their folded name alone, and folded names are
    // numbered densely, so a plain vector finds each artist's slot.
    let mut artist_slots: Vec<Option<usize>> = vec![None; names.folded.len()];
    let mut artists: Vec<ArtistBuild> = Vec::new();
    let mut track_artist = Vec::with_capacity(tracks.len());
    for (i, track) in folded.iter().enumerate() {
        let slot = *artist_slots[track.artist as usize].get_or_insert_with(|| {
            artists.push(ArtistBuild::new(track.artist));
            artists.len() - 1
        });
        artists[slot].add(i, track, track_album[i]);
        track_artist.push(slot);
    }

    let album_ids: Vec<String> = albums.iter().map(|a| a.key.id(&names)).collect();
    let artist_ids: Vec<String> = artists
        .iter()
        .map(|a| artist_id(names.text(a.name)))
        .collect();
    let album_order = sorted(albums.len(), |s| {
        albums[s].sort_key(&folded, &names, &album_ids[s])
    });
    let artist_order = sorted(artists.len(), |s| {
        artists[s].sort_key(&folded, &names, &artist_ids[s])
    });
    let album_rank = ranks(&album_order);
    let artist_rank = ranks(&artist_order);

    LibraryGroups {
        track_album: track_album.iter().map(|&s| album_rank[s]).collect(),
        track_artist: track_artist.iter().map(|&s| artist_rank[s]).collect(),
        albums: album_order
            .into_iter()
            .map(|s| albums[s].finish(&album_ids[s]))
            .collect(),
        artists: artist_order
            .into_iter()
            .map(|s| artists[s].finish(&artist_ids[s]))
            .collect(),
    }
}

/// The rest of Dart's `foldText` once the text is lower-cased: runs of space,
/// tab, CR and LF become one space, common Latin diacritics fold to their base
/// letter, and the ends are trimmed as Dart's `trim` does.
pub fn fold(lower: &str) -> String {
    let mut out = String::with_capacity(lower.len());
    let mut last_was_space = false;
    for ch in lower.chars() {
        if matches!(ch, ' ' | '\t' | '\n' | '\r') {
            if !last_was_space {
                out.push(' ');
                last_was_space = true;
            }
            continue;
        }
        last_was_space = false;
        match diacritic(ch) {
            Some(base) => out.push_str(base),
            None => out.push(ch),
        }
    }
    dart_trim(&out).to_owned()
}

/// `value` without the leading and trailing characters Dart's `String.trim`
/// removes.
pub fn dart_trim(value: &str) -> &str {
    value.trim_matches(is_dart_whitespace)
}

/// Dart's `String.trim` whitespace: the Unicode White_Space characters plus
/// the byte order mark.
fn is_dart_whitespace(ch: char) -> bool {
    matches!(
        ch,
        '\u{09}'..='\u{0D}'
            | '\u{20}'
            | '\u{85}'
            | '\u{A0}'
            | '\u{1680}'
            | '\u{2000}'..='\u{200A}'
            | '\u{2028}'
            | '\u{2029}'
            | '\u{202F}'
            | '\u{205F}'
            | '\u{3000}'
            | '\u{FEFF}'
    )
}

/// The table in `lib/core/catalog/text_folding.dart`.
fn diacritic(ch: char) -> Option<&'static str> {
    Some(match ch {
        'á' | 'à' | 'â' | 'ä' | 'ã' | 'å' | 'ā' | 'ă' | 'ą' => "a",
        'ç' | 'ć' | 'č' | 'ċ' => "c",
        'ď' | 'đ' => "d",
        'é' | 'è' | 'ê' | 'ë' | 'ē' | 'ė' | 'ę' | 'ě' => "e",
        'ğ' => "g",
        'í' | 'ì' | 'î' | 'ï' | 'ī' | 'į' | 'ı' => "i",
        'ł' | 'ľ' => "l",
        'ñ' | 'ń' | 'ň' => "n",
        'ó' | 'ò' | 'ô' | 'ö' | 'õ' | 'ø' | 'ō' | 'ő' => "o",
        'ŕ' | 'ř' => "r",
        'š' | 'ś' | 'ş' | 'ș' => "s",
        'ť' | 'ț' => "t",
        'ú' | 'ù' | 'û' | 'ü' | 'ū' | 'ů' | 'ű' => "u",
        'ý' | 'ÿ' => "y",
        'ž' | 'ź' | 'ż' => "z",
        'ß' => "ss",
        'œ' => "oe",
        'æ' => "ae",
        _ => return None,
    })
}

/// Every distinct name, folded once. A catalog repeats each album and artist
/// name on many tracks, so most tracks fold nothing and allocate nothing.
#[derive(Default)]
struct Names<'a> {
    /// Lower-cased input text to the number of its folded form.
    by_input: HashMap<&'a str, u32>,
    /// Folded text to its number.
    by_folded: HashMap<String, u32>,
    /// Folded text by number.
    folded: Vec<String>,
    /// Trimmed source album ids, numbered like folded names.
    album_ids: HashMap<&'a str, u32>,
    album_id_text: Vec<&'a str>,
}

impl<'a> Names<'a> {
    fn track(&mut self, track: &GroupingTrack<'a>) -> FoldedTrack {
        let album_id = dart_trim(track.album_id);
        // Lower-casing never turns a character into whitespace or back, so a
        // blank check on the lower-cased text answers for the raw text.
        FoldedTrack {
            album_id: (!album_id.is_empty()).then(|| self.album_id(album_id)),
            album: self.fold(track.album),
            artist: self.fold(track.artist),
            album_artist: self.fold(track.album_artist),
            has_album: !track.album.is_empty(),
            has_artist: !track.artist.is_empty(),
            artist_not_blank: !dart_trim(track.artist).is_empty(),
            album_artist_not_blank: !dart_trim(track.album_artist).is_empty(),
        }
    }

    /// The number of `lower`'s folded form. Two inputs that fold alike (say
    /// "a  b" and "a b") get the same number.
    fn fold(&mut self, lower: &'a str) -> u32 {
        if let Some(&n) = self.by_input.get(lower) {
            return n;
        }
        let folded = fold(lower);
        let next = self.folded.len() as u32;
        let n = *self.by_folded.entry(folded).or_insert_with_key(|text| {
            self.folded.push(text.clone());
            next
        });
        self.by_input.insert(lower, n);
        n
    }

    fn album_id(&mut self, trimmed: &'a str) -> u32 {
        let next = self.album_id_text.len() as u32;
        *self.album_ids.entry(trimmed).or_insert_with(|| {
            self.album_id_text.push(trimmed);
            next
        })
    }

    fn text(&self, folded: u32) -> &str {
        &self.folded[folded as usize]
    }
}

/// A track's names as [Names] numbers, plus which raw fields were present.
struct FoldedTrack {
    album_id: Option<u32>,
    album: u32,
    artist: u32,
    album_artist: u32,
    has_album: bool,
    has_artist: bool,
    artist_not_blank: bool,
    album_artist_not_blank: bool,
}

impl FoldedTrack {
    /// `albumIdForTrack`'s tiers: the source's album id, else album + album
    /// artist, else album + artist, else the artist's Unknown Album.
    fn album_key(&self, names: &Names) -> AlbumKey {
        if let Some(id) = self.album_id {
            AlbumKey::Source(id)
        } else if names.text(self.album).is_empty() {
            AlbumKey::Unknown(self.artist)
        } else if !names.text(self.album_artist).is_empty() {
            AlbumKey::AlbumArtist(self.album, self.album_artist)
        } else {
            AlbumKey::Artist(self.album, self.artist)
        }
    }
}

/// One album's identity, as [Names] numbers. Equal keys are exactly equal
/// album ids, without building the id for every track.
#[derive(Clone, Copy, PartialEq, Eq, Hash)]
enum AlbumKey {
    Source(u32),
    Unknown(u32),
    AlbumArtist(u32, u32),
    Artist(u32, u32),
}

impl AlbumKey {
    /// The id `albumIdForTrack` gives this album.
    fn id(self, names: &Names) -> String {
        let key = match self {
            AlbumKey::Source(id) => format!("id:{}", names.album_id_text[id as usize]),
            AlbumKey::Unknown(artist) => format!("un:{}", names.text(artist)),
            AlbumKey::AlbumArtist(album, artist) => {
                format!("aa:{}", album_key(names.text(album), names.text(artist)))
            }
            AlbumKey::Artist(album, artist) => {
                format!("ar:{}", album_key(names.text(album), names.text(artist)))
            }
        };
        format!("al-{}", base64url(key.as_bytes()))
    }
}

/// `_albumKey`: the album's length (in UTF-16 code units, like Dart) keeps the
/// pair unambiguous whatever the title contains.
fn album_key(album: &str, artist: &str) -> String {
    format!("{}|{album}|{artist}", album.encode_utf16().count())
}

/// `artistIdForTrack`.
fn artist_id(folded_artist: &str) -> String {
    if folded_artist.is_empty() {
        UNKNOWN_ARTIST_ID.to_owned()
    } else {
        format!("ar-{}", base64url(folded_artist.as_bytes()))
    }
}

/// Dart's `base64Url.encode` with the `=` padding removed.
fn base64url(bytes: &[u8]) -> String {
    const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        let b = [
            chunk[0],
            *chunk.get(1).unwrap_or(&0),
            *chunk.get(2).unwrap_or(&0),
        ];
        let n = (u32::from(b[0]) << 16) | (u32::from(b[1]) << 8) | u32::from(b[2]);
        for i in 0..=chunk.len() {
            out.push(ALPHABET[(n >> (18 - 6 * i) & 63) as usize] as char);
        }
    }
    out
}

struct AlbumBuild {
    key: AlbumKey,
    title_track: Option<usize>,
    album_artist_track: Option<usize>,
    artist_track: Option<usize>,
    track_count: usize,
}

impl AlbumBuild {
    fn new(key: AlbumKey) -> Self {
        Self {
            key,
            title_track: None,
            album_artist_track: None,
            artist_track: None,
            track_count: 0,
        }
    }

    /// `_AlbumAgg.add`: the first track to supply each label keeps it.
    fn add(&mut self, index: usize, track: &FoldedTrack) {
        self.track_count += 1;
        if self.title_track.is_none() && track.has_album {
            self.title_track = Some(index);
        }
        if self.album_artist_track.is_none() && track.album_artist_not_blank {
            self.album_artist_track = Some(index);
        }
        if self.artist_track.is_none() && track.artist_not_blank {
            self.artist_track = Some(index);
        }
    }

    /// `_albumCompare`'s keys: the folded title (or "Unknown Album"), the
    /// folded artist label (the album artist when any track has one), the id.
    fn sort_key<'n>(
        &self,
        tracks: &[FoldedTrack],
        names: &'n Names,
        id: &'n str,
    ) -> [Utf16Order<'n>; 3] {
        let title = match self.title_track {
            Some(i) => names.text(tracks[i].album),
            None => UNKNOWN_ALBUM_FOLDED,
        };
        let artist = match (self.album_artist_track, self.artist_track) {
            (Some(i), _) => names.text(tracks[i].album_artist),
            (None, Some(i)) => names.text(tracks[i].artist),
            (None, None) => "",
        };
        [Utf16Order(title), Utf16Order(artist), Utf16Order(id)]
    }

    fn finish(&self, id: &str) -> AlbumGroup {
        AlbumGroup {
            id: id.to_owned(),
            title_track: self.title_track,
            album_artist_track: self.album_artist_track,
            artist_track: self.artist_track,
            track_count: self.track_count,
        }
    }
}

struct ArtistBuild {
    /// The folded name, as a [Names] number.
    name: u32,
    name_track: Option<usize>,
    albums: Vec<usize>,
    track_count: usize,
}

impl ArtistBuild {
    fn new(name: u32) -> Self {
        Self {
            name,
            name_track: None,
            albums: Vec::new(),
            track_count: 0,
        }
    }

    /// `_ArtistAgg.add`.
    fn add(&mut self, index: usize, track: &FoldedTrack, album_slot: usize) {
        self.track_count += 1;
        if self.name_track.is_none() && track.has_artist {
            self.name_track = Some(index);
        }
        self.albums.push(album_slot);
    }

    /// `_artistCompare`'s keys: the folded name (or "Unknown Artist"), the id.
    fn sort_key<'n>(
        &self,
        tracks: &[FoldedTrack],
        names: &'n Names,
        id: &'n str,
    ) -> [Utf16Order<'n>; 2] {
        let name = match self.name_track {
            Some(i) => names.text(tracks[i].artist),
            None => UNKNOWN_ARTIST_FOLDED,
        };
        [Utf16Order(name), Utf16Order(id)]
    }

    fn finish(&self, id: &str) -> ArtistGroup {
        let mut albums = self.albums.clone();
        albums.sort_unstable();
        albums.dedup();
        ArtistGroup {
            id: id.to_owned(),
            name_track: self.name_track,
            album_count: albums.len(),
            track_count: self.track_count,
        }
    }
}

/// Text ordered the way Dart's `String.compareTo` orders it: by UTF-16 code
/// unit.
///
/// That is code point order (which UTF-8 bytes already follow) except where a
/// character above U+FFFF meets one in U+E000..=U+FFFF: in UTF-16 the first
/// starts with a surrogate (U+D800..=U+DBFF) and sorts before the second.
#[derive(PartialEq, Eq)]
struct Utf16Order<'a>(&'a str);

impl Ord for Utf16Order<'_> {
    fn cmp(&self, other: &Self) -> Ordering {
        let (a, b) = (self.0.as_bytes(), other.0.as_bytes());
        let Some(at) = a.iter().zip(b).position(|(x, y)| x != y) else {
            return a.len().cmp(&b.len());
        };
        // The shared prefix ends on the same boundary in both strings, so the
        // first differing characters start at the same place.
        let start = (0..=at)
            .rev()
            .find(|&i| self.0.is_char_boundary(i))
            .unwrap_or(0);
        let first = |text: &str| text[start..].chars().next().map(utf16_units);
        first(self.0).cmp(&first(other.0))
    }
}

impl PartialOrd for Utf16Order<'_> {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

/// `ch` as one or two UTF-16 code units, in an order-preserving pair.
fn utf16_units(ch: char) -> (u16, u16) {
    let mut units = [0u16; 2];
    let encoded = ch.encode_utf16(&mut units);
    (encoded[0], *encoded.get(1).unwrap_or(&0))
}

/// The slots `0..len` in the order of their keys. Ids are unique, so
/// the keys are too and the order is total.
fn sorted<K: Ord>(len: usize, key: impl Fn(usize) -> K) -> Vec<usize> {
    let keys: Vec<K> = (0..len).map(key).collect();
    let mut order: Vec<usize> = (0..len).collect();
    order.sort_unstable_by(|&a, &b| keys[a].cmp(&keys[b]));
    order
}

/// The inverse of `order`: where each slot ended up.
fn ranks(order: &[usize]) -> Vec<u32> {
    let mut rank = vec![0u32; order.len()];
    for (position, &slot) in order.iter().enumerate() {
        rank[slot] = position as u32;
    }
    rank
}

#[cfg(test)]
mod tests {
    use super::*;

    fn track<'a>(album: &'a str, artist: &'a str) -> GroupingTrack<'a> {
        GroupingTrack {
            album,
            artist,
            ..GroupingTrack::default()
        }
    }

    #[test]
    fn base64url_matches_dart_without_padding() {
        assert_eq!(base64url(b""), "");
        assert_eq!(base64url(b"f"), "Zg");
        assert_eq!(base64url(b"fo"), "Zm8");
        assert_eq!(base64url(b"foo"), "Zm9v");
        assert_eq!(base64url(&[0xfb, 0xff]), "-_8");
    }

    #[test]
    fn fold_collapses_whitespace_folds_accents_and_trims_like_dart() {
        assert_eq!(fold("  the   café \t\n"), "the cafe");
        assert_eq!(fold("straße"), "strasse");
        assert_eq!(fold("\u{feff}björk\u{a0}"), "bjork");
        // Only space, tab, CR and LF collapse; an inner no-break space stays.
        assert_eq!(fold("a\u{a0}\u{a0}b"), "a\u{a0}\u{a0}b");
        assert_eq!(fold("\u{3000}"), "");
    }

    #[test]
    fn ids_match_the_dart_tiers() {
        // Values computed with albumIdForTrack / artistIdForTrack in Dart.
        let groups = group(&[
            GroupingTrack {
                album_id: " jellyfin:al-1 ",
                album: "x",
                artist: "y",
                album_artist: "",
            },
            GroupingTrack {
                album_artist: "various",
                ..track("hits", "abba")
            },
            track("hits", "abba"),
            track("", "abba"),
            track("", ""),
        ]);
        let ids: Vec<&str> = groups.albums.iter().map(|a| a.id.as_str()).collect();
        assert_eq!(
            ids,
            [
                // ar:4|hits|abba
                "al-YXI6NHxoaXRzfGFiYmE",
                // aa:4|hits|various
                "al-YWE6NHxoaXRzfHZhcmlvdXM",
                // un: (Unknown Album of the Unknown Artist)
                "al-dW46",
                // un:abba
                "al-dW46YWJiYQ",
                // id:jellyfin:al-1
                "al-aWQ6amVsbHlmaW46YWwtMQ",
            ]
        );
        let artists: Vec<&str> = groups.artists.iter().map(|a| a.id.as_str()).collect();
        assert_eq!(artists, ["ar-YWJiYQ", "unknown-artist", "ar-eQ"]);
    }

    #[test]
    fn album_key_counts_utf16_units() {
        // "𝄞" is one char but two UTF-16 code units in Dart.
        assert_eq!(album_key("𝄞", "a"), "2|𝄞|a");
    }

    #[test]
    fn labels_come_from_the_first_track_that_has_them() {
        let groups = group(&[
            GroupingTrack {
                album_id: "al",
                album: "",
                artist: "  ",
                album_artist: "",
            },
            GroupingTrack {
                album_id: "al",
                album: "record",
                artist: "guest",
                album_artist: "",
            },
            GroupingTrack {
                album_id: "al",
                album: "other",
                artist: "main",
                album_artist: "main",
            },
        ]);
        assert_eq!(
            groups.albums,
            [AlbumGroup {
                id: "al-aWQ6YWw".to_owned(),
                title_track: Some(1),
                album_artist_track: Some(2),
                artist_track: Some(1),
                track_count: 3,
            }]
        );
        // "  " is a non-empty artist, so it names the artist group, which
        // folds to the Unknown Artist.
        assert_eq!(groups.artists[0].id, "unknown-artist");
        assert_eq!(groups.artists[0].name_track, Some(0));
    }

    #[test]
    fn artists_count_distinct_albums() {
        let groups = group(&[
            track("one", "abba"),
            track("one", "abba"),
            track("two", "abba"),
        ]);
        assert_eq!(groups.artists.len(), 1);
        assert_eq!(groups.artists[0].album_count, 2);
        assert_eq!(groups.artists[0].track_count, 3);
    }

    #[test]
    fn order_is_by_title_then_artist_then_id_in_utf16_order() {
        let groups = group(&[
            track("b", "x"),
            track("a", "z"),
            track("a", "y"),
            // U+FF5E sorts before U+1F3B5 by code point, but after it in
            // UTF-16, where the emoji starts with the surrogate U+D83C.
            track("\u{1f3b5}", "x"),
            track("\u{ff5e}", "x"),
        ]);
        let titles: Vec<usize> = groups
            .albums
            .iter()
            .map(|a| a.title_track.unwrap())
            .collect();
        assert_eq!(titles, [2, 1, 0, 3, 4]);
        assert_eq!(groups.track_album, [2, 1, 0, 3, 4]);
    }

    #[test]
    fn every_track_points_at_its_groups() {
        let tracks = [track("one", "a"), track("two", "b"), track("one", "a")];
        let groups = group(&tracks);
        assert_eq!(groups.track_album[0], groups.track_album[2]);
        assert_ne!(groups.track_album[0], groups.track_album[1]);
        assert_eq!(groups.track_artist[0], groups.track_artist[2]);
        assert_eq!(groups.artists.len(), 2);
    }

    #[test]
    fn utf16_order_matches_comparing_utf16_units() {
        let samples = [
            "",
            "a",
            "ab",
            "b",
            "é",
            "e\u{301}",
            "\u{e000}",
            "\u{ff5e}",
            "\u{fffd}",
            "\u{10000}",
            "\u{1f3b5}",
            "\u{1f3b6}",
            "\u{1d11e}",
            "a\u{1f3b5}",
            "a\u{ff5e}",
            "\u{d7ff}",
            "z\u{10ffff}",
            "\u{7ff}",
            "\u{800}",
        ];
        for a in samples {
            for b in samples {
                let expected = a.encode_utf16().cmp(b.encode_utf16());
                assert_eq!(
                    Utf16Order(a).cmp(&Utf16Order(b)),
                    expected,
                    "{a:?} vs {b:?}"
                );
            }
        }
    }

    #[test]
    fn empty_input_is_empty() {
        assert_eq!(group(&[]), LibraryGroups::default());
    }
}
