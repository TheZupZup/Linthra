//! Replays test/fixtures/search_rank_cases.txt, the cases the Dart rule
//! (test/core/catalog/search_rank_cases_test.dart) replays too.

use crate::search_rank::{rank_results, ResultKind};

const CASES: &str = include_str!("../../../test/fixtures/search_rank_cases.txt");

#[test]
fn replays_every_shared_case() {
    let mut replayed = 0;
    for line in CASES.lines() {
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let fields: Vec<&str> = line.split('\t').collect();
        assert_eq!(fields.len(), 3, "bad case line {line:?}");
        let results: Vec<(ResultKind, &str)> = fields[1]
            .split('|')
            .map(|entry| {
                let (kind, name) = entry.split_once(':').expect("kind:name");
                let kind = match kind {
                    "artist" => ResultKind::Artist,
                    "album" => ResultKind::Album,
                    "song" => ResultKind::Song,
                    other => panic!("unknown kind {other:?}"),
                };
                (kind, name)
            })
            .collect();
        let expected: Vec<usize> = fields[2]
            .split(' ')
            .map(|p| p.parse().expect("position"))
            .collect();
        assert_eq!(rank_results(fields[0], &results), expected, "case {line:?}");
        replayed += 1;
    }
    assert!(replayed >= 12, "only {replayed} cases");
}
