import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/dimens.dart';
import '../../../core/models/lyrics.dart';
import '../../../shared/widgets/empty_state.dart';
import '../../../shared/widgets/loading_indicator.dart';
import '../lyrics_providers.dart';
import 'lyrics/lyrics_viewport.dart';

/// The lyrics experience shown from Now Playing.
///
/// A thin orchestrator: it picks which of four shapes to show and hands the work
/// to a dedicated widget. It follows the *currently playing* track (via
/// [currentTrackLyricsProvider]), so skipping reloads the lines in place and the
/// previous song's text never lingers.
///
///  - no lyrics → a calm "No lyrics available yet." placeholder;
///  - plain lyrics (no timestamps) → [PlainLyricsViewport], a static readable
///    column with no highlighting and no invented timings;
///  - timed lyrics → [SyncedLyricsViewport], which holds the active line near
///    the middle of the view and fades the lines around it.
///
/// Critically, it only *reads* playback state — opening it never starts or
/// restarts playback. Because it follows the unified [playbackStateProvider]
/// position, it tracks whichever output is active: the local engine, or a cast
/// receiver when casting.
class LyricsView extends ConsumerWidget {
  const LyricsView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<Lyrics?> lyrics = ref.watch(currentTrackLyricsProvider);

    return lyrics.when(
      loading: () => const LoadingIndicator(label: 'Loading lyrics'),
      // Never surface raw error text (it can carry transport detail); show one
      // calm, friendly line instead.
      error: (_, __) => const _LyricsPlaceholder(
        title: "Couldn't load lyrics",
        message: 'Check your connection and try again.',
      ),
      data: (Lyrics? value) {
        if (value == null || value.isEmpty) {
          return const _LyricsPlaceholder(
            title: 'No lyrics available yet.',
            message: "They'll appear here when your server has them.",
          );
        }
        return value.isSynced
            ? SyncedLyricsViewport(lyrics: value)
            : PlainLyricsViewport(lyrics: value);
      },
    );
  }
}

/// The "nothing to show" states, centred in the lyrics panel.
///
/// Scrollable rather than fixed: the panel is a fraction of Now Playing rather
/// than a full sheet, and at a large text scale — or on a short screen — the
/// placeholder can be taller than the space it is given. Letting it scroll keeps
/// it fully readable instead of clipping the message off the bottom, while the
/// minimum height keeps it optically centred whenever it does fit.
class _LyricsPlaceholder extends StatelessWidget {
  const _LyricsPlaceholder({required this.title, required this.message});

  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        // Room left once the scroll view's own padding is taken out. Floored at
        // zero: a stage squeezed below that padding — a short landscape window,
        // or Now Playing's fixed controls eating the height at a large text
        // scale — would otherwise ask for a negative minimum, which is not a
        // valid BoxConstraints and throws during layout.
        final double available = constraints.maxHeight.isFinite
            ? constraints.maxHeight - AppSpacing.md
            : 0;
        return SingleChildScrollView(
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minHeight: available > 0 ? available : 0,
            ),
            child: EmptyState(
              icon: Icons.lyrics_outlined,
              title: title,
              message: message,
            ),
          ),
        );
      },
    );
  }
}
