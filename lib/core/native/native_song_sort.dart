import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../models/track.dart';
import 'linthra_core_ffi.dart';

/// The Songs list's order in the Rust core
/// (native/linthra_core/src/song_sort.rs). Use `sortSongs`, which calls this.
abstract final class NativeSongSort {
  static const int _none = -0x8000000000000000;

  /// The order of [tracks] (positions in it) and each one's section
  /// character (null for an order without sections), filing albums against
  /// [catalog] when given.
  ///
  /// [field] is a `SongSortField` index. [addedAt] gives each song's first
  /// sighting in microseconds, by uri.
  static (List<int>, List<String>?) sort(
    List<Track> tracks, {
    List<Track>? catalog,
    required int field,
    required bool descending,
    Map<String, DateTime> addedAt = const <String, DateTime>{},
  }) {
    // The songs are their own catalog: no need to send them twice.
    final List<Track> filing = catalog == null || identical(catalog, tracks)
        ? const <Track>[]
        : catalog;
    final int n = tracks.length + filing.length;
    final _Text text = _Text(n);
    final Uint32List spans = Uint32List(14 * n);
    final Int64List discs = Int64List(n);
    final Int64List numbers = Int64List(n);
    final Int64List added = Int64List(n);
    // Text is lower-cased here, by Dart's own table, as grouping's is: Rust's
    // differs for a few letters, and the ids must match Dart's byte for byte.
    // Artists, albums and album ids repeat across a library, so each distinct
    // one is lower-cased and written once.
    final Map<String, int> lowered = <String, int>{};
    final Map<String, int> asIs = <String, int>{};
    int shared(Map<String, int> cache, String value, bool lower) =>
        cache[value] ??= text.add(lower ? value.toLowerCase() : value);
    void entry(int i, Track t, {required bool sorted}) {
      final int at = 14 * i;
      text.span(spans, at, text.add(t.uri));
      final int title = sorted ? text.add(t.title) : text.empty;
      text.span(spans, at + 2, title);
      // An ASCII title (one byte per code unit) needs no lower-cased copy:
      // Rust lower-cases ASCII exactly as Dart does.
      final bool ascii = !sorted || text.lengthOf(title) == t.title.length;
      text.span(
        spans,
        at + 4,
        ascii ? text.empty : text.add(t.title.toLowerCase()),
      );
      text.span(spans, at + 6, shared(lowered, t.artistName ?? '', true));
      text.span(spans, at + 8, shared(lowered, t.albumName ?? '', true));
      text.span(spans, at + 10, shared(lowered, t.albumArtistName ?? '', true));
      text.span(spans, at + 12, shared(asIs, t.albumId ?? '', false));
      discs[i] = t.discNumber ?? _none;
      numbers[i] = t.trackNumber ?? _none;
      added[i] =
          sorted ? addedAt[t.uri]?.microsecondsSinceEpoch ?? _none : _none;
    }

    for (int i = 0; i < tracks.length; i++) {
      entry(i, tracks[i], sorted: true);
    }
    for (int i = 0; i < filing.length; i++) {
      entry(tracks.length + i, filing[i], sorted: false);
    }
    final Uint8List bytes = text.bytes();
    return using((Arena arena) {
      Pointer<T> copy<T extends NativeType>(TypedData data, int size) {
        final Pointer<Uint8> p = arena<Uint8>(data.lengthInBytes + 1);
        p.asTypedList(data.lengthInBytes).setAll(
              0,
              data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
            );
        return p.cast<T>();
      }

      final Pointer<LinthraSongSort> result = linthraSongSort(
        copy<Uint8>(bytes, 1),
        bytes.length,
        copy<Uint32>(spans, 4),
        copy<Int64>(discs, 8),
        copy<Int64>(numbers, 8),
        copy<Int64>(added, 8),
        tracks.length,
        filing.length,
        field,
        descending,
      );
      // Refused (the two sides of the ABI disagree), or Rust's safe answer
      // panicked too.
      if (result == nullptr) {
        throw StateError('linthra_song_sort gave no answer');
      }
      try {
        final List<int> order = List<int>.of(
          linthraSongSortOrder(result).asTypedList(tracks.length),
        );
        final Pointer<Uint8> sections = linthraSongSortSections(result);
        return (
          order,
          sections == nullptr
              ? null
              : <String>[
                  for (final int c in sections.asTypedList(tracks.length))
                    String.fromCharCode(c),
                ],
        );
      } finally {
        linthraSongSortFree(result);
      }
    });
  }
}

/// One UTF-8 buffer for every string, written without an allocation per
/// string when it is ASCII. Each written string is a slot holding its start
/// and length.
class _Text {
  _Text(int entries) : _bytes = Uint8List(64 + entries * 48);

  Uint8List _bytes;
  int _length = 0;
  final List<int> _starts = <int>[];
  final List<int> _lengths = <int>[];

  /// The slot of the empty string.
  late final int empty = add('');

  /// Writes [part] and returns its slot.
  int add(String part) {
    final int start = _length;
    _reserve(part.length * 3);
    for (int i = 0; i < part.length; i++) {
      final int unit = part.codeUnitAt(i);
      if (unit >= 0x80) {
        _length = start;
        final Uint8List encoded = utf8.encode(part);
        _bytes.setRange(_length, _length + encoded.length, encoded);
        _length += encoded.length;
        break;
      }
      _bytes[_length++] = unit;
    }
    _starts.add(start);
    _lengths.add(_length - start);
    return _starts.length - 1;
  }

  /// How many bytes [slot] took.
  int lengthOf(int slot) => _lengths[slot];

  /// Writes [slot]'s start and length into [spans] at [at].
  void span(Uint32List spans, int at, int slot) {
    spans[at] = _starts[slot];
    spans[at + 1] = _lengths[slot];
  }

  void _reserve(int more) {
    if (_length + more <= _bytes.length) return;
    int capacity = _bytes.length * 2;
    while (capacity < _length + more) {
      capacity *= 2;
    }
    _bytes = Uint8List(capacity)..setRange(0, _length, _bytes);
  }

  Uint8List bytes() => Uint8List.sublistView(_bytes, 0, _length);
}
