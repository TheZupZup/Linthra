//! C ABI for [crate::track_availability]: one call, plain `u8` codes numbered
//! like the Dart enums (`SourceAvailability.values` in,
//! `TrackAvailabilityStatus.values` out).

use crate::track_availability::{resolve, SourceAvailability, TrackAvailabilityStatus};

/// The availability code was not known.
pub const TRACK_AVAILABILITY_INVALID: u8 = 254;

/// [resolve]: the status's code, or [TRACK_AVAILABILITY_INVALID].
#[no_mangle]
pub extern "C" fn linthra_track_availability(
    is_remote: bool,
    has_offline_copy: bool,
    is_explicit_download: bool,
    availability_code: u8,
) -> u8 {
    crate::ffi::guard(u8::MAX, || {
        let availability = match availability_code {
            0 => SourceAvailability::NotConfigured,
            1 => SourceAvailability::Checking,
            2 => SourceAvailability::Available,
            3 => SourceAvailability::Unreachable,
            4 => SourceAvailability::AuthenticationError,
            _ => return TRACK_AVAILABILITY_INVALID,
        };
        match resolve(
            is_remote,
            has_offline_copy,
            is_explicit_download,
            availability,
        ) {
            TrackAvailabilityStatus::None => 0,
            TrackAvailabilityStatus::Downloaded => 1,
            TrackAvailabilityStatus::Cached => 2,
            TrackAvailabilityStatus::OfflineCopy => 3,
            TrackAvailabilityStatus::Checking => 4,
            TrackAvailabilityStatus::Unreachable => 5,
            TrackAvailabilityStatus::SessionRejected => 6,
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn resolves_like_the_rule() {
        assert_eq!(linthra_track_availability(false, true, true, 3), 0);
        assert_eq!(linthra_track_availability(true, true, false, 4), 3);
        assert_eq!(linthra_track_availability(true, false, false, 4), 6);
        assert_eq!(
            linthra_track_availability(true, false, false, 5),
            TRACK_AVAILABILITY_INVALID
        );
    }
}
