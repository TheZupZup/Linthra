//! C ABI for [crate::stream_recovery]: leaf calls on plain numbers. Times are
//! microseconds; a missing last position is `i64::MIN`.

use crate::stream_recovery::{
    source_end, watchdog_arms, watchdog_fails, ReconnectBudget, SourceGone, Status,
};

/// Returned for a code the call doesn't know.
pub const STREAM_RECOVERY_INVALID: u8 = 255;

/// [ReconnectBudget::claim]: whether a quick reconnect was taken. When it
/// was, the budget's spent count goes up by one and its progress resets.
#[no_mangle]
pub extern "C" fn linthra_reconnect_claim(spent: u32, max: u32, retryable: bool) -> bool {
    crate::ffi::guard(false, || {
        ReconnectBudget {
            spent,
            ..ReconnectBudget::default()
        }
        .claim(retryable, max)
    })
}

/// [ReconnectBudget::note_progress]: writes the budget's next played time and
/// last position, and returns 1 when this report gave the reconnect back (the
/// budget is then empty), else 0.
///
/// # Safety
///
/// `played_us` and `last_us` must be valid for one write each.
#[no_mangle]
pub unsafe extern "C" fn linthra_reconnect_progress(
    spent: u32,
    played_us: *mut i64,
    last_us: *mut i64,
    position_us: i64,
    counting: bool,
    refill_after_us: i64,
) -> u8 {
    crate::ffi::guard(u8::MAX, || {
        if played_us.is_null() || last_us.is_null() {
            return STREAM_RECOVERY_INVALID;
        }
        let mut budget = ReconnectBudget {
            spent,
            played_us: *played_us,
            last_us: (*last_us != i64::MIN).then_some(*last_us),
        };
        let gave_back = budget.note_progress(position_us, counting, refill_after_us);
        *played_us = budget.played_us;
        *last_us = budget.last_us.unwrap_or(i64::MIN);
        u8::from(gave_back)
    })
}

/// [source_end]: 0 ended, 1 lost.
#[no_mangle]
pub extern "C" fn linthra_source_end(
    gone: u8,
    engine_reports_failure_as_idle: bool,
    stream: bool,
    status: u8,
    position_us: i64,
    duration_us: i64,
) -> u8 {
    crate::ffi::guard(u8::MAX, || {
        let gone = match gone {
            0 => SourceGone::Idle,
            1 => SourceGone::Completed,
            _ => return STREAM_RECOVERY_INVALID,
        };
        let Some(status) = Status::from_code(status) else {
            return STREAM_RECOVERY_INVALID;
        };
        source_end(
            gone,
            engine_reports_failure_as_idle,
            stream,
            status,
            position_us,
            duration_us,
        ) as u8
    })
}

/// [watchdog_arms]: 1 or 0.
#[no_mangle]
pub extern "C" fn linthra_watchdog_arms(reported: u8, current: u8, has_played: bool) -> u8 {
    crate::ffi::guard(u8::MAX, || {
        match (Status::from_code(reported), Status::from_code(current)) {
            (Some(reported), Some(current)) => {
                u8::from(watchdog_arms(reported, current, has_played))
            }
            _ => STREAM_RECOVERY_INVALID,
        }
    })
}

/// [watchdog_fails]: 1 or 0.
#[no_mangle]
pub extern "C" fn linthra_watchdog_fails(
    current: u8,
    recovery_underway: bool,
    has_track: bool,
) -> u8 {
    crate::ffi::guard(u8::MAX, || {
        Status::from_code(current).map_or(STREAM_RECOVERY_INVALID, |current| {
            u8::from(watchdog_fails(current, recovery_underway, has_track))
        })
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn answers_across_the_boundary() {
        assert!(linthra_reconnect_claim(0, 1, true));
        assert!(!linthra_reconnect_claim(1, 1, true));
        let (mut played, mut last) = (0i64, i64::MIN);
        unsafe {
            assert_eq!(
                linthra_reconnect_progress(1, &mut played, &mut last, 5, true, 10),
                0
            );
            assert_eq!((played, last), (0, 5));
            assert_eq!(
                linthra_reconnect_progress(1, &mut played, &mut last, 20, true, 10),
                1
            );
            assert_eq!((played, last), (0, i64::MIN));
        }
        assert_eq!(
            linthra_source_end(1, true, true, 2, 11_900_000, 40_000_000),
            1
        );
        assert_eq!(
            linthra_source_end(2, true, true, 2, 0, 0),
            STREAM_RECOVERY_INVALID
        );
        assert_eq!(linthra_watchdog_arms(2, 4, false), 1);
        assert_eq!(
            linthra_watchdog_fails(9, false, true),
            STREAM_RECOVERY_INVALID
        );
    }
}
