import 'package:flutter/material.dart';

import '../../../app/dimens.dart';
import '../../../core/models/album.dart';
import '../../../shared/focus/list_keyboard_navigation.dart';
import 'album_grid_card.dart';

/// Narrowest a desktop album card should get before the grid drops a column.
///
/// Phones deliberately keep two columns even when that means smaller cards;
/// this lower bound governs when wider layouts are allowed to add columns.
const double _minCardWidth = 200;

/// Widest a card may get before the grid adds a column instead.
///
/// This is what keeps a desktop window from reading as a stretched phone: past
/// this width the extra space buys another album, not a bigger cover.
const double _maxCardWidth = 260;

const int _minColumns = 2;
const double _gridGutter = AppSpacing.md;

/// Columns for [width] logical pixels of content width after the grid's outer
/// padding. The width still includes the gutters between cards.
///
/// A candidate column only counts as fitting once both its minimum card width
/// and the gutters before it fit. Conversely, columns keep being added whenever
/// the resulting cards would exceed [_maxCardWidth]. There is no arbitrary
/// desktop cap: a 4K window simply gets as many columns as its available width
/// calls for.
int albumGridColumnCount(double width) {
  if (!width.isFinite || width <= 0) return _minColumns;

  // For n columns, cardWidth = (width - gutter * (n - 1)) / n.
  // Rearranging that expression gives the two bounds below while accounting
  // for every inter-card gutter.
  final int fits =
      ((width + _gridGutter) / (_minCardWidth + _gridGutter)).floor();
  final int dense =
      ((width + _gridGutter) / (_maxCardWidth + _gridGutter)).ceil();
  final int columns = dense < fits ? dense : fits;
  return columns < _minColumns ? _minColumns : columns;
}

/// The Albums tab body: a responsive grid of [AlbumGridCard]s.
///
/// Every cell is sized as a square cover plus the room its two labels need at
/// the current text scale ([AlbumGridCard.labelExtent]), so cards stay aligned
/// and the artwork stays square whatever the column count.
class AlbumGrid extends StatelessWidget {
  const AlbumGrid({required this.albums, required this.onOpen, super.key});

  final List<Album> albums;
  final void Function(Album album) onOpen;

  @override
  Widget build(BuildContext context) {
    final double labelExtent = AlbumGridCard.labelExtent(context);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double content = constraints.maxWidth - _gridGutter * 2;
        final int columns = albumGridColumnCount(content);
        final double cardWidth =
            (content - _gridGutter * (columns - 1)) / columns;
        // A grid of covers is walked the way a desktop icon grid is: the arrow
        // keys move cell to cell and carry on into the next row at a row's
        // end, and Home/End go to the ends of the collection (#390).
        return ListKeyboardNavigation(
          wrapRows: true,
          child: GridView.builder(
            key: const Key('library_album_grid'),
            padding: const EdgeInsets.all(_gridGutter),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: columns,
              crossAxisSpacing: _gridGutter,
              mainAxisSpacing: AppSpacing.lg,
              mainAxisExtent: cardWidth + labelExtent,
            ),
            itemCount: albums.length,
            itemBuilder: (BuildContext context, int index) {
              final Album album = albums[index];
              return AlbumGridCard(
                album: album,
                onTap: () => onOpen(album),
              );
            },
          ),
        );
      },
    );
  }
}
