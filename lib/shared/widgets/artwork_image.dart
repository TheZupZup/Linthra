import 'dart:io';

import 'package:flutter/widgets.dart';

/// Resolves an artwork [Uri] to the right [ImageProvider] — the app's single
/// artwork-resolver seam.
///
/// Every artwork render goes through here (track rows, album/artist tiles and
/// detail headers, the now-playing background and mini-player), so a local cover
/// and a server cover are treated identically by every surface.
///
/// - A `file:` URI is embedded cover art Linthra extracted from a local audio
///   file into its own private cache; it loads straight from disk with a
///   [FileImage].
/// - Anything else is a server's plain http(s) image URL (Jellyfin builds a
///   token-free primary-image URL), loaded with a [NetworkImage].
///
/// Sources with no cover at all — Subsonic, and untagged local files — carry a
/// null `artworkUri` and never reach here; the caller shows its placeholder. A
/// `file:` cover whose bytes are missing or undecodable (e.g. the OS reclaimed
/// the cache) fails the same way a broken network image does, so the caller's
/// `errorBuilder` falls back to the placeholder — never a broken-image glyph.
ImageProvider artworkImageProvider(Uri uri) {
  if (uri.isScheme('file')) {
    return FileImage(File(uri.toFilePath()));
  }
  return NetworkImage(uri.toString());
}
