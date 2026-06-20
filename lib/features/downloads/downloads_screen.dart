import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/dimens.dart';
import '../../core/models/cache_size.dart';
import '../../core/models/download_progress.dart';
import '../../core/models/track.dart';
import '../../core/repositories/download_repository.dart';
import '../../core/repositories/download_store.dart';
import '../../core/services/offline_cache_manager.dart';
import '../../data/repositories/download_repository_provider.dart';
import '../../shared/widgets/empty_state.dart';
import '../player/now_playing.dart';
import '../player/widgets/track_artwork.dart';
import '../settings/network/network_settings_section.dart';
import 'download_providers.dart';

/// Manage explicit, user-controlled downloads. Lists the tracks the user has
/// marked for offline use — both the ones still in flight (queued / downloading
/// with live progress / failed) and the finished ones — with their cache size
/// and a "Keep offline" pin, shows how much cache is in use, and exposes the
/// "Allow mobile data" preference. Downloads are always user-initiated — never
/// automatic.
class DownloadsScreen extends ConsumerWidget {
  const DownloadsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: const Text('Downloads')),
      body: const Column(
        children: [
          _CacheUsageHeader(),
          MobileDataDownloadsTile(),
          Divider(height: 1),
          Expanded(child: _DownloadsBody()),
        ],
      ),
    );
  }
}

/// A slim "used of limit" header. The full controls (change limit, clear) live
/// on the Settings screen; this is a glanceable status line.
class _CacheUsageHeader extends ConsumerWidget {
  const _CacheUsageHeader();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);
    final int maxBytes =
        ref.watch(maxCacheBytesControllerProvider).valueOrNull ??
            CacheSize.defaultLimit;
    final CacheSnapshot snapshot =
        ref.watch(cacheSnapshotProvider).valueOrNull ?? CacheSnapshot.empty;
    final double fraction =
        maxBytes <= 0 ? 0 : (snapshot.usedBytes / maxBytes).clamp(0.0, 1.0);

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        AppSpacing.md,
        AppSpacing.md,
        AppSpacing.sm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '${CacheSize.formatBytes(snapshot.usedBytes)} of '
            '${CacheSize.formatBytes(maxBytes)} cache used',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
          ClipRRect(
            borderRadius: BorderRadius.circular(AppRadii.pill),
            child: LinearProgressIndicator(
              value: fraction,
              minHeight: 6,
              backgroundColor: theme.colorScheme.surfaceContainerHighest,
            ),
          ),
        ],
      ),
    );
  }
}

/// The scrolling body: in-flight downloads (queued / downloading / failed) on
/// top so caching progress is visible at a glance, then the finished downloads.
/// Both lists are live. The calm "nothing downloaded" empty state shows only
/// when nothing is in flight *and* nothing is finished; a library read error
/// falls back to one friendly, leak-free line.
class _DownloadsBody extends ConsumerWidget {
  const _DownloadsBody();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final List<ActiveDownload> active =
        ref.watch(activeDownloadsProvider).valueOrNull ??
            const <ActiveDownload>[];
    final AsyncValue<List<Track>> downloaded =
        ref.watch(downloadedTracksProvider);

    return downloaded.when(
      // While the finished list loads, still show any in-flight work.
      loading: () => active.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : _DownloadsList(active: active, downloaded: const <Track>[]),
      // Never surface raw exception text (it can carry paths or store detail);
      // show one calm, friendly line instead (the same source feeds [active],
      // so it is empty here too).
      error: (_, __) => const EmptyState(
        icon: Icons.error_outline,
        title: "Couldn't load downloads",
        message:
            'Something went wrong reading your downloads. Try again later.',
      ),
      data: (tracks) {
        if (active.isEmpty && tracks.isEmpty) {
          return const EmptyState(
            icon: Icons.download_outlined,
            title: 'Nothing downloaded',
            message: 'Downloads you start will appear here.',
          );
        }
        return _DownloadsList(active: active, downloaded: tracks);
      },
    );
  }
}

/// The combined list. Section headers appear only when both sections are
/// present, so a screen with just finished downloads stays as clean as before.
class _DownloadsList extends StatelessWidget {
  const _DownloadsList({required this.active, required this.downloaded});

  final List<ActiveDownload> active;
  final List<Track> downloaded;

  @override
  Widget build(BuildContext context) {
    final bool bothSections = active.isNotEmpty && downloaded.isNotEmpty;
    return ListView(
      children: [
        if (active.isNotEmpty) ...[
          const _SectionHeader('In progress'),
          for (final ActiveDownload item in active)
            _ActiveDownloadTile(track: item.track, status: item.status),
        ],
        if (downloaded.isNotEmpty) ...[
          if (bothSections) const _SectionHeader('Downloaded'),
          for (final Track track in downloaded) _DownloadedTile(track: track),
        ],
      ],
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        AppSpacing.md,
        AppSpacing.md,
        AppSpacing.xs,
      ),
      child: Text(
        label,
        style: theme.textTheme.labelLarge?.copyWith(
          color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
          fontWeight: FontWeight.w600,
          letterSpacing: 0.4,
        ),
      ),
    );
  }
}

/// One in-flight download row: queued, downloading (with a live progress bar and
/// byte read-out when the server reported a size), or failed. Cancel is always
/// offered; a failed row also offers Retry. Nothing here shows a URL or path —
/// only the track's own metadata and non-secret byte counts.
class _ActiveDownloadTile extends ConsumerWidget {
  const _ActiveDownloadTile({required this.track, required this.status});

  final Track track;
  final DownloadStatus status;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Only the downloading row subscribes to byte progress; queued/failed rows
    // need none, so idle rows add no stream listener.
    final DownloadProgress? progress = status == DownloadStatus.downloading
        ? ref.watch(trackDownloadProgressProvider(track.id)).valueOrNull
        : null;
    final NowPlayingRowState? nowPlaying =
        ref.watch(nowPlayingProvider.select((n) => n.stateForRow(track)));

    return ListTile(
      leading: TrackArtwork(
        artworkUri: track.artworkUri,
        nowPlaying: nowPlaying,
        dimension: 44,
      ),
      title: Text(track.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: _ActiveSubtitle(status: status, progress: progress),
      isThreeLine: status == DownloadStatus.downloading,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (status == DownloadStatus.failed)
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: 'Retry download',
              onPressed: () => _retry(context, ref),
            ),
          IconButton(
            icon: const Icon(Icons.close),
            tooltip: 'Cancel download',
            onPressed: () =>
                ref.read(downloadRepositoryProvider).removeDownload(track),
          ),
        ],
      ),
    );
  }

  /// Re-requests the download. Surfaces the friendly, secret-free reasons it
  /// might not start — a full cache, or the network policy queueing it — while
  /// any other failure simply lands back in the row's failed state (which keeps
  /// offering Retry).
  Future<void> _retry(BuildContext context, WidgetRef ref) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    try {
      final DownloadRequestOutcome outcome =
          await ref.read(downloadRepositoryProvider).requestDownload(track);
      final String? message = outcome.blockedMessage;
      if (message != null) {
        messenger.showSnackBar(SnackBar(content: Text(message)));
      }
    } on CacheStorageException catch (error) {
      messenger.showSnackBar(SnackBar(content: Text(error.message)));
    }
  }
}

/// The subtitle for an in-flight row: a status line, plus a live progress bar
/// while downloading. Progress is determinate when the server reported a size,
/// otherwise an indeterminate bar — matching [DownloadProgress.fraction].
class _ActiveSubtitle extends StatelessWidget {
  const _ActiveSubtitle({required this.status, required this.progress});

  final DownloadStatus status;
  final DownloadProgress? progress;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    if (status != DownloadStatus.downloading) {
      return Text(
        _label(status),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall?.copyWith(
          color: status == DownloadStatus.failed
              ? theme.colorScheme.error
              : theme.colorScheme.onSurface.withValues(alpha: 0.6),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          _downloadingLabel(progress),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
          ),
        ),
        const SizedBox(height: AppSpacing.xs),
        ClipRRect(
          borderRadius: BorderRadius.circular(AppRadii.pill),
          child: LinearProgressIndicator(
            value: progress?.fraction,
            minHeight: 4,
            backgroundColor: theme.colorScheme.surfaceContainerHighest,
          ),
        ),
      ],
    );
  }

  static String _label(DownloadStatus status) {
    switch (status) {
      case DownloadStatus.queued:
        return 'Queued';
      case DownloadStatus.failed:
        return 'Download failed';
      case DownloadStatus.downloading:
      case DownloadStatus.downloaded:
      case DownloadStatus.notDownloaded:
        return '';
    }
  }

  /// A friendly, secret-free downloading line: a percent + byte read-out when
  /// the size is known, the bytes so far when it isn't, or a plain label before
  /// the first byte arrives.
  static String _downloadingLabel(DownloadProgress? progress) {
    if (progress == null) return 'Downloading…';
    final int? percent = progress.percent;
    if (percent != null && progress.totalBytes != null) {
      return 'Downloading… $percent%  •  '
          '${CacheSize.formatBytes(progress.receivedBytes)} of '
          '${CacheSize.formatBytes(progress.totalBytes!)}';
    }
    if (progress.receivedBytes > 0) {
      return 'Downloading… ${CacheSize.formatBytes(progress.receivedBytes)}';
    }
    return 'Downloading…';
  }
}

/// A finished-download row: artwork, title, an artist • size subtitle, and the
/// pin ("Keep offline") + remove controls.
class _DownloadedTile extends ConsumerWidget {
  const _DownloadedTile({required this.track});

  final Track track;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final CachedTrack? entry = ref.watch(cacheEntriesByIdProvider)[track.id];
    final bool pinned = entry?.pinned ?? false;
    final NowPlayingRowState? nowPlaying =
        ref.watch(nowPlayingProvider.select((n) => n.stateForRow(track)));
    return ListTile(
      leading: TrackArtwork(
        artworkUri: track.artworkUri,
        nowPlaying: nowPlaying,
        dimension: 44,
      ),
      title: Text(track.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: _subtitle(track, entry),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: Icon(pinned ? Icons.push_pin : Icons.push_pin_outlined),
            color: pinned ? Theme.of(context).colorScheme.secondary : null,
            tooltip: pinned ? 'Unpin' : 'Keep offline',
            onPressed: () =>
                ref.read(offlineCacheManagerProvider).setPinned(track, !pinned),
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Remove download',
            onPressed: () =>
                ref.read(downloadRepositoryProvider).removeDownload(track),
          ),
        ],
      ),
    );
  }

  static Widget? _subtitle(Track track, CachedTrack? entry) {
    final String? artist = track.artistName;
    final bool hasArtist = artist != null && artist.isNotEmpty;
    final bool hasSize = entry != null && entry.sizeBytes > 0;
    if (!hasArtist && !hasSize) return null;
    final String text = <String>[
      if (hasArtist) artist,
      if (hasSize) CacheSize.formatBytes(entry.sizeBytes),
    ].join('  •  ');
    return Text(text, maxLines: 1, overflow: TextOverflow.ellipsis);
  }
}
