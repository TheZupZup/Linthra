//! The player's rules for a track that won't play: what an engine error
//! means, which failure and cause it records, what to do next on its own,
//! and what an audio focus change asks for.
//!
//! `classifyEngineError` (lib/core/services/stream_interruption.dart), the
//! failure classifier, `PlaybackRecoveryPolicy` and
//! `JustAudioPlaybackController.audioFocusAction` call these, held to
//! `test/fixtures/playback_error_cases.txt`. Values cross as codes numbered
//! like the Dart enums.

use crate::tags::dart::is_regex_space;

/// `StreamInterruptionKind`, in Dart's order.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
pub enum InterruptionKind {
    NetworkDropped = 0,
    ServerUnreachable = 1,
    SessionExpired = 2,
    FormatUnsupported = 3,
    Unknown = 4,
    LocalFileUnavailable = 5,
}

impl InterruptionKind {
    pub fn from_code(code: u8) -> Option<Self> {
        use InterruptionKind::*;
        [
            NetworkDropped,
            ServerUnreachable,
            SessionExpired,
            FormatUnsupported,
            Unknown,
            LocalFileUnavailable,
        ]
        .get(usize::from(code))
        .copied()
    }

    /// Whether trying the same stream again may help. A rejected session,
    /// bytes that won't decode and a file that's gone give the same answer.
    pub fn retryable(self) -> bool {
        !matches!(
            self,
            InterruptionKind::SessionExpired
                | InterruptionKind::FormatUnsupported
                | InterruptionKind::LocalFileUnavailable
        )
    }
}

/// The engine code for "this audio has no decoder on this device"
/// (Media3's `ERROR_CODE_DECODING_FORMAT_UNSUPPORTED`).
const UNSUPPORTED_AUDIO_FORMAT: &str = "(4005)";

/// What an audio engine's error says happened. Only reads the text to pick a
/// kind; the caller shows a fixed message, so nothing in the error (a
/// tokenized URL, say) reaches the listener.
///
/// Locations are taken out first, since an item id or a token in a URL can
/// hold `401` or `403`. A status line's `HTTP/1.1` and an `I/O` go before
/// that, so their slash doesn't start a path that swallows the reason.
pub fn classify_engine_error(error: &str) -> InterruptionKind {
    let text = redact_locations(&blank_protocol_versions(error)).to_lowercase();
    // Structural, not wording: the Android engine's "no decoder on this
    // device" error carries Media3's code, first, so no digit or word in the
    // message can route it elsewhere.
    if text.starts_with(UNSUPPORTED_AUDIO_FORMAT) {
        return InterruptionKind::FormatUnsupported;
    }
    let mentions = |needles: &[&str]| needles.iter().any(|needle| text.contains(needle));
    // A rejected session first: retrying it gets the same answer. Then a
    // decode failure (the same bytes won't decode next time), a server that
    // doesn't answer at all, and a connection that dropped mid-stream.
    // Anything else is taken for a passing glitch, worth one retry.
    if mentions(&["401", "403", "unauthor", "forbidden"]) {
        InterruptionKind::SessionExpired
    } else if mentions(&[
        "unsupported",
        "decoder",
        "codec",
        "unable to instantiate",
        "parse",
    ]) {
        InterruptionKind::FormatUnsupported
    } else if mentions(&[
        "unreachable",
        "refused",
        "failed host lookup",
        "no address",
        "name resolution",
    ]) {
        InterruptionKind::ServerUnreachable
    } else if mentions(&[
        "timeout",
        "timed out",
        "network",
        "connection",
        "reset",
        "source error",
        "socket",
        "broken pipe",
        "eof",
    ]) {
        InterruptionKind::NetworkDropped
    } else {
        InterruptionKind::Unknown
    }
}

/// `\w` in a Dart regular expression: ASCII letters, digits and `_`.
fn is_word(c: Option<char>) -> bool {
    c.is_some_and(|c| c.is_ascii_alphanumeric() || c == '_')
}

/// Replaces every `\b(?:HTTP/\d(?:\.\d)?|I/O)\b`, ignoring ASCII case, with a
/// space.
fn blank_protocol_versions(text: &str) -> String {
    let chars: Vec<char> = text.chars().collect();
    let at = |i: usize| chars.get(i).copied();
    let mut out = String::with_capacity(text.len());
    let mut i = 0;
    while i < chars.len() {
        let starts_word = !is_word(i.checked_sub(1).and_then(at));
        let matched = starts_word
            .then(|| protocol_version_len(&chars, i).or_else(|| io_len(&chars, i)))
            .flatten();
        match matched {
            Some(len) => {
                out.push(' ');
                i += len;
            }
            None => {
                out.push(chars[i]);
                i += 1;
            }
        }
    }
    out
}

fn ascii_matches(chars: &[char], at: usize, word: &str) -> bool {
    word.chars().enumerate().all(|(k, w)| {
        chars
            .get(at + k)
            .is_some_and(|c| c.eq_ignore_ascii_case(&w))
    })
}

/// `HTTP/\d(?:\.\d)?\b` at `at`: the longer form when a boundary follows it,
/// else the shorter one, as the regex backtracks.
fn protocol_version_len(chars: &[char], at: usize) -> Option<usize> {
    if !ascii_matches(chars, at, "http/") || !chars.get(at + 5).is_some_and(char::is_ascii_digit) {
        return None;
    }
    let boundary_after = |end: usize| !is_word(chars.get(end).copied());
    if chars.get(at + 6) == Some(&'.')
        && chars.get(at + 7).is_some_and(char::is_ascii_digit)
        && boundary_after(at + 8)
    {
        return Some(8);
    }
    boundary_after(at + 6).then_some(6)
}

/// `I/O\b` at `at`.
fn io_len(chars: &[char], at: usize) -> Option<usize> {
    (ascii_matches(chars, at, "i/o") && !is_word(chars.get(at + 3).copied())).then_some(3)
}

/// Whether `c` ends a location inside an error message: a quote, a bracket,
/// a comma or semicolon, or a line break or tab.
fn is_delimiter(c: char) -> bool {
    matches!(
        c,
        '\'' | '"'
            | '`'
            | ','
            | ';'
            | '('
            | ')'
            | '['
            | ']'
            | '{'
            | '}'
            | '<'
            | '>'
            | '\n'
            | '\r'
            | '\t'
    )
}

/// How far a location runs from `at`: to a delimiter, or to the `: ` that
/// separates a location from the reason it was rejected. Spaces are inside
/// it, since a Linux path may hold them.
fn location_end(chars: &[char], mut at: usize) -> usize {
    while let Some(&c) = chars.get(at) {
        if is_delimiter(c) || (c == ':' && chars.get(at + 1).is_some_and(|n| is_regex_space(*n))) {
            break;
        }
        at += 1;
    }
    at
}

/// Every URL replaced with `<url>`, then every path with `<path>`, as
/// `LinuxPlaybackRuntime.redactLocations` does.
pub fn redact_locations(text: &str) -> String {
    let urls_gone = replace_all(text, "<url>", |chars, i| {
        if !chars[i].is_ascii_alphabetic() {
            return None;
        }
        let mut end = i + 1;
        while chars
            .get(end)
            .is_some_and(|c| c.is_ascii_alphanumeric() || matches!(c, '+' | '.' | '-'))
        {
            end += 1;
        }
        let rest: String = chars.get(end..end + 3)?.iter().collect();
        (rest == "://").then(|| location_end(chars, end + 3))
    });
    replace_all(&urls_gone, "<path>", |chars, i| {
        if chars[i] != '/' {
            return None;
        }
        let first = *chars.get(i + 1)?;
        let starts_reason = first == ':' && chars.get(i + 2).is_some_and(|n| is_regex_space(*n));
        if starts_reason || is_delimiter(first) || is_regex_space(first) {
            return None;
        }
        Some(location_end(chars, i + 2))
    })
}

/// Replaces, left to right, each match `matcher` finds (it returns where the
/// match starting at an index ends) with `with`.
fn replace_all(
    text: &str,
    with: &str,
    matcher: impl Fn(&[char], usize) -> Option<usize>,
) -> String {
    let chars: Vec<char> = text.chars().collect();
    let mut out = String::with_capacity(text.len());
    let mut i = 0;
    while i < chars.len() {
        match matcher(&chars, i) {
            Some(end) => {
                out.push_str(with);
                i = end;
            }
            None => {
                out.push(chars[i]);
                i += 1;
            }
        }
    }
    out
}

/// `PlaybackFailureKind`, in Dart's order.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
pub enum FailureKind {
    TemporarySource = 0,
    LocalFileUnavailable = 1,
    SourceSignInRequired = 2,
    UnplayableMedia = 3,
    PlaybackEngineUnavailable = 4,
}

impl FailureKind {
    pub fn from_code(code: u8) -> Option<Self> {
        use FailureKind::*;
        [
            TemporarySource,
            LocalFileUnavailable,
            SourceSignInRequired,
            UnplayableMedia,
            PlaybackEngineUnavailable,
        ]
        .get(usize::from(code))
        .copied()
    }
}

/// `PlaybackFailureCause`, in Dart's order.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
pub enum FailureCause {
    NotSignedIn = 0,
    SessionExpired = 1,
    ServerUnreachable = 2,
    ConnectionDropped = 3,
    ServerReturnedWebPage = 4,
    InvalidStream = 5,
    StreamUnavailable = 6,
    FileUnavailable = 7,
    AudioNotDecoded = 8,
    EngineUnavailable = 9,
    Unrecognized = 10,
}

/// `PlaybackResolutionErrorKind`, in Dart's order: why a track couldn't be
/// turned into something playable.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
pub enum ResolutionKind {
    NotSignedIn = 0,
    SessionExpired = 1,
    ServerUnreachable = 2,
    InvalidStream = 3,
    ServerReturnedWebPage = 4,
    StreamUnavailable = 5,
    LocalFileMissing = 6,
    MediaUnsupported = 7,
    PlaybackEngineUnavailable = 8,
}

impl ResolutionKind {
    pub fn from_code(code: u8) -> Option<Self> {
        use ResolutionKind::*;
        [
            NotSignedIn,
            SessionExpired,
            ServerUnreachable,
            InvalidStream,
            ServerReturnedWebPage,
            StreamUnavailable,
            LocalFileMissing,
            MediaUnsupported,
            PlaybackEngineUnavailable,
        ]
        .get(usize::from(code))
        .copied()
    }

    /// The failure a resolution problem shows as. A source that misbehaves
    /// (unreachable, a login page, no stream right now) may be fine next
    /// time; the rest won't.
    pub fn failure(self) -> (FailureKind, FailureCause) {
        use ResolutionKind as R;
        match self {
            R::NotSignedIn => (FailureKind::SourceSignInRequired, FailureCause::NotSignedIn),
            R::SessionExpired => (
                FailureKind::SourceSignInRequired,
                FailureCause::SessionExpired,
            ),
            R::ServerUnreachable => (
                FailureKind::TemporarySource,
                FailureCause::ServerUnreachable,
            ),
            R::InvalidStream => (FailureKind::TemporarySource, FailureCause::InvalidStream),
            R::ServerReturnedWebPage => (
                FailureKind::TemporarySource,
                FailureCause::ServerReturnedWebPage,
            ),
            R::StreamUnavailable => (
                FailureKind::TemporarySource,
                FailureCause::StreamUnavailable,
            ),
            R::LocalFileMissing => (
                FailureKind::LocalFileUnavailable,
                FailureCause::FileUnavailable,
            ),
            R::MediaUnsupported => (FailureKind::UnplayableMedia, FailureCause::AudioNotDecoded),
            R::PlaybackEngineUnavailable => (
                FailureKind::PlaybackEngineUnavailable,
                FailureCause::EngineUnavailable,
            ),
        }
    }
}

impl InterruptionKind {
    /// The failure a mid-stream interruption shows as. One Linthra can't
    /// place is taken for a glitch: trying again is the cheapest to be wrong
    /// about.
    pub fn failure(self) -> (FailureKind, FailureCause) {
        use InterruptionKind as I;
        match self {
            I::NetworkDropped => (
                FailureKind::TemporarySource,
                FailureCause::ConnectionDropped,
            ),
            I::ServerUnreachable => (
                FailureKind::TemporarySource,
                FailureCause::ServerUnreachable,
            ),
            I::SessionExpired => (
                FailureKind::SourceSignInRequired,
                FailureCause::SessionExpired,
            ),
            I::FormatUnsupported => (FailureKind::UnplayableMedia, FailureCause::AudioNotDecoded),
            I::LocalFileUnavailable => (
                FailureKind::LocalFileUnavailable,
                FailureCause::FileUnavailable,
            ),
            I::Unknown => (FailureKind::TemporarySource, FailureCause::Unrecognized),
        }
    }
}

/// `PlaybackRecoveryStep`, in Dart's order.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
pub enum RecoveryStep {
    Retry = 0,
    Advance = 1,
    Settle = 2,
}

/// Where the queue would move after the failed track.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
pub enum NextTrack {
    /// Nowhere: the queue ends here.
    None = 0,
    /// Back to the failed track itself (repeat-one, or a queue of one).
    Same = 1,
    /// To a track that already failed in this streak.
    FailedBefore = 2,
    /// To a track that hasn't failed yet.
    Fresh = 3,
}

impl NextTrack {
    pub fn from_code(code: u8) -> Option<Self> {
        [
            NextTrack::None,
            NextTrack::Same,
            NextTrack::FailedBefore,
            NextTrack::Fresh,
        ]
        .get(usize::from(code))
        .copied()
    }
}

/// `PlaybackRecoveryPolicy`'s limits, in milliseconds.
#[derive(Clone, Copy, Debug)]
pub struct RecoveryPolicy {
    pub retry_delay_ms: u64,
    pub advance_delay_ms: u64,
    pub max_advance_delay_ms: u64,
    pub max_consecutive_failures: u32,
}

impl RecoveryPolicy {
    /// The wait before moving past the `failures`th failed track in a row:
    /// the advance delay, doubled for each failure before it, up to the cap.
    pub fn delay_before_advance(&self, failures: u32) -> u64 {
        let mut delay = self.advance_delay_ms;
        let mut i = 1;
        while i < failures && delay < self.max_advance_delay_ms {
            delay = delay.saturating_mul(2);
            i += 1;
        }
        delay.min(self.max_advance_delay_ms)
    }

    /// What to do after a track failed with `kind`, `failures_before` other
    /// failures into the streak: retry it once (only the first temporary
    /// failure of a streak, and only once), move on with a countdown, or
    /// stop. An engine failure stops at once, since every track plays through
    /// the same engine.
    pub fn decide(
        &self,
        kind: FailureKind,
        failures_before: u32,
        retry_spent: bool,
        next: NextTrack,
    ) -> (RecoveryStep, u64) {
        if kind == FailureKind::PlaybackEngineUnavailable {
            return (RecoveryStep::Settle, 0);
        }
        if failures_before == 0 && !retry_spent && kind == FailureKind::TemporarySource {
            return (RecoveryStep::Retry, self.retry_delay_ms);
        }
        let failures = failures_before.saturating_add(1);
        if failures >= self.max_consecutive_failures || next != NextTrack::Fresh {
            return (RecoveryStep::Settle, 0);
        }
        (RecoveryStep::Advance, self.delay_before_advance(failures))
    }
}

/// `AudioFocusAction`, in Dart's order.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
pub enum FocusAction {
    PauseTransient = 0,
    PausePermanent = 1,
    Resume = 2,
    Duck = 3,
    Unduck = 4,
}

/// What an audio interruption asks for. `interruption` is audio_session's
/// `AudioInterruptionType`: 0 pause, 1 duck, 2 unknown. An unknown loss is
/// taken as permanent; any end other than a duck's is a regain.
pub fn focus_action(begin: bool, interruption: u8) -> Option<FocusAction> {
    Some(match (begin, interruption) {
        (true, 0) => FocusAction::PauseTransient,
        (true, 1) => FocusAction::Duck,
        (true, 2) => FocusAction::PausePermanent,
        (false, 0 | 2) => FocusAction::Resume,
        (false, 1) => FocusAction::Unduck,
        _ => return None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn redacts_urls_and_paths_to_their_delimiter() {
        assert_eq!(
            redact_locations("GET https://x.example/a b?token=401: refused"),
            "GET <url>: refused"
        );
        assert_eq!(
            redact_locations("open '/home/Ada Lovelace/x.so'"),
            "open '<path>'"
        );
        assert_eq!(redact_locations("a / b"), "a / b");
        assert_eq!(redact_locations("1abc://x"), "1<url>");
    }

    #[test]
    fn blanks_protocol_versions_and_io_only_as_whole_words() {
        assert_eq!(blank_protocol_versions("HTTP/1.1 403"), "  403");
        assert_eq!(blank_protocol_versions("http/2 x"), "  x");
        assert_eq!(blank_protocol_versions("HTTP/1.1x"), " .1x");
        assert_eq!(blank_protocol_versions("I/O error"), "  error");
        assert_eq!(blank_protocol_versions("XI/O"), "XI/O");
        assert_eq!(blank_protocol_versions("I/Os"), "I/Os");
    }

    #[test]
    fn decides_like_the_policy() {
        let policy = RecoveryPolicy {
            retry_delay_ms: 10_000,
            advance_delay_ms: 5_000,
            max_advance_delay_ms: 20_000,
            max_consecutive_failures: 6,
        };
        assert_eq!(
            policy.decide(FailureKind::TemporarySource, 0, false, NextTrack::Fresh),
            (RecoveryStep::Retry, 10_000)
        );
        assert_eq!(
            policy.decide(FailureKind::TemporarySource, 0, true, NextTrack::Fresh),
            (RecoveryStep::Advance, 5_000)
        );
        assert_eq!(
            policy.decide(FailureKind::UnplayableMedia, 2, false, NextTrack::Fresh),
            (RecoveryStep::Advance, 20_000)
        );
        assert_eq!(
            policy.decide(FailureKind::UnplayableMedia, 5, false, NextTrack::Fresh),
            (RecoveryStep::Settle, 0)
        );
        assert_eq!(
            policy.decide(
                FailureKind::UnplayableMedia,
                0,
                false,
                NextTrack::FailedBefore
            ),
            (RecoveryStep::Settle, 0)
        );
        assert_eq!(
            policy.decide(
                FailureKind::PlaybackEngineUnavailable,
                0,
                false,
                NextTrack::Fresh
            ),
            (RecoveryStep::Settle, 0)
        );
    }

    /// test/fixtures/playback_error_cases.txt, written from the Dart rule by
    /// test/core/services/playback_rules_parity_test.dart.
    #[test]
    fn engine_errors_match_the_shared_cases() {
        let cases = include_str!("../../../test/fixtures/playback_error_cases.txt");
        let mut seen = 0;
        for line in cases
            .lines()
            .filter(|line| !line.is_empty() && !line.starts_with('#'))
        {
            let (error, kind) = line.rsplit_once('\t').unwrap();
            let mut text = String::new();
            let mut chars = error.chars();
            while let Some(c) = chars.next() {
                if c != '\\' {
                    text.push(c);
                    continue;
                }
                match chars.next() {
                    Some('t') => text.push('\t'),
                    Some('n') => text.push('\n'),
                    Some(other) => text.push(other),
                    None => {}
                }
            }
            let expected = match kind {
                "networkDropped" => InterruptionKind::NetworkDropped,
                "serverUnreachable" => InterruptionKind::ServerUnreachable,
                "sessionExpired" => InterruptionKind::SessionExpired,
                "formatUnsupported" => InterruptionKind::FormatUnsupported,
                "unknown" => InterruptionKind::Unknown,
                other => panic!("unknown kind {other}"),
            };
            assert_eq!(classify_engine_error(&text), expected, "{text:?}");
            seen += 1;
        }
        assert_eq!(seen, 26);
    }
}
