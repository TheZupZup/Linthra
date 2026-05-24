import 'package:flutter/material.dart';

import '../../../app/dimens.dart';
import '../../../core/models/track.dart';
import 'track_tile.dart';

/// A track list with first-letter section grouping and an A–Z fast-scroll
/// index down the trailing edge, so large libraries stay navigable.
///
/// Tracks are sorted by title (case-insensitive) and grouped under a header for
/// each leading letter; titles that don't start with a letter fall under '#'.
/// The vertical index rail mirrors exactly the letters present and jumps the
/// list to a section on tap or drag (a contacts-app style scrubber).
///
/// Both the rows and the index work off the *same* sorted list, so a row's tap
/// queues the rest of the library in the order the user sees — see [TrackTile].
class AlphabetTrackList extends StatefulWidget {
  const AlphabetTrackList({required this.tracks, super.key});

  final List<Track> tracks;

  @override
  State<AlphabetTrackList> createState() => _AlphabetTrackListState();
}

class _AlphabetTrackListState extends State<AlphabetTrackList> {
  /// Fixed extents let the index compute an exact scroll offset for any letter
  /// without measuring laid-out widgets.
  static const double _headerExtent = 36;
  static const double _trackExtent = 64;

  final ScrollController _controller = ScrollController();

  late List<Track> _sorted;
  late List<_Entry> _entries;
  late List<String> _letters;
  late Map<String, double> _letterOffsets;

  @override
  void initState() {
    super.initState();
    _rebuildIndex();
  }

  @override
  void didUpdateWidget(AlphabetTrackList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.tracks, widget.tracks)) {
      _rebuildIndex();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// (Re)derives the sorted list, the flat header/track entry list, and the
  /// per-letter scroll offsets from the current tracks.
  void _rebuildIndex() {
    _sorted = [...widget.tracks]
      ..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));

    _entries = <_Entry>[];
    _letters = <String>[];
    _letterOffsets = <String, double>{};

    double offset = 0;
    String? current;
    for (var i = 0; i < _sorted.length; i++) {
      final letter = _indexKey(_sorted[i].title);
      if (letter != current) {
        current = letter;
        _letters.add(letter);
        _letterOffsets[letter] = offset;
        _entries.add(_Entry.header(letter));
        offset += _headerExtent;
      }
      _entries.add(_Entry.track(i));
      offset += _trackExtent;
    }
  }

  /// The leading index character for [title]: an uppercase letter, or '#' for
  /// anything that doesn't begin with a letter (digits, symbols, empty).
  static String _indexKey(String title) {
    final trimmed = title.trimLeft();
    if (trimmed.isEmpty) return '#';
    final first = trimmed[0].toUpperCase();
    return RegExp('[A-Z]').hasMatch(first) ? first : '#';
  }

  void _jumpToLetter(String letter) {
    final offset = _letterOffsets[letter];
    if (offset == null || !_controller.hasClients) return;
    final max = _controller.position.maxScrollExtent;
    _controller.jumpTo(offset.clamp(0.0, max));
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        ListView.builder(
          key: const Key('library_track_list'),
          controller: _controller,
          padding: const EdgeInsets.only(right: AppSpacing.md),
          itemCount: _entries.length,
          itemExtentBuilder: (index, _) =>
              _entries[index].isHeader ? _headerExtent : _trackExtent,
          itemBuilder: (context, i) {
            final entry = _entries[i];
            if (entry.isHeader) {
              return _SectionHeader(letter: entry.letter!);
            }
            return TrackTile(tracks: _sorted, index: entry.trackIndex!);
          },
        ),
        Align(
          alignment: Alignment.centerRight,
          child: _AlphabetIndex(
            letters: _letters,
            onSelected: _jumpToLetter,
          ),
        ),
      ],
    );
  }
}

/// A flat-list entry: either a section header (carrying its [letter]) or a
/// track (carrying its index into the sorted track list).
class _Entry {
  const _Entry.header(this.letter) : trackIndex = null;
  const _Entry.track(this.trackIndex) : letter = null;

  final String? letter;
  final int? trackIndex;

  bool get isHeader => letter != null;
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.letter});

  final String letter;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        AppSpacing.sm,
        AppSpacing.md,
        AppSpacing.xs,
      ),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          letter,
          style: theme.textTheme.labelLarge?.copyWith(
            color: theme.colorScheme.primary,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }
}

/// The A–Z scrubber rail. Renders only the letters present and maps a tap or
/// vertical drag to the nearest letter, jumping the list to that section.
class _AlphabetIndex extends StatelessWidget {
  const _AlphabetIndex({required this.letters, required this.onSelected});

  final List<String> letters;
  final ValueChanged<String> onSelected;

  void _handle(Offset localPosition, double height) {
    if (letters.isEmpty || height <= 0) return;
    final fraction = (localPosition.dy / height).clamp(0.0, 0.999);
    onSelected(letters[(fraction * letters.length).floor()]);
  }

  @override
  Widget build(BuildContext context) {
    if (letters.length < 2) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        // Fill the available height so a tap/drag maps linearly across the
        // whole list, and the hit area matches the height used for mapping.
        final double height =
            constraints.hasBoundedHeight ? constraints.maxHeight : 0;
        return GestureDetector(
          key: const Key('library_alphabet_index'),
          behavior: HitTestBehavior.opaque,
          onTapDown: (d) => _handle(d.localPosition, height),
          onVerticalDragStart: (d) => _handle(d.localPosition, height),
          onVerticalDragUpdate: (d) => _handle(d.localPosition, height),
          child: SizedBox(
            height: height > 0 ? height : null,
            child: Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final letter in letters)
                      Text(
                        letter,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurface
                              .withValues(alpha: 0.45),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
