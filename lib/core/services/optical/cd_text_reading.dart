import 'package:flutter/foundation.dart';

import '../../native/native_optical.dart';

/// The CD-Text a disc actually carries — never more.
///
/// Every field is optional and an absent field stays absent: there is no
/// "Unknown Artist" in here, and no track title invented from a number. The
/// fallbacks live in [AudioCdTrack.displayTitle] and [AudioCdDisc.displayTitle]
/// so that a caller which needs to know whether the *disc* named something can
/// still tell.
@immutable
class CdTextMetadata {
  /// Takes a copy of both maps, for the reason [RawCdToc] copies its bytes:
  /// they decide this value's equality *and* its [hashCode], so a caller that
  /// kept the map it passed in could move an already-published value while it
  /// sits in a hash set. That copy is also why this constructor is not
  /// `const` — a `const` one cannot defend itself.
  CdTextMetadata({
    this.discTitle,
    this.discPerformer,
    Map<int, String> trackTitles = const <int, String>{},
    Map<int, String> trackPerformers = const <int, String>{},
  })  : trackTitles = Map<int, String>.unmodifiable(trackTitles),
        trackPerformers = Map<int, String>.unmodifiable(trackPerformers);

  /// No CD-Text at all: what an ordinary disc pressed before 1996, a burnt
  /// CD-R, or a drive that cannot read the lead-in comes back as.
  static final CdTextMetadata empty = CdTextMetadata();

  final String? discTitle;
  final String? discPerformer;

  /// Titles and performers by track number. Sparse: a disc that named only
  /// some of its tracks has only those keys, which is a partial answer rather
  /// than a broken one.
  final Map<int, String> trackTitles;
  final Map<int, String> trackPerformers;

  bool get isEmpty =>
      discTitle == null &&
      discPerformer == null &&
      trackTitles.isEmpty &&
      trackPerformers.isEmpty;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is CdTextMetadata &&
          other.discTitle == discTitle &&
          other.discPerformer == discPerformer &&
          mapEquals(other.trackTitles, trackTitles) &&
          mapEquals(other.trackPerformers, trackPerformers));

  /// Unordered over the maps, because [mapEquals] is: two metadata values
  /// holding the same track titles are equal however their maps were built,
  /// so they have to hash the same or a `HashSet` would hold both.
  @override
  int get hashCode => Object.hash(
        discTitle,
        discPerformer,
        Object.hashAllUnordered(trackTitles.entries.map(_entryHash)),
        Object.hashAllUnordered(trackPerformers.entries.map(_entryHash)),
      );

  static int _entryHash(MapEntry<int, String> entry) =>
      Object.hash(entry.key, entry.value);

  @override
  String toString() => 'CdTextMetadata(${isEmpty ? 'empty' : 'present'})';
}

/// CD-Text pack types. Only two of the thirteen are read.
///
/// The others are songwriters, composers, arrangers, a free-text message area,
/// a catalog number, a genre code, a copy of the table of contents and an ISRC
/// list. None of them is a title or a performer, so none of them is decoded:
/// a disc's "message area" is free text a masterer typed, and putting it in
/// front of a listener as metadata is how a track ends up called
/// "THANKS FOR BUYING THIS CD".
const int cdTextTitlePackType = 0x80;
const int cdTextPerformerPackType = 0x81;
const int cdTextBlockSizePackType = 0x8f;

/// The size of one CD-Text pack: 4 header bytes, 12 payload bytes, 2 CRC.
const int cdTextPackLength = 18;

/// Decodes the drive's raw answer to a CD-Text read.
///
/// [response] is the reply to an MMC `READ TOC/PMA/ATIP` in format 0101b: a
/// four-byte header whose first two bytes are the length of everything after
/// them, then a run of 18-byte packs.
///
/// ## Nothing is guessed
///
/// This returns [CdTextMetadata.empty] — which makes the whole disc fall back
/// to `Audio CD` / `Track 01` — rather than a partial or repaired answer
/// whenever it cannot be *sure*:
///
///  * a truncated header, or a byte count that is not a whole number of packs;
///  * a pack whose CRC does not match (a CRC of zero is treated as "the drive
///    did not fill it in", which many do, rather than as a mismatch);
///  * a gap in the block's sequence numbers, or a first pack numbered anything
///    but zero, either of which means a pack went missing — and a missing pack
///    silently joins the end of one title to the start of another, or hides a
///    run of tracks the disc did name;
///  * a pack whose item byte disagrees with the item the NUL count places it
///    in, which would otherwise attach a real title to the wrong track, or
///    whose character position disagrees with how much text is already
///    carried, which would otherwise splice one title into the middle of
///    another;
///  * double-byte text (MS-JIS), which Linthra has no decoder for. Rendering
///    those bytes as Latin-1 would produce mojibake that *looks* like
///    metadata, and a disc that honestly says "Track 01" is better than one
///    that confidently says "ï¾€ï½".
///
/// Non-ASCII single-byte text is fully supported: a block declaring
/// ISO-8859-1 decodes accented Latin text as the disc meant it.
///
/// ## Only the first block
///
/// A disc may carry the same text in up to eight languages. Linthra reads
/// block 0, the primary one, and ignores the rest: choosing between them means
/// matching the disc's language codes against the user's locale, which is a
/// feature with a UI attached and not something to do silently here.
///
/// Decoded by the Rust core (native/linthra_core/src/optical.rs).
CdTextMetadata cdTextFrom(Uint8List? response) {
  final NativeCdText native = NativeOptical.cdText(response);
  final Map<int, String> titles = <int, String>{
    for (final (int, String) t in native.titles) t.$1: t.$2,
  };
  final Map<int, String> performers = <int, String>{
    for (final (int, String) t in native.performers) t.$1: t.$2,
  };
  if (titles.isEmpty && performers.isEmpty) return CdTextMetadata.empty;
  return CdTextMetadata(
    discTitle: titles.remove(0),
    discPerformer: performers.remove(0),
    trackTitles: titles,
    trackPerformers: performers,
  );
}
