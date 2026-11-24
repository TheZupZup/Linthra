//! Replays test/fixtures/queue_moves_cases.txt, the cases the Dart queue
//! (test/core/models/queue_moves_cases_test.dart) replays too.

use crate::queue_moves::{queue_move_target, QueueMove};

const CASES: &str = include_str!("../../../test/fixtures/queue_moves_cases.txt");

fn queue_move(field: &str) -> QueueMove {
    match field {
        "next" => QueueMove::Next,
        "previous" => QueueMove::Previous,
        "restart" => QueueMove::Restart,
        "moveTo" => QueueMove::MoveTo,
        "jumpToUpNext" => QueueMove::JumpToUpNext,
        "jumpToHistory" => QueueMove::JumpToHistory,
        other => panic!("unknown move {other:?}"),
    }
}

/// An integer field, with a lone `-` meaning none.
fn optional(field: &str) -> Option<i64> {
    (field != "-").then(|| field.parse().expect("integer"))
}

#[test]
fn replays_every_shared_case() {
    let mut replayed = 0;
    for line in CASES.lines() {
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let f: Vec<&str> = line.split('\t').collect();
        assert_eq!(f.len(), 5, "bad case line {line:?}");
        assert_eq!(
            queue_move_target(
                optional(f[0]).expect("length"),
                optional(f[1]).expect("current"),
                queue_move(f[2]),
                optional(f[3]).unwrap_or(0),
            ),
            optional(f[4]),
            "case {line:?}"
        );
        replayed += 1;
    }
    assert_eq!(replayed, 30);
}
