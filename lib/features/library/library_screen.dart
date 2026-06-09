import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/dimens.dart';
import '../../app/routes.dart';
import '../../core/models/album.dart';
import '../../core/models/artist.dart';
import '../../core/models/track.dart';
import '../../core/services/bulk_track_actions.dart';
import '../../core/sources/local/folder_location.dart';
import '../../shared/widgets/empty_state.dart';
import '../playlists/widgets/add_to_playlist_sheet.dart';
import '../settings/jellyfin/jellyfin_sync_controller.dart';
import 'library_browse_providers.dart';
import 'library_controller.dart';
import 'library_search.dart';
import 'library_state.dart';
import 'selected_folder_controller.dart';
import 'song_actions.dart';
import 'unified_library_providers.dart';
import 'widgets/album_tile.dart';
import 'widgets/alphabet_track_list.dart';
import 'widgets/artist_tile.dart';
import 'widgets/library_search_field.dart';

/// Browse the local catalog across three tabs — Songs, Albums, Artists — with a
/// single search box that filters whichever tab is showing. Reads entirely from
/// [libraryControllerProvider] (the flat track catalog) plus the derived
/// [libraryAlbumsProvider]/[libraryArtistsProvider]; it has no knowledge of
/// where tracks are stored or which plugin picks the folder.
///
/// Songs keeps the long-press multi-select and the A–Z fast-scroller from
/// before. Switching tabs clears the query, so a search meant for one tab never
/// silently hides another's contents. Search only filters what is shown — it
/// never touches playback, so the mini-player keeps playing while browsing.
class LibraryScreen extends ConsumerStatefulWidget {
  const LibraryScreen({super.key});

  @override
  ConsumerState<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends ConsumerState<LibraryScreen>
    with SingleTickerProviderStateMixin {
  final Set<String> _selectedIds = <String>{};
  bool _selecting = false;

  late final TabController _tabController;
  final TextEditingController _searchController = TextEditingController();
  String _query = '';
  int _lastTabIndex = 0;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _tabController.addListener(_onTabChanged);
  }

  @override
  void dispose() {
    _tabController.removeListener(_onTabChanged);
    _tabController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  /// Clears the search once per real tab change. A query that filters songs is
  /// meaningless against albums/artists, so resetting on switch keeps each tab
  /// honest about what it's showing.
  void _onTabChanged() {
    if (_tabController.index == _lastTabIndex) return;
    _lastTabIndex = _tabController.index;
    if (_query.isNotEmpty) _clearSearch();
  }

  void _onQueryChanged(String value) => setState(() => _query = value);

  void _clearSearch() {
    setState(() {
      _query = '';
      _searchController.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final LibraryState state = ref.watch(libraryControllerProvider);
    // The de-duplicated catalog the whole screen renders from: one row per
    // logical song, even when the same track is served by more than one provider.
    final List<Track> songs = ref.watch(libraryUnifiedTracksProvider);
    final AsyncValue<String?> selectedFolder =
        ref.watch(selectedFolderControllerProvider);
    // While the first Jellyfin sync is running, an empty catalog should read as
    // "filling up", not "nothing here" — so the library never looks broken
    // during onboarding.
    final bool jellyfinSyncing = ref.watch(
      jellyfinSyncControllerProvider.select((s) => s.isSyncing),
    );

    // Drop any selected ids that are no longer in the catalog (e.g. after a
    // removal) so the count and actions stay accurate.
    final List<Track> selected = <Track>[
      for (final Track track in songs)
        if (_selectedIds.contains(track.id)) track,
    ];

    if (_selecting) {
      return PopScope(
        canPop: false,
        onPopInvokedWithResult: (bool didPop, _) {
          if (!didPop) _exitSelection();
        },
        child: Scaffold(
          appBar: _selectionAppBar(selected),
          body: _songsList(_filteredSongs(songs)),
        ),
      );
    }

    // Tabs and search only appear once there's a loaded, non-empty catalog to
    // browse; loading, error, and the folder-pick empty state take the whole
    // body (and no tabs), exactly as before.
    final bool browsing =
        state.status == LibraryStatus.loaded && songs.isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Library'),
        actions: <Widget>[
          IconButton(
            icon: const Icon(Icons.create_new_folder_outlined),
            tooltip: 'Select music folder',
            onPressed: _pickAndScan,
          ),
        ],
        bottom: browsing ? _tabBar() : null,
      ),
      body: browsing
          ? _browseBody(songs)
          : _statusBody(state, selectedFolder.valueOrNull, jellyfinSyncing),
    );
  }

  PreferredSizeWidget _tabBar() {
    final ThemeData theme = Theme.of(context);
    return TabBar(
      key: const Key('library_tabs'),
      controller: _tabController,
      indicatorColor: theme.colorScheme.secondary,
      indicatorSize: TabBarIndicatorSize.label,
      labelColor: theme.colorScheme.secondary,
      unselectedLabelColor: theme.colorScheme.onSurfaceVariant,
      tabs: const <Widget>[
        Tab(text: 'Songs'),
        Tab(text: 'Albums'),
        Tab(text: 'Artists'),
      ],
    );
  }

  /// Loading / error / folder-pick states, shown full-body without tabs.
  Widget _statusBody(
    LibraryState state,
    String? selectedFolder,
    bool jellyfinSyncing,
  ) {
    switch (state.status) {
      case LibraryStatus.loading:
        return const Center(child: CircularProgressIndicator());
      case LibraryStatus.error:
        return _LibraryError(
          message: state.errorMessage,
          onRetry: () => ref.read(libraryControllerProvider.notifier).refresh(),
        );
      case LibraryStatus.loaded:
        // A first Jellyfin sync in flight takes precedence over the folder-pick
        // prompt: tell the user their library is on its way rather than implying
        // it's empty.
        if (jellyfinSyncing) {
          return const _LibrarySyncing();
        }
        return _LibraryEmpty(
          selectedFolder: selectedFolder,
          onPick: _pickAndScan,
          onRescan:
              selectedFolder == null ? null : () => _rescan(selectedFolder),
        );
    }
  }

  /// Search box + the three browse tabs. Only built when there's content.
  Widget _browseBody(List<Track> songs) {
    return Column(
      children: <Widget>[
        LibrarySearchField(
          controller: _searchController,
          onChanged: _onQueryChanged,
          onClear: _clearSearch,
        ),
        Expanded(
          child: TabBarView(
            controller: _tabController,
            children: <Widget>[
              _songsTab(songs),
              _albumsTab(),
              _artistsTab(),
            ],
          ),
        ),
      ],
    );
  }

  // --- Tabs -------------------------------------------------------------

  Widget _songsTab(List<Track> songs) {
    final List<Track> filtered = _filteredSongs(songs);
    if (filtered.isEmpty) return const _NoResults();
    return _songsList(filtered);
  }

  Widget _albumsTab() {
    final List<Album> filtered =
        filterAlbums(ref.watch(libraryAlbumsProvider), _query);
    if (filtered.isEmpty) return const _NoResults();
    return ListView.builder(
      key: const Key('library_album_list'),
      itemCount: filtered.length,
      itemBuilder: (context, index) {
        final Album album = filtered[index];
        return AlbumTile(
          album: album,
          onTap: () => context.push(AppRoutes.albumDetailPath(album.id)),
        );
      },
    );
  }

  Widget _artistsTab() {
    final List<Artist> filtered =
        filterArtists(ref.watch(libraryArtistsProvider), _query);
    if (filtered.isEmpty) return const _NoResults();
    return ListView.builder(
      key: const Key('library_artist_list'),
      itemCount: filtered.length,
      itemBuilder: (context, index) {
        final Artist artist = filtered[index];
        return ArtistTile(
          artist: artist,
          onTap: () => context.push(AppRoutes.artistDetailPath(artist.id)),
        );
      },
    );
  }

  List<Track> _filteredSongs(List<Track> songs) => filterTracks(songs, _query);

  Widget _songsList(List<Track> tracks) {
    return AlphabetTrackList(
      tracks: tracks,
      selectable: true,
      selectionActive: _selecting,
      selectedIds: _selectedIds,
      onSelectStart: _enterSelection,
      onSelectToggle: _toggle,
    );
  }

  // --- Selection --------------------------------------------------------

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
    // Removing a logical row forgets every provider copy of the song, so a
    // hidden duplicate can't resurrect the row on the next reload.
    final bool removed = await SongActions.removeFromLibrary(
      context,
      ref,
      selected,
      expandLogicalSources: true,
    );
    if (removed) _exitSelection();
  }

  Future<void> _removeOffline(List<Track> selected) async {
    final bool ran =
        await SongActions.removeOfflineCopies(context, ref, selected);
    if (ran) _exitSelection();
  }

  // --- Scan -------------------------------------------------------------

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
}

/// The "no search matches" state, shown when a query filters every row out of
/// the active tab. Deliberately friendly and identical across tabs.
class _NoResults extends StatelessWidget {
  const _NoResults();

  @override
  Widget build(BuildContext context) {
    return const EmptyState(
      icon: Icons.search_off,
      title: 'No results found.',
      message: 'Try a different search.',
    );
  }
}

/// Shown when the catalog is still empty but a first Jellyfin sync is running,
/// so onboarding reads as "your library is on its way" rather than "nothing
/// here". Replaced automatically once the synced tracks land.
class _LibrarySyncing extends StatelessWidget {
  const _LibrarySyncing();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox.square(
              dimension: 36,
              child: CircularProgressIndicator(strokeWidth: 3),
            ),
            const SizedBox(height: AppSpacing.md),
            Text(
              'Your Jellyfin library is syncing',
              style: theme.textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              'This may take a moment. Your songs will appear here as soon as '
              "they're in.",
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
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
    // A folder selected as a plain filesystem path on Android is the legacy/
    // broken case: scoped storage won't let Linthra read it, so it turns up
    // empty. Nudge the user to pick it again, which now returns a SAF grant.
    final bool needsRepick = hasFolder &&
        Platform.isAndroid &&
        !FolderLocation.parse(selectedFolder!).isContentUri;
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
                  ? 'Nothing playable turned up in:\n'
                      '${FolderLocation.parse(selectedFolder!).displayLabel}'
                  : 'Choose a folder on your device to scan for music.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
              ),
              textAlign: TextAlign.center,
            ),
            if (needsRepick) ...[
              const SizedBox(height: AppSpacing.sm),
              Text(
                'Choose the folder again so Linthra can read it.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
                textAlign: TextAlign.center,
              ),
            ],
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
