import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'linthra_core_ffi.dart';

/// Whether this build carries the Rust core (native/linthra_core).
///
/// hook/build.dart skips the library when Rust isn't installed where the app
/// was built, so every caller must keep working without it: check
/// [isAvailable] (or use [NativeSearchIndex.build], which does) and fall back
/// to the Dart code path when it is false.
abstract final class LinthraCore {
  /// The C ABI version this Dart code was written against. Must match
  /// `ABI_VERSION` in native/linthra_core/src/ffi.rs.
  static const int abiVersion = 1;

  static bool? _available;

  /// True when the library is bundled, loads, and speaks [abiVersion].
  /// Probed once, on first use.
  static bool get isAvailable => _available ??= _probe();

  static bool _probe() {
    try {
      return linthraCoreAbiVersion() == abiVersion;
    } catch (_) {
      // No asset in this build (the hook skipped it), or the library could
      // not be loaded: the app runs on its Dart code paths.
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

  /// Builds an index over [records], or returns null when this build has no
  /// Rust core ([LinthraCore.isAvailable] is false).
  static NativeSearchIndex? build(Iterable<NativeSearchRecord> records) {
    if (!LinthraCore.isAvailable) return null;
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
        // null, so a refusal here means the two sides of the ABI disagree.
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
    final NativeSearchIndex result =
        NativeSearchIndex._(index, linthraIndexLen(index));
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

  /// Frees the native index. Safe to call more than once.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _finalizer.detach(this);
    linthraIndexFree(_index);
  }
}
