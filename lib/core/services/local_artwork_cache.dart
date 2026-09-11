import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/local_file_stamp.dart';

/// Persists a local file's embedded cover art (ID3 `APIC`, a FLAC `PICTURE`
/// block, an MP4 `covr` atom, …) into Linthra's private, OS-reclaimable cache
/// and hands back a `file:` URI that [Track.artworkUri] can point at directly
/// — [artworkImageProvider] already loads a `file:` URI straight off disk, so
/// nothing downstream needs to know this cover came from a local file's own
/// tags rather than a server.
///
/// Mirrors the Android SAF walk's own embedded-artwork cache
/// (`SafDocumentScanner.cacheEmbeddedArtwork`): extract once, key by a hash
/// (never the path itself, see [_key]) so a rescan reuses what an earlier one
/// already extracted, write through a temp sibling then rename so a crash
/// mid-write can never leave a half-written cover that fails to decode
/// forever, and treat every failure as "no artwork" rather than a failed scan
/// or a dropped track.
///
/// Distinct from [ArtworkDiskCache] (remote covers, keyed by URL, never
/// resized — a server already serves a sane size) and [MediaArtworkCache] (a
/// bounded copy of *whichever* cover for the platform media session): this is
/// the one path from a local file's own embedded picture to something
/// Linthra's UI can render.
///
/// ## Bounds
///
/// Two of them, because an embedded picture is unvalidated input in the mild
/// sense that nobody ever checked it: it is whatever bytes some tagger wrote
/// into a frame years ago.
///
///  * [_maxSourceBytes] caps what is worth decoding at all, so a malformed
///    picture frame claiming a preposterous length is dropped before it costs
///    a decode, a re-encode and a disk write.
///  * [_maxDimension] caps what reaches disk. An embedded scan can be a
///    multi-megapixel JPEG nobody asked to see at full resolution, and every
///    track row in a scrolling list would otherwise decode it in full just to
///    paint a thumbnail a hundred pixels wide.
///
/// The downsample never materialises the full-size bitmap: the dimensions come
/// from [ui.ImageDescriptor.encoded], which reads the header only, and the
/// decode itself is asked for the *target* size, so a 12000x12000 cover costs
/// a 1024 px bitmap rather than 576 MB of pixels.
class LocalArtworkCache {
  LocalArtworkCache({Future<Directory> Function()? directory})
      : _directory = directory ?? _defaultDirectory;

  final Future<Directory> Function() _directory;

  /// The long edge a cached cover is bounded to. Large enough for every
  /// surface Linthra renders a cover at, including the full-screen Now
  /// Playing background; small enough that a 4000x4000 embedded scan never
  /// sits in memory or on disk at full size just for a list thumbnail.
  static const int _maxDimension = 1024;

  /// The largest embedded picture worth decoding, in bytes.
  ///
  /// Deliberately generous rather than tight: a genuine lossless cover scan
  /// stored as PNG runs into the low tens of megabytes, and rejecting one
  /// would show a placeholder for a file that really does have art, which is
  /// the worse failure. What this rules out is the pathological end — a
  /// truncated or hostile frame whose declared length is nothing a cover could
  /// legitimately be — before it reaches the decoder.
  ///
  /// Peak cost for an accepted picture is therefore this plus one 1024 px
  /// bitmap (4 MB) plus its re-encode, once, for one file at a time; scans are
  /// sequential, so a large library never multiplies it.
  static const int _maxSourceBytes = 16 * 1024 * 1024;

  /// The extension every finished cache entry carries, and the only thing
  /// [retainOnly] will ever delete besides an abandoned [_tempSuffix] write.
  static const String _entrySuffix = '.img';

  /// The extension of an in-flight write, renamed onto [_entrySuffix] once the
  /// bytes are on disk.
  static const String _tempSuffix = '.tmp';

  /// The already-cached cover for the file at [path] as it currently looks on
  /// disk ([stamp]), or `null` on a miss — including a missing, empty, or
  /// otherwise unreadable cache entry, which is treated exactly like a miss so
  /// a later [store] regenerates it safely.
  ///
  /// A file whose size or mtime moved since its cover was extracted misses by
  /// construction (see [_key]), so a re-tagged album shows its *new* cover
  /// rather than the one cached before the edit.
  Future<File?> cachedFile(String path, LocalFileStamp stamp) async {
    final File file = await _fileFor(path, stamp);
    try {
      if (await file.length() > 0) return file;
    } on FileSystemException {
      // Missing, or an odd permissions error — either way, not a usable hit.
    }
    return null;
  }

  /// Bounds a just-extracted embedded picture's [bytes] and writes it to the
  /// private cache for the file at [path] as stamped by [stamp], returning a
  /// `file:` URI to it.
  ///
  /// Returns `null` — and writes nothing — when [bytes] is empty, larger than
  /// [_maxSourceBytes], or can't be decoded at all (a corrupt or unsupported
  /// embedded picture). Never throws: the caller's track keeps its text tags
  /// and simply renders the normal placeholder.
  Future<Uri?> store(String path, LocalFileStamp stamp, Uint8List bytes) async {
    if (bytes.isEmpty || bytes.length > _maxSourceBytes) return null;
    try {
      final Uint8List? bounded = await _bound(bytes);
      if (bounded == null) return null;
      final File file = await _fileFor(path, stamp);
      final Directory dir = file.parent;
      if (!await dir.exists()) await dir.create(recursive: true);
      // Temp sibling then rename: an interrupted write can never leave a
      // truncated cover that then fails to decode forever.
      final File tmp = File('${file.path}$_tempSuffix');
      await tmp.writeAsBytes(bounded, flush: true);
      await tmp.rename(file.path);
      return Uri.file(file.path);
    } catch (_) {
      return null;
    }
  }

  /// Deletes every cache entry [live] does not reference: the covers of files
  /// the library no longer holds (deleted, moved, or renamed) and the
  /// superseded entries of files that were re-tagged since.
  ///
  /// Without this the cache only ever grows. Every re-tag mints a new entry
  /// (the stamp is part of the key) and orphans the old one, and a library
  /// reorganised once a year would keep a cover for every path a track ever
  /// sat at.
  ///
  /// **Why this cannot touch the user's music.** It never leaves its own
  /// directory: the listing is non-recursive and `followLinks: false`, so a
  /// symlink planted in the cache is reported as a [Link] and skipped rather
  /// than followed to whatever it points at; and of what remains it deletes
  /// only plain files whose name ends in [_entrySuffix] or [_tempSuffix],
  /// neither of which is an audio extension. A source file is not reachable
  /// from here even in principle, which is the property worth having — the
  /// user's audio is read-only to all of Linthra, and a cache sweep is exactly
  /// where that would be easiest to get wrong.
  ///
  /// Abandoned `.tmp` writes are always swept: by construction they are never
  /// a finished cover, so the worst case is that a sweep racing a concurrent
  /// [store] costs that one cover a regeneration on the next scan.
  ///
  /// Never throws, and never gives up part-way: an entry that cannot be
  /// deleted (a permission change, a file that vanished under us) is skipped
  /// and the sweep continues.
  Future<void> retainOnly(Set<Uri> live) async {
    try {
      final Directory dir = await _directory();
      if (!await dir.exists()) return;
      final Set<String> keep = <String>{
        for (final Uri uri in live)
          if (uri.isScheme('file')) _canonical(uri.toFilePath()),
      };
      await for (final FileSystemEntity entity
          in dir.list(followLinks: false)) {
        // A Link (symlink) and a Directory are both skipped here: only a plain
        // file this cache itself wrote is ever a deletion candidate.
        if (entity is! File) continue;
        final String name = p.basename(entity.path);
        final bool isEntry = name.endsWith(_entrySuffix);
        final bool isTemp = name.endsWith(_tempSuffix);
        if (!isEntry && !isTemp) continue;
        if (isEntry && keep.contains(_canonical(entity.path))) continue;
        try {
          await entity.delete();
        } catch (_) {
          // Busy, vanished, or read-only. Nothing here is load-bearing.
        }
      }
    } catch (_) {
      // A cache that cannot be swept is a cache that grows, not a failed scan.
    }
  }

  Future<File> _fileFor(String path, LocalFileStamp stamp) async {
    final Directory dir = await _directory();
    return File(p.join(dir.path, '${_key(path, stamp)}$_entrySuffix'));
  }

  /// A stable, path-free cache key: the SHA-256 of the source file's path
  /// *together with the size and mtime it had when its cover was extracted*.
  ///
  /// **Why the path.** Two unrelated files can easily share a size and an
  /// mtime (see [LocalFileStamp], which says so outright), so the stamp alone
  /// would hand one track's cover to another. Hashing keeps a user's real file
  /// path (private — see CONTRIBUTING, Privacy) out of both the file name and
  /// the cache directory listing, mirroring the SHA-1-of-content-URI key the
  /// Android SAF walk uses for the same purpose.
  ///
  /// **Why the stamp.** It is what makes the entry describe *these bytes*
  /// rather than *this location*. A path-only key is wrong in both directions
  /// that matter: re-tag an album with new art and the old cover is served
  /// forever (the scan re-reads the file, finds a cache hit, and never looks
  /// at the new picture), and delete a track then drop a different one at the
  /// same path and it inherits the previous song's cover. Folding in the stamp
  /// turns both into an ordinary miss, and [retainOnly] reaps what they
  /// superseded.
  ///
  /// The cost is that a *moved* file re-extracts once at its new path. That is
  /// the right side to be wrong on: an extraction is cheap and self-correcting,
  /// a cover silently belonging to another song is neither.
  ///
  /// The three parts are joined with NUL, which cannot occur in a path, so no
  /// two distinct (path, size, mtime) triples can spell the same input.
  static String _key(String path, LocalFileStamp stamp) => sha256
      .convert(
        utf8.encode(
          '$path\u0000${stamp.sizeBytes}\u0000${stamp.modifiedAtMs}',
        ),
      )
      .toString();

  /// Compares cache paths the way the filesystem does, so an entry is not
  /// swept merely because the live URI spelled the same file differently.
  static String _canonical(String path) => p.canonicalize(path);

  /// Downsamples [bytes] to at most [_maxDimension] on its long edge,
  /// preserving aspect ratio, or returns it unchanged when already within
  /// bounds — a resize would only cost a decode/re-encode for no benefit.
  /// Returns `null` when the bytes can't be decoded as an image at all, so the
  /// caller never caches something nothing could ever render anyway.
  Future<Uint8List?> _bound(Uint8List bytes) async {
    ui.ImmutableBuffer? buffer;
    ui.ImageDescriptor? descriptor;
    ui.Image? image;
    try {
      buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      final int width = descriptor.width;
      final int height = descriptor.height;
      if (width <= _maxDimension && height <= _maxDimension) return bytes;

      final double scale = _maxDimension / (width > height ? width : height);
      final ui.Codec codec = await descriptor.instantiateCodec(
        targetWidth: (width * scale).round().clamp(1, width),
        targetHeight: (height * scale).round().clamp(1, height),
      );
      final ui.FrameInfo frame = await codec.getNextFrame();
      codec.dispose();
      image = frame.image;
      final ByteData? data =
          await image.toByteData(format: ui.ImageByteFormat.png);
      return data?.buffer.asUint8List();
    } catch (_) {
      return null;
    } finally {
      image?.dispose();
      descriptor?.dispose();
      buffer?.dispose();
    }
  }

  static Future<Directory> _defaultDirectory() async {
    final Directory base = await getApplicationCacheDirectory();
    return Directory(p.join(base.path, 'local_artwork_cache'));
  }
}
