import 'package:flutter/material.dart';

import '../../../app/dimens.dart';
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

/// The Songs list's sort control (#893): the current order on a compact
/// button that opens every order the list offers, the current one checked.
///
/// A labelled button rather than a bare icon, so the order the list is in can
/// be read without opening anything. The same menu serves touch, mouse and
/// keyboard.
class SongSortButton extends StatelessWidget {
  const SongSortButton({
    required this.sort,
    required this.onSelected,
    super.key,
  });

  final SongSort sort;
  final ValueChanged<SongSort> onSelected;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return PopupMenuButton<SongSort>(
      key: const Key('library_song_sort'),
      tooltip: 'Sort songs',
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
                songSortLabel(sort),
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
  List<PopupMenuEntry<SongSort>> _menuItems() {
    final List<PopupMenuEntry<SongSort>> items = <PopupMenuEntry<SongSort>>[];
    SongSortField? group;
    for (final SongSort option in SongSort.values) {
      if (group != null && option.field != group) {
        items.add(const PopupMenuDivider());
      }
      group = option.field;
      items.add(
        CheckedPopupMenuItem<SongSort>(
          value: option,
          checked: option == sort,
          child: Text(songSortLabel(option)),
        ),
      );
    }
    return items;
  }
}
