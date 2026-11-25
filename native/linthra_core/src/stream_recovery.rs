//! What the player does when a stream stalls, drops or ends: its quick
//! reconnect budget, whether a source that went away ended or was lost, and
//! when the buffering watchdog is armed and what its firing means.
//!
//! The same rules as `lib/core/services/stream_recovery_rules.dart`, which is
//! the fallback; `test/core/services/stream_recovery_rules_test.dart` compares
//! the two. Times are microseconds, as Dart's `Duration` counts them.

/// `PlaybackStatus`, in Dart's order.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
pub enum Status {
    Idle = 0,
    Loading = 1,
    Buffering = 2,
    Reconnecting = 3,
    Playing = 4,
    Paused = 5,
    Completed = 6,
    Error = 7,
}

impl Status {
    pub fn from_code(code: u8) -> Option<Self> {
        use Status::*;
        [
            Idle,
            Loading,
            Buffering,
            Reconnecting,
            Playing,
            Paused,
            Completed,
            Error,
        ]
        .get(usize::from(code))
        .copied()
    }
}

/// The quick reconnect a dropped stream gets: one per track, given back once
/// the stream has played on for a while, so a later drop on the same track
/// reconnects quickly again.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct ReconnectBudget {
    /// Quick reconnects spent on the current track.
    pub spent: u32,
    /// Playback heard since the last one, in microseconds.
    pub played_us: i64,
    /// The position last seen while counting, if any.
    pub last_us: Option<i64>,
}

/// How far one position report may move for it to be ordinary playback: a
/// seek or a reload landing moves further.
pub const MAX_PROGRESS_STEP_US: i64 = 2_000_000;

impl ReconnectBudget {
    /// Takes a quick reconnect for a failure that may clear if the stream is
    /// opened again, when one is left. Playback from here on earns it back.
    pub fn claim(&mut self, retryable: bool, max: u32) -> bool {
        if !retryable || self.spent >= max {
            return false;
        }
        self.spent += 1;
        self.played_us = 0;
        self.last_us = None;
        true
    }

    /// Counts a position report towards giving the spent reconnect back.
    /// `counting` is whether the track is playing with no recovery loading:
    /// time paused, buffering or reconnecting doesn't count, nor does a seek
    /// (a step back, or one longer than ordinary playback moves). Returns
    /// whether this report gave the reconnect back.
    pub fn note_progress(
        &mut self,
        position_us: i64,
        counting: bool,
        refill_after_us: i64,
    ) -> bool {
        if self.spent == 0 {
            return false;
        }
        if !counting {
            self.last_us = None;
            return false;
        }
        let last = self.last_us.replace(position_us);
        let Some(last) = last else {
            return false;
        };
        let step = position_us - last;
        if step <= 0 || step > MAX_PROGRESS_STEP_US {
            return false;
        }
        self.played_us += step;
        if self.played_us < refill_after_us {
            return false;
        }
        self.give_back();
        true
    }

    /// The stream has proven itself (or another copy took over).
    pub fn give_back(&mut self) {
        *self = ReconnectBudget::default();
    }
}

/// How the engine said a source is gone.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
pub enum SourceGone {
    /// An idle no load or stop of ours explains, on an engine that reports a
    /// lost source only that way (libmpv on Linux).
    Idle = 0,
    /// The engine reported the end of the source.
    Completed = 1,
}

/// Whether the source ended (the track was heard) or was lost (it should be
/// recovered like a dropped stream, without counting as played).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
pub enum SourceEnd {
    Ended = 0,
    Lost = 1,
}

/// How close to its end an idle source must have been heard for the idle to
/// be its end: the engine decodes about half a second ahead, and what follows
/// the audio (a tag, padding) can fail to decode a moment before the end.
const END_HEARD_TOLERANCE_US: i64 = 2_000_000;

/// How far short of a stream's known end a reported end must come for it to
/// be a lost stream: at least this much, or a tenth of the track. Generous,
/// so a VBR file whose length was only estimated still ends where it ends.
const CUT_SHORT_MIN_US: i64 = 10_000_000;

/// Whether a source that went away ended or was lost.
///
/// An idle on an engine that reports a lost source that way is an end only
/// when the track was heard (playing or buffering) to within two seconds of
/// its known end, or a quarter of it for a short one.
///
/// A completion is an end, except a stream's on such an engine that comes
/// well short of its known end: libmpv gives up on a server that stopped
/// answering by reporting the end of the file, which would otherwise move the
/// queue on and record the track as played.
pub fn source_end(
    gone: SourceGone,
    engine_reports_failure_as_idle: bool,
    stream: bool,
    status: Status,
    position_us: i64,
    duration_us: i64,
) -> SourceEnd {
    let remaining = duration_us - position_us;
    match gone {
        SourceGone::Idle => {
            let heard = matches!(status, Status::Playing | Status::Buffering);
            let tolerance = END_HEARD_TOLERANCE_US.min(duration_us / 4);
            if heard && duration_us > 0 && remaining <= tolerance {
                SourceEnd::Ended
            } else {
                SourceEnd::Lost
            }
        }
        SourceGone::Completed => {
            let cut_short = engine_reports_failure_as_idle
                && stream
                && duration_us > 0
                && position_us >= 0
                && remaining > CUT_SHORT_MIN_US.max(duration_us / 10);
            if cut_short {
                SourceEnd::Lost
            } else {
                SourceEnd::Ended
            }
        }
    }
}

/// Whether an engine report of buffering arms the watchdog: a stall on a
/// track that was playing, or resuming into one on a track that has played
/// (a first load is not a stall).
pub fn watchdog_arms(reported: Status, current: Status, has_played: bool) -> bool {
    reported == Status::Buffering
        && (current == Status::Playing || (has_played && current != Status::Buffering))
}

/// Whether the watchdog firing is a failure: still stalled or reconnecting,
/// with a track to recover and no automatic recovery already under way.
pub fn watchdog_fails(current: Status, recovery_underway: bool, has_track: bool) -> bool {
    !recovery_underway && has_track && matches!(current, Status::Buffering | Status::Reconnecting)
}

#[cfg(test)]
mod tests {
    use super::*;

    const S: i64 = 1_000_000;

    #[test]
    fn a_reconnect_comes_back_after_healthy_playback() {
        let mut budget = ReconnectBudget::default();
        assert!(budget.claim(true, 1));
        assert!(!budget.claim(true, 1));
        // A seek forward and time paused don't count.
        budget.note_progress(0, true, 30 * S);
        budget.note_progress(20 * S, true, 30 * S);
        budget.note_progress(21 * S, false, 30 * S);
        assert_eq!(budget.played_us, 0);
        let mut position = 21 * S;
        for _ in 0..61 {
            position += S / 2;
            if budget.note_progress(position, true, 30 * S) {
                break;
            }
        }
        assert_eq!(budget, ReconnectBudget::default());
        assert!(budget.claim(true, 1));
        assert!(!ReconnectBudget::default().claim(false, 1));
    }

    #[test]
    fn issue_905_a_stream_cut_short_is_lost_not_ended() {
        // libmpv gave up at 11.9 s of a 40 s stream, reporting its end.
        let gone = |linux, stream, position| {
            source_end(
                SourceGone::Completed,
                linux,
                stream,
                Status::Buffering,
                position,
                40 * S,
            )
        };
        assert_eq!(gone(true, true, 11_900_000), SourceEnd::Lost);
        // Within the tolerance: an estimated VBR length.
        assert_eq!(gone(true, true, 31 * S), SourceEnd::Ended);
        // A local file, or another engine, ends where it ends.
        assert_eq!(gone(true, false, 11_900_000), SourceEnd::Ended);
        assert_eq!(gone(false, true, 11_900_000), SourceEnd::Ended);
        // A long track: a tenth of it is the tolerance.
        let hour = 3_600 * S;
        assert_eq!(
            source_end(
                SourceGone::Completed,
                true,
                true,
                Status::Playing,
                hour - 300 * S,
                hour
            ),
            SourceEnd::Ended
        );
        assert_eq!(
            source_end(
                SourceGone::Completed,
                true,
                true,
                Status::Playing,
                hour - 400 * S,
                hour
            ),
            SourceEnd::Lost
        );
        // An unknown length can't be short of anything.
        assert_eq!(
            source_end(SourceGone::Completed, true, true, Status::Playing, S, 0),
            SourceEnd::Ended
        );
    }

    #[test]
    fn an_idle_is_an_end_only_when_heard_to_the_end() {
        let idle =
            |status, position| source_end(SourceGone::Idle, true, true, status, position, 40 * S);
        assert_eq!(idle(Status::Playing, 39 * S), SourceEnd::Ended);
        assert_eq!(idle(Status::Playing, 37 * S), SourceEnd::Lost);
        assert_eq!(idle(Status::Paused, 39_500_000), SourceEnd::Lost);
        // A 4 s track: a quarter of it, one second.
        assert_eq!(
            source_end(
                SourceGone::Idle,
                true,
                true,
                Status::Buffering,
                2_500_000,
                4 * S
            ),
            SourceEnd::Lost
        );
    }

    #[test]
    fn the_watchdog_guards_stalls_not_first_loads() {
        assert!(watchdog_arms(Status::Buffering, Status::Playing, false));
        assert!(watchdog_arms(Status::Buffering, Status::Paused, true));
        assert!(!watchdog_arms(Status::Buffering, Status::Loading, false));
        assert!(!watchdog_arms(Status::Buffering, Status::Buffering, true));
        assert!(!watchdog_arms(Status::Playing, Status::Playing, true));
        assert!(watchdog_fails(Status::Reconnecting, false, true));
        assert!(!watchdog_fails(Status::Reconnecting, true, true));
        assert!(!watchdog_fails(Status::Playing, false, true));
    }
}
