//! Replays test/fixtures/track_availability_cases.txt, the cases the Dart
//! rule (test/core/catalog/track_availability_cases_test.dart) replays too.

use crate::track_availability::{resolve, SourceAvailability, TrackAvailabilityStatus};

const CASES: &str = include_str!("../../../test/fixtures/track_availability_cases.txt");

fn flag(field: &str) -> bool {
    match field {
        "true" => true,
        "false" => false,
        other => panic!("bad boolean {other:?}"),
    }
}

fn availability(field: &str) -> SourceAvailability {
    match field {
        "notConfigured" => SourceAvailability::NotConfigured,
        "checking" => SourceAvailability::Checking,
        "available" => SourceAvailability::Available,
        "unreachable" => SourceAvailability::Unreachable,
        "authenticationError" => SourceAvailability::AuthenticationError,
        other => panic!("unknown availability {other:?}"),
    }
}

fn status(field: &str) -> TrackAvailabilityStatus {
    match field {
        "none" => TrackAvailabilityStatus::None,
        "downloaded" => TrackAvailabilityStatus::Downloaded,
        "cached" => TrackAvailabilityStatus::Cached,
        "offlineCopy" => TrackAvailabilityStatus::OfflineCopy,
        "checking" => TrackAvailabilityStatus::Checking,
        "unreachable" => TrackAvailabilityStatus::Unreachable,
        "sessionRejected" => TrackAvailabilityStatus::SessionRejected,
        other => panic!("unknown status {other:?}"),
    }
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
            resolve(flag(f[0]), flag(f[1]), flag(f[2]), availability(f[3])),
            status(f[4]),
            "case {line:?}"
        );
        replayed += 1;
    }
    // Every combination of the three flags and the five availabilities.
    assert_eq!(replayed, 40);
}
