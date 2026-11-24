//! The order of the search's mixed results: artists, albums and songs in one
//! list, the most relevant first.
//!
//! The same rule as `lib/core/catalog/search_rank.dart`, held to it by the
//! cases in `test/fixtures/search_rank_cases.txt`, which both replay.
//!
//! Each result is judged by its own name (an artist's name, an album's title,
//! a song's title) against the query:
//!
//!  1. `Full`: the name is the query, word for word ("metallica" for
//!     Metallica).
//!  2. `Exact`: every word typed is a whole word of the name.
//!  3. `Prefix`: every word typed starts a word of the name.
//!  4. `Typo`: the same, with a word matched within its typos.
//!  5. `Other`: the name does not match, so the result was found by another
//!     field (a song by its artist or album).
//!
//! Within a tier an artist comes first, then an album, then a song; then the
//! order the results were given in.

use crate::normalize::normalized_tokens;
use crate::typos::matches_with_typos;

/// What a result is. Its order is the order within a tier.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum ResultKind {
    Artist,
    Album,
    Song,
}

/// How well a result's own name matches the query. Its order is the ranking.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum MatchTier {
    Full,
    Exact,
    Prefix,
    Typo,
    Other,
}

/// How [name] matches the query cut into [terms].
pub fn name_tier(terms: &[String], name: &str) -> MatchTier {
    if terms.is_empty() {
        return MatchTier::Other;
    }
    let tokens = normalized_tokens(name);
    let starts = |term: &String| tokens.iter().any(|token| token.starts_with(term.as_str()));
    if terms.iter().all(starts) {
        if tokens == terms {
            MatchTier::Full
        } else if terms.iter().all(|term| tokens.contains(term)) {
            MatchTier::Exact
        } else {
            MatchTier::Prefix
        }
    } else if terms.iter().all(|term| {
        tokens
            .iter()
            .any(|token| token.starts_with(term.as_str()) || matches_with_typos(term, token))
    }) {
        MatchTier::Typo
    } else {
        MatchTier::Other
    }
}

/// The positions of [results] in the order to show them for [query].
pub fn rank_results(query: &str, results: &[(ResultKind, &str)]) -> Vec<usize> {
    let terms = normalized_tokens(query);
    let mut keyed: Vec<(MatchTier, ResultKind, usize)> = results
        .iter()
        .enumerate()
        .map(|(i, (kind, name))| (name_tier(&terms, name), *kind, i))
        .collect();
    keyed.sort_unstable();
    keyed.into_iter().map(|(_, _, i)| i).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_artist_named_as_typed_comes_before_its_songs() {
        let results = [
            (ResultKind::Song, "Battery"),
            (ResultKind::Album, "Master of Puppets"),
            (ResultKind::Artist, "Metallica"),
        ];
        assert_eq!(rank_results("metallica", &results), [2, 1, 0]);
    }
}
