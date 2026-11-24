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
DownloadStatus? settleCanceled(DownloadStatus? row, CommittedCopy committed) {
  if (row == null) return null;
  switch (committed) {
    case CommittedCopy.nothing:
    case CommittedCopy.preCache:
      return DownloadStatus.notDownloaded;
    case CommittedCopy.download:
      return row == DownloadStatus.downloaded
          ? null
          : DownloadStatus.downloaded;
  }
}
