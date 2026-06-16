import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/dimens.dart';
import '../../core/models/lyrics.dart';
import '../../core/models/playback_state.dart';
import '../../core/models/track.dart';
import '../../core/services/playback_controller.dart';
import 'lyrics_providers.dart';
import 'player_accent_provider.dart';
import 'player_providers.dart';
import 'player_theme.dart';
import 'widgets/lyrics_view.dart';
import 'widgets/waveform_seek_bar.dart';

/// The full, dedicated lyrics page (pushed above the now-playing screen).
///
/// It follows the *currently playing* track, offers a Synced / Static segmented
/// switch (Synced is the default and primary mode when the track has timing),
/// and keeps a small playback strip pinned at the bottom so the user can seek
/// and play/pause without leaving the lyrics. Wrapped in the same soft-light
/// [PlayerTheme] as the player, with an album-derived accent for highlights.
/// Opening it only reads playback state — it never starts or restarts playback.
class LyricsScreen extends ConsumerStatefulWidget {
  const LyricsScreen({super.key});

  @override
  ConsumerState<LyricsScreen> createState() => _LyricsScreenState();
}

class _LyricsScreenState extends ConsumerState<LyricsScreen> {
  /// The user's explicit choice, or null to follow the default for the track
  /// (Synced when timed, else Static). Reset whenever the track's lyrics change.
  LyricsViewMode? _mode;

  @override
  Widget build(BuildContext context) {
    // Reset the manual mode when the song (its lyrics) changes, so each track
    // opens in its own sensible default rather than a stale choice.
    ref.listen<AsyncValue<Lyrics?>>(currentTrackLyricsProvider, (prev, next) {
      if (prev?.valueOrNull != next.valueOrNull && _mode != null) {
        setState(() => _mode = null);
      }
    });

    final Track? track = ref.watch(playbackStateProvider.select(
          (s) => s.valueOrNull?.currentTrack,
        )) ??
        ref.read(playbackControllerProvider).state.currentTrack;
    final Color accent = ref
        .watch(playerAccentProvider(track?.artworkUri))
        .maybeWhen(data: (c) => c, orElse: () => PlayerPalette.fallbackAccent);

    final AsyncValue<Lyrics?> lyricsAsync =
        ref.watch(currentTrackLyricsProvider);
    final Lyrics? lyrics = lyricsAsync.valueOrNull;
    final bool hasLyrics = lyrics != null && lyrics.isNotEmpty;
    final bool isSynced = lyrics?.isSynced ?? false;
    final LyricsViewMode mode =
        _mode ?? (isSynced ? LyricsViewMode.synced : LyricsViewMode.static);

    return Theme(
      data: PlayerTheme.of(accent),
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle.dark.copyWith(
          statusBarColor: Colors.transparent,
          systemNavigationBarColor: PlayerPalette.background,
          systemNavigationBarIconBrightness: Brightness.dark,
        ),
        child: Scaffold(
          body: SafeArea(
            child: Column(
              children: [
                const _LyricsHeader(),
                if (hasLyrics) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                      AppSpacing.lg,
                      AppSpacing.xs,
                      AppSpacing.lg,
                      AppSpacing.sm,
                    ),
                    child: _LyricsModeToggle(
                      synced: mode == LyricsViewMode.synced,
                      syncedEnabled: isSynced,
                      onChanged: (wantSynced) => setState(
                        () => _mode = wantSynced
                            ? LyricsViewMode.synced
                            : LyricsViewMode.static,
                      ),
                    ),
                  ),
                ],
                Expanded(
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
                    child: LyricsView(mode: mode),
                  ),
                ),
                const _LyricsStrip(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Minimal top bar: back · centred "Lyrics".
class _LyricsHeader extends StatelessWidget {
  const _LyricsHeader();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.xs,
        vertical: AppSpacing.xs,
      ),
      child: Row(
        children: [
          IconButton(
            onPressed: () => Navigator.of(context).maybePop(),
            icon: const Icon(Icons.arrow_back),
            tooltip: 'Back',
          ),
          Expanded(
            child: Text(
              'Lyrics',
              textAlign: TextAlign.center,
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          // Balance the leading button so the title stays centred.
          const SizedBox(width: 48),
        ],
      ),
    );
  }
}

/// A two-segment pill switching between Synced and Static lyrics. The Synced
/// segment dims and becomes inert when the track has no timing.
class _LyricsModeToggle extends StatelessWidget {
  const _LyricsModeToggle({
    required this.synced,
    required this.syncedEnabled,
    required this.onChanged,
  });

  final bool synced;
  final bool syncedEnabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(AppSpacing.xs),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(AppRadii.pill),
      ),
      child: Row(
        children: [
          _Segment(
            label: 'Synced',
            selected: synced,
            enabled: syncedEnabled,
            onTap: syncedEnabled ? () => onChanged(true) : null,
          ),
          _Segment(
            label: 'Static',
            selected: !synced,
            enabled: true,
            onTap: () => onChanged(false),
          ),
        ],
      ),
    );
  }
}

class _Segment extends StatelessWidget {
  const _Segment({
    required this.label,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final bool enabled;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final Color fg = selected
        ? theme.colorScheme.onSecondary
        : theme.colorScheme.onSurface.withValues(alpha: enabled ? 0.7 : 0.32);
    return Expanded(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm + 2),
          decoration: BoxDecoration(
            color: selected ? theme.colorScheme.secondary : Colors.transparent,
            borderRadius: BorderRadius.circular(AppRadii.pill),
          ),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: theme.textTheme.labelLarge?.copyWith(
              color: fg,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.2,
            ),
          ),
        ),
      ),
    );
  }
}

/// A compact pinned strip: play/pause and a waveform seek, so playback stays
/// controllable while reading without crowding the lyrics.
class _LyricsStrip extends ConsumerWidget {
  const _LyricsStrip();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.watch(playbackControllerProvider);
    final state =
        ref.watch(playbackStateProvider).valueOrNull ?? controller.state;

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.xs,
        AppSpacing.lg,
        AppSpacing.md,
      ),
      child: Row(
        children: [
          _StripPlayButton(state: state, controller: controller),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: WaveformSeekBar(
              position: state.position,
              duration: state.duration,
              compact: true,
              onSeek: (pos) => controller.seek(pos),
            ),
          ),
        ],
      ),
    );
  }
}

class _StripPlayButton extends StatelessWidget {
  const _StripPlayButton({required this.state, required this.controller});

  final PlaybackState state;
  final PlaybackController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (state.isBusy) {
      return SizedBox.square(
        dimension: 48,
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: theme.colorScheme.secondary,
          ),
        ),
      );
    }
    final bool playing = state.isPlaying;
    return IconButton.filled(
      onPressed: playing ? controller.pause : controller.play,
      icon: Icon(playing ? Icons.pause : Icons.play_arrow),
      tooltip: playing ? 'Pause' : 'Play',
      style: IconButton.styleFrom(
        backgroundColor: theme.colorScheme.secondary,
        foregroundColor: theme.colorScheme.onSecondary,
        fixedSize: const Size(48, 48),
      ),
    );
  }
}
