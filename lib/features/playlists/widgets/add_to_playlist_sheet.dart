import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/dimens.dart';
import '../../../core/models/playlist.dart';
import '../../../core/models/track.dart';
import '../../../core/sources/jellyfin/jellyfin_track_mapper.dart';
import '../../../core/sources/subsonic/subsonic_track_mapper.dart';
import '../../../data/repositories/playlist_repository_provider.dart';
import '../../../shared/widgets/empty_state.dart';
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
      final String label = playlist.source.serverLabel ?? 'this server';
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            'Only $label tracks can be added to a $label playlist.',
          ),
        ),
      );
      return;
    }
    // The repository skips uris already in the playlist, so the count the user
    // sees must be the genuinely-new ones — not the whole addable list. Keyed by
    // the provider-namespaced uri, so adding `subsonic:101` to a playlist that
    // holds `jellyfin:101` is a real add, not a no-op "already there".
    final Set<String> existing = playlist.trackIds.toSet();
    final int added =
        addable.where((Track t) => !existing.contains(t.uri)).length;
    await ref.read(playlistRepositoryProvider).addTracks(
      playlist.id,
      <String>[for (final Track track in addable) track.uri],
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
    final List<Track> addable = _addableFor(created);
    if (addable.isNotEmpty) {
      await repository.addTracks(
        created.id,
        <String>[for (final Track track in addable) track.uri],
      );
    }
    navigator.pop();
    // A freshly created playlist is empty, so every addable track is genuinely
    // added; the skipped remainder (if any) was filtered as a different source.
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
  /// local playlist, only same-provider tracks for a synced playlist (so it
  /// stays consistent with the server — a Jellyfin playlist holds only
  /// `jellyfin:` tracks, a Navidrome playlist only `subsonic:` tracks).
  List<Track> _addableFor(Playlist playlist) {
    final String? scheme = _schemeFor(playlist.source);
    if (scheme == null) return tracks;
    return <Track>[
      for (final Track track in tracks)
        if (track.uri.startsWith(scheme)) track,
    ];
  }

  /// The track-uri scheme a synced playlist of [source] accepts, or `null` for a
  /// local playlist (which accepts any source's tracks).
  static String? _schemeFor(PlaylistSource source) {
    switch (source) {
      case PlaylistSource.local:
        return null;
      case PlaylistSource.jellyfin:
        return JellyfinTrackMapper.uriScheme;
      case PlaylistSource.subsonic:
        return SubsonicTrackMapper.uriScheme;
    }
  }

  /// A snackbar line reflecting what actually changed. [added] is the number of
  /// tracks genuinely appended (the repository skips ids already present, and
  /// [addableCount] excludes tracks the playlist can't take — e.g. a different
  /// source's tracks for a synced playlist), so this never claims more than was
  /// added.
  String _resultMessage(
    Playlist playlist, {
    required int addableCount,
    required int added,
  }) {
    if (added == 0) {
      // Nothing new landed. Either the whole selection was unsupported, or
      // every track was already in the playlist.
      if (addableCount == 0 && playlist.source != PlaylistSource.local) {
        final String label = playlist.source.serverLabel ?? 'this server';
        return 'Only $label tracks can be added to ${playlist.name}.';
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
