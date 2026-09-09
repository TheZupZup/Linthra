import 'package:flutter/foundation.dart';

import '../repositories/download_repository.dart';

/// The state of one "Download all" batch: an album or a playlist the user
/// deliberately asked to take offline.
///
/// The same type is emitted while the batch runs (with [running] true, as live
/// progress) and once it finishes. [completed] is the honest live signal: how
/// many of the batch's tracks the download repository has finished working
/// through so far. [downloaded] and [failed] are meaningful only on the final
/// summary: they are counted once, at the end, from the repository's own record
/// of what is actually available offline, rather than inferred from the request
/// calls.
///
/// Security note: every field is a plain count, a flag, or the collection name
/// the user just tapped, never a URL, token, or file path, so a summary is safe
/// to show verbatim.
@immutable
class BulkDownloadSummary {
  const BulkDownloadSummary({
    required this.label,
    required this.total,
    this.alreadyOffline = 0,
    this.completed = 0,
    this.downloaded = 0,
    this.waitingForNetwork = 0,
    this.waitingReason,
    this.failed = 0,
    this.evictedExisting = 0,
    this.running = false,
    this.canceled = false,
    this.outOfSpace = false,
  });

  /// What the user asked to download ("Abbey Road"), for the progress line.
  final String label;

  /// Unique tracks in the batch, after duplicates were collapsed.
  final int total;

  /// Tracks that already had an offline copy before the batch started. They are
  /// never re-requested, so asking for the album again neither re-fetches nor
  /// endangers what is already downloaded.
  final int alreadyOffline;

  /// How many of the [requested] tracks the repository has finished with, in any
  /// way. The live "12 of 30" number.
  final int completed;

  /// Tracks this batch newly made available offline. Final summary only.
  final int downloaded;

  /// Tracks the network policy queued rather than downloaded (mobile data not
  /// allowed, or offline). They stay queued for a retry, exactly as a single
  /// queued track does.
  final int waitingForNetwork;

  /// Why the network policy held tracks back, taken from the first request it
  /// queued, so the batch can repeat the same friendly, secret-free explanation
  /// a single queued track gets. Null when nothing was held back.
  final DownloadRequestOutcome? waitingReason;

  /// Tracks that were requested but ended with neither an offline copy nor a
  /// network wait: the partial failures. Each keeps the repository's `failed`
  /// status, so the Downloads screen offers it a retry. Final summary only.
  final int failed;

  /// Downloads that existed before this batch and no longer do: the cache limit
  /// evicted them (least-recently-played and unpinned first) to make room. Never
  /// includes anything the user pinned with "Keep offline". Worth telling the
  /// user about, since they asked for one thing and lost another.
  final int evictedExisting;

  /// True while the batch is still working through its tracks.
  final bool running;

  /// True when the batch was stopped before it reached the end.
  final bool canceled;

  /// True when the cache limit stopped the batch: the cache was full with
  /// nothing safe to evict, so the remaining tracks were never requested.
  final bool outOfSpace;

  /// How many of the batch's tracks are available offline now: the ones that
  /// already were, plus the ones this batch downloaded.
  int get offlineNow => alreadyOffline + downloaded;

  /// How many tracks the batch actually asks the repository for.
  int get requested => total - alreadyOffline;

  /// Requested tracks the batch produced nothing for because it stopped early:
  /// the ones it never reached, plus (when [outOfSpace]) the one the full cache
  /// refused. Zero for a batch that ran to the end.
  int get notAttempted => requested - completed;

  BulkDownloadSummary copyWith({
    int? alreadyOffline,
    int? completed,
    int? downloaded,
    int? waitingForNetwork,
    DownloadRequestOutcome? waitingReason,
    int? failed,
    int? evictedExisting,
    bool? running,
    bool? canceled,
    bool? outOfSpace,
  }) {
    return BulkDownloadSummary(
      label: label,
      total: total,
      alreadyOffline: alreadyOffline ?? this.alreadyOffline,
      completed: completed ?? this.completed,
      downloaded: downloaded ?? this.downloaded,
      waitingForNetwork: waitingForNetwork ?? this.waitingForNetwork,
      waitingReason: waitingReason ?? this.waitingReason,
      failed: failed ?? this.failed,
      evictedExisting: evictedExisting ?? this.evictedExisting,
      running: running ?? this.running,
      canceled: canceled ?? this.canceled,
      outOfSpace: outOfSpace ?? this.outOfSpace,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is BulkDownloadSummary &&
          other.label == label &&
          other.total == total &&
          other.alreadyOffline == alreadyOffline &&
          other.completed == completed &&
          other.downloaded == downloaded &&
          other.waitingForNetwork == waitingForNetwork &&
          other.waitingReason == waitingReason &&
          other.failed == failed &&
          other.evictedExisting == evictedExisting &&
          other.running == running &&
          other.canceled == canceled &&
          other.outOfSpace == outOfSpace);

  @override
  int get hashCode => Object.hash(
        label,
        total,
        alreadyOffline,
        completed,
        downloaded,
        waitingForNetwork,
        waitingReason,
        failed,
        evictedExisting,
        running,
        canceled,
        outOfSpace,
      );
}

/// The one friendly, secret-free line that tells the user how a batch ended.
///
/// Lives next to the summary (not in a widget) so the wording is written once,
/// unit-tested without pumping a screen, and identical wherever a batch is
/// reported. It reuses [DownloadRequestOutcomeMessage.blockedMessage] for the
/// network cases, so a queued album explains itself exactly as a queued track
/// does. Like the summary itself it can only ever carry counts and the
/// collection name, never a URL, token, or path.
extension BulkDownloadSummaryMessage on BulkDownloadSummary {
  String get completionMessage {
    if (total == 0) return 'Nothing to download.';
    if (requested == 0) {
      return 'Every song in “$label” is already available offline.';
    }
    // Held back before anything downloaded: lead with the reason, which is the
    // only thing the user can act on.
    if (downloaded == 0 && failed == 0 && waitingForNetwork > 0) {
      final String reason = waitingReason?.blockedMessage ?? '';
      final String queued = waitingForNetwork == 1
          ? '1 song from “$label” is queued.'
          : '$waitingForNetwork songs from “$label” are queued.';
      return reason.isEmpty ? queued : '$queued $reason';
    }
    if (outOfSpace) {
      return '${_progressSentence()} There is not enough cache space for the '
          'rest. Free up space or raise the cache limit in Settings.';
    }
    if (canceled) return 'Stopped. ${_progressSentence()}${_evictionNote()}';
    if (offlineNow == total) {
      final String done = total == 1
          ? '“$label” is available offline.'
          : 'All $total songs from “$label” are available offline.';
      return '$done${_evictionNote()}';
    }
    final StringBuffer buffer = StringBuffer(_progressSentence());
    if (waitingForNetwork > 0) {
      buffer.write(
        waitingForNetwork == 1
            ? ' 1 is queued for later.'
            : ' $waitingForNetwork are queued for later.',
      );
    }
    if (failed > 0) {
      buffer.write(
        failed == 1
            ? ' 1 failed. Retry it from Downloads.'
            : ' $failed failed. Retry them from Downloads.',
      );
    }
    buffer.write(_evictionNote());
    return buffer.toString();
  }

  String _progressSentence() =>
      'Downloaded $offlineNow of $total songs from “$label”.';

  /// Says so when the cache limit had to evict earlier downloads to fit this
  /// batch, rather than letting the user discover it themselves.
  String _evictionNote() {
    if (evictedExisting <= 0) return '';
    return evictedExisting == 1
        ? ' 1 earlier download was removed to stay under the cache limit.'
        : ' $evictedExisting earlier downloads were removed to stay under the '
            'cache limit.';
  }
}
