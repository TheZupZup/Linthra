/// A playlist's track uris ([stored]) with one song moved, by identity rather
/// than position: the song [shown] at [from] goes right after the song shown
/// before it once it is at [to], wherever both are in [stored] now.
///
/// [shown] is the order a screen showed when the move was made, [from] and [to]
/// 0-based into it, [to] being the destination after removal. It need not
/// match [stored]: the rows only catch up with a move once the playlist's songs
/// are read again, so a second drag in the meantime comes from the old order
/// (#749). Applying its indices to [stored] would move whichever song is there
/// now instead.
///
/// The song keeps its identity through duplicates: it is the same copy of the
/// uri, counted from the top, in both orders. When the song before the drop is
/// gone, the one after it anchors the move instead; with neither, [to] is
/// clamped into [stored].
///
/// Null when there is nothing to move: [from] is out of range, or the song is
/// no longer in the playlist.
List<String>? playlistWithMove(
  List<String> stored, {
  required List<String> shown,
  required int from,
  required int to,
}) {
  if (from < 0 || from >= shown.length) return null;
  final String moved = shown[from];
  final List<String> after = List<String>.of(shown)..removeAt(from);
  final int slot = to.clamp(0, after.length);
  after.insert(slot, moved);

  final List<String> ids = List<String>.of(stored);
  final int at = _indexOfCopy(ids, moved, _copiesBefore(shown, from));
  if (at < 0) return null;
  ids.removeAt(at);

  int insertAt = -1;
  if (slot > 0) {
    final String before = after[slot - 1];
    final int index = _indexOfCopy(ids, before, _copiesBefore(after, slot - 1));
    if (index >= 0) insertAt = index + 1;
  } else {
    insertAt = 0;
  }
  if (insertAt < 0 && slot + 1 < after.length) {
    final String next = after[slot + 1];
    // Counted in [after] without the moved song, as [ids] now is.
    final List<String> rest = List<String>.of(after)..removeAt(slot);
    insertAt = _indexOfCopy(ids, next, _copiesBefore(rest, slot));
  }
  if (insertAt < 0) insertAt = slot.clamp(0, ids.length);
  ids.insert(insertAt, moved);
  return ids;
}

/// Where the song [shown] at [index] is in [songs], counting copies the way
/// [playlistWithMove] does, or -1 when it isn't there.
int indexOfShownSong(List<String> songs, List<String> shown, int index) =>
    _indexOfCopy(songs, shown[index], _copiesBefore(shown, index));

/// How many copies of `songs[index]` come before [index].
int _copiesBefore(List<String> songs, int index) {
  int copies = 0;
  for (int i = 0; i < index; i++) {
    if (songs[i] == songs[index]) copies++;
  }
  return copies;
}

/// Where the copy of [song] numbered [copy] (from 0, from the top) is in
/// [songs]: that copy when there are enough of them, the last one otherwise,
/// and -1 when there is none.
int _indexOfCopy(List<String> songs, String song, int copy) {
  int seen = 0;
  int last = -1;
  for (int i = 0; i < songs.length; i++) {
    if (songs[i] != song) continue;
    if (seen == copy) return i;
    seen++;
    last = i;
  }
  return last;
}
