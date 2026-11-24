//! Replays test/fixtures/download_held_cases.txt, the cases the Dart rule
//! (test/core/services/download_held_cases_test.dart) replays too.

use crate::download_state::{held_action, DownloadStatus, HeldAction};

const CASES: &str = include_str!("../../../test/fixtures/download_held_cases.txt");

fn flag(field: &str) -> bool {
    match field {
        "true" => true,
        "false" => false,
        other => panic!("bad boolean {other:?}"),
    }
}

/// A row field, with a lone `-` meaning no row.
fn row(field: &str) -> Option<DownloadStatus> {
    match field {
        "-" => None,
        "queued" => Some(DownloadStatus::Queued),
        "downloading" => Some(DownloadStatus::Downloading),
        "downloaded" => Some(DownloadStatus::Downloaded),
        "failed" => Some(DownloadStatus::Failed),
        other => panic!("unknown row {other:?}"),
    }
}

fn action(field: &str) -> HeldAction {
    match field {
        "retry" => HeldAction::Retry,
        "drop" => HeldAction::Drop,
        "dropAndReset" => HeldAction::DropAndReset,
        other => panic!("unknown action {other:?}"),
    }
}

#[test]
fn replays_every_shared_case() {
    let mut replayed = 0;
    for line in CASES.lines() {
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let fields: Vec<&str> = line.split('\t').collect();
        assert_eq!(fields.len(), 4, "bad case line {line:?}");
        assert_eq!(
            held_action(flag(fields[0]), flag(fields[1]), row(fields[2])),
            action(fields[3]),
            "case {line:?}"
        );
        replayed += 1;
    }
    // Same account or not, in flight or not, with every row.
    assert_eq!(replayed, 20);
}
