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
import '../../playlists/widgets/add_to_playlist_sheet.dart';
import '../song_actions.dart';

/// The actions reachable from a track row's overflow menu. Which subset is
/// offered is context-aware: it depends on whether the track is remote and on
/// its current [DownloadStatus] (see `_OverflowMenu._menuItems`).
enum _TrackAction {
  playNext,
  addToQueue,
  addToPlaylist,
  download,
  removeOffline,
  retryDownload,
  cancel,
  removeFromLibrary,
}

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
/// Selection: when [selectable] is set, a long-press starts multi-select via
/// [onSelectStart] and, while [selectionActive], a tap toggles this row via
/// [onSelectToggle] instead of playing. Hosts that don't pass these (e.g.
/// Favorites) keep the plain tap-to-play behaviour.
///
/// Source-awareness: offline/download actions only appear for *remote* tracks
/// (resolved through [remoteTrackDownloaderProvider], the same seam the
/// download repository uses). On-device tracks are already local, so showing
/// "Download for offline" on them would be meaningless — they only get the
/// queue/playlist/remove actions.
class TrackTile extends ConsumerWidget {
  const TrackTile({
    required this.tracks,
    required this.index,
    this.selectable = false,
    this.selectionActive = false,
    this.selected = false,
    this.onSelectToggle,
    this.onSelectStart,
    super.key,
  });

  /// The whole visible list, so tapping one track queues the rest after it.
  final List<Track> tracks;
  final int index;

  /// Whether this row participates in multi-select at all.
  final bool selectable;

  /// Whether the host is currently in selection mode (so a tap toggles).
  final bool selectionActive;

  /// Whether this row is currently selected.
  final bool selected;

  final VoidCallback? onSelectToggle;
  final VoidCallback? onSelectStart;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final track = tracks[index];
    final theme = Theme.of(context);
    final status =
        ref.watch(trackDownloadStatusProvider(track.id)).valueOrNull ??
            DownloadStatus.notDownloaded;
    final isRemote = ref.watch(remoteTrackDownloaderProvider).isRemote(track);
    // Only the actively-downloading row watches byte progress, so idle rows add
    // no subscription. Null total (or not downloading) leaves the ring spinning.
    final double? downloadFraction = status == DownloadStatus.downloading
        ? ref
            .watch(trackDownloadProgressProvider(track.id))
            .valueOrNull
            ?.fraction
        : null;

    return ListTile(
      selected: selectionActive && selected,
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
        style: theme.textTheme.titleMedium?.copyWith(
          fontWeight: FontWeight.w600,
        ),
      ),
      subtitle: Text(
        _subtitle(track),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
        ),
      ),
      trailing: selectionActive
          ? Checkbox(
              value: selected,
              onChanged:
                  onSelectToggle == null ? null : (_) => onSelectToggle!(),
            )
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _StatusGlyph(
                  status: status,
                  isRemote: isRemote,
                  progress: downloadFraction,
                ),
                _OverflowMenu(
                  track: track,
                  status: status,
                  isRemote: isRemote,
                ),
              ],
            ),
      onTap: () {
        if (selectionActive) {
          onSelectToggle?.call();
          return;
        }
        final controller = ref.read(playbackControllerProvider);
        controller.playTracks(tracks, startIndex: index);
        context.push(AppRoutes.player);
      },
      onLongPress: (selectable && !selectionActive) ? onSelectStart : null,
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
  const _StatusGlyph({
    required this.status,
    required this.isRemote,
    this.progress,
  });

  final DownloadStatus status;
  final bool isRemote;

  /// Download completion in the range 0.0–1.0 when known; `null` shows an
  /// indeterminate (spinning) ring while downloading.
  final double? progress;

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
        return SizedBox.square(
          dimension: 16,
          child: CircularProgressIndicator(strokeWidth: 2, value: progress),
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
/// the chosen one to the playback controller, download repository, or the safe
/// remove actions.
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
      onSelected: (action) => _run(context, ref, action),
      itemBuilder: (context) => _menuItems(),
    );
  }

  /// Context-aware action list. Offline actions are gated on [isRemote]; the
  /// rest depend on the track's [DownloadStatus]. The queue, add-to-playlist,
  /// and remove-from-Linthra actions are always available.
  List<PopupMenuEntry<_TrackAction>> _menuItems() {
    final items = <PopupMenuEntry<_TrackAction>>[
      _item(_TrackAction.playNext, Icons.queue_music, 'Play next'),
      _item(_TrackAction.addToQueue, Icons.add_to_queue, 'Add to queue'),
      _item(_TrackAction.addToPlaylist, Icons.playlist_add, 'Add to playlist'),
    ];
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
    items.add(_item(_TrackAction.removeFromLibrary, Icons.remove_circle_outline,
        'Remove from Linthra'));
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

  Future<void> _run(
    BuildContext context,
    WidgetRef ref,
    _TrackAction action,
  ) async {
    switch (action) {
      case _TrackAction.playNext:
        ref.read(playbackControllerProvider).playNext(track);
      case _TrackAction.addToQueue:
        ref.read(playbackControllerProvider).addToQueue(track);
      case _TrackAction.addToPlaylist:
        await showAddToPlaylistSheet(context, <Track>[track]);
      case _TrackAction.download:
      case _TrackAction.retryDownload:
        await _download(context, ref);
      case _TrackAction.cancel:
        // Cancelling an in-flight/queued download is not destructive to a saved
        // copy, so it needs no confirmation.
        await ref.read(downloadRepositoryProvider).removeDownload(track.id);
      case _TrackAction.removeOffline:
        await SongActions.removeOfflineCopies(context, ref, <Track>[track]);
      case _TrackAction.removeFromLibrary:
        await SongActions.removeFromLibrary(context, ref, <Track>[track]);
    }
  }

  /// Starts the download, surfacing the friendly, secret-free reasons it might
  /// not start: a full cache with nothing safe to evict, or the network policy
  /// queueing it (mobile data not allowed, or offline). Other errors fall
  /// through to the row's "failed" indicator (with a retry action).
  Future<void> _download(BuildContext context, WidgetRef ref) async {
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
