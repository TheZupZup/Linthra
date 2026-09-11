import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../../core/services/artwork_disk_cache.dart';

/// Turns a credential-free artwork *reference* into a loadable URL at render
/// time, or returns `null` for a [reference] it doesn't own.
///
/// Some sources can't persist a ready-to-load cover URL because it would embed a
/// credential (Subsonic's `getCoverArt` carries the salt+token on every
/// request), and `artworkUri` is persisted in the catalog. Those sources store
/// an opaque reference instead; the resolver, installed once at startup with the
/// live session, weaves the credential in here — on demand, never persisted.
typedef ArtworkReferenceResolver = Uri? Function(Uri reference);

/// The app-level reference resolver, or `null` when none is installed (the
/// default in tests, where references simply fall through and fail to load —
/// degrading to the caller's placeholder, never a broken-image glyph).
ArtworkReferenceResolver? _referenceResolver;

/// Installs the app-level [ArtworkReferenceResolver] (see `main`). Passing
/// `null` clears it. Idempotent and global on purpose: [artworkImageProvider] is
/// the app's single artwork seam, called from plain widgets with no Riverpod
/// scope, so the resolution rule is taught to the seam once rather than threaded
/// through every call site.
void installArtworkReferenceResolver(ArtworkReferenceResolver? resolver) {
  _referenceResolver = resolver;
}

/// The app-level persistent artwork cache (see `main`), or `null` when none is
/// installed — the default in tests, and briefly at app startup before the
/// async install completes, where every render simply behaves exactly as it did
/// before this cache existed (a fresh [NetworkImage] each time).
ArtworkDiskCache? _diskCache;

/// Installs the app-level [ArtworkDiskCache] (see `main`). Passing `null`
/// clears it. Idempotent and global for the same reason as
/// [installArtworkReferenceResolver]: [artworkImageProvider] is a plain
/// function with no Riverpod scope, so the persistent-cache behaviour is taught
/// to the one seam rather than threaded through every call site.
void installArtworkDiskCache(ArtworkDiskCache? cache) {
  _diskCache = cache;
}

/// The most device pixels a cover is ever decoded across, per side.
///
/// Covers arrive at whatever size their source felt like: a server's original
/// scan, or the 1024 px bound Linthra's own local-artwork cache applies. At a
/// fractional or 2x scale factor, an unbounded decode of one of those into a
/// 48 px avatar costs the same memory and the same CPU as showing it
/// full-screen, once per visible row (#457).
///
/// Bounded here rather than per call site so no surface can forget. 1024
/// matches `LocalArtworkCache`'s own bound, which is sized for the largest
/// surface Linthra draws a cover on: the full-screen Now Playing backdrop.
const int maxArtworkDecodeExtent = 1024;

/// Floor for a decode bound, so an unmeasured or nearly-collapsed box can never
/// ask for a one-pixel cover that then has to be decoded again when it settles.
const int minArtworkDecodeExtent = 32;

/// Decode sizes are rounded up to a multiple of this.
///
/// The requested extent is part of the `ResizeImage` cache key, and
/// [AlbumArtwork] derives it from its own box. On a resizable window that box
/// changes with every resize event, so an exact extent would mint a fresh
/// cache key (and a fresh decode) for every width the window is dragged
/// through, which is the churn this bound exists to remove.
///
/// Rounding up to 32 device pixels caps that at 32 distinct decodes per image
/// across the whole range instead of hundreds, and costs at most 31 pixels of
/// over-decode on the covering axis. It also never rounds *down*, so a bucket
/// is never softer than the exact extent would have been.
const int artworkDecodeQuantum = 32;

/// The device-pixel extent to decode a cover at for a box [logicalExtent]
/// logical pixels across on a display of [devicePixelRatio].
///
/// This is the whole HiDPI story for artwork: the decode target follows the
/// *device* pixels the cover will actually occupy, so a 48 px avatar decodes at
/// 48 px at 100%, 84 px at 175% and 96 px at 200%: sharp at every scale,
/// without ever paying for the full-size image.
///
/// A non-finite or non-positive extent means the box has not been measured
/// (an unbounded constraint), and falls back to the maximum: guessing small
/// there would render a blurry cover rather than a large one.
int artworkDecodeExtentFor(double logicalExtent, double devicePixelRatio) {
  if (!logicalExtent.isFinite || logicalExtent <= 0) {
    return maxArtworkDecodeExtent;
  }
  if (!devicePixelRatio.isFinite || devicePixelRatio <= 0) {
    return maxArtworkDecodeExtent;
  }
  final int extent = (logicalExtent * devicePixelRatio).ceil();
  final int bucketed =
      (extent / artworkDecodeQuantum).ceil() * artworkDecodeQuantum;
  return bucketed.clamp(minArtworkDecodeExtent, maxArtworkDecodeExtent);
}

/// [artworkDecodeExtentFor] with the ratio read from [context].
int artworkDecodeExtent(BuildContext context, double logicalExtent) =>
    artworkDecodeExtentFor(
      logicalExtent,
      MediaQuery.devicePixelRatioOf(context),
    );

/// Resolves an artwork [uri] to the right [ImageProvider] — the app's single
/// artwork-resolver seam.
///
/// Every artwork render goes through here (track rows, album/artist tiles and
/// detail headers, the now-playing background and mini-player), so a local
/// cover, a server cover, and a credential-resolved cover are treated
/// identically by every surface.
///
/// - A `file:` URI is embedded cover art Linthra extracted from a local audio
///   file into its own private cache; it loads straight from disk with a
///   [FileImage].
/// - Anything else — a server's plain http(s) image URL (Jellyfin builds a
///   token-free primary-image URL), or a credential-free *reference* (e.g.
///   Subsonic's `subsonic-cover:<id>`) — is first checked against the installed
///   [ArtworkDiskCache] (issue #356): a hit loads straight from disk with a
///   [FileImage], no network at all. A miss is handed to the installed
///   [ArtworkReferenceResolver] (which weaves in the live session's auth to
///   produce a loadable URL for a reference, or returns `null` for an
///   already-loadable URL) and loaded with a [NetworkImage] exactly as before —
///   and, in the background, fetched once more and written to the disk cache so
///   the *next* render of the same cover is a hit.
///
/// Sources with no cover at all — an untagged local file, or a Subsonic item the
/// server reports no `coverArt` for — carry a null `artworkUri` and never reach
/// here; the caller shows its placeholder. A `file:` cover whose bytes are
/// missing or undecodable (e.g. the OS reclaimed the cache), an unresolved
/// reference (signed out), or a failed network fetch all fail the same way, so
/// the caller's `errorBuilder` falls back to the placeholder — never a
/// broken-image glyph.
///
/// [decodeExtent] bounds how large the image is decoded, in device pixels,
/// see [artworkDecodeExtent], which every caller should use to derive it from
/// the box it is about to draw into. Omitting it decodes at full size, which
/// is what the resolver tests want and what a caller that genuinely cannot know
/// its box gets; every surface in the app passes one.
ImageProvider artworkImageProvider(Uri uri, {int? decodeExtent}) {
  final ImageProvider raw = _rawArtworkImageProvider(uri);
  if (decodeExtent == null) {
    return raw;
  }
  return CoverResizeImage(raw, extent: decodeExtent);
}

/// Decodes an image for [BoxFit.cover] into a square of [extent] device pixels.
///
/// Every artwork surface draws with `BoxFit.cover`, and cover is satisfied by
/// the image's *shorter* side. `ResizeImage` cannot express that: given one
/// axis it derives the other from the aspect ratio, so a landscape source
/// constrained on width comes back too short and gets scaled back up, which is
/// a visibly soft cover (#626). Given both axes it either stretches the image
/// (`exact`) or fits it inside the box (`fit`), and neither is cover.
///
/// The decode callback is handed the source's intrinsic size before the codec
/// is instantiated, which is the piece `ResizeImage`'s public API cannot use
/// for this. So the scale is chosen from the shorter side:
///
/// ```
/// scale = extent / min(intrinsicWidth, intrinsicHeight)
/// ```
///
/// A square source therefore decodes exactly as it did before, and a
/// non-square one decodes to whatever makes its shorter side meet [extent],
/// with no extra memory for the common case.
///
/// Never upscales: a source already smaller than [extent] on its shorter side
/// is decoded untouched, so a small cover is not inflated in the image cache.
@immutable
class CoverResizeImage extends ImageProvider<CoverResizeImageKey> {
  const CoverResizeImage(this.imageProvider, {required this.extent});

  /// The provider that actually loads the bytes.
  final ImageProvider imageProvider;

  /// The device pixels the cover's shorter side must reach.
  final int extent;

  /// The target size for a source of [intrinsicWidth] x [intrinsicHeight].
  ///
  /// Separated out so the arithmetic is testable without decoding an image.
  @visibleForTesting
  ui.TargetImageSize targetSizeFor(int intrinsicWidth, int intrinsicHeight) {
    if (intrinsicWidth <= 0 || intrinsicHeight <= 0) {
      return const ui.TargetImageSize();
    }
    final int shortest = math.min(intrinsicWidth, intrinsicHeight);
    if (shortest <= extent) {
      // Already at or below the target on the covering axis. Decoding it
      // larger would be upscaling into the cache for nothing.
      return const ui.TargetImageSize();
    }
    final double scale = extent / shortest;
    return ui.TargetImageSize(
      width: math.max(1, (intrinsicWidth * scale).round()),
      height: math.max(1, (intrinsicHeight * scale).round()),
    );
  }

  @override
  ImageStreamCompleter loadImage(
    CoverResizeImageKey key,
    ImageDecoderCallback decode,
  ) {
    Future<ui.Codec> decodeCover(
      ui.ImmutableBuffer buffer, {
      ui.TargetImageSizeCallback? getTargetSize,
    }) {
      assert(
        getTargetSize == null,
        'CoverResizeImage cannot be composed with another ImageProvider that '
        'applies getTargetSize.',
      );
      return decode(buffer, getTargetSize: targetSizeFor);
    }

    return imageProvider.loadImage(key.providerCacheKey, decodeCover);
  }

  @override
  Future<CoverResizeImageKey> obtainKey(ImageConfiguration configuration) {
    // Mirrors ResizeImage.obtainKey: the wrapped provider's key is usually
    // available synchronously, and forcing it through a Completer would make
    // every artwork render take an extra frame.
    Completer<CoverResizeImageKey>? completer;
    SynchronousFuture<CoverResizeImageKey>? result;
    imageProvider.obtainKey(configuration).then((Object key) {
      if (completer == null) {
        result = SynchronousFuture<CoverResizeImageKey>(
          CoverResizeImageKey._(key, extent),
        );
      } else {
        completer.complete(CoverResizeImageKey._(key, extent));
      }
    });
    if (result != null) {
      return result!;
    }
    completer = Completer<CoverResizeImageKey>();
    return completer.future;
  }
}

/// The image-cache key for a [CoverResizeImage].
///
/// Carries the wrapped provider's key *and* the extent, so the same cover at
/// two different sizes is two cache entries and the same cover at the same
/// size is one. Getting this wrong does not fail loudly, it just silently
/// stops the image cache working, which is why it has its own tests.
@immutable
class CoverResizeImageKey {
  const CoverResizeImageKey._(this.providerCacheKey, this.extent);

  /// The key of the provider [CoverResizeImage] wraps.
  final Object providerCacheKey;

  /// The extent the image was decoded for.
  final int extent;

  @override
  bool operator ==(Object other) {
    if (other.runtimeType != runtimeType) {
      return false;
    }
    return other is CoverResizeImageKey &&
        other.providerCacheKey == providerCacheKey &&
        other.extent == extent;
  }

  @override
  int get hashCode => Object.hash(providerCacheKey, extent);

  @override
  String toString() =>
      'CoverResizeImageKey($providerCacheKey, extent: $extent)';
}

ImageProvider _rawArtworkImageProvider(Uri uri) {
  if (uri.isScheme('file')) {
    return FileImage(File(uri.toFilePath()));
  }
  final ArtworkDiskCache? cache = _diskCache;
  if (cache != null) {
    final File? cached = cache.cachedFile(uri);
    if (cached != null) return FileImage(cached);
    // A miss: warm the persistent cache in the background so a later render of
    // this same cover (this session or the next launch) is a hit. Fire-and-
    // forget and best-effort — never awaited, never blocks this render, and
    // never throws (see [ArtworkDiskCache.warm]).
    unawaited(cache.warm(uri));
  }
  final Uri? resolved = _referenceResolver?.call(uri);
  return NetworkImage((resolved ?? uri).toString());
}
