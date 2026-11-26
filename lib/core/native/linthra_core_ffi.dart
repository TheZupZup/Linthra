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

/// `QueueEditResult` on the Rust side (native/linthra_core/src/ffi/queue.rs).
final class LinthraQueueEditResult extends Opaque {}

/// [linthraQueueMove]'s answers besides a position.
abstract final class LinthraQueueMove {
  static const int none = -1;
  static const int invalid = -2;
}

@Native<Int64 Function(Int64, Int64, Uint8, Int64)>(
  symbol: 'linthra_queue_move',
  isLeaf: true,
)
external int linthraQueueMove(int length, int current, int move, int index);

@Native<
    Pointer<LinthraQueueEditResult> Function(
      Uint8,
      Int64,
      Int64,
      Uint64,
      Pointer<Int64>,
      Size,
      Int64,
      Bool,
      Pointer<Int64>,
      Size,
      Pointer<Uint8>,
      Pointer<Uint8>,
    )>(symbol: 'linthra_queue_edit', isLeaf: true)
external Pointer<LinthraQueueEditResult> linthraQueueEdit(
  int op,
  int a,
  int b,
  int seed,
  Pointer<Int64> ids,
  int length,
  int current,
  bool hasOriginal,
  Pointer<Int64> original,
  int originalLength,
  Pointer<Uint8> removed,
  Pointer<Uint8> removedOriginal,
);

@Native<Bool Function(Pointer<LinthraQueueEditResult>)>(
  symbol: 'linthra_queue_edit_changed',
  isLeaf: true,
)
external bool linthraQueueEditChanged(Pointer<LinthraQueueEditResult> result);

@Native<Size Function(Pointer<LinthraQueueEditResult>)>(
  symbol: 'linthra_queue_edit_len',
  isLeaf: true,
)
external int linthraQueueEditLen(Pointer<LinthraQueueEditResult> result);

@Native<Pointer<Int64> Function(Pointer<LinthraQueueEditResult>)>(
  symbol: 'linthra_queue_edit_ids',
  isLeaf: true,
)
external Pointer<Int64> linthraQueueEditIds(
  Pointer<LinthraQueueEditResult> result,
);

@Native<Pointer<Int64> Function(Pointer<LinthraQueueEditResult>)>(
  symbol: 'linthra_queue_edit_sources',
  isLeaf: true,
)
external Pointer<Int64> linthraQueueEditSources(
  Pointer<LinthraQueueEditResult> result,
);

@Native<Int64 Function(Pointer<LinthraQueueEditResult>)>(
  symbol: 'linthra_queue_edit_current',
  isLeaf: true,
)
external int linthraQueueEditCurrent(Pointer<LinthraQueueEditResult> result);

@Native<Bool Function(Pointer<LinthraQueueEditResult>)>(
  symbol: 'linthra_queue_edit_has_original',
  isLeaf: true,
)
external bool linthraQueueEditHasOriginal(
  Pointer<LinthraQueueEditResult> result,
);

@Native<Size Function(Pointer<LinthraQueueEditResult>)>(
  symbol: 'linthra_queue_edit_original_len',
  isLeaf: true,
)
external int linthraQueueEditOriginalLen(
  Pointer<LinthraQueueEditResult> result,
);

@Native<Pointer<Int64> Function(Pointer<LinthraQueueEditResult>)>(
  symbol: 'linthra_queue_edit_original_ids',
  isLeaf: true,
)
external Pointer<Int64> linthraQueueEditOriginalIds(
  Pointer<LinthraQueueEditResult> result,
);

@Native<Pointer<Int64> Function(Pointer<LinthraQueueEditResult>)>(
  symbol: 'linthra_queue_edit_original_sources',
  isLeaf: true,
)
external Pointer<Int64> linthraQueueEditOriginalSources(
  Pointer<LinthraQueueEditResult> result,
);

@Native<Void Function(Pointer<LinthraQueueEditResult>)>(
  symbol: 'linthra_queue_edit_free',
  isLeaf: true,
)
external void linthraQueueEditFree(Pointer<LinthraQueueEditResult> result);

@Native<Uint8 Function(Uint8, Bool)>(
  symbol: 'linthra_track_end_action',
  isLeaf: true,
)
external int linthraTrackEndAction(int repeat, bool hasNext);

@Native<
    Int32 Function(
      Pointer<Uint8>,
      Size,
      Pointer<Uint8>,
      Size,
      Pointer<Uint8>,
      Pointer<Uint32>,
      Size,
      Pointer<Uint32>,
    )>(symbol: 'linthra_search_rank', isLeaf: true)
external int linthraSearchRank(
  Pointer<Uint8> query,
  int queryLength,
  Pointer<Uint8> text,
  int textLength,
  Pointer<Uint8> kinds,
  Pointer<Uint32> spans,
  int count,
  Pointer<Uint32> out,
);

/// `TagsResult` on the Rust side (native/linthra_core/src/ffi/tags.rs).
final class LinthraTagsResult extends Opaque {}

/// [linthraTagsStatus] values and [linthraTagsText] field indices, as in
/// native/linthra_core/src/ffi/tags.rs.
abstract final class LinthraTags {
  static const int read = 0;
  static const int notHandled = 1;
  static const int ioError = 2;

  static const int title = 0;
  static const int artist = 1;
  static const int albumArtist = 2;
  static const int album = 3;
}

// Not a leaf call: it reads the file, which can take a while on a slow drive.
@Native<Pointer<LinthraTagsResult> Function(Pointer<Uint8>, Size, Bool)>(
  symbol: 'linthra_tags_read',
)
external Pointer<LinthraTagsResult> linthraTagsRead(
  Pointer<Uint8> path,
  int pathLength,
  bool withCover,
);

@Native<Uint8 Function(Pointer<LinthraTagsResult>)>(
  symbol: 'linthra_tags_status',
  isLeaf: true,
)
external int linthraTagsStatus(Pointer<LinthraTagsResult> result);

@Native<
    Pointer<Uint8> Function(Pointer<LinthraTagsResult>, Uint8, Pointer<Size>)>(
  symbol: 'linthra_tags_text',
  isLeaf: true,
)
external Pointer<Uint8> linthraTagsText(
  Pointer<LinthraTagsResult> result,
  int field,
  Pointer<Size> length,
);

@Native<Int64 Function(Pointer<LinthraTagsResult>)>(
  symbol: 'linthra_tags_track_number',
  isLeaf: true,
)
external int linthraTagsTrackNumber(Pointer<LinthraTagsResult> result);

@Native<Int64 Function(Pointer<LinthraTagsResult>)>(
  symbol: 'linthra_tags_duration_micros',
  isLeaf: true,
)
external int linthraTagsDurationMicros(Pointer<LinthraTagsResult> result);

@Native<Pointer<Uint8> Function(Pointer<LinthraTagsResult>, Pointer<Size>)>(
  symbol: 'linthra_tags_cover',
  isLeaf: true,
)
external Pointer<Uint8> linthraTagsCover(
  Pointer<LinthraTagsResult> result,
  Pointer<Size> length,
);

@Native<Void Function(Pointer<LinthraTagsResult>)>(
  symbol: 'linthra_tags_free',
  isLeaf: true,
)
external void linthraTagsFree(Pointer<LinthraTagsResult> result);

// The player's rules (native/linthra_core/src/ffi/playback_rules.rs). Codes
// are numbered like the Dart enums; 255 (or 0xFFFF) is a code Rust didn't know.

@Native<Uint8 Function(Pointer<Uint8>, Size)>(
  symbol: 'linthra_playback_classify_error',
  isLeaf: true,
)
external int linthraPlaybackClassifyError(Pointer<Uint8> text, int length);

@Native<Uint16 Function(Uint8)>(
  symbol: 'linthra_playback_failure_for_resolution',
  isLeaf: true,
)
external int linthraPlaybackFailureForResolution(int kind);

@Native<Uint16 Function(Uint8)>(
  symbol: 'linthra_playback_failure_for_interruption',
  isLeaf: true,
)
external int linthraPlaybackFailureForInterruption(int kind);

@Native<
    Uint8 Function(Uint8, Uint32, Bool, Uint8, Uint64, Uint64, Uint64, Uint32,
        Pointer<Uint64>)>(
  symbol: 'linthra_playback_recovery_decide',
  isLeaf: true,
)
external int linthraPlaybackRecoveryDecide(
  int kind,
  int failuresBefore,
  bool retrySpent,
  int next,
  int retryDelayMs,
  int advanceDelayMs,
  int maxAdvanceDelayMs,
  int maxConsecutiveFailures,
  Pointer<Uint64> delayMs,
);

@Native<Uint8 Function(Bool, Uint8)>(
  symbol: 'linthra_playback_focus_action',
  isLeaf: true,
)
external int linthraPlaybackFocusAction(bool begin, int interruption);

@Native<
    Uint16 Function(Uint8, Uint8, Uint8, Pointer<Uint8>, Size, Pointer<Size>)>(
  symbol: 'linthra_audio_focus_step',
  isLeaf: true,
)
external int linthraAudioFocusStep(
  int state,
  int event,
  int context,
  Pointer<Uint8> steps,
  int capacity,
  Pointer<Size> count,
);

// Stream recovery (native/linthra_core/src/ffi/stream_recovery.rs). Times are
// microseconds; a missing last position is the smallest Int64.

@Native<Bool Function(Uint32, Uint32, Bool)>(
  symbol: 'linthra_reconnect_claim',
  isLeaf: true,
)
external bool linthraReconnectClaim(int spent, int max, bool retryable);

@Native<
    Uint8 Function(Uint32, Pointer<Int64>, Pointer<Int64>, Int64, Bool,
        Int64)>(symbol: 'linthra_reconnect_progress', isLeaf: true)
external int linthraReconnectProgress(
  int spent,
  Pointer<Int64> playedUs,
  Pointer<Int64> lastUs,
  int positionUs,
  bool counting,
  int refillAfterUs,
);

@Native<Uint8 Function(Uint8, Bool, Bool, Uint8, Int64, Int64)>(
  symbol: 'linthra_source_end',
  isLeaf: true,
)
external int linthraSourceEnd(int gone, bool engineReportsFailureAsIdle,
    bool stream, int status, int positionUs, int durationUs);

@Native<Uint8 Function(Uint8, Uint8, Bool)>(
  symbol: 'linthra_watchdog_arms',
  isLeaf: true,
)
external int linthraWatchdogArms(int reported, int current, bool hasPlayed);

@Native<Uint8 Function(Uint8, Bool, Bool)>(
  symbol: 'linthra_watchdog_fails',
  isLeaf: true,
)
external int linthraWatchdogFails(
    int current, bool recoveryUnderway, bool hasTrack);

/// `UnifyResult` on the Rust side (native/linthra_core/src/ffi/track_unifier.rs).
final class LinthraUnifyResult extends Opaque {}

@Native<
    Pointer<LinthraUnifyResult> Function(
        Pointer<Uint8>,
        Size,
        Pointer<Uint32>,
        Pointer<Uint32>,
        Pointer<Uint32>,
        Pointer<Int64>,
        Pointer<Int64>,
        Size)>(symbol: 'linthra_unify_tracks')
external Pointer<LinthraUnifyResult> linthraUnifyTracks(
  Pointer<Uint8> text,
  int textLength,
  Pointer<Uint32> spans,
  Pointer<Uint32> sources,
  Pointer<Uint32> ranks,
  Pointer<Int64> durations,
  Pointer<Int64> trackNumbers,
  int count,
);

@Native<Size Function(Pointer<LinthraUnifyResult>)>(
  symbol: 'linthra_unify_rows',
  isLeaf: true,
)
external int linthraUnifyRows(Pointer<LinthraUnifyResult> result);

@Native<Pointer<Uint32> Function(Pointer<LinthraUnifyResult>)>(
  symbol: 'linthra_unify_starts',
  isLeaf: true,
)
external Pointer<Uint32> linthraUnifyStarts(Pointer<LinthraUnifyResult> result);

@Native<Pointer<Uint32> Function(Pointer<LinthraUnifyResult>)>(
  symbol: 'linthra_unify_indices',
  isLeaf: true,
)
external Pointer<Uint32> linthraUnifyIndices(
    Pointer<LinthraUnifyResult> result);

@Native<Void Function(Pointer<LinthraUnifyResult>)>(
  symbol: 'linthra_unify_free',
  isLeaf: true,
)
external void linthraUnifyFree(Pointer<LinthraUnifyResult> result);

/// `Sorted` on the Rust side (native/linthra_core/src/ffi/song_sort.rs).
final class LinthraSongSort extends Opaque {}

@Native<
    Pointer<LinthraSongSort> Function(
        Pointer<Uint8>,
        Size,
        Pointer<Uint32>,
        Pointer<Int64>,
        Pointer<Int64>,
        Pointer<Int64>,
        Size,
        Size,
        Uint8,
        Bool)>(symbol: 'linthra_song_sort')
external Pointer<LinthraSongSort> linthraSongSort(
  Pointer<Uint8> text,
  int textLength,
  Pointer<Uint32> spans,
  Pointer<Int64> discs,
  Pointer<Int64> tracks,
  Pointer<Int64> added,
  int count,
  int catalogCount,
  int field,
  bool descending,
);

@Native<Pointer<Uint32> Function(Pointer<LinthraSongSort>)>(
  symbol: 'linthra_song_sort_order',
  isLeaf: true,
)
external Pointer<Uint32> linthraSongSortOrder(Pointer<LinthraSongSort> result);

@Native<Pointer<Uint8> Function(Pointer<LinthraSongSort>)>(
  symbol: 'linthra_song_sort_sections',
  isLeaf: true,
)
external Pointer<Uint8> linthraSongSortSections(
    Pointer<LinthraSongSort> result);

@Native<Void Function(Pointer<LinthraSongSort>)>(
  symbol: 'linthra_song_sort_free',
  isLeaf: true,
)
external void linthraSongSortFree(Pointer<LinthraSongSort> result);

/// `ReconcileResult` on the Rust side
/// (native/linthra_core/src/ffi/local_reconcile.rs).
final class LinthraReconcileResult extends Opaque {}

// Not a leaf call: a scan reconciles the whole local catalog.
@Native<
    Pointer<LinthraReconcileResult> Function(
        Pointer<Uint8>,
        Size,
        Pointer<Uint32>,
        Pointer<Int64>,
        Pointer<Int64>,
        Pointer<Uint8>,
        Size,
        Size)>(symbol: 'linthra_local_reconcile')
external Pointer<LinthraReconcileResult> linthraLocalReconcile(
  Pointer<Uint8> text,
  int textLength,
  Pointer<Uint32> spans,
  Pointer<Int64> durations,
  Pointer<Int64> trackNumbers,
  Pointer<Uint8> refreshed,
  int previousCount,
  int count,
);

@Native<Size Function(Pointer<LinthraReconcileResult>)>(
  symbol: 'linthra_reconcile_move_count',
  isLeaf: true,
)
external int linthraReconcileMoveCount(Pointer<LinthraReconcileResult> result);

@Native<Pointer<Uint32> Function(Pointer<LinthraReconcileResult>)>(
  symbol: 'linthra_reconcile_moves',
  isLeaf: true,
)
external Pointer<Uint32> linthraReconcileMoves(
    Pointer<LinthraReconcileResult> result);

@Native<Size Function(Pointer<LinthraReconcileResult>)>(
  symbol: 'linthra_reconcile_removed_count',
  isLeaf: true,
)
external int linthraReconcileRemovedCount(
    Pointer<LinthraReconcileResult> result);

@Native<Pointer<Uint32> Function(Pointer<LinthraReconcileResult>)>(
  symbol: 'linthra_reconcile_removed',
  isLeaf: true,
)
external Pointer<Uint32> linthraReconcileRemoved(
    Pointer<LinthraReconcileResult> result);

@Native<Void Function(Pointer<LinthraReconcileResult>)>(
  symbol: 'linthra_reconcile_free',
  isLeaf: true,
)
external void linthraReconcileFree(Pointer<LinthraReconcileResult> result);

/// `CueText` on the Rust side (native/linthra_core/src/ffi/cue_sheet.rs).
final class LinthraCueText extends Opaque {}

/// `CueTracks` on the Rust side (native/linthra_core/src/ffi/cue_sheet.rs).
final class LinthraCueTracks extends Opaque {}

/// The field indices of [linthraCueField], as in
/// native/linthra_core/src/ffi/cue_sheet.rs.
abstract final class LinthraCueField {
  static const int file = 0;
  static const int title = 1;
  static const int performer = 2;
  static const int album = 3;
  static const int albumPerformer = 4;
}

@Native<Pointer<LinthraCueText> Function(Pointer<Uint8>, Size)>(
  symbol: 'linthra_cue_decode',
  isLeaf: true,
)
external Pointer<LinthraCueText> linthraCueDecode(
    Pointer<Uint8> bytes, int length);

@Native<Pointer<Uint16> Function(Pointer<LinthraCueText>, Pointer<Size>)>(
  symbol: 'linthra_cue_text',
  isLeaf: true,
)
external Pointer<Uint16> linthraCueText(
    Pointer<LinthraCueText> text, Pointer<Size> length);

@Native<Void Function(Pointer<LinthraCueText>)>(
  symbol: 'linthra_cue_text_free',
  isLeaf: true,
)
external void linthraCueTextFree(Pointer<LinthraCueText> text);

@Native<Pointer<LinthraCueTracks> Function(Pointer<Uint8>, Size)>(
  symbol: 'linthra_cue_parse',
  isLeaf: true,
)
external Pointer<LinthraCueTracks> linthraCueParse(
    Pointer<Uint8> text, int length);

@Native<Size Function(Pointer<LinthraCueTracks>)>(
  symbol: 'linthra_cue_track_count',
  isLeaf: true,
)
external int linthraCueTrackCount(Pointer<LinthraCueTracks> tracks);

@Native<Int64 Function(Pointer<LinthraCueTracks>, Size)>(
  symbol: 'linthra_cue_number',
  isLeaf: true,
)
external int linthraCueNumber(Pointer<LinthraCueTracks> tracks, int index);

@Native<Int64 Function(Pointer<LinthraCueTracks>, Size)>(
  symbol: 'linthra_cue_start_ms',
  isLeaf: true,
)
external int linthraCueStartMs(Pointer<LinthraCueTracks> tracks, int index);

@Native<
    Pointer<Uint8> Function(
        Pointer<LinthraCueTracks>, Size, Uint8, Pointer<Size>)>(
  symbol: 'linthra_cue_field',
  isLeaf: true,
)
external Pointer<Uint8> linthraCueField(
  Pointer<LinthraCueTracks> tracks,
  int index,
  int field,
  Pointer<Size> length,
);

@Native<Void Function(Pointer<LinthraCueTracks>)>(
  symbol: 'linthra_cue_tracks_free',
  isLeaf: true,
)
external void linthraCueTracksFree(Pointer<LinthraCueTracks> tracks);
