//! C ABI for [crate::track_end]: one call, plain `u8` codes numbered like the
//! Dart enums (`RepeatMode.values`: off, all, one; `TrackEndAction.values`:
//! replay, next, restart, stop).

use crate::track_end::{track_end_action, RepeatMode, TrackEndAction};

/// The repeat code was not known.
pub const TRACK_END_INVALID: u8 = 254;

/// [track_end_action]: the action's code, or [TRACK_END_INVALID].
#[no_mangle]
pub extern "C" fn linthra_track_end_action(repeat_code: u8, has_next: bool) -> u8 {
    crate::ffi::guard(u8::MAX, || {
        crate::ffi::fail_safe(
            || {
                let repeat = match repeat_code {
                    0 => RepeatMode::Off,
                    1 => RepeatMode::All,
                    2 => RepeatMode::One,
                    _ => return TRACK_END_INVALID,
                };
                match track_end_action(repeat, has_next) {
                    TrackEndAction::Replay => 0,
                    TrackEndAction::Next => 1,
                    TrackEndAction::Restart => 2,
                    TrackEndAction::Stop => 3,
                }
            },
            || {
                // Safe answer: `Stop`.
                3
            },
        )
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decides_like_the_rule() {
        assert_eq!(linthra_track_end_action(2, true), 0);
        assert_eq!(linthra_track_end_action(0, true), 1);
        assert_eq!(linthra_track_end_action(1, false), 2);
        assert_eq!(linthra_track_end_action(0, false), 3);
        assert_eq!(linthra_track_end_action(3, false), TRACK_END_INVALID);
    }
}
