//! C ABI for [crate::download_gate] and [crate::download_state].
//!
//! Every value crosses as a `u8` code, numbered like the Dart enum it mirrors
//! (its `index`), so no pointer and no allocation cross for these calls. A
//! code this side does not know comes back as [DOWNLOAD_INVALID], and Dart
//! then decides with its own rules.

use crate::download_gate::{download_gate, DownloadGate, NetworkStatus};
use crate::download_state::{
    held_action, settle_canceled, CommittedCopy, DownloadStatus, HeldAction,
};

/// A row with no status (Dart's `null`), as an argument or a result.
pub const DOWNLOAD_NONE: u8 = 255;
/// An argument was not a known code.
pub const DOWNLOAD_INVALID: u8 = 254;

/// `NetworkStatus.values` in Dart: offline, wifi, mobile, unknown.
fn network(code: u8) -> Option<NetworkStatus> {
    Some(match code {
        0 => NetworkStatus::Offline,
        1 => NetworkStatus::Wifi,
        2 => NetworkStatus::Mobile,
        3 => NetworkStatus::Unknown,
        _ => return None,
    })
}

/// `DownloadGate.values` in Dart: allowed, needsWifi, offline.
fn gate_code(gate: DownloadGate) -> u8 {
    match gate {
        DownloadGate::Allowed => 0,
        DownloadGate::NeedsWifi => 1,
        DownloadGate::Offline => 2,
    }
}

/// `DownloadStatus.values` in Dart: notDownloaded, queued, downloading,
/// downloaded, failed. [DOWNLOAD_NONE] is no row.
fn row(code: u8) -> Option<Option<DownloadStatus>> {
    Some(Some(match code {
        DOWNLOAD_NONE => return Some(None),
        0 => DownloadStatus::NotDownloaded,
        1 => DownloadStatus::Queued,
        2 => DownloadStatus::Downloading,
        3 => DownloadStatus::Downloaded,
        4 => DownloadStatus::Failed,
        _ => return None,
    }))
}

fn row_code(status: Option<DownloadStatus>) -> u8 {
    match status {
        None => DOWNLOAD_NONE,
        Some(DownloadStatus::NotDownloaded) => 0,
        Some(DownloadStatus::Queued) => 1,
        Some(DownloadStatus::Downloading) => 2,
        Some(DownloadStatus::Downloaded) => 3,
        Some(DownloadStatus::Failed) => 4,
    }
}

/// `CommittedCopy.values` in Dart: nothing, preCache, download.
fn committed(code: u8) -> Option<CommittedCopy> {
    Some(match code {
        0 => CommittedCopy::Nothing,
        1 => CommittedCopy::PreCache,
        2 => CommittedCopy::Download,
        _ => return None,
    })
}

/// `HeldAction.values` in Dart: retry, drop, dropAndReset.
fn held_code(action: HeldAction) -> u8 {
    match action {
        HeldAction::Retry => 0,
        HeldAction::Drop => 1,
        HeldAction::DropAndReset => 2,
    }
}

/// [download_gate]: the gate's code, or [DOWNLOAD_INVALID].
#[no_mangle]
pub extern "C" fn linthra_download_gate(network_code: u8, allow_mobile_data: bool) -> u8 {
    crate::ffi::guard(u8::MAX, || {
        network(network_code).map_or(DOWNLOAD_INVALID, |n| {
            gate_code(download_gate(n, allow_mobile_data))
        })
    })
}

/// [settle_canceled]: the status to set, [DOWNLOAD_NONE] to leave the row, or
/// [DOWNLOAD_INVALID].
#[no_mangle]
pub extern "C" fn linthra_download_settle_canceled(row_status: u8, committed_copy: u8) -> u8 {
    crate::ffi::guard(u8::MAX, || {
        match (row(row_status), committed(committed_copy)) {
            (Some(r), Some(c)) => row_code(settle_canceled(r, c)),
            _ => DOWNLOAD_INVALID,
        }
    })
}

/// [held_action]: the action's code, or [DOWNLOAD_INVALID].
#[no_mangle]
pub extern "C" fn linthra_download_held_action(
    same_account: bool,
    in_flight: bool,
    row_status: u8,
) -> u8 {
    crate::ffi::guard(u8::MAX, || {
        row(row_status).map_or(DOWNLOAD_INVALID, |r| {
            held_code(held_action(same_account, in_flight, r))
        })
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_code_round_trips() {
        for code in 0..=4 {
            assert_eq!(row(code).map(row_code), Some(code));
        }
        assert_eq!(row(DOWNLOAD_NONE).map(row_code), Some(DOWNLOAD_NONE));
    }

    #[test]
    fn decides_like_the_rules() {
        assert_eq!(linthra_download_gate(1, false), 0);
        assert_eq!(linthra_download_gate(2, false), 1);
        assert_eq!(linthra_download_gate(0, true), 2);
        assert_eq!(linthra_download_settle_canceled(1, 2), 3);
        assert_eq!(linthra_download_settle_canceled(3, 2), DOWNLOAD_NONE);
        assert_eq!(
            linthra_download_settle_canceled(DOWNLOAD_NONE, 0),
            DOWNLOAD_NONE
        );
        assert_eq!(linthra_download_held_action(false, false, 1), 2);
    }

    #[test]
    fn refuses_unknown_codes() {
        assert_eq!(linthra_download_gate(4, true), DOWNLOAD_INVALID);
        assert_eq!(linthra_download_settle_canceled(5, 0), DOWNLOAD_INVALID);
        assert_eq!(linthra_download_settle_canceled(0, 3), DOWNLOAD_INVALID);
        assert_eq!(
            linthra_download_held_action(true, true, 200),
            DOWNLOAD_INVALID
        );
    }
}
