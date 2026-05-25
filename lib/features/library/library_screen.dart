import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/dimens.dart';
import '../../core/models/track.dart';
import '../../core/services/bulk_track_actions.dart';
import '../playlists/widgets/add_to_playlist_sheet.dart';
import 'library_controller.dart';
import 'library_state.dart';
import 'selected_folder_controller.dart';
import 'song_actions.dart';
import 'widgets/alphabet_track_list.dart';

/// Browse tracks from the local catalog. Reads entirely from
/// [libraryControllerProvider] and [selectedFolderControllerProvider]; it has
/// no knowledge of where tracks are stored or which plugin picks the folder.
///
/// A long-press on a row enters multi-select; the app bar then becomes a
/// contextual selection bar offering only the actions that are safe for the
/// current selection (mixed-source selections hide unsafe destructive actions).
class LibraryScreen extends ConsumerStatefulWidget {
  const LibraryScreen({super.key});

  @override
  ConsumerState<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends ConsumerState<LibraryScreen> {
  final Set<String> _selectedIds = <String>{};
  bool _selecting = false;

  @override
  Widget build(BuildContext context) {
    final LibraryState state = ref.watch(libraryControllerProvider);
    final AsyncValue<String?> selectedFolder =
        ref.watch(selectedFolderControllerProvider);

    // Drop any selected ids that are no longer in the catalog (e.g. after a
    // removal) so the count and actions stay accurate.
    final List<Track> selected = <Track>[
      for (final Track track in state.tracks)
        if (_selectedIds.contains(track.id)) track,
    ];

    return PopScope(
      canPop: !_selecting,
      onPopInvokedWithResult: (bool didPop, _) {
        if (!didPop && _selecting) _exitSelection();
      },
      child: Scaffold(
        appBar: _selecting
            ? _selectionAppBar(selected)
            : AppBar(
                title: const Text('Library'),
                actions: <Widget>[
                  IconButton(
                    icon: const Icon(Icons.create_new_folder_outlined),
                    tooltip: 'Select music folder',
                    onPressed: () => _pickAndScan(),
                  ),
                ],
              ),
        body: _body(state, selectedFolder.valueOrNull),
      ),
    );
  }

  PreferredSizeWidget _selectionAppBar(List<Track> selected) {
    final BulkActionAvailability actions =
        bulkActionsFor(selected, inPlaylist: false);
    return AppBar(
      leading: IconButton(
        icon: const Icon(Icons.close),
        tooltip: 'Cancel selection',
        onPressed: _exitSelection,
      ),
      title: Text('${selected.length} selected'),
      actions: <Widget>[
        if (actions.canAddToPlaylist)
          IconButton(
            icon: const Icon(Icons.playlist_add),
            tooltip: 'Add to playlist',
            onPressed: selected.isEmpty ? null : () => _addToPlaylist(selected),
          ),
        if (actions.canRemoveOfflineCopy)
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Remove offline copies',
            onPressed: selected.isEmpty ? null : () => _removeOffline(selected),
          ),
        if (actions.canRemoveFromLibrary)
          IconButton(
            icon: const Icon(Icons.remove_circle_outline),
            tooltip: 'Remove from Linthra',
            onPressed:
                selected.isEmpty ? null : () => _removeFromLibrary(selected),
          ),
      ],
    );
  }

  void _enterSelection(Track track) {
    setState(() {
      _selecting = true;
      _selectedIds
        ..clear()
        ..add(track.id);
    });
  }

  void _toggle(Track track) {
    setState(() {
      if (!_selectedIds.add(track.id)) {
        _selectedIds.remove(track.id);
      }
      if (_selectedIds.isEmpty) _selecting = false;
    });
  }

  void _exitSelection() {
    setState(() {
      _selecting = false;
      _selectedIds.clear();
    });
  }

  Future<void> _addToPlaylist(List<Track> selected) async {
    await showAddToPlaylistSheet(context, selected);
    _exitSelection();
  }

  Future<void> _removeFromLibrary(List<Track> selected) async {
    final bool removed =
        await SongActions.removeFromLibrary(context, ref, selected);
    if (removed) _exitSelection();
  }

  Future<void> _removeOffline(List<Track> selected) async {
    final bool ran =
        await SongActions.removeOfflineCopies(context, ref, selected);
    if (ran) _exitSelection();
  }

  /// Open the system folder picker, persist the choice, then scan it. A
  /// cancelled pick leaves everything untouched. The UI only talks to the two
  /// controllers — never to a picker plugin or the file system directly.
  Future<void> _pickAndScan() async {
    final String? path = await ref
        .read(selectedFolderControllerProvider.notifier)
        .pickAndPersist();
    if (path != null) {
      await ref.read(libraryControllerProvider.notifier).scanFolder(path);
    }
  }

  /// Re-scan the folder the user already selected, without opening the picker.
  Future<void> _rescan(String folder) {
    return ref.read(libraryControllerProvider.notifier).scanFolder(folder);
  }

  Widget _body(LibraryState state, String? selectedFolder) {
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
            onPick: _pickAndScan,
            onRescan:
                selectedFolder == null ? null : () => _rescan(selectedFolder),
          );
        }
        return AlphabetTrackList(
          tracks: state.tracks,
          selectable: true,
          selectionActive: _selecting,
          selectedIds: _selectedIds,
          onSelectStart: _enterSelection,
          onSelectToggle: _toggle,
        );
    }
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
