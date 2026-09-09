import 'dart:async';

import '../models/bulk_download_summary.dart';
import '../models/track.dart';
import '../repositories/download_repository.dart';
import '../repositories/download_store.dart';

/// Turns "download this album" into the per-track requests the existing
/// [DownloadRepository] already knows how to serve.
///
/// It is deliberately **not** a second downloader. It owns no network code, no
/// cache policy, and no file handling: every track goes through
/// [DownloadRepository.requestDownload], so the Wi-Fi/mobile-data rules, the
/// cache limit and its eviction, pinned downloads, per-track progress, dedup and
/// per-track cancellation all stay in the one place that already enforces them.
/// What this adds is only what a *set* of tracks needs and a single track does
/// not:
///
///  - **Never a surprise download.** Nothing here starts on its own; a batch
///    runs only when a caller hands it an explicit list of tracks.
///  - **Existing offline copies are left alone.** Tracks that are already
///    downloaded are filtered out before any request, so re-running "Download
///    all" on a mostly-downloaded album costs nothing and cannot disturb what is
///    already on disk.
///  - **One request per track.** Duplicates within the list (the same song twice
///    in a playlist) collapse to one request, keyed provider-aware so two
///    providers' same-id copies stay distinct.
///  - **A bounded number of outstanding requests**, so a 500-track playlist
///    doesn't hand the repository 500 simultaneous ones. The bytes are still
///    fetched by the repository's own scheduler at its own limit; this bound is
///    what keeps a batch stoppable.
///  - **A stop that means stop.** Cancellation and a full cache both end the
///    batch, and the tracks it never reached are never requested.
///
/// Stopping a batch never deletes anything: requests already handed to the
/// repository (at most [maxOutstanding]) finish normally and stay offline, since
/// stopping must not take away a file the user already has. Cancelling one of
/// *those* is what the Downloads screen's per-track cancel is for.
class BulkDownloader {
  const BulkDownloader({this.maxOutstanding = defaultMaxOutstanding})
      : assert(maxOutstanding >= 1, 'maxOutstanding must be at least 1');

  /// Matches the download scheduler's own concurrency ceiling: enough
  /// outstanding requests to keep it saturated, few enough that a stop takes
  /// effect within a track or two.
  static const int defaultMaxOutstanding = 3;

  /// How many tracks may be outstanding with the repository at once.
  final int maxOutstanding;

  /// Requests an offline copy of every track in [tracks], reporting progress
  /// through [onProgress] and returning the final summary.
  ///
  /// [isCanceled] is polled before each track is requested, so a user who stops
  /// the batch stops it: the remaining tracks are never asked for.
  Future<BulkDownloadSummary> run({
    required DownloadRepository repository,
    required String label,
    required List<Track> tracks,
    bool Function()? isCanceled,
    void Function(BulkDownloadSummary progress)? onProgress,
  }) async {
    // Collapse duplicates (the same song twice in a playlist) to one request
    // each, provider-aware so a Plex and a Subsonic copy of one id both get one.
    final Map<String, Track> unique = <String, Track>{};
    for (final Track track in tracks) {
      unique.putIfAbsent(CachedTrack.cacheKeyForTrack(track), () => track);
    }

    // What is already offline is never requested again, so an existing download
    // is left exactly as it is.
    final Set<String> offlineBefore =
        (await repository.downloadedTrackKeys()).toSet();
    final List<MapEntry<String, Track>> pending = <MapEntry<String, Track>>[
      for (final MapEntry<String, Track> entry in unique.entries)
        if (!offlineBefore.contains(entry.key)) entry,
    ];

    BulkDownloadSummary summary = BulkDownloadSummary(
      label: label,
      total: unique.length,
      alreadyOffline: unique.length - pending.length,
      running: true,
    );
    onProgress?.call(summary);
    if (pending.isEmpty) return summary.copyWith(running: false);

    int next = 0;
    bool stopped = false;

    Future<void> worker() async {
      while (!stopped && next < pending.length) {
        if (isCanceled?.call() ?? false) {
          summary = summary.copyWith(canceled: true);
          stopped = true;
          return;
        }
        final Track track = pending[next++].value;
        try {
          final DownloadRequestOutcome outcome =
              await repository.requestDownload(track);
          if (outcome != DownloadRequestOutcome.started) {
            summary = summary.copyWith(
              waitingForNetwork: summary.waitingForNetwork + 1,
              // Keep the first reason: it is the one the user is asked to act
              // on, and a later track can only report the same policy.
              waitingReason: summary.waitingReason ?? outcome,
            );
          }
        } on CacheStorageException {
          // The cache is full with nothing safe to evict, so every remaining
          // track would fail the same way. Stop, rather than spend time and
          // data on requests that cannot fit.
          summary = summary.copyWith(outOfSpace: true);
          stopped = true;
          return;
        } catch (_) {
          // One track failing is not the batch failing: the repository has
          // already marked it failed (the Downloads screen offers it a retry),
          // so carry on with the rest. The count comes from the repository's own
          // record below, not from here.
        }
        summary = summary.copyWith(completed: summary.completed + 1);
        onProgress?.call(summary);
      }
    }

    await Future.wait(<Future<void>>[
      for (int i = 0; i < maxOutstanding; i++) worker(),
    ]);

    // Count what actually landed from the repository's own record rather than
    // from the request calls: a request can report "started" and still fail
    // mid-fetch, and only the repository knows which tracks ended up with an
    // offline copy.
    final Set<String> offlineAfter =
        (await repository.downloadedTrackKeys()).toSet();
    int downloaded = 0;
    for (final MapEntry<String, Track> entry in pending) {
      if (offlineAfter.contains(entry.key)) downloaded++;
    }
    return summary.copyWith(
      downloaded: downloaded,
      failed: (summary.completed - downloaded - summary.waitingForNetwork)
          .clamp(0, summary.completed),
      // Downloads that were offline before and are not now: the cache limit
      // evicted them (unpinned, least recently played) to fit this batch. The
      // user asked for one thing and lost another, so the summary says so.
      evictedExisting: offlineBefore.difference(offlineAfter).length,
      running: false,
    );
  }
}
