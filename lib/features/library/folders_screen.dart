import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/dimens.dart';
import '../../core/models/music_folder.dart';
import '../../core/services/folder_browsable_music_source.dart';
import '../../shared/widgets/empty_state.dart';
import '../../shared/widgets/loading_indicator.dart';
import 'folder_browser_providers.dart';
import 'widgets/track_tile.dart';

/// Browses the real directory hierarchy exposed by Jellyfin and
/// Navidrome/Subsonic, one level at a time.
///
/// A top-level destination beside Library, Playlists, Downloads and Settings,
/// with its own navigation branch — so a folder you were three levels deep in
/// is still open when you come back to it from another tab.
///
/// The hierarchy is fetched on demand, so this does not require the directory
/// tree to be persisted or recursively synced first. With no folder-capable
/// server connected it shows an empty state pointing at Connections rather
/// than disappearing, so the feature is discoverable before it is usable.
///
/// Android's system Back first walks up the folder trail; only at the roots
/// does it leave the screen.
class FoldersScreen extends ConsumerStatefulWidget {
  const FoldersScreen({super.key});

  @override
  ConsumerState<FoldersScreen> createState() => _FoldersScreenState();
}

class _FoldersScreenState extends ConsumerState<FoldersScreen> {
  final List<_FolderLocation> _trail = <_FolderLocation>[];

  @override
  Widget build(BuildContext context) {
    final List<FolderBrowsableMusicSource> sources =
        ref.watch(folderBrowsableSourcesProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Folders')),
      body: _body(sources),
    );
  }

  Widget _body(List<FolderBrowsableMusicSource> sources) {
    if (_trail.isNotEmpty &&
        !sources.any((source) => source.id == _trail.last.sourceId)) {
      // A sign-out can happen while this screen is open. Return to roots on the
      // next frame instead of trying to fetch with a session that no longer
      // exists (and never mutate state during build).
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(_trail.clear);
      });
      return const LoadingIndicator(label: 'Loading folders');
    }

    if (_trail.isEmpty) {
      // Nothing to intercept at the roots, so no listener is registered and
      // Back behaves exactly as it does on the other top-level destinations.
      return _FolderRoots(sources: sources, onOpen: _openRoot);
    }

    // BackButtonListener talks directly to the Router used by go_router, and
    // can consume the physical/system Back event before the app's root route
    // is closed — which a nested PopScope does not do reliably on every
    // Android back implementation.
    return BackButtonListener(
      onBackButtonPressed: _handleSystemBack,
      child: _FolderContents(
        location: _trail.last,
        onBack: _goBack,
        onOpen: _openChild,
      ),
    );
  }

  /// Consumes Android Back only when this branch is the one on screen and
  /// there is a folder level to leave.
  ///
  /// The shell keeps every branch mounted inside an IndexedStack, so a Folders
  /// screen sitting three levels deep behind the Library tab would otherwise
  /// swallow Back while the user is looking at Library. go_router marks the
  /// inactive branches by disabling their tickers, which is the one signal
  /// available here that distinguishes "mounted" from "visible" — the branches
  /// are all laid out at the same offset, so measuring bounds cannot.
  Future<bool> _handleSystemBack() async {
    if (_trail.isEmpty || !TickerMode.valuesOf(context).enabled) {
      return false;
    }
    _goBack();
    return true;
  }

  void _openRoot(FolderBrowsableMusicSource source, MusicFolder folder) {
    setState(() {
      _trail.add(
        _FolderLocation(
          sourceId: source.id,
          sourceName: source.displayName,
          folder: folder,
        ),
      );
    });
  }

  void _openChild(MusicFolder folder) {
    final _FolderLocation current = _trail.last;
    setState(() {
      _trail.add(
        _FolderLocation(
          sourceId: current.sourceId,
          sourceName: current.sourceName,
          folder: folder,
        ),
      );
    });
  }

  void _goBack() {
    if (_trail.isEmpty) return;
    setState(() => _trail.removeLast());
  }
}

class _FolderRoots extends ConsumerWidget {
  const _FolderRoots({required this.sources, required this.onOpen});

  final List<FolderBrowsableMusicSource> sources;
  final void Function(FolderBrowsableMusicSource source, MusicFolder folder)
      onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (sources.isEmpty) {
      return const EmptyState(
        icon: Icons.folder_off_outlined,
        title: 'No server folders available',
        message: 'Connect Jellyfin or Navidrome / Subsonic to browse its '
            'folder hierarchy.',
      );
    }

    // Roots are cached like any other level, so they need the same deliberate
    // way past it: a top-level folder added or renamed on the server would
    // otherwise stay hidden behind the cached list. Always-scrollable for the
    // usual reason, a couple of servers do not fill a screen.
    return RefreshIndicator(
      onRefresh: () => _refreshRoots(ref, sources),
      child: ListView(
        key: const Key('folder_browser_roots'),
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.only(bottom: AppSpacing.xl),
        children: <Widget>[
          for (final FolderBrowsableMusicSource source in sources)
            _SourceRootsSection(
              key: ValueKey<String>('folder_source_${source.id}'),
              source: source,
              onOpen: (folder) => onOpen(source, folder),
            ),
        ],
      ),
    );
  }
}

/// Re-reads every connected source's root list for one pull-to-refresh.
///
/// Failures are swallowed for the same reason as [_refresh]: each section shows
/// its own error state, and a gesture-driven future that rejects would surface
/// the same failure a second time as an unhandled async error. One slow or
/// broken server must not stop the others from refreshing, so these are awaited
/// together rather than in sequence.
Future<void> _refreshRoots(
  WidgetRef ref,
  List<FolderBrowsableMusicSource> sources,
) async {
  await Future.wait<void>(<Future<void>>[
    for (final FolderBrowsableMusicSource source in sources)
      () async {
        ref.invalidate(folderRootFoldersProvider(source.id));
        try {
          await ref.read(folderRootFoldersProvider(source.id).future);
        } catch (_) {
          // Rendered by the section's own error state.
        }
      }(),
  ]);
}

class _SourceRootsSection extends ConsumerWidget {
  const _SourceRootsSection({
    required this.source,
    required this.onOpen,
    super.key,
  });

  final FolderBrowsableMusicSource source;
  final ValueChanged<MusicFolder> onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);
    final AsyncValue<List<MusicFolder>> roots =
        ref.watch(folderRootFoldersProvider(source.id));

    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md,
              vertical: AppSpacing.sm,
            ),
            child: Text(
              source.displayName,
              style: theme.textTheme.titleSmall?.copyWith(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          roots.when(
            loading: () => const Padding(
              padding: EdgeInsets.all(AppSpacing.lg),
              child: LoadingIndicator(label: 'Loading folders'),
            ),
            error: (_, __) => _FolderError(
              message: 'Could not load folders from ${source.displayName}.',
              onRetry: () =>
                  ref.invalidate(folderRootFoldersProvider(source.id)),
            ),
            data: (List<MusicFolder> folders) {
              if (folders.isEmpty) {
                return const ListTile(
                  leading: Icon(Icons.folder_off_outlined),
                  title: Text('No music folders reported'),
                );
              }
              return Column(
                children: <Widget>[
                  for (final MusicFolder folder in folders)
                    ListTile(
                      key: ValueKey<String>(
                        'folder_root_${source.id}_${folder.id}',
                      ),
                      leading: const Icon(Icons.folder_outlined),
                      title: Text(
                        folder.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => onOpen(folder),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

/// Re-reads [request] for a pull-to-refresh gesture.
///
/// The failure is swallowed on purpose. RefreshIndicator drives this from a
/// gesture and does not handle a rejected future, so letting a dropped server
/// connection through would surface it as an unhandled async error on top of
/// the error state the provider already renders. The watched AsyncValue is what
/// tells the user; this future only has to end so the spinner retracts.
Future<void> _refresh(WidgetRef ref, FolderBrowseRequest request) async {
  ref.invalidate(folderListingProvider(request));
  try {
    await ref.read(folderListingProvider(request).future);
  } catch (_) {
    // Rendered by the provider's error state, not by the indicator.
  }
}

class _FolderContents extends ConsumerWidget {
  const _FolderContents({
    required this.location,
    required this.onBack,
    required this.onOpen,
  });

  final _FolderLocation location;
  final VoidCallback onBack;
  final ValueChanged<MusicFolder> onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final FolderBrowseRequest request = FolderBrowseRequest(
      sourceId: location.sourceId,
      folderId: location.folder.id,
    );
    final AsyncValue<MusicFolderListing> listing =
        ref.watch(folderListingProvider(request));
    final ThemeData theme = Theme.of(context);

    return Column(
      children: <Widget>[
        Material(
          color: theme.colorScheme.surfaceContainerLow,
          child: ListTile(
            key: const Key('folder_browser_header'),
            leading: IconButton(
              icon: const Icon(Icons.arrow_back),
              tooltip: 'Back to previous folder',
              onPressed: onBack,
            ),
            title: Text(
              location.folder.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              location.sourceName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
        Expanded(
          child: listing.when(
            loading: () => const LoadingIndicator(label: 'Loading folders'),
            error: (_, __) => _FolderError(
              message: 'Could not open this folder.',
              onRetry: () => ref.invalidate(folderListingProvider(request)),
            ),
            data: (MusicFolderListing data) {
              // Pull to refresh is the way out of the cache above: the level is
              // held for a few minutes, so a folder you just changed on the
              // server needs a deliberate way to be re-read (#581).
              //
              // The empty state lives *inside* the refreshable scrollable, and
              // the physics are always-scrollable, because those are exactly
              // the folders that need it most: a folder that is empty or has
              // three entries cannot overscroll on clamping physics, so an
              // indicator wrapped around content alone would be unreachable in
              // the one case where the user knows the server has changed.
              return RefreshIndicator(
                onRefresh: () => _refresh(ref, request),
                child: data.isEmpty
                    ? ListView(
                        key: const Key('folder_browser_contents'),
                        physics: const AlwaysScrollableScrollPhysics(),
                        children: <Widget>[
                          SizedBox(
                            height: MediaQuery.sizeOf(context).height * 0.5,
                            child: const EmptyState(
                              icon: Icons.folder_open_outlined,
                              title: 'This folder is empty',
                              message:
                                  'No child folders or playable songs were '
                                  'found.',
                            ),
                          ),
                        ],
                      )
                    : ListView.builder(
                        key: const Key('folder_browser_contents'),
                        physics: const AlwaysScrollableScrollPhysics(),
                        itemCount: data.folders.length + data.tracks.length,
                        itemBuilder: (BuildContext context, int index) {
                          if (index < data.folders.length) {
                            final MusicFolder folder = data.folders[index];
                            return ListTile(
                              key: ValueKey<String>(
                                'folder_child_${folder.id}',
                              ),
                              leading: const Icon(Icons.folder_outlined),
                              title: Text(
                                folder.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              trailing: const Icon(Icons.chevron_right),
                              onTap: () => onOpen(folder),
                            );
                          }
                          final int trackIndex = index - data.folders.length;
                          return TrackTile(
                            key: ValueKey<String>(
                              'folder_track_${data.tracks[trackIndex].uri}',
                            ),
                            tracks: data.tracks,
                            index: trackIndex,
                          );
                        },
                      ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _FolderError extends StatelessWidget {
  const _FolderError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const Icon(Icons.cloud_off_outlined, size: 36),
          const SizedBox(height: AppSpacing.sm),
          Text(message, textAlign: TextAlign.center),
          const SizedBox(height: AppSpacing.md),
          FilledButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh),
            label: const Text('Try again'),
          ),
        ],
      ),
    );
  }
}

class _FolderLocation {
  const _FolderLocation({
    required this.sourceId,
    required this.sourceName,
    required this.folder,
  });

  final String sourceId;
  final String sourceName;
  final MusicFolder folder;
}
