import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/dimens.dart';
import '../../app/routes.dart';
import '../../shared/layout/adaptive_layout.dart';
import '../../shared/scroll/horizontal_wheel_scroll.dart';
import '../../shared/widgets/empty_state.dart';
import '../../shared/widgets/loading_indicator.dart';
import 'audiobooks_library_controller.dart';
import 'audiobooks_library_state.dart';

/// Browses the books on a connected Audiobookshelf server.
///
/// Listing only: this is the second half of the Audiobookshelf connection
/// milestone, so a row shows what the book is and nothing opens yet. Playback,
/// chapters and resume position arrive with the domain model next.
///
/// It is reached from Settings › Connections for now. When Audiobooks gets its
/// own navigation destination (its own reviewable change, agreed on the
/// tracking issue), this screen moves there unchanged.
class AudiobooksScreen extends ConsumerStatefulWidget {
  const AudiobooksScreen({super.key});

  @override
  ConsumerState<AudiobooksScreen> createState() => _AudiobooksScreenState();
}

class _AudiobooksScreenState extends ConsumerState<AudiobooksScreen> {
  @override
  void initState() {
    super.initState();
    // After the first frame: the controller awaits the keyring read, and
    // mutating a provider during build is not allowed.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(
        ref.read(audiobooksLibraryControllerProvider.notifier).load(),
      );
    });
  }

  Future<void> _refresh() =>
      ref.read(audiobooksLibraryControllerProvider.notifier).refresh();

  @override
  Widget build(BuildContext context) {
    final AudiobooksLibraryState state =
        ref.watch(audiobooksLibraryControllerProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Audiobooks'),
        actions: <Widget>[
          if (state.isConnected)
            IconButton(
              onPressed: state.isLoading ? null : _refresh,
              icon: const Icon(Icons.refresh_outlined),
              tooltip: 'Refresh',
            ),
        ],
      ),
      body: AdaptiveContentWidth(child: _Body(state: state)),
    );
  }
}

class _Body extends ConsumerWidget {
  const _Body({required this.state});

  final AudiobooksLibraryState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!state.isConnected) {
      return const _NotConnectedView();
    }
    if (state.isLoading) {
      return const LoadingIndicator(label: 'Loading audiobooks');
    }
    // Nothing loaded and something went wrong: the error *is* the screen.
    // A failure with books already on it is reported under the list instead,
    // so a page that didn't arrive can't take the ones that did off screen.
    if (state.books.isEmpty && state.errorMessage != null) {
      return _ErrorView(
        message: state.errorMessage!,
        onRetry: () =>
            ref.read(audiobooksLibraryControllerProvider.notifier).refresh(),
      );
    }
    if (state.libraries.isEmpty) {
      return const EmptyState(
        icon: Icons.menu_book_outlined,
        title: 'No audiobook libraries',
        message: 'This account can\'t see a book library on your '
            'Audiobookshelf server yet. Add one there, then refresh.',
      );
    }

    return _LibraryView(state: state);
  }
}

/// The library picker and the book list, sharing one scroll controller.
///
/// The list's controller is held here rather than inside [_BookList] because
/// the chip row above it has to reach it. The two are siblings in a column, so
/// a wheel notch that the row cannot use has nothing to fall through to on its
/// own — see [HorizontalWheelScroll.chainTo], which is what carries it down to
/// the books instead of it doing nothing at all.
class _LibraryView extends StatefulWidget {
  const _LibraryView({required this.state});

  final AudiobooksLibraryState state;

  @override
  State<_LibraryView> createState() => _LibraryViewState();
}

class _LibraryViewState extends State<_LibraryView> {
  final ScrollController _books = ScrollController();

  @override
  void dispose() {
    _books.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        // Only worth the row when there is a choice to make.
        if (widget.state.libraries.length > 1)
          _LibraryPicker(state: widget.state, chainTo: _books),
        Expanded(child: _BookList(state: widget.state, controller: _books)),
      ],
    );
  }
}

/// The connection isn't set up (or was signed out): say so and point at the
/// one place that fixes it, rather than showing an empty list.
class _NotConnectedView extends StatelessWidget {
  const _NotConnectedView();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const EmptyState(
              icon: Icons.headphones_outlined,
              title: 'No Audiobookshelf server',
              message: 'Connect your self-hosted Audiobookshelf server to '
                  'browse your audiobooks here.',
            ),
            FilledButton.icon(
              onPressed: () => context.go(AppRoutes.settingsConnections),
              icon: const Icon(Icons.link_outlined),
              label: const Text('Set up the connection'),
            ),
            const SizedBox(height: AppSpacing.xl),
          ],
        ),
      ),
    );
  }
}

/// The listing failed with nothing to show: the message plus a way to try
/// again. The session is still fine, only the request wasn't.
class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.error_outline, size: 40, color: theme.colorScheme.error),
            const SizedBox(height: AppSpacing.md),
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: AppSpacing.md),
            FilledButton.tonalIcon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_outlined),
              label: const Text('Try again'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Which library is being browsed, when the account can see more than one.
class _LibraryPicker extends ConsumerWidget {
  const _LibraryPicker({required this.state, required this.chainTo});

  final AudiobooksLibraryState state;

  /// The book list under this row, which takes a wheel notch once the row
  /// itself has run out of libraries to show.
  final ScrollController chainTo;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        AppSpacing.sm,
        AppSpacing.md,
        0,
      ),
      // The one genuinely horizontal surface in the app, and the only place a
      // vertical wheel is allowed to mean "sideways": a mouse with one wheel
      // could otherwise never reach the libraries past the right edge (#396).
      child: HorizontalWheelScroll(
        chainTo: chainTo,
        builder: (BuildContext context, ScrollController controller) =>
            SingleChildScrollView(
          controller: controller,
          scrollDirection: Axis.horizontal,
          child: Row(
            children: <Widget>[
              for (final AudiobookLibrarySummary library in state.libraries)
                Padding(
                  padding: const EdgeInsets.only(right: AppSpacing.sm),
                  child: ChoiceChip(
                    label: Text(library.name),
                    selected: library.id == state.selectedLibraryId,
                    onSelected: (bool selected) {
                      if (!selected) return;
                      unawaited(
                        ref
                            .read(audiobooksLibraryControllerProvider.notifier)
                            .selectLibrary(library.id),
                      );
                    },
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BookList extends ConsumerWidget {
  const _BookList({required this.state, required this.controller});

  final AudiobooksLibraryState state;

  /// Owned by [_LibraryView], so the picker above can scroll this list.
  final ScrollController controller;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bool hasFooter = state.hasMore || state.errorMessage != null;
    // Only really empty when there is also nothing left to fetch. A first
    // page whose every record was unreadable comes back with no books but
    // more to come, and calling that "empty" would strand the rest of the
    // library behind a footer this never drew.
    if (state.books.isEmpty && !hasFooter) {
      return const EmptyState(
        icon: Icons.menu_book_outlined,
        title: 'No audiobooks yet',
        message: 'This library is empty. Add books on your Audiobookshelf '
            'server and scan it, then refresh.',
      );
    }

    return RefreshIndicator(
      onRefresh: () =>
          ref.read(audiobooksLibraryControllerProvider.notifier).refresh(),
      child: ListView.builder(
        controller: controller,
        itemCount: state.books.length + (hasFooter ? 1 : 0),
        itemBuilder: (BuildContext context, int index) {
          if (index >= state.books.length) {
            return _ListFooter(state: state);
          }
          return _BookTile(book: state.books[index]);
        },
      ),
    );
  }
}

/// One book. Nothing opens yet (the listing is this milestone, playback is
/// the next one), so the row is deliberately not tappable.
class _BookTile extends StatelessWidget {
  const _BookTile({required this.book});

  final AudiobookSummary book;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final String? subtitle = _subtitleOf(book);
    final String? length = formatBookDuration(book.duration);

    return ListTile(
      leading: CircleAvatar(
        backgroundColor: theme.colorScheme.primary.withValues(alpha: 0.12),
        foregroundColor: theme.colorScheme.primary,
        child: const Icon(Icons.menu_book_outlined),
      ),
      title: Text(book.title, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: subtitle == null
          ? null
          : Text(subtitle, maxLines: 2, overflow: TextOverflow.ellipsis),
      trailing: length == null
          ? null
          : Text(length, style: theme.textTheme.bodySmall),
    );
  }

  /// The one supporting line: who wrote it, the series it's part of, and who
  /// reads it, in that order and only when the server reported them.
  static String? _subtitleOf(AudiobookSummary book) {
    final List<String> parts = <String>[
      if (book.author != null) book.author!,
      if (book.series != null) book.series!,
      if (book.narrator != null) 'Read by ${book.narrator}',
    ];
    if (parts.isEmpty) return book.subtitle;
    return parts.join(' • ');
  }
}

/// The tail of the list: whatever the last page attempt left behind, more to
/// load, a spinner, or the failure that stopped it.
class _ListFooter extends ConsumerWidget {
  const _ListFooter({required this.state});

  final AudiobooksLibraryState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        children: <Widget>[
          if (state.errorMessage != null) ...<Widget>[
            Text(
              state.errorMessage!,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.error),
            ),
            const SizedBox(height: AppSpacing.sm),
          ] else if (state.books.isEmpty && state.hasMore) ...<Widget>[
            // Every record on this page was unreadable (a half-scanned book,
            // say). Say so plainly and keep the next page reachable.
            Text(
              "Nothing on this page could be read. There's more in this "
              'library, though.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
          ],
          if (state.isLoadingMore)
            const SizedBox.square(
              dimension: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else if (state.hasMore)
            OutlinedButton(
              onPressed: () => unawaited(
                ref
                    .read(audiobooksLibraryControllerProvider.notifier)
                    .loadMore(),
              ),
              child: Text(
                state.books.isEmpty
                    ? 'Load the next page'
                    : 'Load more (${state.books.length} of '
                        '${state.totalBooks})',
              ),
            ),
        ],
      ),
    );
  }
}

/// Renders a running time the way a listener reads one: "11h 42m", "48m", or
/// "3m" for something very short. `null` when the server didn't report one, so
/// the row shows nothing rather than a made-up 0:00.
String? formatBookDuration(Duration? duration) {
  if (duration == null || duration <= Duration.zero) return null;
  final int hours = duration.inHours;
  final int minutes = duration.inMinutes.remainder(60);
  if (hours > 0) {
    return minutes > 0 ? '${hours}h ${minutes}m' : '${hours}h';
  }
  // Under a minute still reads as a minute: a book that short is a scanning
  // artifact, and "0m" looks like a bug.
  return '${minutes < 1 ? 1 : minutes}m';
}
