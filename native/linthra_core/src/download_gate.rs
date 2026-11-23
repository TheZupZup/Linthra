//! Whether the network lets a download run now, and why not when it doesn't.
//!
//! The same rule as `lib/core/services/download_gate.dart`, held to it by the
//! cases in `test/fixtures/download_gate_cases.txt`, which both replay.
//!
//!  - Unmetered (Wi-Fi, Ethernet): always allowed.
//!  - Metered, or metering unknown: allowed only when the user turned on
//!    "Allow mobile data". An unknown link is never assumed to be free.
//!  - Offline: never; the download waits for a connection.

/// The active network, as `ConnectivityService` reports it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum NetworkStatus {
    Offline,
    Wifi,
    Mobile,
    Unknown,
}

/// What the gate says about a download asked now.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DownloadGate {
    Allowed,
    /// Held until Wi-Fi, or until the user allows mobile data.
    NeedsWifi,
    /// Held until a connection returns.
    Offline,
}

pub fn download_gate(network: NetworkStatus, allow_mobile_data: bool) -> DownloadGate {
    match network {
        NetworkStatus::Wifi => DownloadGate::Allowed,
        NetworkStatus::Mobile | NetworkStatus::Unknown if allow_mobile_data => {
            DownloadGate::Allowed
        }
        NetworkStatus::Mobile | NetworkStatus::Unknown => DownloadGate::NeedsWifi,
        NetworkStatus::Offline => DownloadGate::Offline,
    }
}
