import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/routes.dart';
import '../../core/models/playlist.dart';
import '../../data/repositories/playlist_repository_provider.dart';
import '../../shared/widgets/confirm_dialog.dart';
import '../../shared/widgets/empty_state.dart';
import '../library/remote_library_refresher.dart';
import 'playlist_providers.dart';
import 'widgets/create_playlist_dialog.dart';

/// The Playlists tab: the user's playlists, with the always-present Favorites
/// collection pinned at the top. Playlists can be created here, and each one can
/// be opened, renamed, or deleted (with confirmation).
///
/// Opening the tab triggers a smart, throttled refresh so playlists (and
/// favourites) changed on a connected server from another client show up without
/// pressing "Sync".
class PlaylistsScreen extends ConsumerStatefulWidget {
  const PlaylistsScreen({super.key});

  @override
  ConsumerState<PlaylistsScreen> createState() => _PlaylistsScreenState();
}

class _PlaylistsScreenState extends ConsumerState<PlaylistsScreen> {
  @override
  void initState() {
    super.initState();
    // After the first frame (so it can't touch provider state mid-build), pull
    // any server-side playlist/favourite changes. Throttled + best-effort.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(remoteLibraryRefresherProvider).refresh();
    });
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color accent = theme.colorScheme.primary;
    final AsyncValue<List<Playlist>> playlists = ref.watch(playlistsProvider);
    final bool serverConnected =
        ref.watch(playlistSyncTargetsProvider).isNotEmpty;

    return Scaffold(
      appBar: AppBar(title: const Text('Playlists')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _create(context, ref),
        icon: const Icon(Icons.add),
        label: const Text('New playlist'),
      ),
      body: Column(
        children: <Widget>[
          ListTile(
            leading: CircleAvatar(
              backgroundColor: accent.withValues(alpha: 0.12),
              child: Icon(Icons.favorite, color: accent),
            ),
            title: const Text('Favorites'),
            subtitle: const Text('Tracks you’ve liked'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push(AppRoutes.favorites),
          ),
          const Divider(height: 0),
          ListTile(
            leading: CircleAvatar(
              backgroundColor: accent.withValues(alpha: 0.12),
              child: Icon(Icons.auto_awesome, color: accent),
            ),
            title: const Text('Smart mixes'),
            subtitle: const Text('Made by Linthra'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push(AppRoutes.smartMixes),
          ),
          const Divider(height: 0),
          Expanded(
            child: playlists.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (_, __) => const _PlaylistsError(),
              data: (List<Playlist> items) => items.isEmpty
                  ? _PlaylistsEmpty(serverConnected: serverConnected)
                  : ListView.builder(
                      padding: const EdgeInsets.only(bottom: 88),
                      itemCount: items.length,
                      itemBuilder: (context, index) =>
                          _PlaylistTile(playlist: items[index]),
                    ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _create(BuildContext context, WidgetRef ref) async {
    final List<PlaylistSyncTarget> targets =
        ref.read(playlistSyncTargetsProvider);
    final PlaylistEdit? edit = await showCreatePlaylistDialog(
      context,
      syncTargets: targets,
    );
    if (edit == null) return;
    await ref.read(playlistRepositoryProvider).createPlaylist(
          edit.name,
          description: edit.description,
          source: edit.source,
        );
  }
}

class _PlaylistTile extends ConsumerWidget {
  const _PlaylistTile({required this.playlist});

  final Playlist playlist;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: theme.colorScheme.primary.withValues(alpha: 0.12),
        child: Icon(
          playlist.isRemote ? Icons.cloud_outlined : Icons.queue_music,
          color: theme.colorScheme.primary,
        ),
      ),
      title: Text(
        playlist.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(_subtitle()),
      trailing: PopupMenuButton<_PlaylistMenuAction>(
        icon: const Icon(Icons.more_vert),
        tooltip: 'Playlist actions',
        onSelected: (action) => _run(context, ref, action),
        itemBuilder: (context) => const <PopupMenuEntry<_PlaylistMenuAction>>[
          PopupMenuItem<_PlaylistMenuAction>(
            value: _PlaylistMenuAction.rename,
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.edit_outlined),
              title: Text('Rename'),
            ),
          ),
          PopupMenuItem<_PlaylistMenuAction>(
            value: _PlaylistMenuAction.delete,
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.delete_outline),
              title: Text('Delete'),
            ),
          ),
        ],
      ),
      onTap: () => context.push(AppRoutes.playlistDetailPath(playlist.id)),
    );
  }

  /// "{n} songs", with a subtle source/status suffix: "· Sync failed" when a
  /// sync didn't land, otherwise the server label ("· Jellyfin", "· Navidrome")
  /// for a synced playlist so its origin is clear without cluttering the row.
  /// Local playlists show no suffix.
  String _subtitle() {
    final String count = '${playlist.length} '
        '${playlist.length == 1 ? 'song' : 'songs'}';
    if (playlist.syncState == PlaylistSyncState.syncFailed) {
      return '$count · Sync failed';
    }
    final String? label = playlist.source.serverLabel;
    if (label != null) {
      return '$count · $label';
    }
    return count;
  }

  Future<void> _run(
    BuildContext context,
    WidgetRef ref,
    _PlaylistMenuAction action,
  ) async {
    switch (action) {
      case _PlaylistMenuAction.rename:
        await _rename(context, ref);
      case _PlaylistMenuAction.delete:
        await _delete(context, ref);
    }
  }

  Future<void> _rename(BuildContext context, WidgetRef ref) async {
    final PlaylistEdit? edit = await showRenamePlaylistDialog(
      context,
      initialName: playlist.name,
      initialDescription: playlist.description,
    );
    if (edit == null) return;
    await ref.read(playlistRepositoryProvider).renamePlaylist(
          playlist.id,
          edit.name,
          description: edit.description,
        );
  }

  Future<void> _delete(BuildContext context, WidgetRef ref) async {
    final bool confirmed = await showConfirmDialog(
      context,
      title: 'Delete playlist',
      message: 'Delete playlist “${playlist.name}”? This removes the playlist '
          'from Linthra. Synced playlists may also be removed from the server '
          'if sync is enabled.',
      confirmLabel: 'Delete',
    );
    if (!confirmed) return;
    await ref.read(playlistRepositoryProvider).deletePlaylist(playlist.id);
  }
}

enum _PlaylistMenuAction { rename, delete }

/// The empty Playlists state, worded for the situation: signed in to a server
/// (your server playlists land here after a sync) vs not (create one, or sign in
/// to import). A failed *load* is a separate state — see [_PlaylistsError].
class _PlaylistsEmpty extends StatelessWidget {
  const _PlaylistsEmpty({required this.serverConnected});

  final bool serverConnected;

  @override
  Widget build(BuildContext context) {
    return EmptyState(
      icon: Icons.queue_music_outlined,
      title: 'No playlists yet',
      message: serverConnected
          ? 'Tap “New playlist” to create one. Your server playlists appear '
              'here after you sync your library.'
          : 'Tap “New playlist” to create one, or sign in to Jellyfin or '
              'Navidrome in Settings to import your server playlists.',
    );
  }
}

class _PlaylistsError extends StatelessWidget {
  const _PlaylistsError();

  @override
  Widget build(BuildContext context) {
    return const EmptyState(
      icon: Icons.error_outline,
      title: "Couldn't load your playlists",
      message: 'Try again in a moment.',
    );
  }
}
