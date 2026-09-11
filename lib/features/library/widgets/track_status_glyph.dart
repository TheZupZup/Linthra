import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/catalog/track_availability.dart';
import '../../../core/catalog/track_identity.dart';
import '../../../core/models/playback_source.dart';
import '../../../core/models/track.dart';
import '../../../core/repositories/download_repository.dart';
import '../../../core/repositories/download_store.dart';
import '../../../core/services/playback_source_label.dart';
import '../../../core/sources/source_availability.dart';
import '../../downloads/download_providers.dart';
import '../source_availability_providers.dart';

/// The single, non-interactive status glyph a library track row shows beside its
/// overflow menu.
///
/// It is the row's one status surface, and it speaks about two axes at once so
/// they can never contradict each other or double up:
///
///  * the **download task** — queued, downloading (a determinate ring when the
///    server reported a size), or failed. Transient and actionable, so it wins
///    whenever it has something to say.
///  * the **settled availability** — [TrackAvailabilityStatus], which answers
///    "will this still play when the server is away?" once nothing is being
///    transferred.
///
/// Splitting them across two widgets would let a row show an in-flight ring next
/// to an availability icon for the same track, which is how a quiet row turns
/// noisy. One widget, one glyph.
///
/// Nothing here is tappable and nothing is fetched: it mirrors the per-source
/// availability the probe controller already publishes and the offline-cache set
/// the download repository already maintains, so it costs no network and adds no
/// subscription to an idle row. On-device tracks render nothing at all.
///
/// Security: the only text this ever announces is a fixed, human-readable
/// server name ("Jellyfin", "Navidrome", "Plex") taken from
/// [PlaybackSourceLabel]'s safe vocabulary. A server URL, host, username, token,
/// or file path is never reachable from here.
class TrackStatusGlyph extends ConsumerWidget {
  const TrackStatusGlyph({
    required this.track,
    required this.isRemote,
    required this.downloadStatus,
    this.downloadProgress,
    super.key,
  });

  final Track track;

  /// Whether this track came off a server at all. On-device music is already
  /// local, so it has no offline story to tell and shows no glyph.
  final bool isRemote;

  final DownloadStatus downloadStatus;

  /// Download completion in the range 0.0–1.0 when known; `null` shows an
  /// indeterminate (spinning) ring while downloading.
  final double? downloadProgress;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!isRemote) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final Color muted = theme.colorScheme.onSurface.withValues(alpha: 0.5);

    // The task axis first, and before any `watch`: an in-flight download is the
    // only thing worth saying about this row, and an idle row must not pick up
    // subscriptions it will never read. Same reason the byte-progress watch is
    // kept to the downloading case.
    switch (downloadStatus) {
      case DownloadStatus.queued:
        return Icon(
          Icons.schedule,
          size: 18,
          color: muted,
          semanticLabel: 'Queued',
        );
      case DownloadStatus.downloading:
        // The other states name themselves; this one is a bare ring.
        return Semantics(
          label: 'Downloading',
          child: SizedBox.square(
            dimension: 16,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              value: downloadProgress,
            ),
          ),
        );
      case DownloadStatus.failed:
        return Icon(
          Icons.error_outline,
          size: 18,
          color: theme.colorScheme.error,
          semanticLabel: 'Download failed',
        );
      case DownloadStatus.downloaded:
      case DownloadStatus.notDownloaded:
        // Settled: nothing is being transferred, so the question becomes
        // whether this row still plays when its server is away.
        break;
    }

    // Scoped to *this* row's own source, so a probe of one server never rebuilds
    // another's rows. An unlisted source is reachable by construction — see
    // [sourceAvailabilityProvider].
    final SourceAvailability availability = ref.watch(
      sourceAvailabilityProvider.select(
        (Map<String, SourceAvailability> bySource) =>
            bySource[trackSourceId(track)] ?? SourceAvailability.available,
      ),
    );

    final bool isExplicitDownload = downloadStatus == DownloadStatus.downloaded;
    // An explicit download is a managed copy by definition, and saying so here
    // keeps the glyph correct on a row whose cache set hasn't been read yet
    // (and in tests that stub the download status alone).
    final bool hasOfflineCopy = isExplicitDownload ||
        ref.watch(
          offlineAvailableTrackKeysProvider.select(
            (Set<String> keys) =>
                keys.contains(CachedTrack.cacheKeyForTrack(track)),
          ),
        );

    final TrackAvailabilityStatus status = resolveTrackAvailability(
      isRemote: isRemote,
      hasOfflineCopy: hasOfflineCopy,
      isExplicitDownload: isExplicitDownload,
      availability: availability,
    );

    // The same safe names the now-playing "Playing from …" indicator uses, so
    // the two can never tell the listener different stories about one server.
    final String server = PlaybackSourceLabel.of(
      trackUri: track.uri,
      source: PlaybackSource.streamingDirect,
    );

    switch (status) {
      case TrackAvailabilityStatus.none:
        return const SizedBox.shrink();
      case TrackAvailabilityStatus.downloaded:
        return Icon(
          Icons.download_done,
          size: 18,
          color: theme.colorScheme.primary,
          semanticLabel: 'Downloaded',
        );
      case TrackAvailabilityStatus.cached:
        return Icon(
          Icons.offline_pin_outlined,
          size: 18,
          color: theme.colorScheme.primary,
          semanticLabel: 'Cached for offline play',
        );
      case TrackAvailabilityStatus.offlineCopy:
        // Filled where the cached state is outlined: this copy is not a
        // convenience, it is the only reason the row still plays.
        return Icon(
          Icons.offline_pin,
          size: 18,
          color: theme.colorScheme.primary,
          semanticLabel: 'Playing from offline copy',
        );
      case TrackAvailabilityStatus.checking:
        return Icon(
          Icons.cloud_sync_outlined,
          size: 18,
          color: muted,
          semanticLabel: 'Checking $server',
        );
      case TrackAvailabilityStatus.unreachable:
        return Icon(
          Icons.cloud_off_outlined,
          size: 18,
          color: theme.colorScheme.error,
          semanticLabel: '$server unavailable',
        );
      case TrackAvailabilityStatus.sessionRejected:
        return Icon(
          Icons.lock_outline,
          size: 18,
          color: theme.colorScheme.error,
          semanticLabel: '$server sign-in needed',
        );
    }
  }
}
