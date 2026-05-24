import 'package:flutter/material.dart';

import '../../../app/dimens.dart';
import '../../../core/models/playback_source.dart';

/// Title / artist / album block for the now-playing screen.
///
/// Only renders the lines it actually has, so a track with no artist or album
/// stays clean rather than showing blank rows. Text is centered and clipped to
/// keep the layout stable under long titles.
class TrackMetadata extends StatelessWidget {
  const TrackMetadata({
    required this.title,
    this.artistName,
    this.albumName,
    super.key,
  });

  final String title;
  final String? artistName;
  final String? albumName;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurface.withValues(alpha: 0.72);
    final fainter = theme.colorScheme.onSurface.withValues(alpha: 0.55);
    final hasArtist = artistName != null && artistName!.isNotEmpty;
    final hasAlbum = albumName != null && albumName!.isNotEmpty;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          title,
          style: theme.textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.w700,
          ),
          textAlign: TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        if (hasArtist) ...[
          const SizedBox(height: AppSpacing.sm),
          Text(
            artistName!,
            style: theme.textTheme.titleMedium?.copyWith(color: muted),
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
        if (hasAlbum) ...[
          const SizedBox(height: AppSpacing.xs),
          Text(
            albumName!,
            style: theme.textTheme.bodyMedium?.copyWith(color: fainter),
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ],
    );
  }
}

/// A small badge that states where the audio is coming from: LOCAL FILE,
/// STREAMING DIRECT, or OFFLINE CACHE. Its text comes from
/// [PlaybackSource.label] so the wording stays in one place.
class PlaybackSourceChip extends StatelessWidget {
  const PlaybackSourceChip({required this.source, super.key});

  final PlaybackSource source;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.xs + 2,
      ),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(AppRadii.pill),
        border: Border.all(
          color: theme.colorScheme.onSurface.withValues(alpha: 0.12),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            _iconFor(source),
            size: 14,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(width: AppSpacing.xs + 2),
          Text(
            source.label,
            style: theme.textTheme.labelSmall?.copyWith(
              letterSpacing: 0.8,
              fontWeight: FontWeight.w700,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.8),
            ),
          ),
        ],
      ),
    );
  }

  static IconData _iconFor(PlaybackSource source) {
    switch (source) {
      case PlaybackSource.localFile:
        return Icons.smartphone_outlined;
      case PlaybackSource.streamingDirect:
        return Icons.cloud_outlined;
      case PlaybackSource.offlineCache:
        return Icons.offline_pin_outlined;
    }
  }
}
