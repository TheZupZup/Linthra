import 'package:flutter/material.dart';

import '../../../app/dimens.dart';
import '../album_sort.dart';
import '../song_sort.dart';

/// What each order is called, on the button and in its menu.
String songSortLabel(SongSort sort) => switch (sort) {
      SongSort.titleAscending => 'Title (A to Z)',
      SongSort.titleDescending => 'Title (Z to A)',
      SongSort.artistAscending => 'Artist (A to Z)',
      SongSort.artistDescending => 'Artist (Z to A)',
      SongSort.albumAscending => 'Album (A to Z)',
      SongSort.albumDescending => 'Album (Z to A)',
      SongSort.newestAdded => 'Date added (newest first)',
      SongSort.oldestAdded => 'Date added (oldest first)',
    };

String albumSortLabel(AlbumSort sort) => switch (sort) {
      AlbumSort.titleAscending => 'Title (A to Z)',
      AlbumSort.titleDescending => 'Title (Z to A)',
      AlbumSort.artistAscending => 'Artist (A to Z)',
      AlbumSort.artistDescending => 'Artist (Z to A)',
      AlbumSort.newestAdded => 'Date added (newest first)',
      AlbumSort.oldestAdded => 'Date added (oldest first)',
    };

/// The Songs list's sort control. See [LibrarySortButton].
class SongSortButton extends StatelessWidget {
  const SongSortButton({
    required this.sort,
    required this.onSelected,
    super.key,
  });

  final SongSort sort;
  final ValueChanged<SongSort> onSelected;

  @override
  Widget build(BuildContext context) => LibrarySortButton<SongSort>(
        buttonKey: const Key('library_song_sort'),
        tooltip: 'Sort songs',
        sort: sort,
        options: SongSort.values,
        label: songSortLabel,
        groupOf: (SongSort option) => option.field,
        onSelected: onSelected,
      );
}

/// The Albums grid's sort control. See [LibrarySortButton].
class AlbumSortButton extends StatelessWidget {
  const AlbumSortButton({
    required this.sort,
    required this.onSelected,
    super.key,
  });

  final AlbumSort sort;
  final ValueChanged<AlbumSort> onSelected;

  @override
  Widget build(BuildContext context) => LibrarySortButton<AlbumSort>(
        buttonKey: const Key('library_album_sort'),
        tooltip: 'Sort albums',
        sort: sort,
        options: AlbumSort.values,
        label: albumSortLabel,
        groupOf: (AlbumSort option) => option.field,
        onSelected: onSelected,
      );
}

/// A Library list's sort control: the current order on a compact button that
/// opens every order the list offers, the current one checked.
///
/// A labelled button rather than a bare icon, so the order the list is in can
/// be read without opening anything. The same menu serves touch, mouse and
/// keyboard.
class LibrarySortButton<T> extends StatelessWidget {
  const LibrarySortButton({
    required this.buttonKey,
    required this.tooltip,
    required this.sort,
    required this.options,
    required this.label,
    required this.groupOf,
    required this.onSelected,
    super.key,
  });

  final Key buttonKey;
  final String tooltip;
  final T sort;
  final List<T> options;
  final String Function(T) label;

  /// What an order sorts on: a divider separates each group in the menu.
  final Object Function(T) groupOf;
  final ValueChanged<T> onSelected;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return PopupMenuButton<T>(
      key: buttonKey,
      tooltip: tooltip,
      initialValue: sort,
      onSelected: onSelected,
      itemBuilder: (BuildContext context) => _menuItems(),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.sm,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.sort, size: 18, color: theme.colorScheme.primary),
            const SizedBox(width: AppSpacing.sm),
            Flexible(
              child: Text(
                label(sort),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelLarge,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Every order, grouped by what it sorts on.
  List<PopupMenuEntry<T>> _menuItems() {
    final List<PopupMenuEntry<T>> items = <PopupMenuEntry<T>>[];
    Object? group;
    for (final T option in options) {
      final Object field = groupOf(option);
      if (group != null && field != group) {
        items.add(const PopupMenuDivider());
      }
      group = field;
      items.add(
        CheckedPopupMenuItem<T>(
          value: option,
          checked: option == sort,
          child: Text(label(option)),
        ),
      );
    }
    return items;
  }
}
