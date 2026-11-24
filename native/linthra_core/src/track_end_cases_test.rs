//! Replays test/fixtures/track_end_cases.txt, the cases the Dart rule
//! (test/core/services/track_end_cases_test.dart) replays too.

use crate::track_end::{track_end_action, RepeatMode, TrackEndAction};

const CASES: &str = include_str!("../../../test/fixtures/track_end_cases.txt");

fn repeat(field: &str) -> RepeatMode {
    match field {
        "off" => RepeatMode::Off,
        "all" => RepeatMode::All,
        "one" => RepeatMode::One,
        other => panic!("unknown repeat mode {other:?}"),
    }
}

fn action(field: &str) -> TrackEndAction {
    match field {
        "replay" => TrackEndAction::Replay,
        "next" => TrackEndAction::Next,
        "restart" => TrackEndAction::Restart,
        "stop" => TrackEndAction::Stop,
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
        assert_eq!(fields.len(), 3, "bad case line {line:?}");
        let has_next = match fields[1] {
            "true" => true,
            "false" => false,
            other => panic!("bad boolean {other:?}"),
        };
        assert_eq!(
            track_end_action(repeat(fields[0]), has_next),
            action(fields[2]),
            "case {line:?}"
        );
        replayed += 1;
    }
    // Every repeat mode, with and without a next track.
    assert_eq!(replayed, 6);
}
