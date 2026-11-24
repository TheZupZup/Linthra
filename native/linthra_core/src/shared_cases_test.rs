//! Replays test/fixtures/search_cases.txt, the cases the Dart fallback
//! (test/core/catalog/search_shared_cases_test.dart) replays too. See the
//! file's header for the format.

use crate::normalize::normalized_tokens;
use crate::{LibraryIndex, TrackRecord};

const CASES: &str = include_str!("../../../test/fixtures/search_cases.txt");

/// Undoes the fixture's escapes: \t, \n, \\ and \u{HEX}.
fn unescape(field: &str) -> String {
    let mut out = String::new();
    let mut chars = field.chars();
    while let Some(c) = chars.next() {
        if c != '\\' {
            out.push(c);
            continue;
        }
        match chars.next() {
            Some('t') => out.push('\t'),
            Some('n') => out.push('\n'),
            Some('\\') => out.push('\\'),
            Some('u') => {
                assert_eq!(chars.next(), Some('{'), "bad \\u escape in {field:?}");
                let hex: String = chars.by_ref().take_while(|c| *c != '}').collect();
                let code = u32::from_str_radix(&hex, 16).expect("hex code point");
                out.push(char::from_u32(code).expect("valid code point"));
            }
            other => panic!("unknown escape \\{other:?} in {field:?}"),
        }
    }
    out
}

/// A field, with a lone `-` meaning none.
fn optional(field: &str) -> Option<String> {
    (field != "-").then(|| unescape(field))
}

/// The fields of each case line, keyed by its kind letter.
fn cases() -> Vec<(char, Vec<String>)> {
    CASES
        .lines()
        .filter(|line| !line.is_empty() && !line.starts_with('#'))
        .map(|line| {
            let mut fields = line.split('\t');
            let kind = fields
                .next()
                .and_then(|kind| kind.chars().next())
                .expect("a kind letter");
            (kind, fields.map(str::to_owned).collect())
        })
        .collect()
}

#[test]
fn tokens_match_the_shared_cases() {
    let mut seen = 0;
    for (kind, fields) in cases() {
        if kind != 'T' {
            continue;
        }
        let text = optional(&fields[0]).unwrap_or_default();
        let expected: Vec<String> = optional(&fields[1])
            .map(|tokens| tokens.split(' ').map(str::to_owned).collect())
            .unwrap_or_default();
        assert_eq!(normalized_tokens(&text), expected, "tokens of {text:?}");
        seen += 1;
    }
    assert!(seen > 0, "no T cases read");
}

#[test]
fn matches_match_the_shared_cases() {
    let mut tracks = Vec::new();
    let mut queries = Vec::new();
    for (kind, fields) in cases() {
        match kind {
            'R' => tracks.push(TrackRecord::new(
                unescape(&fields[0]),
                unescape(&fields[1]),
                unescape(&fields[2]),
                unescape(&fields[3]),
                optional(&fields[4]),
                unescape(&fields[5]),
            )),
            'M' => {
                let query = optional(&fields[0]).unwrap_or_default();
                let expected: Vec<usize> = optional(&fields[1])
                    .map(|positions| {
                        positions
                            .split(' ')
                            .map(|position| position.parse().expect("a position"))
                            .collect()
                    })
                    .unwrap_or_default();
                queries.push((query, expected));
            }
            'T' | 'F' => {}
            other => panic!("unknown case kind {other:?}"),
        }
    }
    assert!(!queries.is_empty(), "no M cases read");

    let index = LibraryIndex::build(tracks);
    for (query, expected) in queries {
        let mut positions: Vec<usize> = index
            .search(&query, usize::MAX)
            .iter()
            .map(|hit| {
                index
                    .tracks
                    .iter()
                    .position(|track| std::ptr::eq(track, hit.track))
                    .expect("a hit is a track of the index")
            })
            .collect();
        positions.sort_unstable();
        assert_eq!(positions, expected, "matches for {query:?}");
        // The unranked view the Library filter uses must agree too.
        assert_eq!(index.matching(&query), expected, "matching for {query:?}");
    }
}

#[test]
fn typos_match_the_shared_cases() {
    let mut seen = 0;
    for (kind, fields) in cases() {
        if kind != 'F' {
            continue;
        }
        let expected = match fields[2].as_str() {
            "true" => true,
            "false" => false,
            other => panic!("bad boolean {other:?}"),
        };
        assert_eq!(
            crate::typos::matches_with_typos(&unescape(&fields[0]), &unescape(&fields[1])),
            expected,
            "typo case {fields:?}"
        );
        seen += 1;
    }
    assert!(seen > 0, "no F cases read");
}
