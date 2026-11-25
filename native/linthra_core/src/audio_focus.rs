//! The player's audio focus machine: what a call, a voice prompt, a
//! navigation cue, unplugged headphones or the listener's own transport does
//! to playback.
//!
//! Pure: [step] takes the state and one event and returns the next state and
//! the commands the player carries out, in order (timers, a queued pause or
//! resume, the engine volume). The player owns the timers and the engine;
//! this decides. The same machine is kept in Dart
//! (`lib/core/services/audio_focus_machine.dart`) as the fallback, and both
//! replay the scenarios in `test/fixtures/audio_focus_cases.txt`.
//!
//! The state is four facts:
//!  - `resume_armed`: a transient loss interrupted playback the regain is to
//!    resume.
//!  - `pause_pending`: a transient loss is waiting out its debounce before it
//!    pauses, so a brief blip (screen off, Doze) never pauses at all.
//!  - `ducked`: the volume is lowered for a duckable interruption.
//!  - `held`: the media service is kept in the foreground across the pause,
//!    so the resume can still get audio focus from the background.

use crate::playback_rules::FocusAction;

/// The machine's state, as bits: see the module docs.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct FocusState {
    pub resume_armed: bool,
    pub pause_pending: bool,
    pub ducked: bool,
    pub held: bool,
}

impl FocusState {
    pub fn from_bits(bits: u8) -> Self {
        Self {
            resume_armed: bits & 1 != 0,
            pause_pending: bits & 2 != 0,
            ducked: bits & 4 != 0,
            held: bits & 8 != 0,
        }
    }

    pub fn bits(self) -> u8 {
        u8::from(self.resume_armed)
            | u8::from(self.pause_pending) << 1
            | u8::from(self.ducked) << 2
            | u8::from(self.held) << 3
    }

    /// Whether a transient loss holds playback paused for the regain to
    /// resume: armed, and past the debounce. A load landing meanwhile waits.
    pub fn held_for_transient_focus(self) -> bool {
        self.resume_armed && !self.pause_pending
    }
}

/// What the player knows when an interruption arrives.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct FocusContext {
    pub playing: bool,
    /// A track is loading and the listener wants it to play when it lands.
    pub loading_to_play: bool,
    /// An automatic retry or move is scheduled or loading.
    pub recovery_underway: bool,
}

impl FocusContext {
    pub fn from_bits(bits: u8) -> Self {
        Self {
            playing: bits & 1 != 0,
            loading_to_play: bits & 2 != 0,
            recovery_underway: bits & 4 != 0,
        }
    }
}

/// One thing that happened to the player.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FocusEvent {
    /// Audio focus changed.
    Interruption(FocusAction),
    /// A transient loss outlasted its debounce.
    PauseDebounceFired,
    /// The foreground hold ran out before the regain came.
    HoldExpired,
    /// The output became the phone speaker: headphones were unplugged.
    BecomingNoisy,
    /// The app came back to the foreground.
    AppForegrounded,
    /// The listener pressed play.
    Play,
    /// The listener paused.
    Pause,
    /// The listener stopped.
    Stop,
    /// A cast receiver took over the audio.
    Suspend,
    /// The engine reports playing again.
    EnginePlaying,
    /// Playback ended in an error.
    Error,
}

impl FocusEvent {
    /// Event codes: 0-4 an interruption by its `AudioFocusAction` code, then
    /// 5 on in the order above.
    pub fn from_code(code: u8) -> Option<Self> {
        use FocusAction::*;
        use FocusEvent::*;
        Some(match code {
            0 => Interruption(PauseTransient),
            1 => Interruption(PausePermanent),
            2 => Interruption(Resume),
            3 => Interruption(Duck),
            4 => Interruption(Unduck),
            5 => PauseDebounceFired,
            6 => HoldExpired,
            7 => BecomingNoisy,
            8 => AppForegrounded,
            9 => Play,
            10 => Pause,
            11 => Stop,
            12 => Suspend,
            13 => EnginePlaying,
            14 => Error,
            _ => return None,
        })
    }
}

/// What the player is to do, in order.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
pub enum FocusCommand {
    StartPauseTimer = 0,
    CancelPauseTimer = 1,
    /// Supersede any focus pause or resume still queued.
    BumpEpoch = 2,
    EnqueuePause = 3,
    EnqueueResume = 4,
    /// Queue the engine volume for the current duck state.
    ApplyVolume = 5,
    StartHoldTimer = 6,
    CancelHoldTimer = 7,
    /// Publish the state again, so the media session sees the hold change.
    EmitState = 8,
    /// A track still loading must not start when it lands.
    ClearPlayWhenLoaded = 9,
    /// No automatic retry or move may start a track.
    HaltRecovery = 10,
    /// A diagnostic breadcrumb, by [Diagnostic] code.
    Diagnostic = 11,
}

/// The breadcrumbs the machine leaves, in the order the Dart side lists their
/// text.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
pub enum Diagnostic {
    LossTransientArmed = 0,
    LossTransientNotArmed = 1,
    LossPermanent = 2,
    Ducked = 3,
    UnduckRestored = 4,
    UnduckIgnored = 5,
    RegainChurnAbsorbed = 6,
    RegainRecoveryStarts = 7,
    RegainResumed = 8,
    RegainIgnored = 9,
    LossTransientPaused = 10,
    LossTransientAlreadyPaused = 11,
    HoldExpiredAfterRegain = 12,
    HoldExpired = 13,
    NoisyPaused = 14,
}

/// A command and, for [FocusCommand::Diagnostic], its breadcrumb.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Step(pub FocusCommand, pub Option<Diagnostic>);

struct Machine {
    state: FocusState,
    out: Vec<Step>,
}

impl Machine {
    fn emit(&mut self, command: FocusCommand) {
        self.out.push(Step(command, None));
    }

    fn note(&mut self, diagnostic: Diagnostic) {
        self.out
            .push(Step(FocusCommand::Diagnostic, Some(diagnostic)));
    }

    /// Arms (or disarms) the resume, and with it the foreground hold: the two
    /// are the same fact.
    fn arm(&mut self, armed: bool) {
        self.state.resume_armed = armed;
        self.set_held(armed);
    }

    fn set_held(&mut self, held: bool) {
        if self.state.held == held {
            return;
        }
        self.state.held = held;
        self.emit(if held {
            FocusCommand::StartHoldTimer
        } else {
            FocusCommand::CancelHoldTimer
        });
        self.emit(FocusCommand::EmitState);
    }

    /// Cancels a pause still waiting out its debounce; whether there was one.
    fn cancel_pause(&mut self) -> bool {
        if !self.state.pause_pending {
            return false;
        }
        self.state.pause_pending = false;
        self.emit(FocusCommand::CancelPauseTimer);
        true
    }

    fn supersede(&mut self) {
        self.emit(FocusCommand::BumpEpoch);
        self.cancel_pause();
    }

    fn restore_duck(&mut self) {
        if self.state.ducked {
            self.state.ducked = false;
            self.emit(FocusCommand::ApplyVolume);
        }
    }

    fn schedule_pause(&mut self) {
        if !self.state.pause_pending {
            self.state.pause_pending = true;
            self.emit(FocusCommand::StartPauseTimer);
        }
    }

    /// Pauses for good: nothing resumes, loads or recovers on its own after.
    fn pause_for_good(&mut self, diagnostic: Diagnostic) {
        self.arm(false);
        self.emit(FocusCommand::ClearPlayWhenLoaded);
        self.cancel_pause();
        self.emit(FocusCommand::HaltRecovery);
        self.note(diagnostic);
        self.restore_duck();
        self.emit(FocusCommand::EnqueuePause);
    }
}

/// The next state, and the commands to carry out, for `event` in `state`.
pub fn step(
    state: FocusState,
    event: FocusEvent,
    context: FocusContext,
) -> (FocusState, Vec<Step>) {
    let mut m = Machine {
        state,
        out: Vec::new(),
    };
    match event {
        FocusEvent::Interruption(FocusAction::PauseTransient) => {
            // Resume afterwards only what this interrupted, and keep a resume
            // already armed: one voice session can send several losses, and
            // the second would read the first's pause as the listener's.
            let armed = context.playing || context.loading_to_play || m.state.resume_armed;
            m.arm(armed);
            // A real loss supersedes a duck, so the resume is at full volume.
            m.restore_duck();
            m.schedule_pause();
            m.note(if m.state.resume_armed {
                Diagnostic::LossTransientArmed
            } else {
                Diagnostic::LossTransientNotArmed
            });
        }
        FocusEvent::Interruption(FocusAction::PausePermanent) => {
            m.pause_for_good(Diagnostic::LossPermanent)
        }
        FocusEvent::Interruption(FocusAction::Duck) => {
            m.state.ducked = true;
            m.note(Diagnostic::Ducked);
            m.emit(FocusCommand::ApplyVolume);
        }
        FocusEvent::Interruption(FocusAction::Unduck) => {
            m.note(if m.state.ducked {
                Diagnostic::UnduckRestored
            } else {
                Diagnostic::UnduckIgnored
            });
            m.restore_duck();
        }
        FocusEvent::Interruption(FocusAction::Resume) => {
            m.restore_duck();
            if m.cancel_pause() {
                // A blip the debounce absorbed: never paused, so keep playing.
                m.arm(false);
                m.note(Diagnostic::RegainChurnAbsorbed);
            } else if m.state.resume_armed {
                // The resume is consumed; the hold stays until the engine
                // plays again, so the service isn't demoted mid-resume.
                m.state.resume_armed = false;
                if context.recovery_underway {
                    // The recovery step starts its own track once it may.
                    m.set_held(false);
                    m.note(Diagnostic::RegainRecoveryStarts);
                } else {
                    m.note(Diagnostic::RegainResumed);
                    m.emit(FocusCommand::EnqueueResume);
                }
            } else {
                // A permanent loss, or nothing was playing: never auto-resume.
                m.note(Diagnostic::RegainIgnored);
            }
        }
        FocusEvent::PauseDebounceFired => {
            m.state.pause_pending = false;
            m.note(if m.state.resume_armed {
                Diagnostic::LossTransientPaused
            } else {
                Diagnostic::LossTransientAlreadyPaused
            });
            m.emit(FocusCommand::EnqueuePause);
        }
        FocusEvent::HoldExpired => {
            if m.state.resume_armed {
                // The resume goes with the hold: from the background, without
                // a foreground service, Android may refuse it.
                m.note(Diagnostic::HoldExpired);
                m.arm(false);
                m.emit(FocusCommand::ClearPlayWhenLoaded);
                m.emit(FocusCommand::HaltRecovery);
            } else {
                // Focus already came back and its resume is under way.
                m.note(Diagnostic::HoldExpiredAfterRegain);
                m.set_held(false);
            }
        }
        FocusEvent::BecomingNoisy => m.pause_for_good(Diagnostic::NoisyPaused),
        FocusEvent::AppForegrounded => m.restore_duck(),
        FocusEvent::Play => {
            m.arm(false);
            m.supersede();
            m.restore_duck();
        }
        FocusEvent::Pause | FocusEvent::Stop => {
            m.arm(false);
            m.supersede();
        }
        FocusEvent::Suspend => m.arm(false),
        FocusEvent::EnginePlaying => {
            // Playing keeps the service in the foreground by itself now. The
            // state about to be published carries the change, so no re-emit.
            if m.state.held && !m.state.resume_armed {
                m.state.held = false;
                m.emit(FocusCommand::CancelHoldTimer);
            }
        }
        FocusEvent::Error => {
            if m.state.resume_armed || m.state.held {
                m.arm(false);
            }
        }
    }
    (m.state, m.out)
}

#[cfg(test)]
mod tests {
    use super::*;
    use FocusCommand::*;

    fn commands(steps: &[Step]) -> Vec<FocusCommand> {
        steps.iter().map(|s| s.0).collect()
    }

    #[test]
    fn a_call_pauses_after_the_debounce_and_resumes_on_regain() {
        let playing = FocusContext {
            playing: true,
            ..FocusContext::default()
        };
        let (s, out) = step(
            FocusState::default(),
            FocusEvent::Interruption(FocusAction::PauseTransient),
            playing,
        );
        assert_eq!(
            commands(&out),
            [StartHoldTimer, EmitState, StartPauseTimer, Diagnostic]
        );
        assert!(s.resume_armed && s.pause_pending && s.held);

        let (s, out) = step(s, FocusEvent::PauseDebounceFired, FocusContext::default());
        assert_eq!(commands(&out), [Diagnostic, EnqueuePause]);
        assert!(s.held_for_transient_focus());

        let (s, out) = step(
            s,
            FocusEvent::Interruption(FocusAction::Resume),
            FocusContext::default(),
        );
        assert_eq!(commands(&out), [Diagnostic, EnqueueResume]);
        // The hold bridges the resume until the engine plays.
        assert!(!s.resume_armed && s.held);

        let (s, out) = step(s, FocusEvent::EnginePlaying, FocusContext::default());
        assert_eq!(commands(&out), [CancelHoldTimer]);
        assert_eq!(s, FocusState::default());
    }

    #[test]
    fn a_blip_inside_the_debounce_never_pauses() {
        let playing = FocusContext {
            playing: true,
            ..FocusContext::default()
        };
        let (s, _) = step(
            FocusState::default(),
            FocusEvent::Interruption(FocusAction::PauseTransient),
            playing,
        );
        let (s, out) = step(s, FocusEvent::Interruption(FocusAction::Resume), playing);
        assert_eq!(
            commands(&out),
            [CancelPauseTimer, CancelHoldTimer, EmitState, Diagnostic]
        );
        assert_eq!(s, FocusState::default());
    }

    #[test]
    fn state_bits_round_trip() {
        for bits in 0..16 {
            assert_eq!(FocusState::from_bits(bits).bits(), bits);
        }
    }
}
