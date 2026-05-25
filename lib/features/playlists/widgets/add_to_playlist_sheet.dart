import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/dimens.dart';
import '../../../core/models/playlist.dart';
import '../../../core/models/track.dart';
import '../../../core/sources/jellyfin/jellyfin_track_mapper.dart';
import '../../../data/repositories/playlist_repository_provider.dart';
import '../../../shared/widgets/empty_state.dart';
import '../../settings/jellyfin/jellyfin_settings_controller.dart';
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
    final List<Track> addable = _addableFor(playlist);
    if (addable.isEmpty) {
      navigator.pop();
      messenger.showSnackBar(
        const SnackBar(
          content: Text(
            'Only Jellyfin tracks can be added to a Jellyfin playlist.',
          ),
        ),
      );
      return;
    }
    await ref.read(playlistRepositoryProvider).addTracks(
      playlist.id,
      <String>[for (final Track track in addable) track.id],
    );
    navigator.pop();
    messenger.showSnackBar(
      SnackBar(content: Text(_addedMessage(playlist, addable.length))),
    );
  }

  Future<void> _createAndAdd(BuildContext context, WidgetRef ref) async {
    final bool connected = ref.read(
      jellyfinSettingsControllerProvider.select((s) => s.isConnected),
    );
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final NavigatorState navigator = Navigator.of(context);
    final PlaylistEdit? edit = await showCreatePlaylistDialog(
      context,
      canSyncToJellyfin: connected,
    );
    if (edit == null) return;
    final repository = ref.read(playlistRepositoryProvider);
    final Playlist created = await repository.createPlaylist(
      edit.name,
      description: edit.description,
      source: edit.source,
    );
    final List<Track> addable = _addableFor(created);
    if (addable.isNotEmpty) {
      await repository.addTracks(
        created.id,
        <String>[for (final Track track in addable) track.id],
      );
    }
    navigator.pop();
    messenger.showSnackBar(
      SnackBar(content: Text(_addedMessage(created, addable.length))),
    );
  }

  /// The subset of [tracks] that can be added to [playlist]: every track for a
  /// local playlist, only Jellyfin tracks for a Jellyfin playlist (so a synced
  /// playlist stays consistent with the server).
  List<Track> _addableFor(Playlist playlist) {
    if (playlist.source != PlaylistSource.jellyfin) return tracks;
    return <Track>[
      for (final Track track in tracks)
        if (track.uri.startsWith(JellyfinTrackMapper.uriScheme)) track,
    ];
  }

  String _addedMessage(Playlist playlist, int added) {
    final int skipped = tracks.length - added;
    final String base = added == 1
        ? 'Added to ${playlist.name}.'
        : 'Added $added songs to ${playlist.name}.';
    if (skipped > 0) {
      return '$base $skipped not added (not Jellyfin tracks).';
    }
    return base;
  }
}
