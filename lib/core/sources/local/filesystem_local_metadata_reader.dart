import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:flutter/foundation.dart';

import '../../models/local_file_stamp.dart';
import '../../services/local_artwork_cache.dart';
import 'local_audio_metadata.dart';
import 'local_metadata_reader.dart';
import 'mp4_box_guard.dart';
import 'vorbis_comment_fields.dart';

/// Reads audio tags — and embedded cover art — from a real file on disk: the
/// desktop/Linux half of [LocalMetadataReader], where Android's SAF walk reads
/// both natively.
///
/// Without this, a Linux library shows filenames and folder names: the mapper's
/// fallback is deliberately decent, but "03 - Track.flac" in a folder called
/// "Album" is not the same as a real title, artist, duration and cover. This is
/// what makes a local Linux library look like a library (#407, #408).
///
/// It reads through `audio_metadata_reader` (MIT, pure Dart), on an isolate of
/// its own (see [_parseStoppably]), which opens the
/// file and parses only the tag structures (headers, frames, comment blocks)
/// rather than reading a whole 60 MB FLAC into memory to find its title. Cover
/// art is fetched (`getImage: true`) only on a cache miss — [_artworkCache] is
/// consulted first, so a file whose cover was already extracted on an earlier
/// scan costs exactly what a tags-only read costs; pulling the embedded
/// picture back out of a parse nobody needs is exactly the cost that skips.
///
/// Deliberately total, like the SAF reader it mirrors: an unreadable file, an
/// unsupported container, a truncated tag, a format the package has no parser
/// for, or an MP4 whose boxes would send the parser into a loop
/// ([Mp4BoxGuard]) all return `null`, so the track still appears with its
/// filename-derived metadata instead of vanishing from the library.
class FilesystemLocalMetadataReader
    implements
        LocalMetadataReader,
        LocalMetadataReadOutcomes,
        LocalArtworkMaintainer,
        LocalArtworkInventory {
  FilesystemLocalMetadataReader({
    LocalArtworkCache? artworkCache,
    Duration parseLimit = const Duration(seconds: 10),
    @visibleForTesting
    bool Function(File file) guard = Mp4BoxGuard.isSafeToParse,
  })  : _artworkCache = artworkCache ?? LocalArtworkCache(),
        _parseLimit = parseLimit,
        _guard = guard;

  final LocalArtworkCache _artworkCache;

  /// How long a tag parse may run on its own isolate before it is taken for a
  /// parser loop and stopped. A healthy file takes milliseconds, even on a
  /// slow drive; this only has to tell "slow" from "never".
  final Duration _parseLimit;

  /// The check that refuses a file the MP4 parser would loop on, run on the
  /// parse's isolate right before the parse. [Mp4BoxGuard.isSafeToParse];
  /// replaceable only so a test can show a loop that gets past it is still
  /// stopped. Must be a top-level or static function, to cross to the
  /// isolate.
  final bool Function(File file) _guard;

  /// The isolate parses run on: started by the first read, kept for the next
  /// one, and replaced only after a parse runs past [_parseLimit] or the
  /// isolate dies (see [_ParserIsolate]).
  _ParserIsolate? _parser;

  /// The last parse handed to [_parser]. Parses run one at a time, each after
  /// the one before, so a parse's [_parseLimit] counts its own time on the
  /// isolate, never time spent queued behind another file.
  Future<void> _lastParse = Future<void>.value();

  int _parsersStarted = 0;

  /// How many parser isolates this reader has started: one for a whole scan,
  /// plus one for each parse that had to be stopped.
  @visibleForTesting
  int get parsersStarted => _parsersStarted;

  /// Stops the parser isolate once the parse in progress, if any, is done. A
  /// read after this starts another.
  Future<void> close() {
    final Future<void> closed = _lastParse.then((_) {
      _parser?.stop();
      _parser = null;
    });
    _lastParse = closed;
    return closed;
  }

  @override
  Future<void> retainArtwork(Set<Uri> live) => _artworkCache.retainOnly(live);

  @override
  Future<Set<Uri>> missingArtwork(Set<Uri> referenced) =>
      _artworkCache.missing(referenced);

  @override
  Future<LocalAudioMetadata?> readFromPath(String path) async =>
      (await readWithOutcome(path)).metadata;

  /// A read that came to nothing because the file could not be read: not a
  /// regular file (any more), a parse refused, thrown, stopped at its time
  /// limit or lost with its isolate, or an I/O error on the way.
  static const LocalMetadataRead _failed = (metadata: null, failed: true);

  @override
  Future<LocalMetadataRead> readWithOutcome(String path) async {
    try {
      final File file = File(path);
      // `await`, and an asynchronous `stat()` rather than `statSync()`, is
      // load-bearing: for a missing file or a directory it is the only point
      // in this method that reaches the event loop (a parse does too, by
      // waiting on the parser isolate). Without a real asynchronous call
      // there, this method would do all its work before returning an
      // already-completed Future. A caller awaiting that gets a
      // microtask, and the microtask queue drains completely before the event
      // loop runs again, so a scan of thousands of files would be one
      // unbroken chain with no frame rendered and no input handled from the
      // first file to the last. Measured on a 2000-iteration stand-in: zero
      // event-loop ticks with the synchronous check, one per file with this.
      // Switching this back to a synchronous check re-freezes the desktop UI
      // for the length of the scan, silently (see the test that asserts the
      // yield).
      //
      // `stat` rather than `exists` because it is the same one syscall and
      // answers strictly more: whether this is a regular file (a *directory*
      // named `Album.mp3` used to read as "exists" and then fail deeper in),
      // and the size and mtime that identify which bytes any cached cover was
      // extracted from.
      final FileStat stat = await file.stat();
      if (stat.type != FileSystemEntityType.file) return _failed;
      final LocalFileStamp stamp = LocalFileStamp(
        sizeBytes: stat.size,
        modifiedAtMs: stat.modified.millisecondsSinceEpoch,
      );

      // A cover cached from an earlier scan needs no re-extraction: checking
      // first means a hit costs nothing beyond this stat, and only a genuine
      // miss asks the parser for the (possibly large) embedded picture. The
      // lookup is keyed by the stamp too, so a file re-tagged with new art
      // misses here and re-extracts rather than serving the cover from before
      // the edit.
      final File? cachedArtwork = await _artworkCache.cachedFile(path, stamp);
      final bool needsArtwork = cachedArtwork == null;

      final _Parsed? parsed =
          await _parseStoppably(path, getImage: needsArtwork);
      if (parsed == null) return _failed;
      if (parsed.rejected) {
        return await _flacInTheClear(file, cachedArtwork) ?? _failed;
      }
      final LocalAudioMetadata? parsedTags = parsed.tags;
      // FLAC's comment block is readable in the clear, so prefer the real
      // ARTIST/ALBUMARTIST over what the package merged. See
      // [VorbisCommentFields] for why no heuristic can substitute for this.
      final Map<String, List<String>>? vorbisFields =
          parsedTags == null ? null : await VorbisCommentFields.read(file);
      final LocalAudioMetadata textMetadata = parsedTags == null
          ? LocalAudioMetadata.empty
          : _withVorbisArtists(parsedTags, vorbisFields);

      Uri? artworkUri =
          cachedArtwork == null ? null : Uri.file(cachedArtwork.path);
      final TransferableTypedData? cover = parsed.cover;
      if (cover != null) {
        artworkUri = await _artworkCache.store(
          path,
          stamp,
          cover.materialize().asUint8List(),
        );
      }

      final LocalAudioMetadata result = LocalAudioMetadata(
        title: textMetadata.title,
        artist: textMetadata.artist,
        albumArtist: textMetadata.albumArtist,
        album: textMetadata.album,
        albumId: textMetadata.albumId,
        trackNumber: textMetadata.trackNumber,
        duration: textMetadata.duration,
        artworkUri: artworkUri,
      );
      // Read, and found nothing: a settled answer, unlike a failed read.
      return (metadata: result.isEmpty ? null : result, failed: false);
    } catch (_) {
      // Any failure is "no tags", never a failed scan. The path is not logged:
      // a user's file path is private data (see CONTRIBUTING, Privacy).
      return _failed;
    }
  }

  /// The file's tags, and its cover when [getImage] asks for it, parsed on
  /// the parser isolate; null for a file that is refused or fails to parse,
  /// and for one whose parse runs past [_parseLimit] (the isolate is killed
  /// then, and the next file gets a new one), so the track keeps its filename
  /// and the scan goes on.
  ///
  /// The package's MP4 parser loops forever, synchronously and without
  /// throwing, on some box layouts an interrupted encode leaves behind (see
  /// [Mp4BoxGuard]). Nothing on the isolate running it can end that, and any
  /// file can be one: the parser is picked by content, and a file still being
  /// written can become such an MP4 at any moment, between any check and the
  /// parse. So every parse runs where it can be stopped. The guard runs there
  /// too, right before the parse, so the files that are already broken are
  /// refused at once rather than waited out, and its walk (a few reads, or
  /// many for a file of tiny boxes) stays off this isolate as well.
  Future<_Parsed?> _parseStoppably(String path, {required bool getImage}) {
    final Future<_Parsed?> parsed =
        _lastParse.then((_) => _parseNext(path, getImage));
    _lastParse = parsed.then<void>((_) {}, onError: (Object _) {});
    return parsed;
  }

  Future<_Parsed?> _parseNext(String path, bool getImage) async {
    _ParserIsolate? parser = _parser;
    if (parser == null || !parser.isRunning) {
      parser = _parser = await _ParserIsolate.start(_guard, _parseLimit);
      _parsersStarted++;
    }
    return parser.parse(path, getImage, _parseLimit);
  }

  /// The parser isolate's entry point: hands back the port it listens on,
  /// then answers each request (a path, and whether to pull out the cover)
  /// with [_parse].
  static void _serve((SendPort, bool Function(File)) message) {
    final (SendPort replies, guard) = message;
    final RawReceivePort requests = RawReceivePort((Object? request) {
      final (String path, bool getImage) = request! as (String, bool);
      replies.send(_parse(path, getImage, guard));
    });
    replies.send(requests.sendPort);
  }

  /// One file's parse, on the parser isolate: [guard] first, then the tags,
  /// mapped here so only the few fields Linthra keeps cross back. Of the
  /// pictures, only the one picked as the cover crosses, as transferable
  /// bytes the reader takes over without copying them again. Null for a
  /// refused or failed file.
  static _Parsed? _parse(
    String path,
    bool getImage,
    bool Function(File file) guard,
  ) {
    final File file = File(path);
    try {
      if (!guard(file)) return null;
    } catch (_) {
      // The guard reads the file first, so this is the file that couldn't be
      // read (a drive or a share answering with an I/O error, a file gone):
      // nothing is known about its tags.
      return null;
    }
    try {
      // Format-specific rather than the package's unified `readMetadata`:
      // that one folds ID3's TPE2 (album artist) into a single `artist`
      // field, which would lose the distinction the catalog groups albums by.
      final Object tag = readAllMetadata(file, getImage: getImage);
      final Picture? cover = getImage ? _bestCover(_picturesOf(tag)) : null;
      return (
        tags: _fromParserTag(tag),
        cover: cover == null
            ? null
            : TransferableTypedData.fromList(<TypedData>[cover.bytes]),
        rejected: false,
      );
    } catch (_) {
      // The parser gave up on what it read, which one field it can't parse
      // is enough for (see [_flacInTheClear]).
      return (tags: null, cover: null, rejected: true);
    }
  }

  /// The embedded pictures a parsed container carries, regardless of which
  /// format-specific field they live under. Every format but MP4 collects them
  /// as `pictures`; MP4's `covr` atom is modeled as a single nullable picture.
  static List<Picture> _picturesOf(Object tag) => switch (tag) {
        Mp3Metadata() => tag.pictures,
        ApeMetadata() => tag.pictures,
        VorbisMetadata() => tag.pictures,
        RiffMetadata() => tag.pictures,
        Mp4Metadata() =>
          tag.picture == null ? const <Picture>[] : <Picture>[tag.picture!],
        _ => const <Picture>[],
      };

  /// The picture to treat as *the* cover, when a file carries more than one
  /// (a front cover alongside a back cover or a band photo, say): the one
  /// explicitly tagged as the front cover, or the first attached picture when
  /// none is.
  static Picture? _bestCover(List<Picture> pictures) {
    for (final Picture picture in pictures) {
      if (picture.pictureType == PictureType.coverFront) return picture;
    }
    return pictures.isEmpty ? null : pictures.first;
  }

  /// Replaces the artist fields with the file's real ones when the comment
  /// block could be read with its field names intact.
  ///
  /// [fields] is null for every non-FLAC container (and for an unreadable
  /// block), in which case [metadata] keeps whatever the package's merged list
  /// produced. Both fields join their values: the spec's way to write a joint
  /// credit is to repeat the field, and that is as true of an album credited to
  /// two artists as of a track. Keeping only the first would drop the rest of
  /// the credit and group the album under an incomplete name.
  static LocalAudioMetadata _withVorbisArtists(
    LocalAudioMetadata metadata,
    Map<String, List<String>>? fields,
  ) {
    if (fields == null) return metadata;
    final List<String> artists = _nonBlank(fields['ARTIST']);
    final List<String> albumArtists = _nonBlank(fields['ALBUMARTIST']);
    return LocalAudioMetadata(
      title: metadata.title,
      artist: artists.isEmpty ? null : artists.join(', '),
      albumArtist: albumArtists.isEmpty ? null : albumArtists.join(', '),
      album: metadata.album,
      albumId: metadata.albumId,
      trackNumber: metadata.trackNumber,
      duration: metadata.duration,
      artworkUri: metadata.artworkUri,
    );
  }

  /// What a FLAC the package gave up on still says in the clear: its
  /// comments and its length, and its cover only when one is cached already.
  /// The package fails the whole file over one field it can't parse (a
  /// TRACKNUMBER of `A1` on a vinyl rip, an empty `TRACKTOTAL=`, a comment
  /// with no `=`), which left the track named after its file for good, with
  /// no length. Null when this isn't a FLAC, or its comments can't be read
  /// either.
  static Future<LocalMetadataRead?> _flacInTheClear(
    File file,
    File? cachedArtwork,
  ) async {
    final Map<String, List<String>>? fields =
        await VorbisCommentFields.read(file);
    if (fields == null) return null;
    final List<String> artists = _nonBlank(fields['ARTIST']);
    final List<String> albumArtists = _nonBlank(fields['ALBUMARTIST']);
    final LocalAudioMetadata? tags = _metadata(
      title: _nonBlank(fields['TITLE']).firstOrNull,
      artist: artists.isEmpty ? null : artists.join(', '),
      albumArtist: albumArtists.isEmpty ? null : albumArtists.join(', '),
      album: _nonBlank(fields['ALBUM']).firstOrNull,
      trackNumber: _leadingNumber(fields['TRACKNUMBER']?.firstOrNull),
      duration: await FlacStreamInfo.duration(file),
    );
    if (tags == null || cachedArtwork == null) {
      return (metadata: tags, failed: false);
    }
    return (
      metadata: LocalAudioMetadata(
        title: tags.title,
        artist: tags.artist,
        albumArtist: tags.albumArtist,
        album: tags.album,
        trackNumber: tags.trackNumber,
        duration: tags.duration,
        artworkUri: Uri.file(cachedArtwork.path),
      ),
      failed: false,
    );
  }

  /// The number a track field starts with: `3` from `3` or `3/12`, and none
  /// from `A1`. A vinyl side's `A1` and `B1` are not both track 1: read that
  /// way, the album would play its sides interleaved.
  static int? _leadingNumber(String? value) {
    final RegExpMatch? match = RegExp(r'^\s*(\d+)').firstMatch(value ?? '');
    return match == null ? null : int.tryParse(match.group(1)!);
  }

  static List<String> _nonBlank(List<String>? values) => <String>[
        for (final String value in values ?? const <String>[])
          if (value.trim().isNotEmpty) value.trim(),
      ];

  /// The track artist from Vorbis's merged ARTIST/ALBUMARTIST list, or null
  /// when the entries disagree. Only OGG and Opus reach this: FLAC's real field
  /// names are read instead (see [VorbisCommentFields]).
  ///
  /// Vorbis comments carry no ordering requirement, and the package folds both
  /// tags into one list in file order, so `first` is whichever the tagger
  /// happened to write first. On a compilation (`ARTIST=Featured Guest`,
  /// `ALBUMARTIST=Various Artists`) that means the same file reports the
  /// performer or the compilation name depending on the tool that wrote it,
  /// verified against fixtures written both ways.
  ///
  /// The distinction only matters when the values actually differ. A normal
  /// album tags both with the same name, so the list is one repeated value and
  /// there is nothing to guess; that is the common case and it is answered
  /// exactly. When they disagree this returns null rather than a coin flip, and
  /// the mapper falls back to the filename and folder: absent beats wrong half
  /// the time. It cannot do better, because two distinct entries are equally
  /// consistent with a collaboration (two ARTIST fields) and a compilation
  /// (ARTIST plus ALBUMARTIST), the case FLAC no longer has to guess at.
  static String? _unambiguousArtist(List<String> merged) {
    final Set<String> distinct = <String>{
      for (final String value in merged)
        if (value.trim().isNotEmpty) value.trim(),
    };
    return distinct.length == 1 ? distinct.first : null;
  }

  /// Maps one parsed container to Linthra's source-agnostic holder.
  ///
  /// Only the fields the catalog can actually store are mapped. The package
  /// also exposes disc number, year and genre, which `Track` has nowhere to put
  /// today. Surfacing those needs a catalog/schema change, so they are left
  /// unread rather than parsed into a field nothing reads.
  ///
  /// Typed as [Object] on purpose: the package's common supertype (`ParserTag`)
  /// lives under `src/` and is not exported, and reaching into another
  /// package's private library to name it would be worse than matching the
  /// public container types directly.
  static LocalAudioMetadata? _fromParserTag(Object tag) {
    return switch (tag) {
      // ID3: TIT2 / TPE1 / TPE2 / TALB. The one format where the track artist
      // and the album artist are unambiguously separate.
      Mp3Metadata() => _metadata(
          title: tag.songName,
          artist: tag.leadPerformer,
          albumArtist: tag.bandOrOrchestra,
          album: tag.album,
          trackNumber: tag.trackNumber,
          duration: tag.duration,
        ),
      // APEv2 names its album artist outright.
      ApeMetadata() => _metadata(
          title: tag.title,
          artist: tag.artist,
          albumArtist: tag.albumArtist,
          album: tag.album,
          trackNumber: tag.trackNumber,
          duration: tag.duration,
        ),
      // Vorbis comments (FLAC, OGG, Opus). The package appends both ARTIST and
      // ALBUMARTIST to one list (`case 'ARTIST' || "ALBUMARTIST"`), discarding
      // which was which. The artist here is therefore provisional: for FLAC,
      // readFromPath replaces it (and fills the album artist) from the real
      // field names via [VorbisCommentFields]. OGG and Opus keep what
      // [_unambiguousArtist] can salvage and report no album artist, which lets
      // the mapper group on album + artist the same way the Subsonic source
      // handles a server with no trustworthy per-song album artist.
      VorbisMetadata() => _metadata(
          title: tag.title.firstOrNull,
          artist: _unambiguousArtist(tag.artist),
          album: tag.album.firstOrNull,
          trackNumber: tag.trackNumber.firstOrNull,
          duration: tag.duration,
        ),
      // iTunes-style atoms. The package does not read `aART`, so no album
      // artist.
      Mp4Metadata() => _metadata(
          title: tag.title,
          artist: tag.artist,
          album: tag.album,
          trackNumber: tag.trackNumber,
          duration: tag.duration,
        ),
      // RIFF INFO chunks (WAV), which have no album-artist concept at all.
      RiffMetadata() => _metadata(
          title: tag.title,
          artist: tag.artist,
          album: tag.album,
          trackNumber: tag.trackNumber,
          duration: tag.duration,
        ),
      _ => null,
    };
  }

  /// Builds the holder, or null when the file carried nothing usable.
  ///
  /// Blank and whitespace-only tags (common in files written by sloppy
  /// taggers) are normalized to absent here so the mapper's filename fallback wins
  /// instead of a track showing an empty title. A non-positive track number is
  /// meaningless as an index and folds to null the same way.
  static LocalAudioMetadata? _metadata({
    String? title,
    String? artist,
    String? albumArtist,
    String? album,
    int? trackNumber,
    Duration? duration,
  }) {
    final LocalAudioMetadata metadata = LocalAudioMetadata(
      title: _blankToNull(title),
      artist: _blankToNull(artist),
      albumArtist: _blankToNull(albumArtist),
      album: _blankToNull(album),
      trackNumber:
          (trackNumber != null && trackNumber > 0) ? trackNumber : null,
      duration:
          (duration != null && duration > Duration.zero) ? duration : null,
    );
    return metadata.isEmpty ? null : metadata;
  }

  static String? _blankToNull(String? value) {
    if (value == null) return null;
    final String trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
}

/// What a parse sends back: the file's tags, and the picture picked as its
/// cover when one was asked for and there is one. [rejected] when the parser
/// gave up on the file's contents, which it read.
typedef _Parsed = ({
  LocalAudioMetadata? tags,
  TransferableTypedData? cover,
  bool rejected,
});

/// The reply [_ParserIsolate] gets when its isolate is gone. Never a parse's
/// answer, which is a [_Parsed] or null.
const String _exited = 'exited';

/// The isolate a [FilesystemLocalMetadataReader] runs its parses on, one at a
/// time, kept from file to file so a scan starts one isolate rather than one
/// per file.
///
/// It is killed outright when a parse runs past its limit: a parser loop
/// never gives its isolate back to the event loop to hear anything gentler.
/// If it dies on its own, the read waiting on it is answered (with null) at
/// once, not when its limit runs out. Either way the reader starts a new one
/// for the next file.
final class _ParserIsolate {
  _ParserIsolate._(this._isolate, this._requests, this._inbox) {
    _inbox.handler = _receive;
  }

  final Isolate _isolate;
  final SendPort _requests;

  /// Where answers, and the exit notice, arrive. It doesn't keep the reader's
  /// isolate alive: an idle parser is no reason for anything to stay up.
  final RawReceivePort _inbox;

  Completer<Object?>? _answer;
  bool _running = true;

  bool get isRunning => _running;

  static Future<_ParserIsolate> start(
    bool Function(File file) guard,
    Duration limit,
  ) async {
    final Completer<Object?> hello = Completer<Object?>();
    final RawReceivePort inbox = RawReceivePort((Object? message) {
      if (!hello.isCompleted) hello.complete(message);
    })
      ..keepIsolateAlive = false;
    Isolate? isolate;
    try {
      // Started paused, so the exit listener is on before it can exit.
      isolate = await Isolate.spawn(
        FilesystemLocalMetadataReader._serve,
        (inbox.sendPort, guard),
        paused: true,
        debugName: 'tag parser',
      );
      isolate.addOnExitListener(inbox.sendPort, response: _exited);
      isolate.resume(isolate.pauseCapability!);
      final Object? requests =
          await hello.future.timeout(limit, onTimeout: () => null);
      if (requests is! SendPort) {
        throw StateError('the tag parser isolate did not start');
      }
      return _ParserIsolate._(isolate, requests, inbox);
    } catch (_) {
      isolate?.kill(priority: Isolate.immediate);
      inbox.close();
      rethrow;
    }
  }

  /// [path]'s parse, or null: refused or failed, run past [limit] (this
  /// isolate is stopped then), or this isolate died on it.
  Future<_Parsed?> parse(String path, bool getImage, Duration limit) async {
    final Completer<Object?> answer = _answer = Completer<Object?>();
    _requests.send((path, getImage));
    final Object? reply = await answer.future.timeout(
      limit,
      onTimeout: () {
        stop();
        return null;
      },
    );
    return reply is _Parsed ? reply : null;
  }

  void _receive(Object? message) {
    if (message == _exited) {
      _running = false;
      _inbox.close();
    }
    final Completer<Object?>? answer = _answer;
    _answer = null;
    answer?.complete(message);
  }

  /// Kills the isolate, answering a parse still waiting on it with null.
  void stop() {
    if (!_running) return;
    _running = false;
    _isolate.kill(priority: Isolate.immediate);
    _inbox.close();
    final Completer<Object?>? answer = _answer;
    _answer = null;
    answer?.complete(null);
  }
}
