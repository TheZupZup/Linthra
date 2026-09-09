//! High-performance, dependency-free library primitives for Linthra.
//!
//! The first responsibility of this crate is intentionally narrow: index and
//! search very large music libraries without asking Flutter to walk hundreds of
//! thousands of Dart objects for every query. The public API is platform-neutral
//! so Android/iOS/desktop bindings can be added later without changing the core.

use std::collections::{BTreeMap, HashMap, HashSet};

mod normalize;

use normalize::normalized_tokens;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TrackRecord {
    pub id: String,
    pub title: String,
    pub artist: String,
    pub album: String,
    pub album_artist: Option<String>,
    pub provider: String,
}

impl TrackRecord {
    pub fn new(
        id: impl Into<String>,
        title: impl Into<String>,
        artist: impl Into<String>,
        album: impl Into<String>,
        album_artist: Option<String>,
        provider: impl Into<String>,
    ) -> Self {
        Self {
            id: id.into(),
            title: title.into(),
            artist: artist.into(),
            album: album.into(),
            album_artist,
            provider: provider.into(),
        }
    }
}

#[derive(Clone, Copy, Debug)]
struct Posting {
    track_index: usize,
    weight: u16,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SearchHit<'a> {
    pub track: &'a TrackRecord,
    pub score: u32,
}

/// Immutable inverted index designed for fast repeated searches.
///
/// Tokens live in a BTreeMap rather than a HashMap because the ordered keyspace
/// makes prefix lookup (`metal` → `metallica`) logarithmic to enter and linear
/// only in the number of matching tokens. Query work therefore scales with the
/// relevant postings, not the full catalog size.
pub struct LibraryIndex {
    tracks: Vec<TrackRecord>,
    postings: BTreeMap<String, Vec<Posting>>,
}

impl LibraryIndex {
    pub fn build(tracks: Vec<TrackRecord>) -> Self {
        let mut postings: BTreeMap<String, Vec<Posting>> = BTreeMap::new();

        for (track_index, track) in tracks.iter().enumerate() {
            index_field(&mut postings, track_index, &track.title, 12);
            index_field(&mut postings, track_index, &track.artist, 8);
            index_field(&mut postings, track_index, &track.album, 5);
            if let Some(album_artist) = &track.album_artist {
                index_field(&mut postings, track_index, album_artist, 6);
            }
            // Provider is intentionally searchable at a low weight. It makes
            // diagnostics/power-user searches useful without outranking music
            // metadata (e.g. "navidrome halo").
            index_field(&mut postings, track_index, &track.provider, 2);
        }

        Self { tracks, postings }
    }

    pub fn len(&self) -> usize {
        self.tracks.len()
    }

    pub fn is_empty(&self) -> bool {
        self.tracks.is_empty()
    }

    /// Searches using AND semantics across query terms and prefix semantics
    /// within each term. Results are ranked by field importance and exact-token
    /// matches, then deterministically by title/id/provider/index for stable UI
    /// ordering even when providers expose otherwise-identical copies.
    pub fn search(&self, query: &str, limit: usize) -> Vec<SearchHit<'_>> {
        if limit == 0 || self.tracks.is_empty() {
            return Vec::new();
        }

        let terms = normalized_tokens(query);
        if terms.is_empty() {
            return Vec::new();
        }

        // Evaluate the rarest query token first. A common token such as
        // "album" can have a posting for every track in a 200k catalog; making
        // a 200k-entry HashMap for that before seeing a selective token such as
        // "199421" wastes both CPU and memory. Counting posting lengths is
        // cheap, then subsequent common terms only retain scores for candidates
        // that already survived the selective terms.
        let mut planned_terms: Vec<(String, usize)> = terms
            .into_iter()
            .map(|term| {
                let estimated_postings = self.estimated_postings(&term);
                (term, estimated_postings)
            })
            .collect();
        if planned_terms.iter().any(|(_, count)| *count == 0) {
            return Vec::new();
        }
        planned_terms.sort_unstable_by_key(|(_, count)| *count);

        let mut candidates: Option<HashMap<usize, u32>> = None;

        for (term, _) in planned_terms {
            let mut best_for_term: HashMap<usize, u16> = match &candidates {
                Some(current) => HashMap::with_capacity(current.len()),
                None => HashMap::new(),
            };

            for (token, token_postings) in self.postings.range(term.clone()..) {
                if !token.starts_with(&term) {
                    break;
                }
                let exact_bonus: u16 = if token == &term { 3 } else { 0 };
                for posting in token_postings {
                    // After the first (most selective) term, never materialize
                    // scores for tracks that have already been eliminated.
                    if let Some(current) = &candidates {
                        if !current.contains_key(&posting.track_index) {
                            continue;
                        }
                    }

                    let score = posting.weight.saturating_add(exact_bonus);
                    best_for_term
                        .entry(posting.track_index)
                        .and_modify(|best| *best = (*best).max(score))
                        .or_insert(score);
                }
            }

            if best_for_term.is_empty() {
                return Vec::new();
            }

            candidates = Some(match candidates {
                None => best_for_term
                    .into_iter()
                    .map(|(index, score)| (index, u32::from(score)))
                    .collect(),
                Some(mut current) => {
                    current.retain(|index, total| {
                        if let Some(score) = best_for_term.get(index) {
                            *total += u32::from(*score);
                            true
                        } else {
                            false
                        }
                    });
                    if current.is_empty() {
                        return Vec::new();
                    }
                    current
                }
            });
        }

        let mut ranked: Vec<(usize, u32)> = candidates.unwrap_or_default().into_iter().collect();
        ranked.sort_unstable_by(|(left_index, left_score), (right_index, right_score)| {
            right_score
                .cmp(left_score)
                .then_with(|| {
                    self.tracks[*left_index]
                        .title
                        .cmp(&self.tracks[*right_index].title)
                })
                .then_with(|| {
                    self.tracks[*left_index]
                        .id
                        .cmp(&self.tracks[*right_index].id)
                })
                .then_with(|| {
                    self.tracks[*left_index]
                        .provider
                        .cmp(&self.tracks[*right_index].provider)
                })
                .then_with(|| left_index.cmp(right_index))
        });
        ranked.truncate(limit);

        ranked
            .into_iter()
            .map(|(track_index, score)| SearchHit {
                track: &self.tracks[track_index],
                score,
            })
            .collect()
    }

    fn estimated_postings(&self, term: &str) -> usize {
        let mut count = 0usize;
        for (token, token_postings) in self.postings.range(term.to_owned()..) {
            if !token.starts_with(term) {
                break;
            }
            count = count.saturating_add(token_postings.len());
        }
        count
    }
}

fn index_field(
    postings: &mut BTreeMap<String, Vec<Posting>>,
    track_index: usize,
    value: &str,
    weight: u16,
) {
    // Deduplicate within one field so "Very Very Good" does not artificially
    // outrank another track merely because a token is repeated in its metadata.
    let unique: HashSet<String> = normalized_tokens(value).into_iter().collect();
    for token in unique {
        postings.entry(token).or_default().push(Posting {
            track_index,
            weight,
        });
    }
}

#[cfg(test)]
mod tests {
    use super::{LibraryIndex, SearchHit, TrackRecord};

    fn fixture() -> LibraryIndex {
        LibraryIndex::build(vec![
            TrackRecord::new(
                "1",
                "Master of Puppets",
                "Metallica",
                "Master of Puppets",
                Some("Metallica".into()),
                "navidrome",
            ),
            TrackRecord::new(
                "2",
                "Battery",
                "Metallica",
                "Master of Puppets",
                Some("Metallica".into()),
                "jellyfin",
            ),
            TrackRecord::new(
                "3",
                "Master Blaster",
                "Stevie Wonder",
                "Hotter than July",
                None,
                "local",
            ),
        ])
    }

    #[test]
    fn exact_multi_term_search_prefers_title_and_artist() {
        let index = fixture();
        let hits = index.search("metallica master", 10);
        assert_eq!(hits.len(), 2);
        assert_eq!(hits[0].track.id, "1");
    }

    #[test]
    fn prefix_search_does_not_scan_for_an_exact_full_word() {
        let index = fixture();
        let hits = index.search("met mast", 10);
        assert_eq!(hits.len(), 2);
        assert_eq!(hits[0].track.id, "1");
    }

    #[test]
    fn query_terms_have_and_semantics() {
        let index = fixture();
        let hits = index.search("stevie puppets", 10);
        assert!(hits.is_empty());
    }

    #[test]
    fn provider_can_be_used_as_a_low_weight_filter_term() {
        let index = fixture();
        let hits = index.search("jellyfin battery", 10);
        assert_eq!(hits.len(), 1);
        assert_eq!(hits[0].track.id, "2");
    }

    /// A catalog whose metadata is deliberately awkward: accents, a ligature,
    /// a sharp s, a decomposed name, and two non-Latin scripts.
    fn accented_fixture() -> LibraryIndex {
        LibraryIndex::build(vec![
            TrackRecord::new("a1", "Jóga", "Björk", "Homogenic", None, "local"),
            TrackRecord::new(
                "a2",
                "Ace of Spades",
                "Motörhead",
                "Ace of Spades",
                None,
                "local",
            ),
            TrackRecord::new(
                "a3",
                "Halo",
                "Beyoncé",
                "I Am… Sasha Fierce",
                None,
                "jellyfin",
            ),
            TrackRecord::new(
                "a4",
                "Straße der Ohren",
                "Einstürzende Neubauten",
                "Tabula Rasa",
                None,
                "local",
            ),
            // Written decomposed on purpose (o + U+0308), the way some servers
            // and filesystems hand it over.
            TrackRecord::new(
                "a5",
                "Kickstart My Heart",
                "Mo\u{0308}tley Cru\u{0308}e",
                "Dr. Feelgood",
                None,
                "local",
            ),
            TrackRecord::new("a6", "Группа крови", "Кино", "Группа крови", None, "local"),
        ])
    }

    fn ids<'a>(hits: &'a [SearchHit<'a>]) -> Vec<&'a str> {
        hits.iter().map(|hit| hit.track.id.as_str()).collect()
    }

    // --- #336: accented metadata ------------------------------------------

    #[test]
    fn an_accent_in_the_middle_of_a_name_is_searchable_without_it() {
        // The case a byte-prefix match could never reach: "bjork" is not a
        // prefix of "björk", because the accent comes before the k.
        let index = accented_fixture();
        assert_eq!(ids(&index.search("bjork", 10)), ["a1"]);
        assert_eq!(ids(&index.search("motorhead", 10)), ["a2"]);
    }

    #[test]
    fn typing_the_accent_finds_the_same_track() {
        // Folding both sides is what makes this symmetric: the listener who
        // knows the spelling is not punished for it.
        let index = accented_fixture();
        assert_eq!(index.search("björk", 10), index.search("bjork", 10));
        assert_eq!(
            index.search("beyoncé halo", 10),
            index.search("beyonce halo", 10)
        );
    }

    #[test]
    fn a_sharp_s_is_findable_spelled_out() {
        let index = accented_fixture();
        assert_eq!(ids(&index.search("strasse", 10)), ["a4"]);
        assert_eq!(ids(&index.search("straße", 10)), ["a4"]);
        assert_eq!(ids(&index.search("einsturzende", 10)), ["a4"]);
    }

    #[test]
    fn decomposed_metadata_is_findable_as_one_word() {
        // Before the combining-mark rule this artist indexed as "mo", "tley",
        // "cru" and "e", so the obvious query found nothing.
        let index = accented_fixture();
        assert_eq!(ids(&index.search("motley", 10)), ["a5"]);
        assert_eq!(ids(&index.search("motley crue", 10)), ["a5"]);
        assert_eq!(ids(&index.search("mötley crüe", 10)), ["a5"]);
        assert!(index.search("tley", 10).is_empty());
    }

    #[test]
    fn a_folded_query_still_earns_the_exact_match_bonus() {
        // "bjork" is now the token, not merely a prefix of it, so the artist
        // hit scores as an exact match rather than as a partial one.
        let index = accented_fixture();
        let exact = index.search("bjork", 10);
        let prefix = index.search("bjor", 10);
        assert_eq!(ids(&exact), ["a1"]);
        assert_eq!(ids(&prefix), ["a1"]);
        assert!(exact[0].score > prefix[0].score);
    }

    #[test]
    fn unfolded_scripts_are_still_searchable() {
        let index = accented_fixture();
        assert_eq!(ids(&index.search("кино", 10)), ["a6"]);
        assert_eq!(ids(&index.search("Кино", 10)), ["a6"]);
    }

    #[test]
    fn folding_does_not_merge_two_different_artists() {
        // Folding is not fuzzy matching: it removes accents, it does not make
        // near-misses match.
        let index = accented_fixture();
        assert!(index.search("bjor k", 10).is_empty());
        assert!(index.search("motorhed", 10).is_empty());
    }

    // --- #343: search edge cases -------------------------------------------

    #[test]
    fn a_query_with_no_tokens_returns_nothing() {
        let index = fixture();
        assert!(index.search("", 10).is_empty());
        assert!(index.search("   ", 10).is_empty());
        assert!(index.search("!!! --- ???", 10).is_empty());
        assert!(index.search("\u{0301}", 10).is_empty());
    }

    #[test]
    fn a_zero_limit_returns_nothing_without_doing_the_work() {
        let index = fixture();
        assert!(index.search("metallica", 0).is_empty());
    }

    #[test]
    fn a_limit_larger_than_the_result_set_returns_everything_it_has() {
        let index = fixture();
        let hits = index.search("metallica", usize::MAX);
        assert_eq!(hits.len(), 2);
    }

    #[test]
    fn a_limit_smaller_than_the_result_set_keeps_the_best_ranked() {
        let index = fixture();
        let all = index.search("metallica", 10);
        let capped = index.search("metallica", 1);
        assert_eq!(capped.len(), 1);
        assert_eq!(capped[0].track.id, all[0].track.id);
    }

    #[test]
    fn searching_an_empty_index_returns_nothing() {
        let index = LibraryIndex::build(Vec::new());
        assert!(index.is_empty());
        assert_eq!(index.len(), 0);
        assert!(index.search("anything", 10).is_empty());
    }

    #[test]
    fn one_unmatched_term_eliminates_the_whole_query() {
        // AND semantics: a term nothing matches is not silently dropped.
        let index = fixture();
        assert!(!index.search("metallica", 10).is_empty());
        assert!(index.search("metallica zzzzz", 10).is_empty());
        assert!(index.search("zzzzz metallica", 10).is_empty());
    }

    #[test]
    fn a_term_longer_than_any_token_matches_nothing() {
        let index = fixture();
        assert!(index.search("metallicaaaaaaaa", 10).is_empty());
    }

    #[test]
    fn surrounding_and_repeated_whitespace_does_not_change_the_result() {
        let index = fixture();
        let plain = index.search("metallica master", 10);
        assert_eq!(index.search("  metallica   master  ", 10), plain);
        assert_eq!(index.search("\tmetallica\nmaster\r\n", 10), plain);
    }

    #[test]
    fn punctuation_inside_a_query_only_separates_terms() {
        let index = fixture();
        let plain = index.search("metallica master", 10);
        assert_eq!(index.search("metallica, master!", 10), plain);
        assert_eq!(index.search("metallica/master", 10), plain);
    }

    #[test]
    fn repeating_a_term_does_not_reorder_the_results() {
        // The repeat adds the same weight to every candidate, so the ranking
        // has to come out identical even though the scores are larger.
        let index = fixture();
        let once = index.search("master", 10);
        let twice = index.search("master master", 10);
        assert_eq!(ids(&once), ids(&twice));
        assert!(twice[0].score > once[0].score);
    }

    #[test]
    fn a_term_that_is_a_prefix_of_another_term_still_ands() {
        let index = fixture();
        let hits = index.search("mast master", 10);
        assert_eq!(ids(&hits), ids(&index.search("master", 10)));
    }

    #[test]
    fn an_absurdly_long_query_is_handled_without_panicking() {
        let index = fixture();
        let long_term = "a".repeat(100_000);
        assert!(index.search(&long_term, 10).is_empty());
        let many_terms = vec!["master"; 5_000].join(" ");
        assert_eq!(
            ids(&index.search(&many_terms, 10)),
            ids(&index.search("master", 10))
        );
    }

    #[test]
    fn blank_metadata_indexes_and_searches_without_panicking() {
        let index = LibraryIndex::build(vec![
            TrackRecord::new("", "", "", "", None, ""),
            TrackRecord::new("b", "Real Title", "", "", Some(String::new()), "local"),
        ]);
        assert_eq!(index.len(), 2);
        assert!(index.search("", 10).is_empty());
        assert_eq!(ids(&index.search("real", 10)), ["b"]);
    }

    #[test]
    fn emoji_and_symbols_in_metadata_do_not_break_the_index() {
        let index = LibraryIndex::build(vec![TrackRecord::new(
            "e1",
            "🎵 Sunrise 🎵",
            "The ✨ Band",
            "Vol. 1",
            None,
            "local",
        )]);
        assert_eq!(ids(&index.search("sunrise", 10)), ["e1"]);
        assert_eq!(ids(&index.search("band", 10)), ["e1"]);
        assert!(index.search("🎵", 10).is_empty());
    }

    #[test]
    fn identical_title_and_id_records_have_a_total_provider_order() {
        let index = LibraryIndex::build(vec![
            TrackRecord::new(
                "same-id",
                "Same Song",
                "Same Artist",
                "Same Album",
                None,
                "plex",
            ),
            TrackRecord::new(
                "same-id",
                "Same Song",
                "Same Artist",
                "Same Album",
                None,
                "jellyfin",
            ),
        ]);

        let hits = index.search("same song", 10);
        assert_eq!(hits.len(), 2);
        assert_eq!(hits[0].track.provider, "jellyfin");
        assert_eq!(hits[1].track.provider, "plex");
    }
}
