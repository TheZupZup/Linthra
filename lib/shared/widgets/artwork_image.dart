import 'dart:async';
import 'dart:io';

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
  return ResizeImage.resizeIfNeeded(
    decodeExtent,
    null,
    _rawArtworkImageProvider(uri),
  );
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
