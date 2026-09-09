import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/dimens.dart';
import '../../../core/catalog/library_grouping.dart';
import '../../../core/models/album.dart';
import '../../../core/models/track.dart';
import '../../../shared/widgets/context_menu_region.dart';
import '../../../shared/widgets/hover_highlight.dart';
import '../../player/widgets/album_artwork.dart';
import '../../playlists/widgets/add_to_playlist_sheet.dart';
import '../unified_library_providers.dart';
import 'collection_menu.dart';

/// One card in the Albums grid: square cover, title, artist.
///
/// Same gestures as the list row it replaces — a tap opens the album, a
/// long-press sends every album track through the shared bulk playlist flow —
/// so muscle memory and the existing safeguards both carry over.
///
/// The card expects a bounded height (the grid gives every cell a fixed
/// [AlbumGridCard.labelExtent] above the square artwork). The artwork is
/// [Flexible], so it shrinks rather than overflowing if a cell ever ends up
/// shorter than the text needs.
class AlbumGridCard extends ConsumerWidget {
  const AlbumGridCard({required this.album, this.onTap, super.key});

  final Album album;
  final VoidCallback? onTap;

  /// Line-height multiplier applied to both labels. Pinned here (rather than
  /// left to the theme's per-style default) so [labelExtent] can reserve the
  /// exact space the text will occupy at any text scale.
  static const double _lineHeight = 1.3;
  static const double _titleFallbackSize = 14;
  static const double _artistFallbackSize = 12;

  /// Height the two text lines need below the artwork: title (up to two lines)
  /// plus artist (one line), including the gaps around them.
  ///
  /// The grid adds this to the square artwork's side to size each cell, so the
  /// labels keep their room when the user scales text up.
  static double labelExtent(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final TextScaler scaler = MediaQuery.textScalerOf(context);
    final double title = _scaledLine(
      scaler,
      theme.textTheme.titleSmall?.fontSize ?? _titleFallbackSize,
    );
    final double artist = _scaledLine(
      scaler,
      theme.textTheme.bodySmall?.fontSize ?? _artistFallbackSize,
    );
    return AppSpacing.sm + title * 2 + AppSpacing.xs + artist;
  }

  static double _scaledLine(TextScaler scaler, double fontSize) =>
      scaler.scale(fontSize) * _lineHeight;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);
    // One semantics node per card, so a screen reader announces
    // "<title>, <artist>" as a single tappable target instead of two labels.
    return MergeSemantics(
      child: ContextMenuRegion<CollectionAction>(
        itemBuilder: (BuildContext context) => collectionMenuItems(),
        onSelected: (CollectionAction action) => runCollectionAction(
          context,
          ref,
          action,
          _tracks(ref),
        ),
        child: InkWell(
          borderRadius: const BorderRadius.all(Radius.circular(AppRadii.md)),
          onTap: onTap,
          onLongPress: () => _addAllToPlaylist(context, ref),
          // The InkWell's own hover overlay is painted on the Material behind the
          // card, so the cover hides it and a mouse user gets feedback on the
          // labels and none on the artwork they are pointing at. The veil is that
          // same hover colour, drawn where it can be seen.
          child: HoverHighlight(
            builder: (BuildContext context, bool hovered) => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Flexible(
                  child: AspectRatio(
                    aspectRatio: 1,
                    child: HoverArtworkVeil(
                      hovered: hovered,
                      borderRadius: BorderRadius.circular(AppRadii.md),
                      child: AlbumArtwork(artworkUri: album.artworkUri),
                    ),
                  ),
                ),
                const SizedBox(height: AppSpacing.sm),
                Text(
                  album.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    height: _lineHeight,
                  ),
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  album.artistName?.isNotEmpty == true
                      ? album.artistName!
                      : kUnknownArtist,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    height: _lineHeight,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<Track> _tracks(WidgetRef ref) =>
      tracksForAlbum(ref.read(libraryUnifiedTracksProvider), album.id);

  void _addAllToPlaylist(BuildContext context, WidgetRef ref) {
    final List<Track> tracks = _tracks(ref);
    if (tracks.isNotEmpty) {
      showAddToPlaylistSheet(context, tracks);
    }
  }
}
