import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/dimens.dart';
import '../../../core/models/lyrics.dart';
import '../../../shared/widgets/empty_state.dart';
import '../lyrics_providers.dart';
import '../player_providers.dart';

/// Which rendering the lyrics body should use.
enum LyricsViewMode {
  /// Pick automatically: timed view when the track has timestamps, else plain.
  auto,

  /// The timed, auto-scrolling, highlighted view (falls back to plain when the
  /// track has no timestamps).
  synced,

  /// A plain, static, scrollable list of every line — no highlighting.
  static,
}

/// The lyrics body shown on the dedicated lyrics page.
///
/// It follows the *currently playing* track (via [currentTrackLyricsProvider]),
/// so skipping reloads the lines in place and the previous song's text never
/// lingers. Four shapes:
///  - loading / error → calm placeholders;
///  - no lyrics → an honest "No lyrics available yet." state;
///  - plain or [LyricsViewMode.static] → a static, readable list;
///  - timed + [LyricsViewMode.synced]/[LyricsViewMode.auto] → a smooth synced
///    view that highlights the current line and auto-scrolls as playback moves.
///
/// Critically, it only *reads* playback state — opening it never starts or
/// restarts playback. Because it follows the unified [playbackStateProvider]
/// position, it tracks whichever output is active: the local engine, or a cast
/// receiver when casting.
class LyricsView extends ConsumerWidget {
  const LyricsView({this.mode = LyricsViewMode.auto, super.key});

  final LyricsViewMode mode;

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
        final bool showSynced = value.isSynced && mode != LyricsViewMode.static;
        return showSynced
            ? _SyncedLyrics(lyrics: value)
            : _PlainLyrics(lyrics: value);
      },
    );
  }
}

/// Static lyrics: a plain, readable, scrollable list with generous spacing.
class _PlainLyrics extends StatelessWidget {
  const _PlainLyrics({required this.lyrics});

  final Lyrics lyrics;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final TextStyle? style = theme.textTheme.titleMedium?.copyWith(
      color: theme.colorScheme.onSurface.withValues(alpha: 0.88),
      height: 1.5,
      fontWeight: FontWeight.w500,
    );
    return ListView.builder(
      key: const Key('plain-lyrics'),
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
      itemCount: lyrics.lines.length,
      itemBuilder: (context, index) {
        final String text = lyrics.lines[index].text;
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
          // A blank line keeps its vertical rhythm rather than collapsing.
          child: Text(text.isEmpty ? ' ' : text, style: style),
        );
      },
    );
  }
}

/// Timed lyrics: highlights the line active at the current playback position and
/// auto-scrolls to keep it near centre, with neighbouring lines softly dimmed.
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

  /// The lyric line active at the current playback position.
  ///
  /// Battery: the active-line index is computed *inside* the provider [select],
  /// so this widget rebuilds only when the highlighted line actually changes (a
  /// handful of times per song) — not on every ~4 Hz position tick. Falls back
  /// to the controller's latest position until the first stream event arrives.
  /// Reads only — never triggers playback.
  int _activeLine() {
    final Lyrics lyrics = widget.lyrics;
    final Duration fallback =
        ref.read(playbackControllerProvider).state.position;
    return ref.watch(
      playbackStateProvider.select(
        (s) => lyrics.activeLineIndex(s.valueOrNull?.position ?? fallback),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final int active = _activeLine();

    if (active != _activeIndex) {
      _activeIndex = active;
      _scheduleScrollTo(active);
    }

    final TextStyle base =
        theme.textTheme.titleLarge ?? const TextStyle(fontSize: 22);

    return ListView.builder(
      key: const Key('synced-lyrics'),
      controller: _scroll,
      // Generous vertical padding so the first and last lines can sit centred.
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xxl),
      itemCount: widget.lyrics.lines.length,
      itemBuilder: (context, index) {
        final LyricLine line = widget.lyrics.lines[index];
        final bool isActive = index == active;
        final Color color = isActive
            ? theme.colorScheme.onSurface
            : theme.colorScheme.onSurface.withValues(alpha: 0.32);
        return Padding(
          key: _keys[index],
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm + 2),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            // Tap a timed line to jump there — routed through the controller, so
            // it seeks whichever output is active (local or cast).
            onTap: line.start == null
                ? null
                : () => ref.read(playbackControllerProvider).seek(line.start!),
            child: AnimatedDefaultTextStyle(
              duration: const Duration(milliseconds: 240),
              curve: Curves.easeOut,
              style: base.copyWith(
                color: color,
                fontWeight: isActive ? FontWeight.w700 : FontWeight.w500,
                height: 1.4,
              ),
              child: Text(line.text.isEmpty ? ' ' : line.text),
            ),
          ),
        );
      },
    );
  }

  /// Smoothly centres the active line (a touch above centre so upcoming lines
  /// are visible). Guarded so it only runs once per change and only while the
  /// line is laid out.
  void _scheduleScrollTo(int index) {
    if (index < 0 || index >= _keys.length) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final BuildContext? ctx = _keys[index].currentContext;
      if (ctx == null) return;
      Scrollable.ensureVisible(
        ctx,
        alignment: 0.42,
        duration: const Duration(milliseconds: 380),
        curve: Curves.easeInOut,
      );
    });
  }
}
