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
    // The repository skips ids already in the playlist, so the count the user
    // sees must be the genuinely-new ones — not the whole addable list.
    final Set<String> existing = playlist.trackIds.toSet();
    final int added =
        addable.where((Track t) => !existing.contains(t.id)).length;
    await ref.read(playlistRepositoryProvider).addTracks(
      playlist.id,
      <String>[for (final Track track in addable) track.id],
    );
    navigator.pop();
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          _resultMessage(playlist, addableCount: addable.length, added: added),
        ),
      ),
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
    // A freshly created playlist is empty, so every addable track is genuinely
    // added; the skipped remainder (if any) was filtered as non-Jellyfin.
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          _resultMessage(created,
              addableCount: addable.length, added: addable.length),
        ),
      ),
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

  /// A snackbar line reflecting what actually changed. [added] is the number of
  /// tracks genuinely appended (the repository skips ids already present, and
  /// [addableCount] excludes tracks the playlist can't take — e.g. non-Jellyfin
  /// tracks for a synced playlist), so this never claims more than was added.
  String _resultMessage(
    Playlist playlist, {
    required int addableCount,
    required int added,
  }) {
    if (added == 0) {
      // Nothing new landed. Either the whole selection was unsupported, or
      // every track was already in the playlist.
      if (addableCount == 0 && playlist.source == PlaylistSource.jellyfin) {
        return 'Only Jellyfin tracks can be added to ${playlist.name}.';
      }
      return tracks.length == 1
          ? "That song's already in ${playlist.name}."
          : 'Those songs are already in ${playlist.name}.';
    }
    final int skipped = tracks.length - added;
    final String base = added == 1
        ? 'Added to ${playlist.name}.'
        : 'Added $added songs to ${playlist.name}.';
    if (skipped > 0) {
      return '$base $skipped skipped (already added or not supported).';
    }
    return base;
  }
}
