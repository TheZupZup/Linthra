import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/dimens.dart';
import '../../app/routes.dart';
import '../../core/models/track.dart';
import '../player/player_providers.dart';
import 'library_controller.dart';
import 'library_state.dart';
import 'selected_folder_controller.dart';

/// Browse tracks from the local catalog. Reads entirely from
/// [libraryControllerProvider] and [selectedFolderControllerProvider]; it has
/// no knowledge of where tracks are stored or which plugin picks the folder.
class LibraryScreen extends ConsumerWidget {
  const LibraryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(libraryControllerProvider);
    final selectedFolder = ref.watch(selectedFolderControllerProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Library'),
        actions: [
          IconButton(
            icon: const Icon(Icons.create_new_folder_outlined),
            tooltip: 'Select music folder',
            onPressed: () => _pickAndScan(ref),
          ),
        ],
      ),
      body: _body(ref, state, selectedFolder.valueOrNull),
    );
  }

  /// Open the system folder picker, persist the choice, then scan it. A
  /// cancelled pick leaves everything untouched. The UI only talks to the two
  /// controllers — never to a picker plugin or the file system directly.
  Future<void> _pickAndScan(WidgetRef ref) async {
    final path = await ref
        .read(selectedFolderControllerProvider.notifier)
        .pickAndPersist();
    if (path != null) {
      await ref.read(libraryControllerProvider.notifier).scanFolder(path);
    }
  }

  /// Re-scan the folder the user already selected, without opening the picker.
  Future<void> _rescan(WidgetRef ref, String folder) {
    return ref.read(libraryControllerProvider.notifier).scanFolder(folder);
  }

  Widget _body(WidgetRef ref, LibraryState state, String? selectedFolder) {
    switch (state.status) {
      case LibraryStatus.loading:
        return const Center(child: CircularProgressIndicator());
      case LibraryStatus.error:
        return _LibraryError(
          message: state.errorMessage,
          onRetry: () => ref.read(libraryControllerProvider.notifier).refresh(),
        );
      case LibraryStatus.loaded:
        if (state.isEmpty) {
          return _LibraryEmpty(
            selectedFolder: selectedFolder,
            onPick: () => _pickAndScan(ref),
            onRescan: selectedFolder == null
                ? null
                : () => _rescan(ref, selectedFolder),
          );
        }
        return _TrackList(tracks: state.tracks);
    }
  }
}

class _TrackList extends StatelessWidget {
  const _TrackList({required this.tracks});

  final List<Track> tracks;

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      itemCount: tracks.length,
      itemBuilder: (context, index) =>
          _TrackTile(tracks: tracks, index: index),
    );
  }
}

class _TrackTile extends ConsumerWidget {
  const _TrackTile({required this.tracks, required this.index});

  /// The whole visible list, so tapping one track queues the rest after it.
  final List<Track> tracks;
  final int index;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final track = tracks[index];
    return ListTile(
      leading: const Icon(Icons.music_note_outlined),
      title: Text(track.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        _subtitle(track),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      // Play the tapped track and queue the rest of the list behind it, then
      // surface the now-playing screen.
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

/// The empty state, split by whether a folder has been selected yet so the
/// user always sees the right next step:
///  - no folder chosen → invite them to pick one;
///  - folder chosen but nothing found → show the folder and offer a re-scan or
///    a change of folder.
class _LibraryEmpty extends StatelessWidget {
  const _LibraryEmpty({
    required this.selectedFolder,
    required this.onPick,
    this.onRescan,
  });

  final String? selectedFolder;
  final VoidCallback onPick;
  final VoidCallback? onRescan;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasFolder = selectedFolder != null;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              hasFolder
                  ? Icons.library_music_outlined
                  : Icons.folder_off_outlined,
              size: 48,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(height: AppSpacing.md),
            Text(
              hasFolder ? 'No music found' : 'No music folder selected',
              style: theme.textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              hasFolder
                  ? 'Nothing playable turned up in:\n$selectedFolder'
                  : 'Choose a folder on your device to scan for music.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: AppSpacing.md),
            if (hasFolder) ...[
              FilledButton.tonal(
                onPressed: onRescan,
                child: const Text('Rescan folder'),
              ),
              const SizedBox(height: AppSpacing.sm),
              TextButton(
                onPressed: onPick,
                child: const Text('Change folder'),
              ),
            ] else
              FilledButton(
                onPressed: onPick,
                child: const Text('Select a folder'),
              ),
          ],
        ),
      ),
    );
  }
}

class _LibraryError extends StatelessWidget {
  const _LibraryError({required this.message, required this.onRetry});

  final String? message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 48, color: theme.colorScheme.error),
            const SizedBox(height: AppSpacing.md),
            Text(
              "Couldn't load your library",
              style: theme.textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            if (message != null) ...[
              const SizedBox(height: AppSpacing.sm),
              Text(
                message!,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                ),
                textAlign: TextAlign.center,
              ),
            ],
            const SizedBox(height: AppSpacing.md),
            FilledButton.tonal(
              onPressed: onRetry,
              child: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }
}
