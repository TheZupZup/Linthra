import 'package:flutter/material.dart';

import '../../../app/dimens.dart';
import '../../../core/models/playback_source.dart';
import '../../../core/services/playback_source_label.dart';
import '../../../shared/layout/desktop_presentation.dart';

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
    final ThemeData theme = Theme.of(context);
    final TextScaler scaler = MediaQuery.textScalerOf(context);
    final bool shortLargeText =
        MediaQuery.sizeOf(context).height <= 640 && scaler.scale(1) >= 1.5;
    final Color muted = theme.colorScheme.onSurface.withValues(alpha: 0.75);
    final Color fainter = theme.colorScheme.onSurface.withValues(alpha: 0.5);
    final bool hasArtist = artistName != null && artistName!.isNotEmpty;
    final bool hasAlbum = albumName != null && albumName!.isNotEmpty;

    // A short desktop window with accessibility text scaling has horizontal
    // room but very little vertical room. Keeping the normal two-line title +
    // artist + album can consume the space the flexible lyrics pane needs.
    // Collapse only in that constrained case: title and artist remain visible,
    // the album is the least important line and yields its height.
    if (shortLargeText) {
      return Column(
        key: const Key('track_metadata_compact_height'),
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            title,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          if (hasArtist) ...<Widget>[
            const SizedBox(height: AppSpacing.xs),
            Text(
              artistName!,
              style: theme.textTheme.bodyMedium?.copyWith(color: muted),
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      );
    }

    // A deliberate three-step hierarchy: the title carries full weight, the
    // artist is a clear secondary line, and the album recedes to a quiet tag.
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          title,
          style: theme.textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.w700,
            letterSpacing: -0.2,
            height: 1.15,
          ),
          textAlign: TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        if (hasArtist) ...<Widget>[
          const SizedBox(height: AppSpacing.sm),
          Text(
            artistName!,
            style: theme.textTheme.titleMedium?.copyWith(
              color: muted,
              fontWeight: FontWeight.w500,
            ),
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
        if (hasAlbum) ...<Widget>[
          const SizedBox(height: AppSpacing.xs),
          Text(
            albumName!,
            style: theme.textTheme.bodySmall?.copyWith(
              color: fainter,
              letterSpacing: 0.1,
            ),
            textAlign: TextAlign.center,
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
class PlaybackSourceChip extends StatelessWidget {
  const PlaybackSourceChip({
    required this.source,
    required this.trackUri,
    super.key,
  });

  final PlaybackSource source;
  final String? trackUri;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color color = theme.colorScheme.onSurfaceVariant;
    return Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        Icon(
          _iconFor(source, desktop: usesDesktopPresentation(context)),
          size: 15,
          color: color,
        ),
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

  static IconData _iconFor(PlaybackSource source, {required bool desktop}) {
    switch (source) {
      case PlaybackSource.localFile:
        // Music on this device: a phone, or on a desktop the computer.
        return desktop ? Icons.computer_outlined : Icons.smartphone_outlined;
      case PlaybackSource.streamingDirect:
        return Icons.cloud_outlined;
      case PlaybackSource.offlineCache:
        return Icons.offline_pin_outlined;
    }
  }
}
