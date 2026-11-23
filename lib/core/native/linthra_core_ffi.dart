/// Raw bindings to the Rust core's C ABI (native/linthra_core/src/ffi.rs).
///
/// Written by hand rather than generated: the surface is small, and keeping it
/// beside the Rust file it mirrors makes the boundary easy to review. Change
/// both together, and bump `ABI_VERSION` there and [linthraCoreAbiVersion]'s
/// expected value in linthra_core.dart.
///
/// Nothing outside lib/core/native/ should import this file: the functions take
/// raw pointers. Use [NativeSearchIndex] (linthra_core.dart) instead.
@DefaultAsset('package:linthra/linthra_core')
library;

import 'dart:ffi';

import 'package:ffi/ffi.dart';

/// `IndexBuilder` on the Rust side.
final class LinthraIndexBuilder extends Opaque {}

/// `LibraryIndex` on the Rust side.
final class LinthraIndex extends Opaque {}

/// `SearchResults` on the Rust side.
final class LinthraSearchResults extends Opaque {}

/// Status codes returned by [linthraIndexBuilderAdd].
abstract final class LinthraStatus {
  static const int ok = 0;
  static const int nullArgument = 1;
  static const int invalidUtf8 = 2;
}

@Native<Uint32 Function()>(symbol: 'linthra_core_abi_version', isLeaf: true)
external int linthraCoreAbiVersion();

@Native<Pointer<LinthraIndexBuilder> Function()>(
  symbol: 'linthra_index_builder_new',
)
external Pointer<LinthraIndexBuilder> linthraIndexBuilderNew();

@Native<
    Int32 Function(
      Pointer<LinthraIndexBuilder>,
      Pointer<Utf8>,
      Pointer<Utf8>,
      Pointer<Utf8>,
      Pointer<Utf8>,
      Pointer<Utf8>,
      Pointer<Utf8>,
    )>(symbol: 'linthra_index_builder_add')
external int linthraIndexBuilderAdd(
  Pointer<LinthraIndexBuilder> builder,
  Pointer<Utf8> id,
  Pointer<Utf8> title,
  Pointer<Utf8> artist,
  Pointer<Utf8> album,
  Pointer<Utf8> albumArtist,
  Pointer<Utf8> provider,
);

@Native<Pointer<LinthraIndex> Function(Pointer<LinthraIndexBuilder>)>(
  symbol: 'linthra_index_builder_finish',
)
external Pointer<LinthraIndex> linthraIndexBuilderFinish(
  Pointer<LinthraIndexBuilder> builder,
);

@Native<Void Function(Pointer<LinthraIndexBuilder>)>(
  symbol: 'linthra_index_builder_free',
)
external void linthraIndexBuilderFree(Pointer<LinthraIndexBuilder> builder);

@Native<Size Function(Pointer<LinthraIndex>)>(
  symbol: 'linthra_index_len',
  isLeaf: true,
)
external int linthraIndexLen(Pointer<LinthraIndex> index);

@Native<Void Function(Pointer<LinthraIndex>)>(symbol: 'linthra_index_free')
external void linthraIndexFree(Pointer<LinthraIndex> index);

@Native<
    Pointer<LinthraSearchResults> Function(
      Pointer<LinthraIndex>,
      Pointer<Utf8>,
      Size,
    )>(symbol: 'linthra_index_search')
external Pointer<LinthraSearchResults> linthraIndexSearch(
  Pointer<LinthraIndex> index,
  Pointer<Utf8> query,
  int limit,
);

@Native<Size Function(Pointer<LinthraSearchResults>)>(
  symbol: 'linthra_search_results_len',
  isLeaf: true,
)
external int linthraSearchResultsLen(Pointer<LinthraSearchResults> results);

@Native<Pointer<Utf8> Function(Pointer<LinthraSearchResults>, Size)>(
  symbol: 'linthra_search_results_id',
  isLeaf: true,
)
external Pointer<Utf8> linthraSearchResultsId(
  Pointer<LinthraSearchResults> results,
  int position,
);

@Native<Void Function(Pointer<LinthraSearchResults>)>(
  symbol: 'linthra_search_results_free',
)
external void linthraSearchResultsFree(Pointer<LinthraSearchResults> results);

/// `MatchResults` on the Rust side.
final class LinthraMatchResults extends Opaque {}

@Native<
    Pointer<LinthraMatchResults> Function(
        Pointer<LinthraIndex>, Pointer<Utf8>)>(
  symbol: 'linthra_index_match',
)
external Pointer<LinthraMatchResults> linthraIndexMatch(
  Pointer<LinthraIndex> index,
  Pointer<Utf8> query,
);

@Native<Size Function(Pointer<LinthraMatchResults>)>(
  symbol: 'linthra_match_results_len',
  isLeaf: true,
)
external int linthraMatchResultsLen(Pointer<LinthraMatchResults> results);

@Native<Pointer<Uint32> Function(Pointer<LinthraMatchResults>)>(
  symbol: 'linthra_match_results_positions',
  isLeaf: true,
)
external Pointer<Uint32> linthraMatchResultsPositions(
  Pointer<LinthraMatchResults> results,
);

@Native<Void Function(Pointer<LinthraMatchResults>)>(
  symbol: 'linthra_match_results_free',
)
external void linthraMatchResultsFree(Pointer<LinthraMatchResults> results);
