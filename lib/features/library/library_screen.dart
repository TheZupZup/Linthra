import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/dimens.dart';
import '../../app/routes.dart';
import '../../core/models/track.dart';
import '../../shared/widgets/empty_state.dart';
import '../player/player_providers.dart';
import 'library_controller.dart';
import 'library_state.dart';

/// Browse tracks from the local catalog. Reads entirely from
/// [libraryControllerProvider]; it has no knowledge of where tracks are stored.
class LibraryScreen extends ConsumerWidget {
  const LibraryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(libraryControllerProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Library'),
        actions: [
          IconButton(
            icon: const Icon(Icons.create_new_folder_outlined),
            tooltip: 'Scan a folder',
            onPressed: () => _promptScan(context, ref),
          ),
        ],
      ),
      body: _body(ref, state),
    );
  }

  /// Dev entry point for the scan flow: ask for a folder path and hand it to
  /// the controller. Deliberately a plain text prompt — a real folder picker
  /// and runtime permissions land in a later PR.
  Future<void> _promptScan(BuildContext context, WidgetRef ref) async {
    final path = await showDialog<String>(
      context: context,
      builder: (_) => const _ScanFolderDialog(),
    );
    if (path != null && path.isNotEmpty) {
      await ref.read(libraryControllerProvider.notifier).scanFolder(path);
    }
  }

  Widget _body(WidgetRef ref, LibraryState state) {
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
          return const EmptyState(
            icon: Icons.library_music_outlined,
            title: 'Your library is empty',
            message: 'Tap the folder icon to scan a folder for music.',
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
      itemBuilder: (context, index) => _TrackTile(track: tracks[index]),
    );
  }
}

class _TrackTile extends ConsumerWidget {
  const _TrackTile({required this.track});

  final Track track;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListTile(
      leading: const Icon(Icons.music_note_outlined),
      title: Text(track.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        _subtitle(track),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      // Start playback, then surface the now-playing screen.
      onTap: () {
        ref.read(playbackControllerProvider).playTrack(track);
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

/// Simple prompt for a folder path to scan. Pops the trimmed path, or null
/// when cancelled. Kept tiny on purpose; a proper picker comes later.
class _ScanFolderDialog extends StatefulWidget {
  const _ScanFolderDialog();

  @override
  State<_ScanFolderDialog> createState() => _ScanFolderDialogState();
}

class _ScanFolderDialogState extends State<_ScanFolderDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() => Navigator.of(context).pop(_controller.text.trim());

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Scan a folder'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: const InputDecoration(
          labelText: 'Folder path',
          hintText: '/storage/emulated/0/Music',
        ),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Scan')),
      ],
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
