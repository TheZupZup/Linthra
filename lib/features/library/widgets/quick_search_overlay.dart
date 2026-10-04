import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/dimens.dart';
import '../../../app/routes.dart';
import '../../../core/models/track.dart';
import '../../player/now_playing_after_play.dart';
import '../../player/player_providers.dart';
import '../../player/widgets/album_artwork.dart';
import '../quick_search.dart';
import '../quick_search_providers.dart';

/// Opens the quick-search overlay above whatever is on screen.
///
/// It is a dialog on the root navigator, so the current screen keeps its state:
/// nothing is pushed onto a tab's stack, no branch is switched, and closing the
/// overlay leaves the user exactly where they were — including mid-scroll, with
/// a Library search of their own still typed in the box behind it.
Future<void> showQuickSearch(BuildContext context) {
  return showDialog<void>(
    context: context,
    // A soft scrim rather than the default heavy one: the overlay is a lookup
    // over the app, not a modal that has taken it over.
    barrierColor: Colors.black.withValues(alpha: 0.35),
    barrierLabel: 'Quick search',
    builder: (BuildContext context) => const QuickSearchOverlay(),
  );
}

/// The desktop quick-search overlay: one box that searches songs, albums,
/// artists and playlists at once, fully drivable from the keyboard.
///
/// Everything it shows comes from the providers the Library screen already
/// browses (see `quick_search_providers.dart`) — there is no second catalog and
/// no separate query path to the repository. Typing is debounced so a large
/// library is ranked when the user pauses, not on every keystroke.
class QuickSearchOverlay extends ConsumerStatefulWidget {
  const QuickSearchOverlay({super.key});

  /// How long typing must pause before the ranking re-runs. Shorter than the
  /// Library screen's 300 ms: the overlay is a "type three letters and hit
  /// Enter" surface, where a longer wait is felt as lag.
  static const Duration debounce = Duration(milliseconds: 200);

  /// Widest the overlay gets, so it stays a dialog on an ultrawide monitor.
  static const double maxWidth = 640;

  /// Tallest the result list gets before it scrolls.
  static const double maxResultsHeight = 380;

  @override
  ConsumerState<QuickSearchOverlay> createState() => _QuickSearchOverlayState();
}

class _QuickSearchOverlayState extends ConsumerState<QuickSearchOverlay> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _fieldFocus = FocusNode(debugLabel: 'quickSearchField');
  final ScrollController _scrollController = ScrollController();

  /// One key per rendered result row, so the highlighted row can be scrolled
  /// into view without guessing at row heights.
  final List<GlobalKey> _rowKeys = <GlobalKey>[];

  /// The debounced query the ranking runs on — deliberately not the field text,
  /// which changes on every keystroke.
  String _query = '';

  /// Index into [QuickSearchResults.rows] of the row Enter would open.
  int _highlighted = 0;

  Timer? _debounce;

  /// Where the pointer was when it last drove the selection, so a synthesized
  /// hover at the same spot can be told from a real one.
  Offset? _lastPointerPosition;

  /// Whether the box is currently blank. Tracked separately from [_query]
  /// because they legitimately disagree for one debounce window, and the
  /// difference is exactly what tells "nothing typed yet" from "still ranking".
  bool _fieldIsBlank = true;

  @override
  void initState() {
    super.initState();
    // The *ranking* is debounced; the chrome around it is not. Without this the
    // clear button and the "Searching…" note would lag 200 ms behind the text
    // the user can already see in the box.
    _controller.addListener(_onFieldTextChanged);
  }

  /// Rebuilds only when the field crosses between blank and non-blank, so an
  /// ordinary keystroke costs nothing beyond the debounce it restarts.
  void _onFieldTextChanged() {
    final bool blank = _controller.text.trim().isEmpty;
    if (blank != _fieldIsBlank) setState(() => _fieldIsBlank = blank);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.removeListener(_onFieldTextChanged);
    _controller.dispose();
    _fieldFocus.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  // --- Query ------------------------------------------------------------

  void _onQueryChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(QuickSearchOverlay.debounce, () {
      if (!mounted) return;
      setState(_applyQuery(value));
    });
  }

  /// The state mutation a newly settled [query] causes, as a closure for
  /// `setState`. Shared by the debounce and by [_flushPendingQuery] so a flushed
  /// query can never leave the list in a different state than a settled one.
  VoidCallback _applyQuery(String query) {
    return () {
      _query = query;
      // A new query means a new list, so the highlight goes back to the top.
      _highlighted = 0;
      // ...and so does the list itself. Without this a user who had scrolled
      // the previous results down would get row 0 highlighted off-screen, and
      // Enter would open something they cannot see.
      _resetScroll();
    };
  }

  /// Returns the scroll offset to the top, once the new list has been laid out.
  void _resetScroll() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      if (_scrollController.offset != 0) _scrollController.jumpTo(0);
    });
  }

  /// Applies a pending debounce right now and returns the results for what is
  /// actually in the box.
  ///
  /// Without this, a keyboard user who types and presses Enter inside the 200 ms
  /// window acts on the *previous* query: on the first one Enter does nothing,
  /// and on a later one it opens a stale row that no longer matches the text
  /// they can see. Flushing makes the key press act on what is typed, which is
  /// the whole "type three letters and hit Enter" flow.
  QuickSearchResults _flushPendingQuery(QuickSearchResults rendered) {
    final Timer? pending = _debounce;
    if (pending == null || !pending.isActive) return rendered;
    pending.cancel();
    _debounce = null;
    final String typed = _controller.text;
    setState(_applyQuery(typed));
    return ref.read(quickSearchResultsProvider(typed));
  }

  void _clear() {
    // Clearing must be immediate — a pending debounce would otherwise write the
    // just-cleared query back a moment later.
    _debounce?.cancel();
    _debounce = null;
    _controller.clear();
    setState(_applyQuery(''));
    _fieldFocus.requestFocus();
  }

  // --- Keyboard ---------------------------------------------------------

  void _move(int delta, int rowCount) {
    if (rowCount == 0) return;
    setState(() {
      // Wrapping means Up from the first row lands on the last, which is what a
      // short list makes people expect.
      _highlighted = (_highlighted + delta) % rowCount;
      if (_highlighted < 0) _highlighted += rowCount;
    });
    _scrollHighlightedIntoView();
  }

  /// Moves the highlight to a hovered row — but only when the pointer really
  /// moved there.
  ///
  /// A row sliding under a stationary pointer (a re-render on a new query, or
  /// `ensureVisible` scrolling the list) synthesizes an enter/hover at the
  /// unchanged pointer position. That is the list moving, not the user choosing,
  /// so it must not take the selection off the row the keyboard just put it on.
  void _hoverRow(int index, Offset position) {
    // Recorded on every event, selection-changing or not, so "did the pointer
    // move?" is answered against the last place it was actually seen rather
    // than the last place it happened to pick a row.
    final Offset? previous = _lastPointerPosition;
    _lastPointerPosition = position;
    if (previous == position) return;
    if (_highlighted != index) setState(() => _highlighted = index);
  }

  void _scrollHighlightedIntoView() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _highlighted >= _rowKeys.length) return;
      final BuildContext? rowContext = _rowKeys[_highlighted].currentContext;
      if (rowContext == null) return;
      unawaited(
        Scrollable.ensureVisible(
          rowContext,
          alignment: 0.5,
          duration: const Duration(milliseconds: 120),
        ),
      );
    });
  }

  // --- Activation -------------------------------------------------------

  /// Opens [result] and closes the overlay.
  ///
  /// Every kind goes through the route or action the rest of the app already
  /// uses, so a result opens exactly what tapping the same item in the Library
  /// would: songs play through the playback controller (and open Now Playing
  /// where tapping a Library row does); albums, artists and playlists open
  /// their existing detail routes.
  void _activate(QuickSearchResult result, QuickSearchResults results) {
    // The router and the controller are read before the pop, because `context`
    // and `ref` belong to a widget that is about to be gone.
    final GoRouter router = GoRouter.of(context);
    final navigator = Navigator.of(context);
    final bool openNowPlaying = opensNowPlayingOnPlay(context);

    switch (result) {
      case QuickSearchSong():
        final List<Track> songs = <Track>[
          for (final QuickSearchResult row
              in results.groups[QuickSearchKind.song] ??
                  const <QuickSearchResult>[])
            (row as QuickSearchSong).track,
        ];
        final int startIndex = songs.indexOf(result.track);
        ref.read(playbackControllerProvider).playTracks(
              songs,
              // The song group becomes the queue, positioned at the chosen row:
              // Next walks the matches below it and Previous the ones above,
              // exactly as tapping a row in the Library's own list behaves.
              startIndex: startIndex < 0 ? 0 : startIndex,
            );
        navigator.pop();
        // Quick search opens from anywhere, Now Playing included, so the screen
        // it wants may already be the one showing. Pushing a second copy would
        // leave an identical screen behind it and cost the user an extra Back
        // to get home — and one more for every search they run from there.
        if (openNowPlaying && router.state.uri.path != AppRoutes.player) {
          router.push(AppRoutes.player);
        }
      case QuickSearchAlbum():
        navigator.pop();
        router.go(AppRoutes.albumDetailPath(result.album.id));
      case QuickSearchArtist():
        navigator.pop();
        router.go(AppRoutes.artistDetailPath(result.artist.id));
      case QuickSearchPlaylist():
        navigator.pop();
        router.go(AppRoutes.playlistDetailPath(result.playlist.id));
    }
  }

  // --- Build ------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final QuickSearchResults results =
        ref.watch(quickSearchResultsProvider(_query));
    final QuickSearchAvailability availability =
        ref.watch(quickSearchAvailabilityProvider);

    // Clamp before rendering: the catalog can change underneath an open overlay
    // (a sync lands, a playlist is deleted) and shrink the list.
    if (_highlighted >= results.rows.length) {
      _highlighted = results.rows.isEmpty ? 0 : results.rows.length - 1;
    }

    return Shortcuts(
      // Bound above the text field on purpose: Flutter's own autocomplete does
      // the same, and it is what stops the arrow keys from being eaten as
      // cursor movement inside the box.
      shortcuts: const <ShortcutActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.arrowDown): _MoveHighlightIntent(1),
        SingleActivator(LogicalKeyboardKey.arrowUp): _MoveHighlightIntent(-1),
        SingleActivator(LogicalKeyboardKey.enter): _OpenHighlightedIntent(),
        SingleActivator(LogicalKeyboardKey.numpadEnter):
            _OpenHighlightedIntent(),
        SingleActivator(LogicalKeyboardKey.escape): _CloseQuickSearchIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          // Both key actions flush a pending debounce first, so they act on
          // what is in the box rather than on the previous query's rows.
          _MoveHighlightIntent: CallbackAction<_MoveHighlightIntent>(
            onInvoke: (_MoveHighlightIntent intent) {
              _move(intent.delta, _flushPendingQuery(results).rows.length);
              return null;
            },
          ),
          _OpenHighlightedIntent: CallbackAction<_OpenHighlightedIntent>(
            onInvoke: (_) {
              final QuickSearchResults current = _flushPendingQuery(results);
              if (_highlighted < current.rows.length) {
                _activate(current.rows[_highlighted], current);
              }
              return null;
            },
          ),
          _CloseQuickSearchIntent: CallbackAction<_CloseQuickSearchIntent>(
            onInvoke: (_) {
              Navigator.of(context).pop();
              return null;
            },
          ),
        },
        child: Dialog(
          // Sits high in the window rather than centred: the results grow
          // downwards from the box, so the box itself never moves as they do.
          alignment: const Alignment(0, -0.55),
          clipBehavior: Clip.antiAlias,
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: QuickSearchOverlay.maxWidth,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                _field(theme),
                const Divider(height: 1),
                Flexible(child: _body(theme, results, availability)),
                const Divider(height: 1),
                _hints(theme),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _field(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.xs,
      ),
      child: TextField(
        key: const Key('quick_search_field'),
        controller: _controller,
        focusNode: _fieldFocus,
        autofocus: true,
        onChanged: _onQueryChanged,
        style: theme.textTheme.titleMedium,
        decoration: InputDecoration(
          border: InputBorder.none,
          hintText: 'Search songs, albums, artists, playlists',
          prefixIcon: const Icon(Icons.search),
          suffixIcon: _fieldIsBlank
              ? null
              : IconButton(
                  key: const Key('quick_search_clear'),
                  icon: const Icon(Icons.close),
                  tooltip: 'Clear search',
                  onPressed: _clear,
                ),
        ),
      ),
    );
  }

  Widget _body(
    ThemeData theme,
    QuickSearchResults results,
    QuickSearchAvailability availability,
  ) {
    // Whatever did load is worth showing even when something else failed: a
    // Jellyfin outage should not hide the local songs behind an error screen.
    if (results.isNotEmpty) return _resultList(theme, results);

    // Nothing to show. Which of the reasons it is matters: a user who typed
    // something and sees "nothing here" while the catalog is still loading — or
    // failed to load — would reasonably conclude their music is missing.
    final Widget message;
    if (availability == QuickSearchAvailability.loading) {
      message = const _Placeholder(
        key: Key('quick_search_loading'),
        icon: Icons.hourglass_empty,
        title: 'Loading your library…',
        message: 'Search will be ready in a moment.',
      );
    } else if (_fieldIsBlank) {
      message = const _Placeholder(
        key: Key('quick_search_prompt'),
        icon: Icons.search,
        title: 'Search your library',
        message: 'Songs, albums, artists and playlists.',
      );
    } else if (_query.trim().isEmpty) {
      // Typed, but the debounce has not fired yet: say "searching" rather than
      // flashing "no results" for a moment and then contradicting it.
      message = const _Placeholder(
        key: Key('quick_search_searching'),
        icon: Icons.search,
        title: 'Searching…',
      );
    } else if (availability == QuickSearchAvailability.degraded) {
      // Empty *and* something failed to load: "no results" would be a claim we
      // cannot back up, so say what actually happened instead.
      message = const _Placeholder(
        key: Key('quick_search_unavailable'),
        icon: Icons.cloud_off,
        title: 'Some of your library could not be loaded',
        message: 'Search results are incomplete until it loads again.',
      );
    } else {
      message = _Placeholder(
        key: const Key('quick_search_no_results'),
        icon: Icons.search_off,
        title: 'No results for “${_query.trim()}”',
        message: 'Try fewer words, or part of a name.',
      );
    }
    return SizedBox(height: 180, child: message);
  }

  Widget _resultList(ThemeData theme, QuickSearchResults results) {
    // Every row is built (rather than lazily, as a ListView would): the groups
    // are capped at a handful of rows each, and having all of them in the tree
    // is what lets `ensureVisible` scroll to a highlighted row that is
    // currently off-screen.
    _syncRowKeys(results.rows.length);
    int index = 0;
    final List<Widget> children = <Widget>[];
    for (final MapEntry<QuickSearchKind, List<QuickSearchResult>> group
        in results.groups.entries) {
      children.add(_groupHeader(theme, group.key));
      for (final QuickSearchResult result in group.value) {
        final int rowIndex = index++;
        children.add(
          _ResultRow(
            key: _rowKeys[rowIndex],
            result: result,
            selected: rowIndex == _highlighted,
            onTap: () => _activate(result, results),
            onPointerAt: (Offset position) => _hoverRow(rowIndex, position),
          ),
        );
      }
    }

    return ConstrainedBox(
      constraints: const BoxConstraints(
        maxHeight: QuickSearchOverlay.maxResultsHeight,
      ),
      child: SingleChildScrollView(
        controller: _scrollController,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: children,
        ),
      ),
    );
  }

  /// Grows or shrinks [_rowKeys] to [count], reusing the keys already made so a
  /// row that stayed put keeps its element across a re-rank.
  void _syncRowKeys(int count) {
    while (_rowKeys.length < count) {
      _rowKeys.add(GlobalKey(debugLabel: 'quickSearchRow${_rowKeys.length}'));
    }
    if (_rowKeys.length > count) _rowKeys.removeRange(count, _rowKeys.length);
  }

  Widget _groupHeader(ThemeData theme, QuickSearchKind kind) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        AppSpacing.md,
        AppSpacing.md,
        AppSpacing.xs,
      ),
      child: Text(
        kind.label,
        style: theme.textTheme.labelMedium?.copyWith(
          color: theme.colorScheme.primary,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _hints(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.sm,
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              '↑ ↓ to move · Enter to open · Esc to close',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Move the highlight by [delta] rows.
class _MoveHighlightIntent extends Intent {
  const _MoveHighlightIntent(this.delta);

  final int delta;
}

/// Open whatever row is highlighted.
class _OpenHighlightedIntent extends Intent {
  const _OpenHighlightedIntent();
}

/// Close the overlay without opening anything.
class _CloseQuickSearchIntent extends Intent {
  const _CloseQuickSearchIntent();
}

/// One result row. Highlighted rows are tinted rather than focused, because the
/// text field keeps focus the whole time — the arrow keys move a selection, not
/// the focus.
class _ResultRow extends StatelessWidget {
  const _ResultRow({
    required this.result,
    required this.selected,
    required this.onTap,
    required this.onPointerAt,
    super.key,
  });

  final QuickSearchResult result;
  final bool selected;
  final VoidCallback onTap;

  /// Called with the pointer's position on every enter and hover, so the host
  /// can tell a real mouse move from a row sliding under a still pointer.
  final ValueChanged<Offset> onPointerAt;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final String? subtitle = result.subtitle;
    return MouseRegion(
      onEnter: (PointerEnterEvent event) => onPointerAt(event.position),
      onHover: (PointerHoverEvent event) => onPointerAt(event.position),
      child: ListTile(
        selected: selected,
        selectedTileColor: theme.colorScheme.primary.withValues(alpha: 0.12),
        // The tint is the whole point of the highlight, so it must not also
        // recolour the text into the accent.
        selectedColor: theme.colorScheme.onSurface,
        leading: _leading(theme),
        title: Text(
          result.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: subtitle == null
            ? null
            : Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
        onTap: onTap,
      ),
    );
  }

  Widget _leading(ThemeData theme) {
    switch (result) {
      case QuickSearchSong(:final Track track):
        return _cover(track.artworkUri);
      case QuickSearchAlbum(:final album):
        return _cover(album.artworkUri);
      case QuickSearchArtist():
        return _icon(theme, Icons.person_outline);
      case QuickSearchPlaylist():
        return _icon(theme, Icons.queue_music_outlined);
    }
  }

  Widget _cover(Uri? artworkUri) {
    return SizedBox.square(
      dimension: 40,
      child: AlbumArtwork(
        artworkUri: artworkUri,
        borderRadius: const BorderRadius.all(Radius.circular(AppRadii.sm)),
      ),
    );
  }

  Widget _icon(ThemeData theme, IconData icon) {
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: theme.colorScheme.primary.withValues(alpha: 0.12),
        borderRadius: const BorderRadius.all(Radius.circular(AppRadii.sm)),
      ),
      child: Icon(icon, size: 20, color: theme.colorScheme.primary),
    );
  }
}

/// The calm centred message the overlay shows when it has no rows: a prompt, a
/// loading note, or an honest "nothing matched".
class _Placeholder extends StatelessWidget {
  const _Placeholder({
    required this.icon,
    required this.title,
    this.message,
    super.key,
  });

  final IconData icon;
  final String title;
  final String? message;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              icon,
              size: 32,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.4),
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              title,
              style: theme.textTheme.titleSmall,
              textAlign: TextAlign.center,
            ),
            if (message != null) ...<Widget>[
              const SizedBox(height: AppSpacing.xs),
              Text(
                message!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
