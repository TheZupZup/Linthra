import 'dart:typed_data';

import 'package:linthra/core/services/optical/cd_text_reading.dart';
import 'package:linthra/core/services/optical/cdrom_toc_source.dart';

/// Builders for the two things a real drive hands back: a table of contents,
/// and the raw CD-Text bytes from a disc's lead-in.
///
/// Every test in this feature is driven from here rather than from hardware,
/// which is the whole reason the platform half was kept to "issue three ioctls
/// and pass the numbers on". Nothing in this file needs a drive, a disc or a
/// running engine.

/// One TOC entry.
RawCdTocTrack tocTrack(int number, int lba, {bool data = false}) =>
    RawCdTocTrack(
      number: number,
      startLba: lba,
      // 0x04 marks a data track; 0x00 is ordinary two-channel audio.
      control: data ? cdDataTrackControlFlag : 0x00,
    );

/// A table of contents from a list of `(number, lba)` starts and a lead-out.
RawCdToc tocOf({
  required List<RawCdTocTrack> tracks,
  required int leadOutLba,
  int? firstTrack,
  int? lastTrack,
  Uint8List? cdText,
}) =>
    RawCdToc(
      firstTrack: firstTrack ?? tracks.first.number,
      lastTrack: lastTrack ?? tracks.last.number,
      leadOutLba: leadOutLba,
      tracks: tracks,
      cdText: cdText,
    );

/// A seven-track audio CD, using the track offsets MusicBrainz's own disc-ID
/// worked example is built from.
///
/// Its offsets are quoted in the documentation as *absolute* frames (LBA plus
/// the 150-frame lead-in), so the LBAs here are those minus 150. Keeping the
/// same disc means Linthra's disc ID can be checked against a value computed
/// independently from the published algorithm.
RawCdToc sevenTrackAudioCd({Uint8List? cdText}) => tocOf(
      tracks: <RawCdTocTrack>[
        tocTrack(1, 0),
        tocTrack(2, 13959),
        tocTrack(3, 33436),
        tocTrack(4, 52927),
        tocTrack(5, 65631),
        tocTrack(6, 77742),
        tocTrack(7, 99024),
      ],
      leadOutLba: 114424,
      cdText: cdText,
    );

/// The same seven audio tracks plus a data session — a CD-Extra.
///
/// The data track starts 126 000 frames in, which is *not* where the audio
/// stops: the run-out, the second session's lead-in and its pre-gap sit in
/// between, so the music ends 11 400 frames earlier.
RawCdToc sevenTrackCdExtra({Uint8List? cdText}) => tocOf(
      tracks: <RawCdTocTrack>[
        tocTrack(1, 0),
        tocTrack(2, 13959),
        tocTrack(3, 33436),
        tocTrack(4, 52927),
        tocTrack(5, 65631),
        tocTrack(6, 77742),
        tocTrack(7, 99024),
        tocTrack(8, 126000, data: true),
      ],
      leadOutLba: 240000,
      cdText: cdText,
    );

/// A single-session mixed-mode disc: a data track 1 followed by audio.
///
/// The shape a 1990s game CD has, and the one that catches a track list which
/// assumes every physical track is music.
RawCdToc mixedModeCd() => tocOf(
      tracks: <RawCdTocTrack>[
        tocTrack(1, 0, data: true),
        tocTrack(2, 30000),
        tocTrack(3, 60000),
        tocTrack(4, 90000),
      ],
      leadOutLba: 120000,
    );

/// One audio track, start to lead-out.
RawCdToc singleTrackCd({int leadOutLba = 20000, Uint8List? cdText}) => tocOf(
      tracks: <RawCdTocTrack>[tocTrack(1, 0)],
      leadOutLba: leadOutLba,
      cdText: cdText,
    );

// --- CD-Text ---------------------------------------------------------------

/// Builds one 18-byte CD-Text pack.
///
/// [crc] defaults to zero, which is what a good many drives and mastering
/// tools actually write and which the decoder treats as "not filled in". Pass
/// a value to exercise the CRC check itself.
Uint8List cdTextPack({
  required int type,
  required int item,
  required int sequence,
  required List<int> payload,
  int block = 0,
  int characterPosition = 0,
  bool doubleByte = false,
  int crc = 0,
}) {
  assert(payload.length <= 12, 'a pack carries twelve payload bytes');
  final Uint8List pack = Uint8List(cdTextPackLength);
  pack[0] = type;
  pack[1] = item;
  pack[2] = sequence;
  pack[3] = (doubleByte ? 0x80 : 0x00) |
      ((block & 0x07) << 4) |
      (characterPosition & 0x0f);
  for (int i = 0; i < payload.length; i++) {
    pack[4 + i] = payload[i];
  }
  pack[16] = (crc >> 8) & 0xff;
  pack[17] = crc & 0xff;
  return pack;
}

/// Packs a run of NUL-terminated strings of one pack type, exactly as a disc
/// does: the payloads run on into each other, and a string may straddle packs.
///
/// [texts] is indexed from [startItem]: item 0 is the disc, 1-99 are tracks.
/// An empty string still costs its NUL, which is how a disc says "this one has
/// no title" without shifting everything after it.
List<Uint8List> cdTextPacksFor({
  required int type,
  required List<String> texts,
  int startItem = 0,
  int startSequence = 0,
  int block = 0,
  bool withCrc = false,
}) {
  final List<int> stream = <int>[];
  // Where each item's text begins in the stream, so a pack can be stamped with
  // the item it starts inside — which is what the decoder anchors on.
  final List<int> itemStarts = <int>[];
  for (final String text in texts) {
    itemStarts.add(stream.length);
    stream.addAll(text.codeUnits);
    stream.add(0);
  }

  final List<Uint8List> packs = <Uint8List>[];
  for (int offset = 0; offset < stream.length; offset += 12) {
    final int end = offset + 12 < stream.length ? offset + 12 : stream.length;
    final List<int> payload = stream.sublist(offset, end);
    int item = startItem;
    for (int i = 0; i < itemStarts.length; i++) {
      if (itemStarts[i] <= offset) item = startItem + i;
    }
    final Uint8List pack = cdTextPack(
      type: type,
      item: item,
      sequence: startSequence + packs.length,
      payload: payload,
      block: block,
    );
    packs.add(withCrc ? withPackCrc(pack) : pack);
  }
  return packs;
}

/// The same pack with a correct CRC written into its last two bytes.
Uint8List withPackCrc(Uint8List pack) {
  final int crc = cdTextPackCrc(pack);
  final Uint8List copy = Uint8List.fromList(pack);
  copy[16] = (crc >> 8) & 0xff;
  copy[17] = crc & 0xff;
  return copy;
}

/// The block-size record (`0x8f`) that declares a block's character code.
List<Uint8List> cdTextBlockSizePacks({
  required int charset,
  int firstTrack = 1,
  int lastTrack = 1,
  int startSequence = 0,
  int block = 0,
}) =>
    <Uint8List>[
      cdTextPack(
        type: cdTextBlockSizePackType,
        item: 0,
        sequence: startSequence,
        payload: <int>[charset, firstTrack, lastTrack, 0],
        block: block,
      ),
      cdTextPack(
        type: cdTextBlockSizePackType,
        item: 1,
        sequence: startSequence + 1,
        payload: const <int>[0],
        block: block,
      ),
      cdTextPack(
        type: cdTextBlockSizePackType,
        item: 2,
        sequence: startSequence + 2,
        payload: const <int>[0],
        block: block,
      ),
    ];

/// Wraps packs in the four-byte header a `READ TOC/PMA/ATIP` reply carries.
///
/// [declaredLength] overrides the header's own length field, which is how a
/// truncated or lying drive is reproduced.
Uint8List cdTextResponse(List<Uint8List> packs, {int? declaredLength}) {
  final int payload = packs.length * cdTextPackLength;
  final int declared = declaredLength ?? payload + 2;
  final Uint8List response = Uint8List(4 + payload);
  response[0] = (declared >> 8) & 0xff;
  response[1] = declared & 0xff;
  for (int i = 0; i < packs.length; i++) {
    response.setRange(
        4 + i * cdTextPackLength, 4 + (i + 1) * cdTextPackLength, packs[i]);
  }
  return response;
}

/// Renumbers a block's packs so their sequence bytes run 0, 1, 2, … .
///
/// A block's sequence counter is shared by every pack type in it, so a disc
/// that carries titles and then performers numbers them straight through. A
/// gap means a pack went missing, which the decoder refuses — so a fixture
/// that assembled two groups each starting at zero, or each starting at a
/// guess, would be testing the wrong thing.
List<Uint8List> cdTextBlockOf(List<List<Uint8List>> groups) {
  final List<Uint8List> packs = <Uint8List>[];
  for (final List<Uint8List> group in groups) {
    for (final Uint8List pack in group) {
      final Uint8List renumbered = Uint8List.fromList(pack);
      renumbered[2] = packs.length & 0xff;
      packs.add(renumbered);
    }
  }
  return packs;
}

/// The same, with each pack's CRC recomputed after renumbering.
List<Uint8List> cdTextBlockWithCrcOf(List<List<Uint8List>> groups) =>
    cdTextBlockOf(groups).map(withPackCrc).toList(growable: false);
