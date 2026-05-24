import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/dimens.dart';
import '../../../app/routes.dart';
import '../../../core/models/track.dart';
import '../../../core/repositories/download_repository.dart';
import '../../../data/repositories/download_repository_provider.dart';
import '../../downloads/download_providers.dart';
import '../../player/player_providers.dart';
import '../../player/widgets/album_artwork.dart';

/// The actions reachable from a track row's overflow menu. Which subset is
/// offered is context-aware: it depends on whether the track is remote and on
/// its current [DownloadStatus] (see `_OverflowMenu._menuItems`).
enum _TrackAction { playNext, download, removeOffline, retryDownload, cancel }

/// A single library track row.
///
/// The row is deliberately calm: artwork (or a placeholder), the title, and a
/// clean artist • album subtitle. Per-track actions live behind a trailing
/// 3-dots overflow menu rather than a dedicated button, so the list stays
/// uncluttered. Download state is still surfaced — but only as a subtle leading
/// glyph next to the menu, never as a large control.
///
/// Tapping the row plays the tapped track and queues the rest of [tracks]
/// behind it, then opens the now-playing screen — unchanged from before.
///
/// Source-awareness: offline/download actions only appear for *remote* tracks
/// (resolved through [remoteTrackDownloaderProvider], the same seam the
/// download repository uses). On-device tracks are already local, so showing
/// "Download for offline" on them would be meaningless — they only get the
/// queue action.
class TrackTile extends ConsumerWidget {
  const TrackTile({required this.tracks, required this.index, super.key});

  /// The whole visible list, so tapping one track queues the rest after it.
  final List<Track> tracks;
  final int index;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final track = tracks[index];
    final theme = Theme.of(context);
    final status =
        ref.watch(trackDownloadStatusProvider(track.id)).valueOrNull ??
            DownloadStatus.notDownloaded;
    final isRemote = ref.watch(remoteTrackDownloaderProvider).isRemote(track);

    return ListTile(
      leading: SizedBox.square(
        dimension: 48,
        child: AlbumArtwork(
          artworkUri: track.artworkUri,
          borderRadius: const BorderRadius.all(Radius.circular(AppRadii.sm)),
        ),
      ),
      title: Text(
        track.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.titleMedium,
      ),
      subtitle: Text(
        _subtitle(track),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
        ),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _StatusGlyph(status: status, isRemote: isRemote),
          _OverflowMenu(
            track: track,
            status: status,
            isRemote: isRemote,
          ),
        ],
      ),
      onTap: () {
        final controller = ref.read(playbackControllerProvider);
        controller.playTracks(tracks, startIndex: index);
        context.push(AppRoutes.player);
      },
    );
  }

  /// Prefer human-readable artist/album metadata; fall back to the raw
  /// uri/path when a track has no tags yet.
  static String _subtitle(Track track) {
    final parts = <String>[
      if (track.artistName != null && track.artistName!.isNotEmpty)
        track.artistName!,
      if (track.albumName != null && track.albumName!.isNotEmpty)
        track.albumName!,
    ];
    return parts.isEmpty ? track.uri : parts.join(' • ');
  }
}

/// The subtle, non-interactive download-state hint shown just before the
/// overflow menu. Nothing here is tappable — it only mirrors state so the row
/// stays quiet. Only meaningful for remote tracks; local tracks render nothing.
class _StatusGlyph extends StatelessWidget {
  const _StatusGlyph({required this.status, required this.isRemote});

  final DownloadStatus status;
  final bool isRemote;

  @override
  Widget build(BuildContext context) {
    if (!isRemote) return const SizedBox.shrink();
    final theme = Theme.of(context);
    switch (status) {
      case DownloadStatus.downloaded:
        return Icon(
          Icons.download_done,
          size: 18,
          color: theme.colorScheme.primary,
          semanticLabel: 'Downloaded',
        );
      case DownloadStatus.downloading:
        return const SizedBox.square(
          dimension: 16,
          child: CircularProgressIndicator(strokeWidth: 2),
        );
      case DownloadStatus.queued:
        return Icon(
          Icons.schedule,
          size: 18,
          color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
          semanticLabel: 'Queued',
        );
      case DownloadStatus.failed:
        return Icon(
          Icons.error_outline,
          size: 18,
          color: theme.colorScheme.error,
          semanticLabel: 'Download failed',
        );
      case DownloadStatus.notDownloaded:
        return const SizedBox.shrink();
    }
  }
}

/// The trailing 3-dots menu. Builds a context-aware action set and dispatches
/// the chosen one to the playback controller or download repository.
class _OverflowMenu extends ConsumerWidget {
  const _OverflowMenu({
    required this.track,
    required this.status,
    required this.isRemote,
  });

  final Track track;
  final DownloadStatus status;
  final bool isRemote;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return PopupMenuButton<_TrackAction>(
      icon: const Icon(Icons.more_vert),
      tooltip: 'More actions',
      onSelected: (action) => _run(ref, action),
      itemBuilder: (context) => _menuItems(),
    );
  }

  /// Context-aware action list. Offline actions are gated on [isRemote]; the
  /// rest depend on the track's [DownloadStatus]. The queue action is always
  /// available.
  List<PopupMenuEntry<_TrackAction>> _menuItems() {
    final items = <PopupMenuEntry<_TrackAction>>[];
    if (isRemote) {
      switch (status) {
        case DownloadStatus.notDownloaded:
          items.add(_item(_TrackAction.download, Icons.download_outlined,
              'Download for offline'));
        case DownloadStatus.queued:
        case DownloadStatus.downloading:
          items.add(_item(_TrackAction.cancel, Icons.close, 'Cancel download'));
        case DownloadStatus.downloaded:
          items.add(_item(_TrackAction.removeOffline, Icons.delete_outline,
              'Remove offline copy'));
        case DownloadStatus.failed:
          items.add(_item(
              _TrackAction.retryDownload, Icons.refresh, 'Retry download'));
          items.add(_item(_TrackAction.cancel, Icons.close, 'Cancel download'));
      }
    }
    items.add(_item(_TrackAction.playNext, Icons.queue_music, 'Play next'));
    return items;
  }

  PopupMenuItem<_TrackAction> _item(
    _TrackAction action,
    IconData icon,
    String label,
  ) {
    return PopupMenuItem<_TrackAction>(
      value: action,
      child: ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Icon(icon),
        title: Text(label),
      ),
    );
  }

  void _run(WidgetRef ref, _TrackAction action) {
    switch (action) {
      case _TrackAction.playNext:
        ref.read(playbackControllerProvider).playNext(track);
      case _TrackAction.download:
      case _TrackAction.retryDownload:
        ref.read(downloadRepositoryProvider).requestDownload(track);
      case _TrackAction.removeOffline:
      case _TrackAction.cancel:
        ref.read(downloadRepositoryProvider).removeDownload(track.id);
    }
  }
}
