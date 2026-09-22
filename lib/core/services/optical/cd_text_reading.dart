import 'package:flutter/foundation.dart';

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

/// The character code a block declares in its 0x8f record.
const int _cdTextCharsetIso8859_1 = 0x00;
const int _cdTextCharsetAscii = 0x01;

/// Repeats the previous item's text; CD-Text's way of not spending 12 bytes a
/// track saying the same artist 20 times.
const int _cdTextRepeatMarker = 0x09; // TAB

/// The most packs a conforming disc can carry: 8 blocks of at most 256.
const int _cdTextMaxPacks = 2048;

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
///  * a gap in the block's sequence numbers, which means a pack went missing
///    and every continuation after it would be joined to the wrong text;
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
CdTextMetadata cdTextFrom(Uint8List? response) {
  final List<_CdTextPack>? packs = _packsFrom(response);
  if (packs == null || packs.isEmpty) return CdTextMetadata.empty;

  final int charset = _blockCharset(packs);
  if (charset != _cdTextCharsetIso8859_1 && charset != _cdTextCharsetAscii) {
    // MS-JIS, or a code this decoder does not know. See the class docs.
    return CdTextMetadata.empty;
  }

  final Map<int, String>? titles =
      _textsFor(packs, cdTextTitlePackType, charset);
  final Map<int, String>? performers =
      _textsFor(packs, cdTextPerformerPackType, charset);
  // All or nothing: a pack whose header contradicts the stream means this
  // disc's CD-Text cannot be trusted, and a half-decoded answer is exactly
  // the kind of plausible-but-wrong metadata this decoder exists to refuse.
  if (titles == null || performers == null) return CdTextMetadata.empty;

  return CdTextMetadata(
    discTitle: titles.remove(0),
    discPerformer: performers.remove(0),
    trackTitles: Map<int, String>.unmodifiable(titles),
    trackPerformers: Map<int, String>.unmodifiable(performers),
  );
}

/// The block-0 packs of [response], in sequence order, or null when the
/// response is not one this decoder will trust.
List<_CdTextPack>? _packsFrom(Uint8List? response) {
  if (response == null || response.length < 4) return null;

  // The header's length field counts everything after itself, so the packs
  // end at `length + 2`. A drive that returned less than it promised is
  // trusted only as far as it actually delivered.
  final int declared = (response[0] << 8) | response[1];
  final int end =
      declared + 2 < response.length ? declared + 2 : response.length;
  final int payload = end - 4;
  if (payload <= 0) return null;
  if (payload % cdTextPackLength != 0) return null;

  final int count = payload ~/ cdTextPackLength;
  if (count > _cdTextMaxPacks) return null;

  final List<_CdTextPack> packs = <_CdTextPack>[];
  for (int i = 0; i < count; i++) {
    final int start = 4 + i * cdTextPackLength;
    final Uint8List bytes =
        Uint8List.sublistView(response, start, start + cdTextPackLength);
    // Block number and character-position indicator. Everything below is
    // judged for block 0 only: a Japanese release carrying MS-JIS in block 1,
    // or a corrupt pack in a language Linthra does not read, must not cost it
    // the English titles in block 0.
    final int indicator = bytes[3];
    if (((indicator >> 4) & 0x07) != 0) continue; // not block 0
    if (!_crcMatches(bytes)) return null;
    if ((indicator & 0x80) != 0) return null; // double-byte text
    packs.add(
      _CdTextPack(
        type: bytes[0],
        item: bytes[1],
        sequence: bytes[2],
        characterPosition: indicator & 0x0f,
        payload: Uint8List.sublistView(bytes, 4, 16),
      ),
    );
  }
  if (packs.isEmpty) return null;

  packs
      .sort((_CdTextPack a, _CdTextPack b) => a.sequence.compareTo(b.sequence));
  for (int i = 1; i < packs.length; i++) {
    // Sequence numbers are per block and count from the block's first pack.
    // A gap means a pack is missing, and a missing pack silently joins the end
    // of one title to the start of another.
    if (packs[i].sequence != packs[i - 1].sequence + 1) return null;
  }
  return packs;
}

/// The character code block 0 declares, or [_cdTextCharsetIso8859_1] when it
/// declares none.
///
/// The declaration lives in the first of the three 0x8f packs, whose payload
/// starts the block's 36-byte size record. A disc with no 0x8f pack at all is
/// out of spec but common enough on burnt discs; ISO-8859-1 is what those
/// discs are in practice, and it is also the only assumption that leaves plain
/// ASCII text correct.
int _blockCharset(List<_CdTextPack> packs) {
  for (final _CdTextPack pack in packs) {
    if (pack.type == cdTextBlockSizePackType && pack.item == 0) {
      return pack.payload[0];
    }
  }
  return _cdTextCharsetIso8859_1;
}

/// The strings of one pack type, keyed by the item they belong to: 0 for the
/// disc, 1-99 for tracks.
///
/// A text may run across several packs and several texts may share one, so the
/// payloads of every pack of this type are concatenated and then split on the
/// NUL that terminates each string. The item number of the first pack says
/// which item the first string belongs to, and each NUL moves on to the next.
///
/// Trailing bytes with no NUL after them are dropped: an unterminated string
/// is a string the disc did not finish writing, and half a title is not a
/// title.
///
/// Returns null — which costs the disc all of its CD-Text — when a pack's own
/// item byte disagrees with the item the NUL count says it begins inside.
/// Those two are the disc telling us the same thing twice, so a disagreement
/// means one of them is wrong and there is no way to know which. Believing the
/// count alone would attach a real title to the wrong track, which is worse
/// than the fallback: `Track 04` is obviously a placeholder, and the name of
/// track 5 sitting on track 4 is not.
Map<int, String>? _textsFor(
  List<_CdTextPack> packs,
  int packType,
  int charset,
) {
  final List<_CdTextPack> ofType = packs
      .where((_CdTextPack pack) => pack.type == packType)
      .toList(growable: false);
  if (ofType.isEmpty) return <int, String>{};

  final Map<int, String> texts = <int, String>{};
  int item = ofType.first.item;
  String? previous;
  final List<int> buffer = <int>[];

  for (final _CdTextPack pack in ofType) {
    // Two independent headers, both describing where this pack sits in the
    // stream, and the running state says the same thing twice over. They have
    // to agree: the item byte pins which text this pack continues, and the
    // character position pins how far into that text it starts. A pack that
    // contradicts either is a stream that cannot be reassembled with any
    // confidence about what belongs where.
    if (pack.item != item) return null;
    if (pack.characterPosition != (buffer.length < 15 ? buffer.length : 15)) {
      return null;
    }
    for (final int byte in pack.payload) {
      if (byte != 0) {
        buffer.add(byte);
        continue;
      }
      if (item > 99) return texts;
      final String? text = _decode(buffer, charset, previous);
      if (text != null && text.isNotEmpty) texts[item] = text;
      // Every terminated item moves the repeat state, blank ones included. A
      // TAB means "the same as the item immediately before this one", so after
      // a blank item it has to repeat the blank — leaving `previous` on the
      // last *named* item would put that name on a track the disc left empty,
      // two tracks further down.
      previous = text != null && text.isNotEmpty ? text : null;
      buffer.clear();
      item++;
    }
  }
  return texts;
}

/// One CD-Text string: [bytes] in [charset], with the repeat marker resolved.
///
/// A single TAB means "the same as the item immediately before this one",
/// which is how a compilation avoids spending a pack per track repeating one
/// performer. After an item the disc left blank it repeats the blank, not the
/// last name seen.
/// Returns null when the bytes are not text this decoder will hand on — an
/// ASCII block carrying a byte above 0x7f is claiming a character it does not
/// have.
String? _decode(List<int> bytes, int charset, String? previous) {
  if (bytes.length == 1 && bytes.first == _cdTextRepeatMarker) return previous;
  if (bytes.isEmpty) return null;
  if (charset == _cdTextCharsetAscii && bytes.any((int byte) => byte > 0x7f)) {
    return null;
  }
  // Both supported character codes map byte-for-byte onto the first 256 code
  // points, which is what `String.fromCharCodes` does.
  return String.fromCharCodes(bytes).trim();
}

/// Whether a pack's stored CRC matches the one its bytes produce.
///
/// CD-Text uses CRC-16/CCITT over the first sixteen bytes with the result
/// inverted, stored big-endian. A stored value of zero means the drive (or the
/// mastering software) left the field blank, which is common and is not a
/// mismatch — treating it as one would throw away the CD-Text of a good many
/// real discs.
bool _crcMatches(Uint8List pack) {
  final int stored = (pack[16] << 8) | pack[17];
  if (stored == 0) return true;
  return stored == cdTextPackCrc(pack);
}

/// CRC-16/CCITT (polynomial 0x1021, zero seed) over the first sixteen bytes of
/// [pack], inverted — the value CD-Text stores in a pack's last two bytes.
@visibleForTesting
int cdTextPackCrc(Uint8List pack) {
  int crc = 0;
  for (int i = 0; i < 16; i++) {
    crc ^= pack[i] << 8;
    for (int bit = 0; bit < 8; bit++) {
      crc = (crc & 0x8000) != 0 ? ((crc << 1) ^ 0x1021) : (crc << 1);
      crc &= 0xffff;
    }
  }
  return crc ^ 0xffff;
}

/// One decoded CD-Text pack header plus its payload.
@immutable
class _CdTextPack {
  const _CdTextPack({
    required this.type,
    required this.item,
    required this.sequence,
    required this.characterPosition,
    required this.payload,
  });

  final int type;

  /// The track number the pack's first text belongs to; 0 means the disc.
  final int item;

  /// The block's running pack counter.
  final int sequence;

  /// How many characters of the text this pack starts inside were carried in
  /// from earlier packs, saturating at 15 — which also stands for "this text
  /// began further back than the previous pack".
  final int characterPosition;

  /// The pack's twelve text bytes.
  final Uint8List payload;
}
