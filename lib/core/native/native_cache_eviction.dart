import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../repositories/download_store.dart';
import 'linthra_core.dart';
import 'linthra_core_ffi.dart';

/// The Rust core's answer for one eviction: whether the download fits, and
/// the entries to delete as indices into the list it was given, in order.
typedef NativeEvictionPlan = ({bool fits, List<int> evict});

/// Runs the cache eviction policy in the Rust core
/// (native/linthra_core/src/cache_eviction.rs).
///
/// Use `CacheEvictionPolicy.plan`, which calls this and falls back to its Dart
/// rules without the Rust core.
abstract final class NativeCacheEviction {
  /// The plan for [cached], or null when this build has no Rust core.
  ///
  /// [protectKeys] and [incomingKey] are [CachedTrack.cacheKey]s.
  static NativeEvictionPlan? plan({
    required List<CachedTrack> cached,
    required int incomingBytes,
    required int maxBytes,
    required Set<String> protectKeys,
    required bool onlyPreloaded,
    String? incomingKey,
  }) {
    if (!LinthraCore.isAvailable) return null;
    final _Text text = _Text(cached.length);
    final int count = cached.length;
    // A key without the separator is not one [CachedTrack.cacheKey] makes, so
    // it can never match an entry: leave it out rather than guess its halves.
    final List<String> protect = <String>[
      for (final String key in protectKeys)
        if (key.contains('\u0000')) key,
    ];
    final String? incoming =
        incomingKey != null && incomingKey.contains('\u0000')
            ? incomingKey
            : null;

    return using((Arena arena) {
      final Pointer<Uint32> spans = arena<Uint32>(4 * count + 4);
      final Pointer<Int64> sizes = arena<Int64>(count + 1);
      final Pointer<Int64> accessed = arena<Int64>(count + 1);
      final Pointer<Int64> cachedAt = arena<Int64>(count + 1);
      final Pointer<Uint8> flags = arena<Uint8>(count + 1);
      final Uint32List spanList = spans.asTypedList(4 * count);
      final Int64List sizeList = sizes.asTypedList(count);
      final Int64List accessedList = accessed.asTypedList(count);
      final Int64List cachedAtList = cachedAt.asTypedList(count);
      final Uint8List flagList = flags.asTypedList(count);

      for (int i = 0; i < count; i++) {
        final CachedTrack track = cached[i];
        text.add(spanList, 4 * i, track.sourceType ?? '', track.trackId);
        sizeList[i] = track.sizeBytes;
        final DateTime? lastAccessed = track.lastAccessedAt;
        final DateTime? downloaded = track.cachedAt;
        accessedList[i] = lastAccessed?.microsecondsSinceEpoch ?? 0;
        cachedAtList[i] = downloaded?.microsecondsSinceEpoch ?? 0;
        flagList[i] = (track.isManaged ? LinthraEvictionFlag.managed : 0) |
            (track.pinned ? LinthraEvictionFlag.pinned : 0) |
            (track.preloaded ? LinthraEvictionFlag.preloaded : 0) |
            (lastAccessed != null ? LinthraEvictionFlag.hasLastAccessed : 0) |
            (downloaded != null ? LinthraEvictionFlag.hasCachedAt : 0);
      }

      final Pointer<Uint32> protectSpans =
          arena<Uint32>(4 * protect.length + 4);
      final Uint32List protectList =
          protectSpans.asTypedList(4 * protect.length);
      for (int i = 0; i < protect.length; i++) {
        text.addKey(protectList, 4 * i, protect[i]);
      }

      Pointer<Uint32> incomingSpan = nullptr;
      if (incoming != null) {
        incomingSpan = arena<Uint32>(4);
        text.addKey(incomingSpan.asTypedList(4), 0, incoming);
      }

      final Uint8List bytes = text.bytes();
      final Pointer<Uint8> textPointer = arena<Uint8>(bytes.length + 1);
      textPointer.asTypedList(bytes.length).setAll(0, bytes);

      final Pointer<LinthraEvictionResult> result = linthraEvictionPlan(
        textPointer,
        bytes.length,
        spans,
        sizes,
        accessed,
        cachedAt,
        flags,
        count,
        protectSpans,
        protect.length,
        incomingSpan,
        incomingBytes,
        maxBytes,
        onlyPreloaded,
      );
      // Every span was written by [_Text] from Dart strings, so a refusal
      // means the two sides of the ABI disagree.
      if (result == nullptr) {
        throw StateError('linthra_eviction_plan refused its input');
      }
      try {
        final int length = linthraEvictionResultLen(result);
        return (
          fits: linthraEvictionResultFits(result),
          evict: length == 0
              ? const <int>[]
              : List<int>.of(
                  linthraEvictionResultIndices(result).asTypedList(length),
                ),
        );
      } finally {
        linthraEvictionResultFree(result);
      }
    });
  }
}

/// One UTF-8 buffer holding every source and id, and the spans that point
/// into it.
///
/// Built for speed, since it is most of what a plan costs: ASCII (nearly
/// every id) is written byte by byte with no allocation, and each provider
/// name is written once and shared by every entry from that provider.
class _Text {
  /// Sized for [entries] typical ids, so a normal plan never grows it.
  _Text(int entries) : _bytes = Uint8List(64 + entries * 24);

  Uint8List _bytes;
  int _length = 0;

  /// Where each provider name already sits: its start and length.
  final Map<String, (int, int)> _sources = <String, (int, int)>{};

  /// Writes the span of (source, id) into [spans] at [at].
  void add(Uint32List spans, int at, String source, String id) {
    final (int, int) written = _sources[source] ??= (_length, _append(source));
    spans[at] = written.$1;
    spans[at + 1] = written.$2;
    spans[at + 2] = _length;
    spans[at + 3] = _append(id);
  }

  /// [add] for a [CachedTrack.cacheKey], which is the source and the id
  /// joined by NUL.
  void addKey(Uint32List spans, int at, String key) {
    final int separator = key.indexOf('\u0000');
    add(spans, at, key.substring(0, separator), key.substring(separator + 1));
  }

  /// Appends [part] as UTF-8 and returns how many bytes it took.
  int _append(String part) {
    final int start = _length;
    // At most three UTF-8 bytes per UTF-16 code unit.
    _reserve(part.length * 3);
    for (int i = 0; i < part.length; i++) {
      final int unit = part.codeUnitAt(i);
      if (unit >= 0x80) {
        // Not ASCII: let the codec handle surrogates and multi-byte forms.
        _length = start;
        final Uint8List encoded = utf8.encode(part);
        _bytes.setRange(_length, _length + encoded.length, encoded);
        _length += encoded.length;
        return encoded.length;
      }
      _bytes[_length++] = unit;
    }
    return _length - start;
  }

  void _reserve(int more) {
    if (_length + more <= _bytes.length) return;
    int capacity = _bytes.length * 2;
    while (capacity < _length + more) {
      capacity *= 2;
    }
    _bytes = Uint8List(capacity)..setRange(0, _length, _bytes);
  }

  /// The bytes written so far, as a view (no copy).
  Uint8List bytes() => Uint8List.sublistView(_bytes, 0, _length);
}
