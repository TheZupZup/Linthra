//! Replays test/fixtures/queue_edits_cases.txt, the cases the Dart queue
//! (test/core/models/queue_edits_cases_test.dart) replays too. See the file's
//! header for the format.

use crate::queue_edits::{edit_queue, QueueIds, QueueOp};

const CASES: &str = include_str!("../../../test/fixtures/queue_edits_cases.txt");

fn list(field: &str) -> Vec<i64> {
    if field == "." {
        return Vec::new();
    }
    field.split(',').map(|id| id.parse().expect("id")).collect()
}

fn optional_list(field: &str) -> Option<Vec<i64>> {
    (field != "-").then(|| list(field))
}

fn int(field: &str) -> i64 {
    field.parse().expect("integer")
}

#[test]
fn replays_every_shared_case() {
    let mut replayed = 0;
    for line in CASES.lines() {
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let f: Vec<&str> = line.split('\t').collect();
        assert!(f.len() == 7 || f.len() == 9, "bad case line {line:?}");
        let queue = QueueIds {
            ids: list(f[0]),
            current: int(f[1]),
            original: optional_list(f[2]),
        };
        let removed_ids = if f[3] == "removeWhere" {
            list(f[4])
        } else {
            Vec::new()
        };
        let removed: Vec<bool> = queue
            .ids
            .iter()
            .map(|id| removed_ids.contains(id))
            .collect();
        let removed_original: Vec<bool> = queue
            .original
            .iter()
            .flatten()
            .map(|id| removed_ids.contains(id))
            .collect();
        let op = match f[3] {
            "insertNext" | "append" => QueueOp::Insert {
                count: int(f[4]) as usize,
                after_current: f[3] == "insertNext",
            },
            "removeUpNextAt" => QueueOp::RemoveUpNextAt(int(f[4])),
            "reorderUpNext" => QueueOp::ReorderUpNext(int(f[4]), int(f[5])),
            "removeWhere" => QueueOp::RemoveWhere {
                removed: &removed,
                removed_original: &removed_original,
            },
            "shuffle" => QueueOp::Shuffle {
                seed: f[4].parse().expect("seed"),
            },
            "unshuffle" => QueueOp::Unshuffle,
            other => panic!("unknown op {other:?}"),
        };
        let edit = edit_queue(&queue, &op);
        if f[6] == "-" {
            assert_eq!(edit, None, "case {line:?}");
        } else {
            let edit = edit.unwrap_or_else(|| panic!("case {line:?} left the queue alone"));
            assert_eq!(edit.ids, list(f[6]), "ids, case {line:?}");
            assert_eq!(edit.current, int(f[7]), "current, case {line:?}");
            assert_eq!(
                edit.original.map(|(ids, _)| ids),
                optional_list(f[8]),
                "original, case {line:?}"
            );
            assert_eq!(edit.sources.len(), edit.ids.len());
        }
        replayed += 1;
    }
    assert!(replayed >= 30, "only {replayed} cases");
}

#[test]
fn shuffle_keeps_every_entry_once() {
    for seed in [0, 1, 42, u64::MAX] {
        let mut items: Vec<usize> = (0..50).collect();
        crate::queue_edits::shuffle_in_place(&mut items, seed);
        let mut sorted = items.clone();
        sorted.sort_unstable();
        assert_eq!(sorted, (0..50).collect::<Vec<_>>());
    }
}
