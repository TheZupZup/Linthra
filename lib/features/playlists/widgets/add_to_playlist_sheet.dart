import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/dimens.dart';
import '../../../core/models/playlist.dart';
import '../../../core/models/track.dart';
import '../../../data/repositories/playlist_repository_provider.dart';
import '../../../shared/widgets/empty_state.dart';
import '../playlist_add.dart';
import '../playlist_providers.dart';
import 'create_playlist_dialog.dart';

/// Opens the "Add to playlist" sheet for [tracks] (one, or a bulk selection).
/// The sheet lists existing playlists and a "New playlist" action; the actual
/// add and any user feedback happen inside it.
Future<void> showAddToPlaylistSheet(
  BuildContext context,
  List<Track> tracks,
) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => _AddToPlaylistSheet(tracks: tracks),
  );
}

class _AddToPlaylistSheet extends ConsumerWidget {
  const _AddToPlaylistSheet({required this.tracks});

  final List<Track> tracks;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);
    final List<Playlist> playlists =
        ref.watch(playlistsProvider).valueOrNull ?? const <Playlist>[];

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.7,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg,
                0,
                AppSpacing.lg,
                AppSpacing.sm,
              ),
              child: Text(
                tracks.length == 1
                    ? 'Add to playlist'
                    : 'Add ${tracks.length} songs to playlist',
                style: theme.textTheme.titleMedium,
              ),
            ),
            ListTile(
              leading: CircleAvatar(
                backgroundColor: theme.colorScheme.primary.withValues(
                  alpha: 0.12,
                ),
                child: Icon(Icons.add, color: theme.colorScheme.primary),
              ),
              title: const Text('New playlist'),
              onTap: () => _createAndAdd(context, ref),
            ),
            const Divider(height: 0),
            Flexible(
              child: playlists.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.symmetric(vertical: AppSpacing.lg),
                      child: EmptyState(
                        icon: Icons.queue_music_outlined,
                        title: 'No playlists yet',
                        message: 'Create one to start adding songs.',
                      ),
                    )
                  : ListView.builder(
                      shrinkWrap: true,
                      itemCount: playlists.length,
                      itemBuilder: (context, index) {
                        final Playlist playlist = playlists[index];
                        return ListTile(
                          leading: Icon(
                            playlist.isRemote
                                ? Icons.cloud_outlined
                                : Icons.queue_music,
                          ),
                          title: Text(
                            playlist.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            '${playlist.length} '
                            '${playlist.length == 1 ? 'song' : 'songs'}',
                          ),
                          onTap: () => _addToExisting(context, ref, playlist),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _addToExisting(
    BuildContext context,
    WidgetRef ref,
    Playlist playlist,
  ) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final NavigatorState navigator = Navigator.of(context);
    final PlaylistAddPlan plan = await addTracksToPlaylist(
      repository: ref.read(playlistRepositoryProvider),
      playlist: playlist,
      tracks: tracks,
    );
    navigator.pop();
    messenger.showSnackBar(SnackBar(content: Text(plan.resultMessage)));
  }

  Future<void> _createAndAdd(BuildContext context, WidgetRef ref) async {
    final List<PlaylistSyncTarget> targets =
        ref.read(playlistSyncTargetsProvider);
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final NavigatorState navigator = Navigator.of(context);
    final PlaylistEdit? edit = await showCreatePlaylistDialog(
      context,
      syncTargets: targets,
    );
    if (edit == null) return;
    final repository = ref.read(playlistRepositoryProvider);
    final Playlist created = await repository.createPlaylist(
      edit.name,
      description: edit.description,
      source: edit.source,
    );
    // A freshly created playlist is empty, so every addable track is genuinely
    // added; the skipped remainder (if any) was filtered as a different source.
    final PlaylistAddPlan plan = await addTracksToPlaylist(
      repository: repository,
      playlist: created,
      tracks: tracks,
    );
    navigator.pop();
    messenger.showSnackBar(SnackBar(content: Text(plan.resultMessage)));
  }
}
