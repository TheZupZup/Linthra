//! C ABI for [crate::audio_focus]: one leaf call per event. The state, the
//! event and the context are small codes; the steps come back as bytes, a
//! `FocusCommand` code or [DIAGNOSTIC_BASE] plus a `Diagnostic` code.

use crate::audio_focus::{step, FocusCommand, FocusContext, FocusEvent, FocusState};

/// A step at or above this is a diagnostic breadcrumb.
pub const DIAGNOSTIC_BASE: u8 = 32;

/// Returned for an unknown event, or when the steps don't fit in `capacity`.
pub const FOCUS_INVALID: u16 = 0xFFFF;

/// Runs one event through the machine: writes its steps to `steps` and their
/// count to `count`, and returns the next state's bits, or [FOCUS_INVALID].
///
/// # Safety
///
/// `steps` must be valid for `capacity` writes and `count` for one.
#[no_mangle]
pub unsafe extern "C" fn linthra_audio_focus_step(
    state: u8,
    event: u8,
    context: u8,
    steps: *mut u8,
    capacity: usize,
    count: *mut usize,
) -> u16 {
    let Some(event) = FocusEvent::from_code(event) else {
        return FOCUS_INVALID;
    };
    if steps.is_null() || count.is_null() {
        return FOCUS_INVALID;
    }
    let (next, out) = step(
        FocusState::from_bits(state),
        event,
        FocusContext::from_bits(context),
    );
    if out.len() > capacity {
        return FOCUS_INVALID;
    }
    for (i, s) in out.iter().enumerate() {
        *steps.add(i) = match (s.0, s.1) {
            (FocusCommand::Diagnostic, Some(d)) => DIAGNOSTIC_BASE + d as u8,
            (command, _) => command as u8,
        };
    }
    *count = out.len();
    u16::from(next.bits())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn steps_cross_as_bytes() {
        let mut steps = [0u8; 32];
        let mut count = 0usize;
        // A permanent loss while playing.
        let next = unsafe {
            linthra_audio_focus_step(0, 1, 1, steps.as_mut_ptr(), steps.len(), &mut count)
        };
        assert_eq!(next, 0);
        assert_eq!(&steps[..count], [9, 10, DIAGNOSTIC_BASE + 2, 3]);
        assert_eq!(
            unsafe {
                linthra_audio_focus_step(0, 99, 0, steps.as_mut_ptr(), steps.len(), &mut count)
            },
            FOCUS_INVALID
        );
        assert_eq!(
            unsafe { linthra_audio_focus_step(0, 1, 1, steps.as_mut_ptr(), 1, &mut count) },
            FOCUS_INVALID
        );
    }
}
