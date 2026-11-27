import '../native/native_downloads.dart';
import '../repositories/download_repository.dart';

/// What the cache holds for a track once its request is done.
enum CommittedCopy {
  nothing,

  /// An automatic pre-cache, free to be evicted.
  preCache,

  /// A download the user asked for.
  download,
}

/// The status a cancelled request leaves on its track's row, or `null` to
/// leave the row as it is. The same rule as
/// `native/linthra_core/src/download_state.rs`, held to it by the cases in
/// `test/fixtures/download_settle_cases.txt`, which both replay.
///
/// The step that noticed the cancel stopped without touching the row, which
/// can still read queued or downloading. A cancelled download must not stay
/// there, or the row sticks and pre-cache skips the track: it goes back to not
/// downloaded, unless its bytes were committed as a download before the cancel
/// landed. A track with no row was already reset by whoever cancelled it.
///
/// Decided by the Rust core.
DownloadStatus? settleCanceled(DownloadStatus? row, CommittedCopy committed) =>
    NativeDownloads.settleCanceled(row, committed);

/// What to do with a download the network policy held, now that it is asked
/// again.
enum HeldAction {
  /// Ask for it again under the same account.
  retry,

  /// Forget it and leave its row alone.
  drop,

  /// Forget it and put its row back to not downloaded.
  dropAndReset,
}

/// A held download is asked again only under the account it was asked under:
/// the session signed in now would fetch another account's item, or nothing,
/// under this track. Dropped, its row goes back to not downloaded when it
/// still reads queued and no other request for it is running. The same rule
/// as `held_action` in `native/linthra_core/src/download_state.rs`, held to it
/// by `test/fixtures/download_held_cases.txt`.
///
/// Decided by the Rust core.
HeldAction heldAction({
  required bool sameAccount,
  required bool inFlight,
  required DownloadStatus? row,
}) =>
    NativeDownloads.heldAction(sameAccount, inFlight, row);
