//! C ABI for [crate::playback_rules]: leaf calls on codes numbered like the
//! Dart enums, plus one that reads an error's text.

use crate::playback_rules::{
    classify_engine_error, focus_action, FailureKind, InterruptionKind, NextTrack, RecoveryPolicy,
    ResolutionKind,
};

/// Returned for a code the call doesn't know.
pub const PLAYBACK_RULES_INVALID: u8 = 255;

/// The `StreamInterruptionKind` code an engine error's text reads as.
/// [PLAYBACK_RULES_INVALID] when `text` is null with a non-zero length or not
/// UTF-8.
///
/// # Safety
///
/// `text` must be null or valid for reads of `len` bytes.
#[no_mangle]
pub unsafe extern "C" fn linthra_playback_classify_error(text: *const u8, len: usize) -> u8 {
    crate::ffi::guard(u8::MAX, || {
        crate::ffi::fail_safe(
            || {
                let bytes = if len == 0 {
                    &[][..]
                } else if text.is_null() {
                    return PLAYBACK_RULES_INVALID;
                } else {
                    std::slice::from_raw_parts(text, len)
                };
                match std::str::from_utf8(bytes) {
                    Ok(text) => classify_engine_error(text) as u8,
                    Err(_) => PLAYBACK_RULES_INVALID,
                }
            },
            || {
                // Safe answer: `Unknown`, one retry.
                4
            },
        )
    })
}

/// A resolution error kind's failure, as `kind << 8 | cause`.
#[no_mangle]
pub extern "C" fn linthra_playback_failure_for_resolution(kind: u8) -> u16 {
    crate::ffi::guard(u16::MAX, || {
        crate::ffi::fail_safe(
            || {
                ResolutionKind::from_code(kind).map_or(u16::MAX, |kind| {
                    let (kind, cause) = kind.failure();
                    (kind as u16) << 8 | cause as u16
                })
            },
            || {
                // Safe answer: `TemporarySource`, `Unrecognized`.
                10
            },
        )
    })
}

/// An interruption kind's failure, as `kind << 8 | cause`.
#[no_mangle]
pub extern "C" fn linthra_playback_failure_for_interruption(kind: u8) -> u16 {
    crate::ffi::guard(u16::MAX, || {
        crate::ffi::fail_safe(
            || {
                InterruptionKind::from_code(kind).map_or(u16::MAX, |kind| {
                    let (kind, cause) = kind.failure();
                    (kind as u16) << 8 | cause as u16
                })
            },
            || {
                // Safe answer: `TemporarySource`, `Unrecognized`.
                10
            },
        )
    })
}

/// The recovery step's code (retry, advance, settle) for a failure of
/// `kind`, its wait written to `delay_ms`.
///
/// # Safety
///
/// `delay_ms` must be valid for one write.
#[no_mangle]
#[allow(clippy::too_many_arguments)]
pub unsafe extern "C" fn linthra_playback_recovery_decide(
    kind: u8,
    failures_before: u32,
    retry_spent: bool,
    next: u8,
    retry_delay_ms: u64,
    advance_delay_ms: u64,
    max_advance_delay_ms: u64,
    max_consecutive_failures: u32,
    delay_ms: *mut u64,
) -> u8 {
    crate::ffi::guard(u8::MAX, || {
        crate::ffi::fail_safe(
            || {
                let (Some(kind), Some(next)) =
                    (FailureKind::from_code(kind), NextTrack::from_code(next))
                else {
                    return PLAYBACK_RULES_INVALID;
                };
                if delay_ms.is_null() {
                    return PLAYBACK_RULES_INVALID;
                }
                let policy = RecoveryPolicy {
                    retry_delay_ms,
                    advance_delay_ms,
                    max_advance_delay_ms,
                    max_consecutive_failures,
                };
                let (step, delay) = policy.decide(kind, failures_before, retry_spent, next);
                *delay_ms = delay;
                step as u8
            },
            || {
                // Safe answer: settle, and show the error.
                if !delay_ms.is_null() {
                    *delay_ms = 0;
                }
                2
            },
        )
    })
}

/// The `AudioFocusAction` code for an interruption beginning (or ending) with
/// audio_session's `AudioInterruptionType` code.
#[no_mangle]
pub extern "C" fn linthra_playback_focus_action(begin: bool, interruption: u8) -> u8 {
    crate::ffi::guard(u8::MAX, || {
        crate::ffi::fail_safe(
            || {
                focus_action(begin, interruption)
                    .map_or(PLAYBACK_RULES_INVALID, |action| action as u8)
            },
            || {
                // Safe answer: pause for good on a loss, only restore the volume on a
                // regain (never start playing on its own).
                if begin {
                    1
                } else {
                    4
                }
            },
        )
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn answers_across_the_boundary() {
        let text = "HTTP/1.1 403 Forbidden";
        assert_eq!(
            unsafe { linthra_playback_classify_error(text.as_ptr(), text.len()) },
            2
        );
        assert_eq!(
            unsafe { linthra_playback_classify_error(std::ptr::null(), 0) },
            4
        );
        assert_eq!(
            unsafe { linthra_playback_classify_error(b"\xff".as_ptr(), 1) },
            PLAYBACK_RULES_INVALID
        );
        assert_eq!(linthra_playback_failure_for_resolution(6), 1 << 8 | 7);
        assert_eq!(linthra_playback_failure_for_resolution(9), u16::MAX);
        assert_eq!(linthra_playback_failure_for_interruption(4), 10);
        assert_eq!(linthra_playback_focus_action(true, 2), 1);
        assert_eq!(
            linthra_playback_focus_action(false, 7),
            PLAYBACK_RULES_INVALID
        );
        let mut delay = 0;
        assert_eq!(
            unsafe {
                linthra_playback_recovery_decide(
                    0, 0, false, 3, 10_000, 5_000, 5_000, 6, &mut delay,
                )
            },
            0
        );
        assert_eq!(delay, 10_000);
        assert_eq!(
            unsafe { linthra_playback_recovery_decide(0, 0, false, 9, 1, 1, 1, 1, &mut delay) },
            PLAYBACK_RULES_INVALID
        );
    }
}
