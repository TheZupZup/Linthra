import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/colors.dart';
import '../../../app/dimens.dart';
import '../../../core/models/playback_state.dart';
import '../../../core/models/playlist.dart';
import '../../../core/models/track.dart';
import '../../../data/repositories/playlist_repository_provider.dart';
import '../../../shared/widgets/now_playing_indicator.dart';
import '../../playlists/widgets/create_playlist_dialog.dart';
import '../now_playing.dart';
import '../player_providers.dart';
import 'album_artwork.dart';

/// Opens the advanced Queue / Up Next manager as a tall bottom sheet.
///
/// It's a sheet (not a route) so it floats over Now Playing without leaving it —
/// browsing the queue never touches playback. The current track keeps playing
/// while the listener reorders, removes, or jumps around the queue.
Future<void> showQueueSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => const QueueSheet(),
  );
}

/// The Queue / Up Next manager.
///
/// Reads the live [PlaybackState] (so it stays current while open) and shows,
/// top to bottom: a header with Save/Clear actions, the played history, the
/// current track, and the reorderable up-next list. Every edit goes through the
/// [PlaybackController] — the same single source of truth the mini-player, Now
/// Playing, Cast, and the media session use — so editing the queue here can
/// never start a second, duplicate playback (local or cast). It only ever holds
/// catalog [Track]s, never a resolved/authenticated stream URL.
class QueueSheet extends ConsumerWidget {
  const QueueSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final controller = ref.watch(playbackControllerProvider);
    final PlaybackState state =
        ref.watch(playbackStateProvider).valueOrNull ?? controller.state;

    final Track? current = state.currentTrack;
    final List<Track> upNext = state.upNext;
    final List<Track> history = state.previous;
    final bool canClear = upNext.isNotEmpty || history.isNotEmpty;
    final bool canSave = current != null;

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.85,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg,
                0,
                AppSpacing.sm,
                AppSpacing.sm,
              ),
              child: Row(
                children: <Widget>[
                  Icon(Icons.queue_music, color: theme.colorScheme.primary),
                  const SizedBox(width: AppSpacing.sm),
                  Text('Queue', style: theme.textTheme.titleMedium),
                  const Spacer(),
                  IconButton(
                    onPressed: canSave
                        ? () => _saveAsPlaylist(context, ref, state)
                        : null,
                    icon: const Icon(Icons.playlist_add),
                    tooltip: 'Save queue as playlist',
                  ),
                  TextButton(
                    onPressed: canClear ? controller.clearQueue : null,
                    child: const Text('Clear'),
                  ),
                ],
              ),
            ),
            Flexible(
              child: current == null
                  ? const _EmptyQueue()
                  : CustomScrollView(
                      slivers: <Widget>[
                        if (history.isNotEmpty) ...<Widget>[
                          const _SectionLabel(label: 'Previously played'),
                          SliverList.builder(
                            itemCount: history.length,
                            itemBuilder: (context, index) => _HistoryTile(
                              track: history[index],
                              onTap: () => ref
                                  .read(playbackControllerProvider)
                                  .playFromHistory(index),
                            ),
                          ),
                        ],
                        const _SectionLabel(label: 'Now playing'),
                        SliverToBoxAdapter(
                          child: _CurrentTile(track: current),
                        ),
                        const _SectionLabel(label: 'Up next'),
                        if (upNext.isEmpty)
                          const SliverToBoxAdapter(child: _NothingUpNext())
                        else
                          SliverReorderableList(
                            itemCount: upNext.length,
                            onReorder: (int oldIndex, int newIndex) {
                              // SliverReorderableList reports newIndex as an
                              // insertion point in the pre-removal list; convert
                              // to the destination index the queue model expects.
                              if (oldIndex < newIndex) newIndex -= 1;
                              ref
                                  .read(playbackControllerProvider)
                                  .reorderQueue(oldIndex, newIndex);
                            },
                            itemBuilder: (context, index) => _UpNextTile(
                              // Index-qualified so the same track queued twice
                              // never produces a duplicate key (which would crash
                              // the reorderable list).
                              key: ValueKey<String>(
                                'queue-$index-${upNext[index].id}',
                              ),
                              track: upNext[index],
                              index: index,
                              onPlay: () => ref
                                  .read(playbackControllerProvider)
                                  .playFromQueue(index),
                              onRemove: () => ref
                                  .read(playbackControllerProvider)
                                  .removeFromQueue(index),
                            ),
                          ),
                        const SliverToBoxAdapter(
                          child: SizedBox(height: AppSpacing.md),
                        ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }

  /// Saves the whole queue (history + current + up-next) as a new **local**
  /// playlist. Deliberately local-only: it never auto-syncs to Jellyfin, so a
  /// queue mixing local and remote tracks can't silently drop the local ones or
  /// push anything to a server (see docs/queue.md). Reuses the shared create
  /// dialog (with sync hidden) so the name prompt matches the rest of the app.
  Future<void> _saveAsPlaylist(
    BuildContext context,
    WidgetRef ref,
    PlaybackState state,
  ) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final List<Track> tracks = <Track>[
      ...state.previous,
      if (state.currentTrack != null) state.currentTrack!,
      ...state.upNext,
    ];
    if (tracks.isEmpty) return;

    final PlaylistEdit? edit = await showCreatePlaylistDialog(context);
    if (edit == null) return;

    final repository = ref.read(playlistRepositoryProvider);
    final Playlist created = await repository.createPlaylist(
      edit.name,
      description: edit.description,
      source: PlaylistSource.local,
    );
    await repository.addTracks(
      created.id,
      <String>[for (final Track track in tracks) track.id],
    );
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          tracks.length == 1
              ? 'Saved 1 song to “${edit.name}”.'
              : 'Saved ${tracks.length} songs to “${edit.name}”.',
        ),
      ),
    );
  }
}

/// A small, calm section label (Previously played / Now playing / Up next).
class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg,
          AppSpacing.sm,
          AppSpacing.lg,
          AppSpacing.xs,
        ),
        child: Text(
          label,
          style: theme.textTheme.labelMedium?.copyWith(
            color: theme.colorScheme.primary,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.4,
          ),
        ),
      ),
    );
  }
}

/// The current track row, highlighted with the warm "live" accent so it reads
/// as the one playing now. Its trailing equalizer animates while playback is
/// playing and rests while paused. Non-draggable and non-removable on purpose:
/// the queue manager never yanks the playing track out from under playback.
class _CurrentTile extends ConsumerWidget {
  const _CurrentTile({required this.track});

  final Track track;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final bool isPlaying =
        ref.watch(nowPlayingProvider.select((n) => n.isPlaying));
    final String? artist = track.artistName;
    return ListTile(
      leading: SizedBox.square(
        dimension: 44,
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
          color: AppColors.accent,
          fontWeight: FontWeight.w700,
        ),
      ),
      subtitle: artist == null || artist.isEmpty
          ? null
          : Text(artist, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: NowPlayingIndicator(animating: isPlaying),
    );
  }
}

/// An already-played track. Tapping it steps back to that point in the queue.
class _HistoryTile extends StatelessWidget {
  const _HistoryTile({required this.track, required this.onTap});

  final Track track;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final String? artist = track.artistName;
    return ListTile(
      dense: true,
      onTap: onTap,
      leading: SizedBox.square(
        dimension: 40,
        child: Opacity(
          opacity: 0.6,
          child: AlbumArtwork(
            artworkUri: track.artworkUri,
            borderRadius: const BorderRadius.all(Radius.circular(AppRadii.sm)),
          ),
        ),
      ),
      title: Text(
        track.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodyLarge?.copyWith(
          color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
        ),
      ),
      subtitle: artist == null || artist.isEmpty
          ? null
          : Text(artist, maxLines: 1, overflow: TextOverflow.ellipsis),
    );
  }
}

/// An upcoming track: tap to play now, an X to remove it from the queue, and a
/// drag handle to reorder. Removing only drops the queue entry — it never
/// deletes the track from the library or its offline copy.
class _UpNextTile extends StatelessWidget {
  const _UpNextTile({
    required this.track,
    required this.index,
    required this.onPlay,
    required this.onRemove,
    super.key,
  });

  final Track track;
  final int index;
  final VoidCallback onPlay;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final String? artist = track.artistName;
    return Material(
      type: MaterialType.transparency,
      child: ListTile(
        onTap: onPlay,
        leading: SizedBox.square(
          dimension: 44,
          child: AlbumArtwork(
            artworkUri: track.artworkUri,
            borderRadius: const BorderRadius.all(Radius.circular(AppRadii.sm)),
          ),
        ),
        title: Text(track.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: artist == null || artist.isEmpty
            ? null
            : Text(artist, maxLines: 1, overflow: TextOverflow.ellipsis),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            IconButton(
              icon: const Icon(Icons.close),
              tooltip: 'Remove from queue',
              onPressed: onRemove,
            ),
            ReorderableDragStartListener(
              index: index,
              child: const Padding(
                padding: EdgeInsets.only(left: AppSpacing.xs),
                child: Icon(Icons.drag_handle),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Shown under "Up next" when the queue holds only the current track.
class _NothingUpNext extends StatelessWidget {
  const _NothingUpNext();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.xs,
        AppSpacing.lg,
        AppSpacing.md,
      ),
      child: Text(
        'Nothing up next. Use “Play next” or “Add to queue” from any song.',
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
        ),
      ),
    );
  }
}

/// The whole-sheet empty state: nothing is playing at all.
class _EmptyQueue extends StatelessWidget {
  const _EmptyQueue();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.xl),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(
            Icons.queue_music_outlined,
            size: 40,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(height: AppSpacing.md),
          Text('Nothing playing', style: theme.textTheme.titleMedium),
          const SizedBox(height: AppSpacing.sm),
          Text(
            'Pick a track to start a queue.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
            ),
          ),
        ],
      ),
    );
  }
}
