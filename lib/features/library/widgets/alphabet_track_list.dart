import 'package:flutter/material.dart';

import '../../../app/dimens.dart';
import '../../../core/models/track.dart';
import 'track_tile.dart';

/// A track list with first-letter section grouping and an A–Z fast-scroll
/// index pinned to the trailing edge, so large libraries stay navigable.
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

  /// Width of the trailing A–Z rail. The list reserves this much right-side
  /// padding so rows (and the 3-dot overflow menu) never sit under the rail.
  static const double _railWidth = 28;

  final ScrollController _controller = ScrollController();

  late List<Track> _sorted;
  late List<_Entry> _entries;
  late List<String> _letters;
  late Map<String, double> _letterOffsets;

  /// The section the list is currently parked at — highlighted in the rail and
  /// shown in the scrub bubble. Tracks both manual scrolling and rail drags.
  String? _activeLetter;

  /// True while the user is touching/dragging the rail, which surfaces the
  /// larger active-letter bubble.
  bool _scrubbing = false;

  @override
  void initState() {
    super.initState();
    _rebuildIndex();
    _controller.addListener(_syncActiveLetter);
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
    _controller.removeListener(_syncActiveLetter);
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
    _activeLetter = _letters.isNotEmpty ? _letters.first : null;
  }

  /// The leading index character for [title]: an uppercase letter, or '#' for
  /// anything that doesn't begin with a letter (digits, symbols, empty).
  static String _indexKey(String title) {
    final trimmed = title.trimLeft();
    if (trimmed.isEmpty) return '#';
    final first = trimmed[0].toUpperCase();
    return RegExp('[A-Z]').hasMatch(first) ? first : '#';
  }

  /// Keeps [_activeLetter] in step with normal list scrolling so the rail
  /// highlight reflects where the user actually is, not just where they tapped.
  void _syncActiveLetter() {
    if (!_controller.hasClients) return;
    final letter = _letterForOffset(_controller.offset);
    if (letter != null && letter != _activeLetter) {
      setState(() => _activeLetter = letter);
    }
  }

  /// The last section whose header sits at or above [offset] — i.e. the section
  /// currently scrolled to the top of the viewport.
  String? _letterForOffset(double offset) {
    String? result;
    for (final entry in _letterOffsets.entries) {
      if (entry.value <= offset + 1) {
        result = entry.key;
      } else {
        break;
      }
    }
    return result ?? (_letters.isNotEmpty ? _letters.first : null);
  }

  void _jumpToLetter(String letter) {
    final offset = _letterOffsets[letter];
    if (offset == null || !_controller.hasClients) return;
    final max = _controller.position.maxScrollExtent;
    _controller.jumpTo(offset.clamp(0.0, max));
    if (letter != _activeLetter) {
      setState(() => _activeLetter = letter);
    }
  }

  @override
  Widget build(BuildContext context) {
    final showRail = _letters.length >= 2;
    return Stack(
      children: [
        ListView.builder(
          key: const Key('library_track_list'),
          controller: _controller,
          // Reserve room for the rail so rows never render beneath it.
          padding:
              EdgeInsets.only(right: showRail ? _railWidth : AppSpacing.md),
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
        if (showRail)
          Positioned(
            top: 0,
            bottom: 0,
            right: 0,
            width: _railWidth,
            child: _AlphabetIndex(
              letters: _letters,
              activeLetter: _activeLetter,
              onSelected: _jumpToLetter,
              onScrubChanged: (scrubbing) =>
                  setState(() => _scrubbing = scrubbing),
            ),
          ),
        if (showRail && _scrubbing && _activeLetter != null)
          Positioned(
            right: _railWidth + AppSpacing.sm,
            top: 0,
            bottom: 0,
            child: Center(child: _ScrubBubble(letter: _activeLetter!)),
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

/// The big translucent letter shown beside the rail while the user is
/// scrubbing, so the target section is legible even under a fingertip.
class _ScrubBubble extends StatelessWidget {
  const _ScrubBubble({required this.letter});

  final String letter;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: 48,
      height: 48,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: theme.colorScheme.primary,
        borderRadius: const BorderRadius.all(Radius.circular(AppRadii.md)),
      ),
      child: Text(
        letter,
        style: theme.textTheme.titleLarge?.copyWith(
          color: theme.colorScheme.onPrimary,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}

/// The A–Z scrubber rail, pinned to the trailing edge at a fixed [width]. It
/// renders only the letters present and maps a tap or vertical drag to the
/// nearest letter, jumping the list to that section. The active letter is
/// drawn in the accent colour; the rest stay subtle.
class _AlphabetIndex extends StatelessWidget {
  const _AlphabetIndex({
    required this.letters,
    required this.activeLetter,
    required this.onSelected,
    required this.onScrubChanged,
  });

  final List<String> letters;
  final String? activeLetter;
  final ValueChanged<String> onSelected;
  final ValueChanged<bool> onScrubChanged;

  void _handle(Offset localPosition, double height) {
    if (letters.isEmpty || height <= 0) return;
    final fraction = (localPosition.dy / height).clamp(0.0, 0.999);
    onSelected(letters[(fraction * letters.length).floor()]);
  }

  @override
  Widget build(BuildContext context) {
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
          onVerticalDragStart: (d) {
            onScrubChanged(true);
            _handle(d.localPosition, height);
          },
          onVerticalDragUpdate: (d) => _handle(d.localPosition, height),
          onVerticalDragEnd: (_) => onScrubChanged(false),
          onVerticalDragCancel: () => onScrubChanged(false),
          child: SizedBox(
            height: height > 0 ? height : null,
            child: Column(
              mainAxisSize: height > 0 ? MainAxisSize.max : MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                for (final letter in letters)
                  Text(
                    letter,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: letter == activeLetter
                          ? theme.colorScheme.primary
                          : theme.colorScheme.onSurface.withValues(alpha: 0.45),
                      fontWeight: letter == activeLetter
                          ? FontWeight.bold
                          : FontWeight.w600,
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}
