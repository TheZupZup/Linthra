import 'package:flutter/material.dart';

import '../../../app/dimens.dart';
import '../../../core/models/artist.dart';
import 'artist_tile.dart';

/// Narrowest an artist row may get before the grid drops a column. Below this
/// the name and the "3 albums • 41 songs" line start to clip on real libraries.
const double _minRowWidth = 340;

/// Widest a row may get before the grid adds a column instead — the same idea
/// as the album grid's card cap. A single 2400 px row would put the avatar and
/// the chevron a screen apart.
const double _maxRowWidth = 520;

const int _minColumns = 1;
const double _gridPadding = AppSpacing.sm;
const double _gridGutter = AppSpacing.sm;

/// Columns for [width] logical pixels of available viewport width.
///
/// One on a phone, and a new column only once the grid's own horizontal padding
/// plus every inter-column gutter leaves at least [_minRowWidth] for each row.
/// Columns continue to grow with the viewport instead of stopping at an
/// arbitrary desktop cap, so common 4K windows keep rows under
/// [_maxRowWidth].
int artistGridColumnCount(double width) {
  if (!width.isFinite || width <= 0) return _minColumns;

  final double innerWidth = width - _gridPadding * 2;
  if (innerWidth <= 0) return _minColumns;

  final int fits =
      ((innerWidth + _gridGutter) / (_minRowWidth + _gridGutter)).floor();
  final int dense =
      ((innerWidth + _gridGutter) / (_maxRowWidth + _gridGutter)).ceil();
  final int columns = dense < fits ? dense : fits;
  return columns < _minColumns ? _minColumns : columns;
}

/// The Artists tab body: [ArtistTile] rows that flow into columns as the window
/// widens.
///
/// At one column this is the list it replaces, row for row — same tile, same
/// tap and long-press. Wider windows lay the same rows out in two or more
/// columns instead of stretching each one across the monitor, which is what
/// made the Artists tab read as a blown-up phone screen on Linux.
class ArtistGrid extends StatelessWidget {
  const ArtistGrid({required this.artists, required this.onOpen, super.key});

  final List<Artist> artists;
  final void Function(Artist artist) onOpen;

  /// Height of one row. [ArtistTile] is a two-line [ListTile], so 72 is its
  /// natural height — but the grid has to give every cell a fixed extent, so
  /// scaled-up text gets the room it needs rather than overflowing the cell.
  static double rowExtent(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final TextScaler scaler = MediaQuery.textScalerOf(context);
    final double title =
        scaler.scale(theme.textTheme.titleMedium?.fontSize ?? 16) * _lineHeight;
    final double subtitle =
        scaler.scale(theme.textTheme.bodyMedium?.fontSize ?? 14) * _lineHeight;
    final double text = title + subtitle + AppSpacing.md;
    // The floor follows the theme's density (#384) so a compact desktop row
    // actually gets shorter instead of sitting in a cell sized for a touch one.
    // The text-driven part above is untouched: density buys padding back, never
    // room the words need.
    final double floor = _defaultRowExtent +
        theme.visualDensity.baseSizeAdjustment.dy.clamp(-8.0, 0.0);
    return text > floor ? text : floor;
  }

  static const double _lineHeight = 1.35;
  static const double _defaultRowExtent = 72;

  @override
  Widget build(BuildContext context) {
    final double extent = rowExtent(context);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final int columns = artistGridColumnCount(constraints.maxWidth);
        final bool single = columns == 1;
        return GridView.builder(
          key: const Key('library_artist_list'),
          // A single column keeps the edge-to-edge list look phones already
          // have; only the multi-column desktop layout needs gutters.
          padding: single
              ? EdgeInsets.zero
              : const EdgeInsets.symmetric(
                  horizontal: _gridPadding,
                  vertical: _gridPadding,
                ),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            crossAxisSpacing: single ? 0 : _gridGutter,
            mainAxisSpacing: 0,
            mainAxisExtent: extent,
          ),
          itemCount: artists.length,
          itemBuilder: (BuildContext context, int index) {
            final Artist artist = artists[index];
            return ArtistTile(
              artist: artist,
              onTap: () => onOpen(artist),
            );
          },
        );
      },
    );
  }
}
