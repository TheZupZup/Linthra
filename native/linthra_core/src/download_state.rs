//! Where a track stands in the download lifecycle, and the rules that move it.
//!
//! The same rules as `lib/core/services/download_state.dart`, held to them by
//! the shared cases in `test/fixtures/`, which both replay.

/// A track's download row, as `DownloadStatus` in Dart.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DownloadStatus {
    NotDownloaded,
    Queued,
    Downloading,
    Downloaded,
    Failed,
}

/// What the cache holds for a track once its request is done.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CommittedCopy {
    Nothing,
    /// An automatic pre-cache, free to be evicted.
    PreCache,
    /// A download the user asked for.
    Download,
}

/// The status a cancelled request leaves on its track's row, or `None` to
/// leave the row as it is.
///
/// The step that noticed the cancel stopped without touching the row, which
/// can still read queued or downloading. A cancelled download must not stay
/// there, or the row sticks and pre-cache skips the track: it goes back to not
/// downloaded, unless its bytes were committed as a download before the cancel
/// landed. A track with no row was already reset by whoever cancelled it.
pub fn settle_canceled(
    row: Option<DownloadStatus>,
    committed: CommittedCopy,
) -> Option<DownloadStatus> {
    let row = row?;
    match committed {
        CommittedCopy::Nothing | CommittedCopy::PreCache => Some(DownloadStatus::NotDownloaded),
        CommittedCopy::Download if row == DownloadStatus::Downloaded => None,
        CommittedCopy::Download => Some(DownloadStatus::Downloaded),
    }
}

/// What to do with a download the network policy held, now that it is asked
/// again.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum HeldAction {
    /// Ask for it again under the same account.
    Retry,
    /// Forget it and leave its row alone.
    Drop,
    /// Forget it and put its row back to not downloaded.
    DropAndReset,
}

/// A held download is asked again only under the account it was asked under:
/// the session signed in now would fetch another account's item, or nothing,
/// under this track. Dropped, its row goes back to not downloaded when it
/// still reads queued and no other request for it is running.
pub fn held_action(same_account: bool, in_flight: bool, row: Option<DownloadStatus>) -> HeldAction {
    if same_account {
        HeldAction::Retry
    } else if !in_flight && row == Some(DownloadStatus::Queued) {
        HeldAction::DropAndReset
    } else {
        HeldAction::Drop
    }
}
