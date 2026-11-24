//! Replays test/fixtures/download_gate_cases.txt, the cases the Dart gate
//! (test/core/services/download_gate_cases_test.dart) replays too.

use crate::download_gate::{download_gate, DownloadGate, NetworkStatus};

const CASES: &str = include_str!("../../../test/fixtures/download_gate_cases.txt");

fn network(field: &str) -> NetworkStatus {
    match field {
        "wifi" => NetworkStatus::Wifi,
        "mobile" => NetworkStatus::Mobile,
        "unknown" => NetworkStatus::Unknown,
        "offline" => NetworkStatus::Offline,
        other => panic!("unknown network {other:?}"),
    }
}

fn decision(field: &str) -> DownloadGate {
    match field {
        "allowed" => DownloadGate::Allowed,
        "needsWifi" => DownloadGate::NeedsWifi,
        "offline" => DownloadGate::Offline,
        other => panic!("unknown decision {other:?}"),
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
        let allow_mobile = match fields[1] {
            "true" => true,
            "false" => false,
            other => panic!("bad boolean {other:?}"),
        };
        assert_eq!(
            download_gate(network(fields[0]), allow_mobile),
            decision(fields[2]),
            "case {line:?}"
        );
        replayed += 1;
    }
    // Every network status with the setting on and off.
    assert_eq!(replayed, 8);
}
