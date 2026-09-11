import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/routes.dart';
import '../../../core/catalog/library_grouping.dart';
import '../../../core/models/track.dart';
import '../../../core/repositories/download_repository.dart';
import '../../../core/repositories/download_store.dart';
import '../../../data/repositories/download_repository_provider.dart';
import '../../../data/repositories/favorites_repository_provider.dart';
import '../../../shared/widgets/context_menu_region.dart';
import '../../downloads/download_providers.dart';
import '../../player/favorites_providers.dart';
import '../../player/now_playing.dart';
import '../../player/player_providers.dart';
import '../../player/widgets/track_artwork.dart';
import '../../playlists/playlist_drag.dart';
import '../../playlists/widgets/add_to_playlist_sheet.dart';
import '../library_browse_providers.dart';
import '../song_actions.dart';
import 'track_status_glyph.dart';

/// The actions reachable from a track row's overflow menu. Which subset is
/// offered is context-aware: it depends on whether the track is remote and on
/// its current [DownloadStatus] (see `_OverflowMenu._menuItems`).
enum _TrackAction {
  toggleFavorite,
  playNext,
  addToQueue,
  addToPlaylist,
  download,
  removeOffline,
  retryDownload,
  cancel,
  showAlbum,
  showArtist,
  removeFromLibrary,
}

/// A single library track row.
///
/// The row is deliberately calm: artwork (or a placeholder), the title, and a
/// clean artist • album subtitle. Per-track actions live behind a trailing
/// 3-dots overflow menu rather than a dedicated button, so the list stays
/// uncluttered. Status is still surfaced — but only as one subtle glyph next to
/// the menu, never as a large control: its download task and whether the row
/// still plays with its server away, both handled by [TrackStatusGlyph].
///
/// Tapping the row plays the tapped track and queues the rest of [tracks]
/// behind it, then opens the now-playing screen — unchanged from before.
///
/// Selection: when [selectable] is set, a long-press starts multi-select via
/// [onSelectStart] and, while [selectionActive], a tap toggles this row via
/// [onSelectToggle] instead of playing. Hosts that don't pass these (e.g.
/// Favorites) keep the plain tap-to-play behaviour.
///
/// With a keyboard attached the modifiers a desktop list is expected to honour
/// work too (#387), whether or not a selection is already running: Ctrl-click
/// (Cmd on macOS) toggles this row alone, and Shift-click extends from the last
/// row picked to this one through [onSelectRange]. They are read off the
/// hardware keyboard at tap time rather than gated on a platform, so a keyboard
/// case on a tablet gets them for free and a bare touch tap is unchanged.
///
/// On desktop the row is also a drag source for playlists (#389): pulling it
/// sideways picks up this track, or the whole selection when this row is part
/// of one, and dropping it on a playlist adds it. A vertical drag still
/// scrolls the list, and nothing about this exists on mobile. The keyboard and
/// menu route to the same operation, "Add to playlist", is unchanged and stays
/// the accessible path.
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
    this.onSelectRange,
    this.dragSelection,
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

  /// Shift-click: select everything between the host's anchor and this row.
  ///
  /// Handed the exact list this row is in, already sorted and filtered as the
  /// user sees it, so a range can never span rows that are not on screen
  /// between its two ends.
  final void Function(List<Track> tracks, int index)? onSelectRange;

  /// The host's current selection, for a drag that starts on a selected row.
  ///
  /// A callback rather than a list because it is only ever called if a drag
  /// actually starts: resolving the selection eagerly would be an O(n) walk
  /// per row on every rebuild, which a 200k-track library cannot afford.
  /// Hosts without selection leave it null and a drag carries this row alone.
  final List<Track> Function()? dragSelection;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final track = tracks[index];
    final theme = Theme.of(context);
    // Only this row's own now-playing state is selected, so a track change that
    // doesn't affect this row never rebuilds it.
    final NowPlayingRowState? nowPlaying =
        ref.watch(nowPlayingProvider.select((n) => n.stateForRow(track)));
    // The provider-aware cache key joins this row to its own copy's status, so
    // two providers' same-id copies never share a download indicator.
    final String cacheKey = CachedTrack.cacheKeyForTrack(track);
    final status =
        ref.watch(trackDownloadStatusProvider(cacheKey)).valueOrNull ??
            DownloadStatus.notDownloaded;
    final isRemote = ref.watch(remoteTrackDownloaderProvider).isRemote(track);
    // Only the actively-downloading row watches byte progress, so idle rows add
    // no subscription. Null total (or not downloading) leaves the ring spinning.
    final double? downloadFraction = status == DownloadStatus.downloading
        ? ref
            .watch(trackDownloadProgressProvider(cacheKey))
            .valueOrNull
            ?.fraction
        : null;

    final Widget row = ListTile(
      selected: selectionActive && selected,
      leading: TrackArtwork(
        artworkUri: track.artworkUri,
        nowPlaying: nowPlaying,
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
          // The row itself already carries the selected state (and toggles on
          // tap), so the box is the visual echo of it: a second, unnamed
          // checkbox node next to every title would only make the list harder
          // to move through, not clearer.
          ? ExcludeSemantics(
              child: Checkbox(
                value: selected,
                onChanged:
                    onSelectToggle == null ? null : (_) => onSelectToggle!(),
              ),
            )
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                TrackStatusGlyph(
                  track: track,
                  isRemote: isRemote,
                  downloadStatus: status,
                  downloadProgress: downloadFraction,
                ),
                _OverflowMenu(
                  track: track,
                  status: status,
                  isRemote: isRemote,
                ),
              ],
            ),
      onTap: () {
        if (selectable && _extendsSelection) {
          onSelectRange?.call(tracks, index);
          return;
        }
        // Ctrl (or Cmd) picks this row out on its own, and starts a selection
        // when there isn't one — the whole point of it on a desktop, where
        // holding a row down for half a second to begin is not the gesture
        // anybody reaches for.
        if (selectable && _togglesSelection) {
          if (selectionActive) {
            onSelectToggle?.call();
          } else {
            onSelectStart?.call();
          }
          return;
        }
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

    // The same menu the 3-dot button opens, on right-click and on the
    // keyboard's menu key (#386). Built at open time, so it reflects the
    // favourite and download state as it is then rather than as it was when the
    // row was laid out. Withheld while selecting: the app bar is acting on the
    // whole selection there, and a per-row menu would be acting on one row.
    final Widget menu = ContextMenuRegion<_TrackAction>(
      enabled: !selectionActive,
      itemBuilder: (BuildContext context) => _trackMenuItems(
        track: track,
        isFavorite: ref.read(isFavoriteProvider(track.uri)),
        isRemote: isRemote,
        status: status,
        hasAlbumPage: _hasAlbumPage(ref, track),
        hasArtistPage: _hasArtistPage(ref, track),
      ),
      onSelected: (_TrackAction action) =>
          _runTrackAction(context, ref, track, action),
      child: row,
    );

    return PlaylistTrackDraggable(
      tracks: () => dragPayloadFor(
        track: track,
        selectionActive: selectionActive,
        selected: selected,
        selection: dragSelection,
      ),
      child: menu,
    );
  }

  /// Whether the modifiers held right now mean "toggle just this row".
  ///
  /// Cmd counts alongside Ctrl so the row behaves the way a macOS list does;
  /// Shift wins when both are down, which is what every file manager does.
  static bool get _togglesSelection {
    final HardwareKeyboard keyboard = HardwareKeyboard.instance;
    return !keyboard.isShiftPressed &&
        (keyboard.isControlPressed || keyboard.isMetaPressed);
  }

  static bool get _extendsSelection => HardwareKeyboard.instance.isShiftPressed;

  /// Prefer human-readable artist/album metadata; fall back to the raw
  /// uri/path when a track has no tags yet.
  static String _subtitle(Track track) {
    final String label = track.artistAlbumLabel;
    return label.isEmpty ? track.uri : label;
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
    // Keyed by the provider-namespaced uri, so local/Jellyfin/Subsonic copies
    // each reflect their own heart. Watched here so the menu label/icon stay
    // live if the favourite state changes while the row is on screen.
    final bool isFavorite = ref.watch(isFavoriteProvider(track.uri));
    return PopupMenuButton<_TrackAction>(
      icon: const Icon(Icons.more_vert),
      tooltip: 'More actions',
      onSelected: (action) => _run(context, ref, action),
      itemBuilder: (context) => _menuItems(ref, isFavorite),
    );
  }

  /// Context-aware action list. Offline actions are gated on [isRemote]; the
  /// rest depend on the track's [DownloadStatus]. The favourite toggle, queue,
  /// add-to-playlist, and remove-from-Linthra actions are always available.
  List<PopupMenuEntry<_TrackAction>> _menuItems(
    WidgetRef ref,
    bool isFavorite,
  ) {
    return _trackMenuItems(
      track: track,
      isFavorite: isFavorite,
      isRemote: isRemote,
      status: status,
      hasAlbumPage: _hasAlbumPage(ref, track),
      hasArtistPage: _hasArtistPage(ref, track),
    );
  }

  Future<void> _run(
    BuildContext context,
    WidgetRef ref,
    _TrackAction action,
  ) =>
      _runTrackAction(context, ref, track, action);
}

/// Whether this track's album has a page to open.
///
/// A row is not proof the catalog knows the album: the folder browser lists a
/// server's tree on demand, so it shows tracks that were never synced into the
/// flat catalog. `AlbumDetailScreen` resolves ids against that catalog alone,
/// so offering "Show album" for one of those rows lands the user on "Album not
/// found" right after they picked a song that plays fine.
///
/// Read, not watched: the menu is built when it opens, so this is the answer at
/// that moment. Both detail screens derive their ids the same way, so a hit
/// here is the page the Albums tab would have opened.
bool _hasAlbumPage(WidgetRef ref, Track track) =>
    ref.read(libraryAlbumIdsProvider).contains(albumIdForTrack(track));

/// Whether this track's artist has a page to open. See [_hasAlbumPage].
bool _hasArtistPage(WidgetRef ref, Track track) =>
    ref.read(libraryArtistIdsProvider).contains(artistIdForTrack(track));

/// The row's action list, built fresh so it always reflects the current
/// favourite and download state.
///
/// Shared by the trailing 3-dot button and the row's right-click menu (#386):
/// one list, one dispatcher, so a right-click can never offer an action a tap
/// cannot — or run it differently.
List<PopupMenuEntry<_TrackAction>> _trackMenuItems({
  required Track track,
  required bool isFavorite,
  required bool isRemote,
  required DownloadStatus status,
  required bool hasAlbumPage,
  required bool hasArtistPage,
}) {
  final items = <PopupMenuEntry<_TrackAction>>[
    _item(
      _TrackAction.toggleFavorite,
      isFavorite ? Icons.favorite : Icons.favorite_border,
      isFavorite ? 'Remove from favorites' : 'Add to favorites',
    ),
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
        items.add(
            _item(_TrackAction.retryDownload, Icons.refresh, 'Retry download'));
        items.add(_item(_TrackAction.cancel, Icons.close, 'Cancel download'));
    }
  }
  // Navigation, last before the destructive action and separated from the
  // rest: "where does this song live" is a different question from "do
  // something to it". Offered only where there is somewhere to go — a track
  // with no album tags has no album page to open.
  final bool hasAlbum = hasAlbumPage &&
      ((track.albumName ?? '').trim().isNotEmpty ||
          (track.albumId ?? '').trim().isNotEmpty);
  final bool hasArtist =
      hasArtistPage && (track.artistName ?? '').trim().isNotEmpty;
  if (hasAlbum || hasArtist) {
    items.add(const PopupMenuDivider());
    if (hasAlbum) {
      items.add(
          _item(_TrackAction.showAlbum, Icons.album_outlined, 'Show album'));
    }
    if (hasArtist) {
      items.add(
          _item(_TrackAction.showArtist, Icons.person_outline, 'Show artist'));
    }
    items.add(const PopupMenuDivider());
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

/// Runs one action against the shared commands — the playback controller, the
/// favourites and download repositories, the safe remove actions — so the menu
/// owns no business logic of its own.
Future<void> _runTrackAction(
  BuildContext context,
  WidgetRef ref,
  Track track,
  _TrackAction action,
) async {
  switch (action) {
    case _TrackAction.toggleFavorite:
      // Like/unlike without touching playback or the queue. Re-read the
      // current state so the toggle is correct even if the heart changed
      // after the menu opened, and hand the real [Track] to the repository so
      // its uri routes local/Jellyfin/Subsonic favourites (and the Subsonic
      // sync push) correctly.
      final bool isFavorite = ref.read(isFavoriteProvider(track.uri));
      await ref
          .read(favoritesRepositoryProvider)
          .setFavorite(track, !isFavorite);
    case _TrackAction.playNext:
      ref.read(playbackControllerProvider).playNext(track);
    case _TrackAction.addToQueue:
      ref.read(playbackControllerProvider).addToQueue(track);
    case _TrackAction.addToPlaylist:
      await showAddToPlaylistSheet(context, <Track>[track]);
    case _TrackAction.download:
    case _TrackAction.retryDownload:
      await _download(context, ref, track);
    case _TrackAction.cancel:
      // Cancelling an in-flight/queued download is not destructive to a saved
      // copy, so it needs no confirmation.
      await ref.read(downloadRepositoryProvider).removeDownload(track);
    case _TrackAction.removeOffline:
      await SongActions.removeOfflineCopies(context, ref, <Track>[track]);
    case _TrackAction.showAlbum:
      // The same derived ids the Albums and Artists grids route with, so the
      // menu lands on exactly the page those tabs would have opened.
      unawaited(
        context.push(AppRoutes.albumDetailPath(albumIdForTrack(track))),
      );
    case _TrackAction.showArtist:
      unawaited(
        context.push(AppRoutes.artistDetailPath(artistIdForTrack(track))),
      );
    case _TrackAction.removeFromLibrary:
      await SongActions.removeFromLibrary(
        context,
        ref,
        <Track>[track],
        expandLogicalSources: true,
      );
  }
}

/// Starts the download, surfacing the friendly, secret-free reasons it might
/// not start: a full cache with nothing safe to evict, or the network policy
/// queueing it (mobile data not allowed, or offline). Other errors fall
/// through to the row's "failed" indicator (with a retry action).
Future<void> _download(
  BuildContext context,
  WidgetRef ref,
  Track track,
) async {
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
