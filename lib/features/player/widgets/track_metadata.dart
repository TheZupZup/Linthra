import 'package:flutter/material.dart';

import '../../../app/dimens.dart';
import '../../../core/models/playback_source.dart';
import '../../../core/services/playback_source_label.dart';

/// Title / artist / album block for the now-playing screen.
///
/// Left-aligned beneath the artwork, with a deliberate three-step hierarchy: the
/// title carries full weight, the artist is a clear secondary line, and the
/// album recedes to a quiet tag. Only renders the lines it actually has, so a
/// track with no artist or album stays clean, and clips long values so the
/// layout stays stable.
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
    final fainter = theme.colorScheme.onSurface.withValues(alpha: 0.5);
    final hasArtist = artistName != null && artistName!.isNotEmpty;
    final hasAlbum = albumName != null && albumName!.isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          title,
          style: theme.textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.w700,
            letterSpacing: -0.3,
            height: 1.15,
          ),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        if (hasArtist) ...[
          const SizedBox(height: AppSpacing.sm),
          Text(
            artistName!,
            style: theme.textTheme.titleMedium?.copyWith(
              color: muted,
              fontWeight: FontWeight.w500,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
        if (hasAlbum) ...[
          const SizedBox(height: AppSpacing.xs),
          Text(
            albumName!,
            style: theme.textTheme.bodySmall?.copyWith(
              color: fainter,
              letterSpacing: 0.1,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ],
    );
  }
}

/// A quiet inline label stating where the audio is *actually* coming from, e.g.
/// "Playing from Navidrome", "Playing from Jellyfin", "Playing from Local music",
/// or "Playing from Cache".
///
/// Rendered as a calm icon-and-caption pair (no boxed chip) so it reads as a
/// whisper under the metadata rather than a competing badge, matching the
/// buffering/casting indicators on the same line.
///
/// Because a logical track can have several source candidates, the indicator
/// reflects the resolved copy — the owning provider derived from [trackUri] plus
/// the [source] the resolver reported — not the active/default provider. Only
/// safe display names are shown (see [PlaybackSourceLabel]); no server URL,
/// username, token, or path is ever exposed.
class PlaybackSourceChip extends StatelessWidget {
  const PlaybackSourceChip({
    required this.source,
    required this.trackUri,
    super.key,
  });

  final PlaybackSource source;

  /// The resolved track's opaque URI, used only to name the owning server
  /// safely (`jellyfin:` → Jellyfin, `subsonic:` → Navidrome).
  final String? trackUri;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.onSurfaceVariant;
    return Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(_iconFor(source), size: 15, color: color),
        const SizedBox(width: AppSpacing.xs + 2),
        Flexible(
          child: Text(
            PlaybackSourceLabel.phrase(trackUri: trackUri, source: source),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelMedium?.copyWith(
              fontWeight: FontWeight.w600,
              letterSpacing: 0.2,
              color: color,
            ),
          ),
        ),
      ],
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
