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
