import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/dimens.dart';
import '../../app/routes.dart';
import '../../core/models/album.dart';
import '../../core/models/artist.dart';
import '../../core/models/track.dart';
import '../../core/repositories/library_tab_store.dart';
import '../../core/services/bulk_track_actions.dart';
import '../../core/sources/local/folder_location.dart';
import '../../data/repositories/host_platform_provider.dart';
import '../../data/repositories/library_tab_store_provider.dart';
import '../../shared/layout/adaptive_layout.dart';
import '../../shared/layout/pane_layout.dart';
import '../../shared/widgets/empty_state.dart';
import '../playlists/widgets/add_to_playlist_sheet.dart';
import 'album_detail_screen.dart';
import 'artist_detail_screen.dart';
import 'folder_browser_providers.dart';
import 'library_browse_providers.dart';
import 'library_controller.dart';
import 'library_search.dart';
import 'library_state.dart';
import 'library_sync_activity.dart';
import 'selected_folder_controller.dart';
import 'song_actions.dart';
import 'track_selection.dart';
import 'unified_library_providers.dart';
import 'widgets/album_grid.dart';
import 'widgets/alphabet_track_list.dart';
import 'widgets/artist_grid.dart';
import 'widgets/library_search_field.dart';
import 'widgets/selection_escape_scope.dart';

/// Browse the de-duplicated catalog across Songs, Albums and Artists.
///
/// All three tabs read the same local catalog and share one search box. The
/// server's real directory hierarchy is not here: it lives on its own top-level
/// [FoldersScreen] destination, so it keeps its place in the tree when you
/// leave it.
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
  /// Widest the search box gets on a desktop window.
  static const double _searchFieldMaxWidth = 520;

  /// Tab order, as stored names rather than indices, so the persisted choice
  /// survives a tab being added or reordered later.
  static const List<String> _tabNames = <String>['songs', 'albums', 'artists'];

  /// Which songs are picked, and where a Shift-click measures from. Held here
  /// rather than in the rows so it survives a catalog refresh or a rebuild.
  final TrackSelection _selection = TrackSelection();
  bool _selecting = false;

  /// What the Albums / Artists detail pane is showing on a window wide enough
  /// to have one. Held here rather than in the panes so it survives the pane
  /// coming and going with the window width — and so a narrow window's pushed
  /// route and a wide window's pane are the same screen, opened two ways.
  String? _paneAlbumId;
  String? _paneArtistId;

  /// What is picked *inside* those panes, for the same reason: the pane is
  /// dropped whenever the window narrows past [listDetailMinWidth], so a
  /// selection owned by the detail screen would not survive a resize the user
  /// did not think of as leaving it. Reset when the pane moves to another
  /// album or artist, since a selection only means anything against the list it
  /// was made in.
  final TrackSelection _paneAlbumSelection = TrackSelection();
  final TrackSelection _paneArtistSelection = TrackSelection();

  late final TabController _tabController;
  final TextEditingController _searchController = TextEditingController();
  String _query = '';
  int _lastTabIndex = 0;

  /// Whether the user has picked a tab themselves. The current index cannot
  /// answer that: Songs to Albums and back leaves it at zero again, and a
  /// restore landing after that would move them somewhere they just left.
  bool _userChangedTab = false;

  /// Set while the app itself drives the controller, so the one handler for a
  /// tab change can tell that from a tap: it is neither a choice to remember
  /// nor a reason to stop a pending restore.
  bool _programmaticTabChange = false;

  /// Pending debounce timer. Cancelled and restarted on every keystroke so the
  /// filter re-runs only once the user pauses typing, not on every character.
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: _tabNames.length, vsync: this);
    _tabController.addListener(_onTabChanged);
    unawaited(_restoreTab());
  }

  /// Reopens Library on the tab last used, instead of always on Songs.
  ///
  /// Reading is async, so the controller starts on the first tab and moves once
  /// the value arrives. In practice that is not visible: the tabs only appear
  /// once the catalog has loaded, which takes longer than a key/value read. The
  /// guard matters anyway, because a user who switched tabs in the meantime has
  /// said something more recent than the stored value.
  Future<void> _restoreTab() async {
    final String? stored;
    try {
      stored = await ref.read(libraryTabStoreProvider).read();
    } catch (_) {
      // A storage or plugin failure means no remembered tab, which is the
      // behaviour before this existed. It must not reach the zone as an
      // uncaught async error.
      return;
    }
    // Selection is a modal state: it replaces the app bar, hides the tab bar
    // and blocks swiping. Moving the tab underneath it would leave the song
    // selection bar sitting over Albums with no visible way back.
    // A swipe in progress has not moved the index yet, so _userChangedTab is
    // still false while the user is very much choosing a tab. TabController
    // reports the drag as a non-zero offset, which is the one signal available
    // before the gesture settles.
    if (!mounted ||
        stored == null ||
        _userChangedTab ||
        _selecting ||
        _tabController.offset != 0) {
      return;
    }
    final int index = _tabNames.indexOf(stored);
    if (index < 0) return; // A tab that no longer exists: stay on the first.
    if (index == _tabController.index) return;

    // Driven through the controller rather than around it, so a restore clears
    // an in-progress search exactly as any other tab change does. Assigning
    // _lastTabIndex first would make the shared handler return early and carry
    // a query typed in Songs into Albums.
    _programmaticTabChange = true;
    _tabController.index = index;
    _programmaticTabChange = false;
  }

  /// Queues the tab writes so they cannot overtake each other.
  ///
  /// Switching Albums then Artists faster than the store can write would
  /// otherwise leave two writes racing, and a slow first one landing last would
  /// store the tab the user had already left. The queue is FIFO, so the value
  /// queued last is the value written last.
  Future<void> _persistQueue = Future<void>.value();

  /// Persists the current tab, swallowing a storage failure.
  ///
  /// Losing this preference only means the next launch opens on Songs, which is
  /// not worth surfacing to someone who was just browsing.
  ///
  /// Both the store and the tab name are read here, synchronously, rather than
  /// inside the queued write. Leaving the screen while a slow write is in
  /// flight would otherwise strand every newer write behind a disposed
  /// [State]: the queue would drop them and the older, already-superseded tab
  /// would be what stayed stored. The write itself needs nothing from the
  /// widget, so it does not have to outlive it to finish correctly.
  void _persistTab() {
    final LibraryTabStore store = ref.read(libraryTabStoreProvider);
    final String tabName = _tabNames[_tabController.index];
    _persistQueue = _persistQueue.then((_) async {
      try {
        await store.write(tabName);
      } catch (_) {
        // Nothing to recover: the next launch simply opens on the first tab.
      }
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _tabController.removeListener(_onTabChanged);
    _tabController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  /// Clears the search once per real tab change. The setState is also needed
  /// when entering/leaving Folders, where the catalog search field is hidden.
  void _onTabChanged() {
    if (_tabController.index == _lastTabIndex) return;
    if (!_programmaticTabChange) _userChangedTab = true;
    _debounce?.cancel();
    setState(() {
      _lastTabIndex = _tabController.index;
      // The field is the source of truth, not [_query]: typing only reaches
      // _query after the 300ms debounce, so between a keystroke and that timer
      // the box holds text while _query is still empty. Testing _query alone
      // left that text visible on the tab we just moved to, filtering nothing,
      // and the next keystroke would then apply the whole thing there.
      if (_query.isNotEmpty || _searchController.text.isNotEmpty) {
        _query = '';
        _searchController.clear();
      }
    });
    // A restore is replaying what is already stored, so there is nothing new to
    // write back. Otherwise fire and forget: where the user is reading is not
    // worth blocking a tab change on.
    if (_programmaticTabChange) return;
    _persistTab();
  }

  void _onQueryChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(
      const Duration(milliseconds: 300),
      () => setState(() => _query = value),
    );
  }

  void _clearSearch() {
    _debounce?.cancel();
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
    final bool hasFolderSources =
        ref.watch(folderBrowsableSourcesProvider).isNotEmpty;
    final AsyncValue<List<String>> selectedFolder =
        ref.watch(selectedFolderControllerProvider);
    // While a first library sync is running, an empty catalog should read as
    // "filling up", not "nothing here" — so the library never looks broken
    // during onboarding. Covers every server source, not just Jellyfin: Plex
    // exposes no folder hierarchy, so before this a scanning Plex library fell
    // through to the local-folder prompt.
    final List<String> syncingSources = ref.watch(syncingSourceNamesProvider);

    // Drop any selected rows no longer in the catalog (e.g. after a removal) so
    // the count and actions stay accurate. Keyed by the provider-namespaced uri,
    // not the bare id, so two different-provider songs sharing an id can't be
    // selected (or bulk-acted on) together.
    final List<Track> selected = _selection.resolve(songs);

    // A connected folder-capable server is browseable before (or even without)
    // a flat catalog sync, so it is enough to show the Library tabs on its own.
    // Selecting implies rows to select, so it always browses.
    final bool browsing = _selecting ||
        (state.status == LibraryStatus.loaded &&
            (songs.isNotEmpty || hasFolderSources));

    // Selection changes the app bar, not the screen. Returning a *different*
    // widget tree here (a bare Scaffold holding the list) would unmount the
    // list, and with it the ScrollController that AlphabetTrackList owns, so
    // long-pressing a row halfway down the catalog jumped back to the top
    // (#582). Everything below therefore stays in the same slot in both modes.
    return PopScope(
      canPop: !_selecting,
      onPopInvokedWithResult: (bool didPop, _) {
        if (!didPop && _selecting) _exitSelection();
      },
      child: SelectionEscapeScope(
        selecting: _selecting,
        onEscape: _exitSelection,
        child: Scaffold(
          appBar: _selecting
              ? _selectionAppBar(selected)
              : AppBar(
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
              ? _browseBody(songs, syncingSources)
              : _statusBody(
                  state,
                  selectedFolder.valueOrNull ?? const <String>[],
                  syncingSources,
                ),
        ),
      ),
    );
  }

  PreferredSizeWidget _tabBar() {
    final ThemeData theme = Theme.of(context);
    return TabBar(
      key: const Key('library_tabs'),
      controller: _tabController,
      // Tapping the tab you are already on is still you choosing a tab, but it
      // leaves the controller index untouched, so the listener never runs: it
      // would neither mark the choice nor store it. A restore still in flight
      // would move you off the tab you just asked for, and the next cold launch
      // would open on the tab you had just rejected.
      //
      // TabBar calls animateTo before onTap, so the index is already current
      // here. A tap that did change tabs therefore queues the same value the
      // listener just queued, which is a harmless second write of a value that
      // is already stored.
      onTap: (_) {
        _userChangedTab = true;
        _persistTab();
      },
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
    List<String> selectedFolders,
    List<String> syncingSources,
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
        // A first sync in flight — from any connected server — takes precedence
        // over the folder-pick prompt: tell the user their library is on its way
        // rather than implying it's empty, or (for Plex, which has no folder
        // hierarchy to fall back on) asking them for a folder they don't want.
        final String? headline = syncingHeadline(syncingSources);
        if (headline != null) {
          return _LibrarySyncing(headline: headline);
        }
        return _LibraryEmpty(
          selectedFolders: selectedFolders,
          onPick: _pickAndScan,
          onRescan:
              selectedFolders.isEmpty ? null : () => _rescan(selectedFolders),
        );
    }
  }

  /// Catalog search + the three browse tabs.
  Widget _browseBody(List<Track> songs, List<String> syncingSources) {
    // A connected folder-capable server (Jellyfin, Navidrome/Subsonic) shows the
    // tabs the moment it connects, so its *first* sync lands here rather than in
    // [_statusBody]. Pass the syncing sources down so the catalog tabs say
    // "still filling" instead of "nothing in the synced catalog".
    final String? syncHeadline = syncingHeadline(syncingSources);
    return Column(
      children: <Widget>[
        // Selection hides the search box, but the slot keeps exactly one child
        // either way: dropping it would move the Expanded below to index 0, and
        // an unkeyed Column re-inflates a child whose index changed — which is
        // the scroll position we are here to preserve (#582).
        if (_selecting)
          const SizedBox.shrink()
        else
          // The box is a text input, not content: on a wide window it stops
          // growing and stays left-aligned under the tabs rather than running
          // the width of a monitor.
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: _searchFieldMaxWidth),
              child: LibrarySearchField(
                controller: _searchController,
                onChanged: _onQueryChanged,
                onClear: _clearSearch,
              ),
            ),
          ),
        Expanded(
          child: TabBarView(
            controller: _tabController,
            // The tab bar is hidden while selecting, so a swipe would be an
            // undocumented way out of selection mode (and onto rows the count
            // in the app bar does not describe).
            physics: _selecting ? const NeverScrollableScrollPhysics() : null,
            children: <Widget>[
              _songsTab(songs, syncHeadline),
              _albumsTab(syncHeadline),
              _artistsTab(syncHeadline),
            ],
          ),
        ),
      ],
    );
  }

  // --- Tabs -------------------------------------------------------------

  Widget _songsTab(List<Track> songs, String? syncHeadline) {
    final List<Track> filtered = _filteredSongs(songs);
    if (filtered.isEmpty) {
      if (_query.isNotEmpty) return const _NoResults();
      if (syncHeadline != null) return _CatalogFilling(headline: syncHeadline);
      return const EmptyState(
        icon: Icons.music_note_outlined,
        title: 'No songs in the synced catalog',
        message: 'You can still browse the connected server from Folders.',
      );
    }
    return _songsList(filtered);
  }

  Widget _albumsTab(String? syncHeadline) {
    final List<Album> filtered =
        filterAlbums(ref.watch(libraryAlbumsProvider), _query);
    if (filtered.isEmpty) {
      if (_query.isNotEmpty) return const _NoResults();
      if (syncHeadline != null) return _CatalogFilling(headline: syncHeadline);
      return const EmptyState(
        icon: Icons.album_outlined,
        title: 'No albums in the synced catalog',
        message: 'You can still browse the connected server from Folders.',
      );
    }
    return ListDetailPanes(
      listBuilder: (BuildContext context, bool paneVisible) => AlbumGrid(
        albums: filtered,
        onOpen: (Album album) {
          if (!paneVisible) {
            context.push(AppRoutes.albumDetailPath(album.id));
            return;
          }
          setState(() {
            if (_paneAlbumId != album.id) _paneAlbumSelection.clear();
            _paneAlbumId = album.id;
          });
        },
      ),
      // A selection that is no longer in the filtered grid would leave the pane
      // showing an album the list says isn't there, so the pane follows the
      // search rather than outliving it.
      detailBuilder: (BuildContext context) {
        final String? id = _paneAlbumId;
        if (id == null) return null;
        if (!filtered.any((Album album) => album.id == id)) return null;
        return AlbumDetailScreen(
          key: ValueKey<String>(id),
          albumId: id,
          selection: _paneAlbumSelection,
        );
      },
      placeholderBuilder: (BuildContext context) => const DetailPanePlaceholder(
        icon: Icons.album_outlined,
        message: 'Pick an album to see its songs here.',
      ),
    );
  }

  Widget _artistsTab(String? syncHeadline) {
    final List<Artist> filtered =
        filterArtists(ref.watch(libraryArtistsProvider), _query);
    if (filtered.isEmpty) {
      if (_query.isNotEmpty) return const _NoResults();
      if (syncHeadline != null) return _CatalogFilling(headline: syncHeadline);
      return const EmptyState(
        icon: Icons.person_outline,
        title: 'No artists in the synced catalog',
        message: 'You can still browse the connected server from Folders.',
      );
    }
    return ListDetailPanes(
      listBuilder: (BuildContext context, bool paneVisible) => ArtistGrid(
        artists: filtered,
        onOpen: (Artist artist) {
          if (!paneVisible) {
            context.push(AppRoutes.artistDetailPath(artist.id));
            return;
          }
          setState(() {
            if (_paneArtistId != artist.id) _paneArtistSelection.clear();
            _paneArtistId = artist.id;
          });
        },
      ),
      detailBuilder: (BuildContext context) {
        final String? id = _paneArtistId;
        if (id == null) return null;
        if (!filtered.any((Artist artist) => artist.id == id)) return null;
        return ArtistDetailScreen(
          key: ValueKey<String>(id),
          artistId: id,
          selection: _paneArtistSelection,
        );
      },
      placeholderBuilder: (BuildContext context) => const DetailPanePlaceholder(
        icon: Icons.person_outline,
        message: 'Pick an artist to see their albums here.',
      ),
    );
  }

  List<Track> _filteredSongs(List<Track> songs) => filterTracks(songs, _query);

  Widget _songsList(List<Track> tracks) {
    // Song rows are a single column of text: past [maxContentWidth] the title
    // and the trailing menu end up a screen apart, so the column stops growing
    // and centres instead of stretching across a desktop monitor.
    return AdaptiveContentWidth(
      child: AlphabetTrackList(
        tracks: tracks,
        selectable: true,
        selectionActive: _selecting,
        selectedUris: _selection.uris,
        onSelectStart: _enterSelection,
        onSelectToggle: _toggle,
        onSelectRange: _extendSelection,
      ),
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
      _selection.start(track);
    });
    // Selection is only reachable from the songs list, so that is the list it
    // must show. Guarding the restore is not enough on its own: a long press
    // holds the pointer for half a second before firing, and a restore landing
    // inside that window sees no selection yet and moves the tab underneath the
    // gesture. Coming back here closes it from the other end, whatever the
    // timing was.
    if (_tabController.index != 0) {
      _programmaticTabChange = true;
      _tabController.index = 0;
      _programmaticTabChange = false;
    }
  }

  void _toggle(Track track) {
    setState(() {
      _selection.toggle(track);
      if (!_selection.isActive) _selecting = false;
    });
  }

  /// Shift-click: everything between the anchor and the clicked row, over the
  /// list the A–Z view actually shows — so a search or a re-sort can never make
  /// a range span rows that are not between its two ends on screen.
  void _extendSelection(List<Track> tracks, int index) {
    setState(() {
      _selection.extendTo(tracks, index);
      _selecting = _selection.isActive;
    });
  }

  void _exitSelection() {
    setState(() {
      _selecting = false;
      _selection.clear();
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

  /// Open the system folder picker, persist the choice, then scan. A cancelled
  /// pick leaves everything untouched. The UI only talks to the two
  /// controllers — never to a picker plugin or the file system directly.
  ///
  /// Desktop adds the folder to the ones already selected; Android replaces the
  /// selection, because its local access is a single grant at a time.
  Future<void> _pickAndScan() async {
    final SelectedFolderController folders =
        ref.read(selectedFolderControllerProvider.notifier);
    final bool isAndroid = ref.read(hostPlatformProvider).isAndroid;
    final String? path =
        isAndroid ? await folders.pickAndPersist() : await folders.pickAndAdd();
    if (path == null) return;
    final List<String> selected =
        ref.read(selectedFolderControllerProvider).valueOrNull ??
            <String>[path];
    await ref.read(libraryControllerProvider.notifier).scanFolders(selected);
  }

  /// Re-scan the folder the user already selected, without opening the picker.
  Future<void> _rescan(List<String> folders) {
    return ref.read(libraryControllerProvider.notifier).scanFolders(folders);
  }
}

/// The catalog-tab counterpart to [_LibrarySyncing], for the case where a
/// folder-capable server is connected (so the tabs are already showing) but its
/// first sync hasn't landed any tracks yet. Says the catalog is still filling
/// rather than that it is empty, and still points at Folders — which *is*
/// browseable right now, ahead of the sync.
class _CatalogFilling extends StatelessWidget {
  const _CatalogFilling({required this.headline});

  final String headline;

  @override
  Widget build(BuildContext context) {
    return EmptyState(
      icon: Icons.sync_outlined,
      title: headline,
      message: 'Your songs will appear here as soon as they’re in. '
          'You can browse the connected server from Folders meanwhile.',
    );
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

/// Shown when the catalog is still empty but a first library sync is running,
/// so onboarding reads as "your library is on its way" rather than "nothing
/// here". Replaced automatically once the synced tracks land.
///
/// [headline] names the syncing source when exactly one is running and stays
/// general when several are — see `syncingHeadline`.
class _LibrarySyncing extends StatelessWidget {
  const _LibrarySyncing({required this.headline});

  final String headline;

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
              headline,
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

/// The empty state, split by which local source is selected so the user always
/// sees the right next step:
///  - nothing chosen → invite them to pick a folder;
///  - a folder chosen but nothing found → show the folder and offer a re-scan
///    or a change of folder;
///  - Android's device-wide MediaStore library chosen → there is no folder to
///    reselect, so say the device reported no music and offer a rescan.
class _LibraryEmpty extends StatelessWidget {
  const _LibraryEmpty({
    required this.selectedFolders,
    required this.onPick,
    this.onRescan,
  });

  final List<String> selectedFolders;
  final VoidCallback onPick;
  final VoidCallback? onRescan;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasFolder = selectedFolders.isNotEmpty;
    final FolderLocation? location =
        hasFolder ? FolderLocation.parse(selectedFolders.first) : null;
    final bool isDeviceLibrary = location?.isAndroidMediaStore ?? false;
    // A folder selected as a plain filesystem path on Android is the legacy/
    // broken case: scoped storage won't let Linthra read it, so it turns up
    // empty. Nudge the user to pick it again, which now returns a SAF grant.
    // The MediaStore sentinel is not a path, so it must not land here.
    final bool needsRepick =
        hasFolder && Platform.isAndroid && location!.isFilesystemPath;
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
              isDeviceLibrary
                  ? "Android's music library reported no audio on this device."
                  : selectedFolders.length > 1
                      ? 'Nothing playable turned up in your '
                          '${selectedFolders.length} music folders.'
                      : hasFolder
                          ? 'Nothing playable turned up in:\n'
                              '${location!.displayLabel}'
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
                child: Text(
                  isDeviceLibrary
                      ? 'Rescan this device'
                      : selectedFolders.length > 1
                          ? 'Rescan folders'
                          : 'Rescan folder',
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              TextButton(
                onPressed: onPick,
                child: Text(
                  isDeviceLibrary
                      ? 'Use a folder instead'
                      : selectedFolders.length > 1
                          ? 'Add a folder'
                          : 'Change folder',
                ),
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
