import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'linthra_core_ffi.dart';

/// The Rust core (native/linthra_core), which runs Linthra's backend.
///
/// hook/build.dart builds it into every app and every `flutter test` run, and
/// fails the build where it can't, so nothing here has a Dart copy to fall
/// back on. [ensureAvailable] is checked once at startup, so a broken build
/// says so at once instead of failing somewhere later.
abstract final class LinthraCore {
  /// The C ABI version this Dart code was written against. Must match
  /// `ABI_VERSION` in native/linthra_core/src/ffi.rs.
  static const int abiVersion = 21;

  static bool? _available;

  /// True when the library is bundled, loads, and speaks [abiVersion].
  /// Probed once, on first use.
  static bool get isAvailable => _available ??= _probe();

  /// Throws when [isAvailable] is false, saying why the app can't run.
  static void ensureAvailable() {
    if (isAvailable) return;
    throw StateError(
      'The Rust core (liblinthra_core) is missing, or not the version this '
      'app was built with (ABI $abiVersion). Linthra cannot run without it; '
      'reinstall the app, or rebuild it with Rust installed.',
    );
  }

  static bool _probe() {
    try {
      return linthraCoreAbiVersion() == abiVersion;
    } catch (_) {
      // The library is missing or could not be loaded.
      return false;
    }
  }
}

/// One track as the Rust search index sees it.
class NativeSearchRecord {
  const NativeSearchRecord({
    required this.id,
    required this.title,
    required this.artist,
    required this.album,
    this.albumArtist,
    required this.provider,
  });

  /// Returned by [NativeSearchIndex.search] for a hit; the index never
  /// interprets it.
  final String id;
  final String title;
  final String artist;
  final String album;
  final String? albumArtist;

  /// Searchable at a low weight, so "navidrome halo" narrows to that server.
  final String provider;
}

/// The Rust core's immutable search index: accent- and case-folded prefix
/// search with AND semantics across terms, ranked by field (title, then
/// artist, album artist, album, provider).
///
/// The index lives in native memory. [dispose] frees it right away; an index
/// that is dropped without [dispose] is freed when Dart collects it.
final class NativeSearchIndex implements Finalizable {
  NativeSearchIndex._(this._index, this.length);

  static final NativeFinalizer _finalizer = NativeFinalizer(
    Native.addressOf<NativeFunction<Void Function(Pointer<LinthraIndex>)>>(
      linthraIndexFree,
    ).cast(),
  );

  final Pointer<LinthraIndex> _index;
  bool _disposed = false;

  /// Number of tracks in the index.
  final int length;

  /// Builds an index over [records].
  static NativeSearchIndex build(Iterable<NativeSearchRecord> records) =>
      NativeSearchIndex.adopt(buildDetached(records));

  /// Builds an index over [records] and returns its native address, for
  /// building on a background isolate: send the address back and pass it to
  /// [NativeSearchIndex.adopt] on the isolate that will use it, exactly once.
  /// Until then nothing frees it.
  static int buildDetached(Iterable<NativeSearchRecord> records) {
    final Pointer<LinthraIndexBuilder> builder = linthraIndexBuilderNew();
    try {
      for (final NativeSearchRecord record in records) {
        final int status = using(
          (Arena arena) => linthraIndexBuilderAdd(
            builder,
            record.id.toNativeUtf8(allocator: arena),
            record.title.toNativeUtf8(allocator: arena),
            record.artist.toNativeUtf8(allocator: arena),
            record.album.toNativeUtf8(allocator: arena),
            record.albumArtist?.toNativeUtf8(allocator: arena) ?? nullptr,
            record.provider.toNativeUtf8(allocator: arena),
          ),
        );
        // Dart strings always encode to valid UTF-8 and none of these is
        // null, so a refusal here means the two sides of the ABI disagree,
        // and a panic that Rust's own safe answer panicked too.
        if (status != LinthraStatus.ok) {
          throw StateError(
            'linthra_index_builder_add refused a track (status $status)',
          );
        }
      }
    } catch (_) {
      linthraIndexBuilderFree(builder);
      rethrow;
    }
    final Pointer<LinthraIndex> index = linthraIndexBuilderFinish(builder);
    // Null only when building the index and its safe answer both panicked.
    if (index == nullptr) {
      throw StateError('linthra_index_builder_finish gave no index');
    }
    return index.address;
  }

  /// Takes ownership of an index from [buildDetached]: it is freed by
  /// [dispose], or when this object is collected.
  factory NativeSearchIndex.adopt(int address) {
    final Pointer<LinthraIndex> index = Pointer<LinthraIndex>.fromAddress(
      address,
    );
    final NativeSearchIndex result = NativeSearchIndex._(
      index,
      linthraIndexLen(index),
    );
    _finalizer.attach(result, index.cast(), detach: result);
    return result;
  }

  /// The ids of the best [limit] matches for [query], best first. An empty or
  /// whitespace-only query, or a [limit] of 0 or less, finds nothing.
  ///
  /// Throws a [StateError] after [dispose].
  List<String> search(String query, {int limit = 50}) {
    if (_disposed) {
      throw StateError('NativeSearchIndex.search called after dispose()');
    }
    if (limit <= 0) return const <String>[];
    final Pointer<LinthraSearchResults> results = using(
      (Arena arena) => linthraIndexSearch(
        _index,
        query.toNativeUtf8(allocator: arena),
        limit,
      ),
    );
    // Null only for a null index or query, or invalid UTF-8: none can happen
    // here, but an empty answer is the right one if it ever does.
    if (results.address == 0) return const <String>[];
    try {
      return List<String>.generate(
        linthraSearchResultsLen(results),
        (int position) =>
            linthraSearchResultsId(results, position).toDartString(),
        growable: false,
      );
    } finally {
      linthraSearchResultsFree(results);
    }
  }

  /// The positions, in the order the records were given to [build], of every
  /// track [query] matches: ascending and unranked, for filtering a list that
  /// keeps its own order. Same matching rules as [search]. An empty or
  /// whitespace-only query matches nothing.
  ///
  /// Throws a [StateError] after [dispose].
  Uint32List matchPositions(String query) {
    if (_disposed) {
      throw StateError(
        'NativeSearchIndex.matchPositions called after dispose()',
      );
    }
    final Pointer<LinthraMatchResults> results = using(
      (Arena arena) =>
          linthraIndexMatch(_index, query.toNativeUtf8(allocator: arena)),
    );
    // Null only for a null index or query, invalid UTF-8, or a catalog past
    // u32: none can happen here.
    if (results.address == 0) return Uint32List(0);
    try {
      final int count = linthraMatchResultsLen(results);
      if (count == 0) return Uint32List(0);
      // One copy out of native memory, before the results are freed.
      return Uint32List.fromList(
        linthraMatchResultsPositions(results).asTypedList(count),
      );
    } finally {
      linthraMatchResultsFree(results);
    }
  }

  /// Frees the native index. Safe to call more than once.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _finalizer.detach(this);
    linthraIndexFree(_index);
  }
}
