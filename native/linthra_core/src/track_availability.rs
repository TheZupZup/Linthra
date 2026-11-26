//! What a library row says about whether it can play: the rule of
//! `resolveTrackAvailability` (lib/core/catalog/track_availability.dart),
//! where the reasoning lives. Both replay
//! test/fixtures/track_availability_cases.txt.

/// `SourceAvailability` in Dart, in the same order.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SourceAvailability {
    NotConfigured,
    Checking,
    Available,
    Unreachable,
    AuthenticationError,
}

/// `TrackAvailabilityStatus` in Dart, in the same order.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TrackAvailabilityStatus {
    None,
    Downloaded,
    Cached,
    OfflineCopy,
    Checking,
    Unreachable,
    SessionRejected,
}

/// `resolveTrackAvailability`. On-device music has nothing to report; a
/// saved copy outranks the server's state; without one, the server's state
/// is the row's.
pub fn resolve(
    is_remote: bool,
    has_offline_copy: bool,
    is_explicit_download: bool,
    availability: SourceAvailability,
) -> TrackAvailabilityStatus {
    use SourceAvailability as Source;
    use TrackAvailabilityStatus as Status;
    if !is_remote {
        return Status::None;
    }
    if has_offline_copy {
        return match availability {
            Source::Unreachable | Source::AuthenticationError => Status::OfflineCopy,
            _ if is_explicit_download => Status::Downloaded,
            _ => Status::Cached,
        };
    }
    match availability {
        Source::AuthenticationError => Status::SessionRejected,
        Source::Unreachable => Status::Unreachable,
        Source::Checking => Status::Checking,
        Source::Available | Source::NotConfigured => Status::None,
    }
}
