//! Replays test/fixtures/download_settle_cases.txt, the cases the Dart rule
//! (test/core/services/download_settle_cases_test.dart) replays too.

use crate::download_state::{settle_canceled, CommittedCopy, DownloadStatus};

const CASES: &str = include_str!("../../../test/fixtures/download_settle_cases.txt");

/// A status field, with a lone `-` meaning none.
fn status(field: &str) -> Option<DownloadStatus> {
    match field {
        "-" => None,
        "notDownloaded" => Some(DownloadStatus::NotDownloaded),
        "queued" => Some(DownloadStatus::Queued),
        "downloading" => Some(DownloadStatus::Downloading),
        "downloaded" => Some(DownloadStatus::Downloaded),
        "failed" => Some(DownloadStatus::Failed),
        other => panic!("unknown status {other:?}"),
    }
}

fn committed(field: &str) -> CommittedCopy {
    match field {
        "nothing" => CommittedCopy::Nothing,
        "preCache" => CommittedCopy::PreCache,
        "download" => CommittedCopy::Download,
        other => panic!("unknown committed copy {other:?}"),
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
        assert_eq!(fields.len(), 3, "bad case line {line:?}");
        assert_eq!(
            settle_canceled(status(fields[0]), committed(fields[1])),
            status(fields[2]),
            "case {line:?}"
        );
        replayed += 1;
    }
    // Every row (none, or one of the four kept in the map) with every copy.
    assert_eq!(replayed, 15);
}
