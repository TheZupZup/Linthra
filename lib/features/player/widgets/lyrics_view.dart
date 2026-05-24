import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/dimens.dart';
import '../../../core/models/lyrics.dart';
import '../../../shared/widgets/empty_state.dart';
import '../lyrics_providers.dart';
import '../player_providers.dart';

/// The lyrics experience shown from Now Playing.
///
/// It follows the *currently playing* track (via [currentTrackLyricsProvider]),
/// so skipping reloads the lines in place and the previous song's text never
/// lingers. Three shapes:
///  - no lyrics → a calm "No lyrics available yet." placeholder;
///  - plain lyrics (no timestamps) → a static, readable list, no highlighting;
///  - timed lyrics → a smooth synced view that highlights the current line and
///    auto-scrolls as playback moves.
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
      loading: () => const Padding(
        padding: EdgeInsets.symmetric(vertical: AppSpacing.xl),
        child: Center(child: CircularProgressIndicator()),
      ),
      // Never surface raw error text (it can carry transport detail); show one
      // calm, friendly line instead.
      error: (_, __) => const Padding(
        padding: EdgeInsets.symmetric(vertical: AppSpacing.lg),
        child: EmptyState(
          icon: Icons.lyrics_outlined,
          title: "Couldn't load lyrics",
          message: 'Check your connection and try again.',
        ),
      ),
      data: (value) {
        if (value == null || value.isEmpty) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: AppSpacing.lg),
            child: EmptyState(
              icon: Icons.lyrics_outlined,
              title: 'No lyrics available yet.',
              message: "They'll appear here when your server has them.",
            ),
          );
        }
        return value.isSynced
            ? _SyncedLyrics(lyrics: value)
            : _PlainLyrics(lyrics: value);
      },
    );
  }
}

/// Static lyrics with no timing: a plain, readable, scrollable list.
class _PlainLyrics extends StatelessWidget {
  const _PlainLyrics({required this.lyrics});

  final Lyrics lyrics;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return ListView.builder(
      key: const Key('plain-lyrics'),
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
      itemCount: lyrics.lines.length,
      itemBuilder: (context, index) {
        final String text = lyrics.lines[index].text;
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
          // A blank line keeps its vertical rhythm rather than collapsing.
          child: Text(
            text.isEmpty ? ' ' : text,
            style: theme.textTheme.bodyLarge,
          ),
        );
      },
    );
  }
}

/// Timed lyrics: highlights the line active at the current playback position and
/// auto-scrolls to keep it centred, with neighbouring lines softly dimmed.
class _SyncedLyrics extends ConsumerStatefulWidget {
  const _SyncedLyrics({required this.lyrics});

  final Lyrics lyrics;

  @override
  ConsumerState<_SyncedLyrics> createState() => _SyncedLyricsState();
}

class _SyncedLyricsState extends ConsumerState<_SyncedLyrics> {
  final ScrollController _scroll = ScrollController();
  List<GlobalKey> _keys = const <GlobalKey>[];
  int _activeIndex = -1;

  @override
  void initState() {
    super.initState();
    _rebuildKeys();
  }

  @override
  void didUpdateWidget(_SyncedLyrics oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A new track's lyrics: reset keys and the highlight so nothing stale shows.
    if (widget.lyrics != oldWidget.lyrics) {
      _rebuildKeys();
      _activeIndex = -1;
    }
  }

  void _rebuildKeys() {
    _keys = List<GlobalKey>.generate(
      widget.lyrics.lines.length,
      (_) => GlobalKey(),
    );
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// The unified playback position, falling back to the controller's latest
  /// state until the first stream event arrives. Reads only — never triggers
  /// playback.
  Duration _position() {
    final Duration? streamed = ref.watch(
      playbackStateProvider.select((s) => s.valueOrNull?.position),
    );
    return streamed ?? ref.read(playbackControllerProvider).state.position;
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final int active = widget.lyrics.activeLineIndex(_position());

    if (active != _activeIndex) {
      _activeIndex = active;
      _scheduleScrollTo(active);
    }

    return ListView.builder(
      key: const Key('synced-lyrics'),
      controller: _scroll,
      // Generous vertical padding so the first and last lines can sit centred.
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xl),
      itemCount: widget.lyrics.lines.length,
      itemBuilder: (context, index) {
        final LyricLine line = widget.lyrics.lines[index];
        final bool isActive = index == active;
        final Color color = isActive
            ? theme.colorScheme.secondary
            : theme.colorScheme.onSurface.withValues(alpha: 0.4);
        return Padding(
          key: _keys[index],
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            // Tap a timed line to jump there — routed through the controller, so
            // it seeks whichever output is active (local or cast).
            onTap: line.start == null
                ? null
                : () => ref.read(playbackControllerProvider).seek(line.start!),
            child: AnimatedDefaultTextStyle(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOut,
              style:
                  (theme.textTheme.titleMedium ?? const TextStyle()).copyWith(
                color: color,
                fontWeight: isActive ? FontWeight.w700 : FontWeight.w500,
                height: 1.35,
              ),
              child: Text(line.text.isEmpty ? ' ' : line.text),
            ),
          ),
        );
      },
    );
  }

  /// Smoothly centres the active line. Guarded so it only runs once per change
  /// and only while the line is laid out.
  void _scheduleScrollTo(int index) {
    if (index < 0 || index >= _keys.length) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final BuildContext? ctx = _keys[index].currentContext;
      if (ctx == null) return;
      Scrollable.ensureVisible(
        ctx,
        alignment: 0.5,
        duration: const Duration(milliseconds: 360),
        curve: Curves.easeInOut,
      );
    });
  }
}
