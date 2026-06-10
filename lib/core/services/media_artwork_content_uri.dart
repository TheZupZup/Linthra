import 'dart:io';

import 'package:path/path.dart' as p;

/// The FileProvider authority that serves Linthra's cached media-session cover
/// art. Must match `android:authorities` on the `<provider>` in
/// `android/app/src/main/AndroidManifest.xml` (and is fixed — independent of the
/// build's `applicationId` — so the authority is the same in debug and release).
const String kMediaArtworkAuthority =
    'io.github.thezupzup.linthra.mediaartwork';

/// The `<paths>` name (`res/xml/media_artwork_paths.xml`) the cover cache dir is
/// exposed under. The first path segment of every served `content://` URI.
const String kMediaArtworkPathName = 'media_artwork';

/// The credential-free `content://` URI Linthra's FileProvider serves [file] at.
///
/// Why `content://` and not the `file:` path: the platform media session loads
/// `MediaItem.artUri` **in its own process** (e.g. Android Auto), which can't
/// read an app-private `file:` path. A FileProvider `content://` URI can be read
/// by the platform/Android Auto, and `audio_service` also decodes it in-process
/// for the session's embedded album-art bitmap.
///
/// Privacy: the path is only the provider name plus the file's **hashed**
/// basename (a SHA-256 of the credential-free `subsonic-cover:` reference) — it
/// carries no username, password, token, salt, server URL, or auth query. The
/// matching `<cache-path>` maps the private cover-cache dir, so nothing else is
/// exposed.
Uri mediaArtworkContentUri(File file) => Uri(
      scheme: 'content',
      host: kMediaArtworkAuthority,
      pathSegments: <String>[kMediaArtworkPathName, p.basename(file.path)],
    );
