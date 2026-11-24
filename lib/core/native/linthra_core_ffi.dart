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

/// `EvictionResult` on the Rust side (native/linthra_core/src/ffi/cache_eviction.rs).
final class LinthraEvictionResult extends Opaque {}

/// The per-entry flags [linthraEvictionPlan] reads, as in
/// native/linthra_core/src/ffi/cache_eviction.rs.
abstract final class LinthraEvictionFlag {
  static const int managed = 1;
  static const int pinned = 1 << 1;
  static const int preloaded = 1 << 2;
  static const int hasLastAccessed = 1 << 3;
  static const int hasCachedAt = 1 << 4;
}

@Native<
    Pointer<LinthraEvictionResult> Function(
      Pointer<Uint8>,
      Size,
      Pointer<Uint32>,
      Pointer<Int64>,
      Pointer<Int64>,
      Pointer<Int64>,
      Pointer<Uint8>,
      Size,
      Pointer<Uint32>,
      Size,
      Pointer<Uint32>,
      Int64,
      Int64,
      Bool,
    )>(symbol: 'linthra_eviction_plan', isLeaf: true)
external Pointer<LinthraEvictionResult> linthraEvictionPlan(
  Pointer<Uint8> text,
  int textLength,
  Pointer<Uint32> spans,
  Pointer<Int64> sizes,
  Pointer<Int64> lastAccessed,
  Pointer<Int64> cachedAt,
  Pointer<Uint8> flags,
  int count,
  Pointer<Uint32> protectSpans,
  int protectCount,
  Pointer<Uint32> incomingSpan,
  int incomingBytes,
  int maxBytes,
  bool onlyPreloaded,
);

@Native<Bool Function(Pointer<LinthraEvictionResult>)>(
  symbol: 'linthra_eviction_result_fits',
  isLeaf: true,
)
external bool linthraEvictionResultFits(Pointer<LinthraEvictionResult> result);

@Native<Size Function(Pointer<LinthraEvictionResult>)>(
  symbol: 'linthra_eviction_result_len',
  isLeaf: true,
)
external int linthraEvictionResultLen(Pointer<LinthraEvictionResult> result);

@Native<Pointer<Uint32> Function(Pointer<LinthraEvictionResult>)>(
  symbol: 'linthra_eviction_result_indices',
  isLeaf: true,
)
external Pointer<Uint32> linthraEvictionResultIndices(
  Pointer<LinthraEvictionResult> result,
);

@Native<Void Function(Pointer<LinthraEvictionResult>)>(
  symbol: 'linthra_eviction_result_free',
  isLeaf: true,
)
external void linthraEvictionResultFree(Pointer<LinthraEvictionResult> result);

/// `GroupingResult` on the Rust side
/// (native/linthra_core/src/ffi/library_grouping.rs).
final class LinthraGroupingResult extends Opaque {}

/// `LibraryGroupsView` on the Rust side: borrowed arrays, valid until the
/// [LinthraGroupingResult] they came from is freed.
final class LinthraLibraryGroupsView extends Struct {
  @Size()
  external int albumCount;

  @Size()
  external int artistCount;

  external Pointer<Uint8> ids;

  /// `albumCount + 1` offsets into [ids].
  external Pointer<Uint32> albumIds;

  /// `artistCount + 1` offsets into [ids].
  external Pointer<Uint32> artistIds;

  /// [LinthraGrouping.albumFields] values per album.
  external Pointer<Uint32> albumFields;

  /// [LinthraGrouping.artistFields] values per artist.
  external Pointer<Uint32> artistFields;

  external Pointer<Uint32> trackAlbum;

  external Pointer<Uint32> trackArtist;
}

/// Constants of the grouping ABI, as in
/// native/linthra_core/src/ffi/library_grouping.rs.
abstract final class LinthraGrouping {
  /// A track index that names no track.
  static const int noTrack = 0xFFFFFFFF;

  /// Title track, album artist track, artist track, track count.
  static const int albumFields = 4;

  /// Name track, album count, track count.
  static const int artistFields = 3;
}

// Not a leaf call: a large catalog takes long enough that it should not hold
// up the garbage collector.
@Native<
    Pointer<LinthraGroupingResult> Function(
      Pointer<Uint8>,
      Size,
      Pointer<Uint32>,
      Size,
    )>(symbol: 'linthra_library_group')
external Pointer<LinthraGroupingResult> linthraLibraryGroup(
  Pointer<Uint8> text,
  int textLength,
  Pointer<Uint32> spans,
  int count,
);

@Native<LinthraLibraryGroupsView Function(Pointer<LinthraGroupingResult>)>(
  symbol: 'linthra_grouping_result_view',
  isLeaf: true,
)
external LinthraLibraryGroupsView linthraGroupingResultView(
  Pointer<LinthraGroupingResult> result,
);

@Native<Void Function(Pointer<LinthraGroupingResult>)>(
  symbol: 'linthra_grouping_result_free',
  isLeaf: true,
)
external void linthraGroupingResultFree(Pointer<LinthraGroupingResult> result);

/// The `u8` codes the download calls (native/linthra_core/src/ffi/downloads.rs)
/// use besides an enum's `index`.
abstract final class LinthraDownloadCode {
  /// A row with no status, as an argument or a result.
  static const int none = 255;

  /// An argument the Rust side did not know.
  static const int invalid = 254;
}

@Native<Uint8 Function(Uint8, Bool)>(
  symbol: 'linthra_download_gate',
  isLeaf: true,
)
external int linthraDownloadGate(int network, bool allowMobileData);

@Native<Uint8 Function(Uint8, Uint8)>(
  symbol: 'linthra_download_settle_canceled',
  isLeaf: true,
)
external int linthraDownloadSettleCanceled(int row, int committed);

@Native<Uint8 Function(Bool, Bool, Uint8)>(
  symbol: 'linthra_download_held_action',
  isLeaf: true,
)
external int linthraDownloadHeldAction(
    bool sameAccount, bool inFlight, int row);
