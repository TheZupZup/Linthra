//! Typo tolerance for the library search.
//!
//! A query word that starts no token anywhere in the catalog ("motorhed",
//! "bjrok", "metalica") would rule the whole query out. Such a word is matched
//! instead against tokens a few typos away. A word that does start some token
//! is never matched this way, so a search that finds something today finds
//! exactly the same tracks.
//!
//! The same rule as `lib/core/catalog/search_typos.dart`, held to it by the F
//! and M cases in `test/fixtures/search_cases.txt`, which both replay.
//!
//! Rules, on folded tokens, counted in characters:
//!  - Fewer than 4 characters: no typo allowed. Short words have too many
//!    near neighbours.
//!  - 4 to 6 characters: one typo. 7 or more: two.
//!  - The first character must match.
//!  - A typo is one character inserted, deleted or replaced, or two neighbours
//!    swapped (optimal string alignment distance).
//!  - The word may also be a mistyped start of the token, so "metalic" finds
//!    "metallica" while it is being typed.

/// How many typos a query word of `length` characters may carry.
pub fn max_typos(length: usize) -> usize {
    match length {
        0..=3 => 0,
        4..=6 => 1,
        _ => 2,
    }
}

/// Whether `term` matches `token`, or the start of `token`, within the typos
/// its length allows.
pub fn matches_with_typos(term: &str, token: &str) -> bool {
    let term: Vec<char> = term.chars().collect();
    let token: Vec<char> = token.chars().collect();
    let allowed = max_typos(term.len());
    if allowed == 0 || term.first() != token.first() {
        return false;
    }
    // The whole token, or a start of it as long as the word give or take the
    // typos allowed.
    let shortest = term.len().saturating_sub(allowed).max(1);
    let longest = (term.len() + allowed).min(token.len());
    if token.len() < shortest {
        return false;
    }
    std::iter::once(token.len())
        .chain(shortest..=longest)
        .any(|end| distance(&term, &token[..end]) <= allowed)
}

/// Optimal string alignment distance: insertions, deletions, substitutions
/// and swaps of two neighbours each cost one.
fn distance(a: &[char], b: &[char]) -> usize {
    let width = b.len() + 1;
    let mut d = vec![0usize; (a.len() + 1) * width];
    for (i, row) in d.chunks_mut(width).enumerate() {
        row[0] = i;
    }
    for (j, cell) in d.iter_mut().enumerate().take(width) {
        *cell = j;
    }
    for i in 1..=a.len() {
        for j in 1..=b.len() {
            let cost = usize::from(a[i - 1] != b[j - 1]);
            let mut best = (d[(i - 1) * width + j] + 1)
                .min(d[i * width + j - 1] + 1)
                .min(d[(i - 1) * width + j - 1] + cost);
            if i > 1 && j > 1 && a[i - 1] == b[j - 2] && a[i - 2] == b[j - 1] {
                best = best.min(d[(i - 2) * width + j - 2] + 1);
            }
            d[i * width + j] = best;
        }
    }
    d[a.len() * width + b.len()]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn counts_a_swap_as_one_typo() {
        let chars = |s: &str| s.chars().collect::<Vec<_>>();
        assert_eq!(distance(&chars("bjrok"), &chars("bjork")), 1);
        assert_eq!(distance(&chars("motorhed"), &chars("motorhead")), 1);
        assert_eq!(distance(&chars(""), &chars("abc")), 3);
    }
}
