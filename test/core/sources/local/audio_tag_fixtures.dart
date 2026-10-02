import 'dart:convert';
import 'dart:typed_data';

/// Byte-level builders for small, real audio files carrying real tags.
///
/// The tag reader parses actual container structures, so testing it needs
/// actual containers. These build them from the format specs instead of
/// committing binary fixtures: a reviewer can see exactly which frame or
/// comment a test is claiming to write, and a fixture that drifts from the
/// spec fails the test rather than silently decoding to something else.
///
/// Each file is metadata plus the smallest plausible audio payload — a few
/// hundred bytes, not a real song.
abstract final class AudioTagFixtures {
  /// An MP3 carrying an ID3v2.3 tag.
  ///
  /// ID3v2.3 is the version practically every tagger writes. Frame layout is
  /// `TTTT` (id) + 4-byte big-endian size + 2 flag bytes + payload, and a text
  /// frame's payload starts with an encoding byte (`0x00` = ISO-8859-1). The
  /// tag's own size is *synchsafe*: 7 bits per byte, so a size byte can never
  /// look like an MPEG sync word.
  static Uint8List mp3({
    String? title,
    String? artist,
    String? albumArtist,
    String? album,
    String? track,
    Uint8List? coverImage,
    String coverMimeType = 'image/png',
  }) {
    final BytesBuilder frames = BytesBuilder();
    void frame(String id, String? value) {
      if (value == null) return;
      final List<int> text = <int>[0x00, ...value.codeUnits];
      frames.add(id.codeUnits);
      frames.add(_uint32be(text.length));
      frames.add(<int>[0x00, 0x00]);
      frames.add(text);
    }

    frame('TIT2', title); // Title
    frame('TPE1', artist); // Lead performer — this track's artist
    frame('TPE2', albumArtist); // Band/orchestra — the album artist
    frame('TALB', album); // Album
    frame('TRCK', track); // Track number, possibly "3/12"
    if (coverImage != null) _apicFrame(frames, coverImage, coverMimeType);

    final Uint8List body = frames.toBytes();
    final BytesBuilder file = BytesBuilder();
    file.add('ID3'.codeUnits);
    file.add(<int>[0x03, 0x00]); // v2.3.0
    file.add(<int>[0x00]); // no flags
    file.add(_synchsafe(body.length));
    file.add(body);
    file.add(_mpegFrames());
    return file.toBytes();
  }

  /// Appends an ID3v2.3 `APIC` (attached picture) frame to [frames]: an
  /// encoding byte, the null-terminated MIME type, a picture-type byte (`0x03`
  /// = cover front), an empty null-terminated description, then the image
  /// bytes verbatim — the exact layout `Id3v2Reader.getPicture` walks.
  static void _apicFrame(
    BytesBuilder frames,
    Uint8List image,
    String mimeType,
  ) {
    final BytesBuilder payload = BytesBuilder();
    payload.add(<int>[0x00]); // ISO-8859-1 encoding
    payload.add(mimeType.codeUnits);
    payload.add(<int>[0x00]); // MIME terminator
    payload.add(<int>[0x03]); // picture type: cover (front)
    payload.add(<int>[0x00]); // empty description, terminator
    payload.add(image);
    final Uint8List body = payload.toBytes();
    frames.add('APIC'.codeUnits);
    frames.add(_uint32be(body.length));
    frames.add(<int>[0x00, 0x00]);
    frames.add(body);
  }

  /// A FLAC carrying Vorbis comments.
  ///
  /// `fLaC`, then metadata blocks each headed by one byte (`last-block` flag in
  /// the top bit, block type in the low seven) and a 24-bit big-endian length.
  /// STREAMINFO (type 0) is mandatory and is where the duration comes from:
  /// total samples divided by sample rate.
  ///
  /// [albumArtistFirst] writes `ALBUMARTIST` ahead of `ARTIST`. Vorbis puts no
  /// ordering requirement on comments and real taggers differ, so a reader that
  /// depends on which one it meets first is wrong for half the files in the
  /// wild. Every other fixture here happens to write `ARTIST` first, which is
  /// exactly the bias that would let such a reader look correct.
  static Uint8List flac({
    String? title,
    String? artist,
    String? albumArtist,
    String? album,
    String? track,
    bool albumArtistFirst = false,
    List<String> artists = const <String>[],
    int paddingBefore = 0,
    int sampleRate = 44100,
    int totalSamples = 44100 * 3,
    Uint8List? coverImage,
    String coverMimeType = 'image/png',
  }) {
    final List<String> artistComments = <String>[
      if (artist != null) 'ARTIST=$artist',
      // Vorbis writes a collaboration as a repeated field, not a joined string.
      for (final String extra in artists) 'ARTIST=$extra',
      if (albumArtist != null) 'ALBUMARTIST=$albumArtist',
    ];
    final List<String> comments = <String>[
      if (title != null) 'TITLE=$title',
      ...(albumArtistFirst ? artistComments.reversed : artistComments),
      if (album != null) 'ALBUM=$album',
      if (track != null) 'TRACKNUMBER=$track',
    ];

    return _flacFrom(
      comments,
      sampleRate: sampleRate,
      totalSamples: totalSamples,
      paddingBefore: paddingBefore,
      coverImage: coverImage,
      coverMimeType: coverMimeType,
    );
  }

  static Uint8List _flacFrom(
    List<String> comments, {
    int sampleRate = 44100,
    int totalSamples = 44100 * 3,
    int paddingBefore = 0,
    Uint8List? coverImage,
    String coverMimeType = 'image/png',
  }) {
    final BytesBuilder vorbis = BytesBuilder();
    const String vendor = 'Linthra test fixture';
    vorbis.add(_uint32le(vendor.length));
    vorbis.add(vendor.codeUnits);
    vorbis.add(_uint32le(comments.length));
    for (final String comment in comments) {
      final List<int> bytes = _utf8(comment);
      vorbis.add(_uint32le(bytes.length));
      vorbis.add(bytes);
    }
    final Uint8List vorbisBlock = vorbis.toBytes();

    final BytesBuilder file = BytesBuilder();
    file.add('fLaC'.codeUnits);
    file.add(<int>[0x00]); // STREAMINFO, not the last block
    file.add(_uint24be(34));
    file.add(_streamInfo(sampleRate: sampleRate, totalSamples: totalSamples));
    if (paddingBefore > 0) {
      // A PADDING block (type 1) standing in for the embedded cover art that
      // real FLACs carry ahead of their comments. Its only job here is to push
      // VORBIS_COMMENT far enough into the file to catch a reader that only
      // looks at a fixed prefix.
      file.add(<int>[0x01]);
      file.add(_uint24be(paddingBefore));
      file.add(Uint8List(paddingBefore));
    }
    file.add(<int>[coverImage == null ? 0x84 : 0x04]); // VORBIS_COMMENT (4)
    file.add(_uint24be(vorbisBlock.length));
    file.add(vorbisBlock);
    if (coverImage != null) {
      final Uint8List pictureBlock = _pictureBlock(coverImage, coverMimeType);
      file.add(<int>[0x86]); // PICTURE (6), last block
      file.add(_uint24be(pictureBlock.length));
      file.add(pictureBlock);
    }
    return file.toBytes();
  }

  /// A FLAC `PICTURE` metadata block body: picture type, MIME type, an empty
  /// description, dimensions/depth/colour-count (unused by the reader, so
  /// zeroed), then the image bytes — the exact layout the FLAC parser's
  /// `case 6` walks.
  static Uint8List _pictureBlock(Uint8List image, String mimeType) {
    final BytesBuilder block = BytesBuilder();
    block.add(_uint32be(3)); // picture type: cover (front)
    final List<int> mime = mimeType.codeUnits;
    block.add(_uint32be(mime.length));
    block.add(mime);
    block.add(_uint32be(0)); // description length: none
    block.add(Uint8List(16)); // width, height, depth, colours used
    block.add(_uint32be(image.length));
    block.add(image);
    return block.toBytes();
  }

  /// A FLAC whose comment block carries [comments] verbatim, so a test can
  /// write shapes the typed builder above will not: a missing `=`, a lower-case
  /// field name, a value containing its own `=`.
  static Uint8List flacWithRawComments(List<String> comments) =>
      _flacFrom(comments);

  /// A WAV carrying RIFF `INFO` tags.
  ///
  /// `RIFF`/`WAVE`, a `fmt ` chunk (the byte rate in it is what the duration is
  /// derived from), a `LIST`/`INFO` chunk of four-character tags, then `data`.
  static Uint8List wav({
    String? title,
    String? artist,
    String? album,
    String? track,
    int sampleRate = 8000,
    int frames = 8000,
  }) {
    const int channels = 1;
    const int bytesPerSample = 2;
    final int byteRate = sampleRate * channels * bytesPerSample;
    final int dataSize = frames * channels * bytesPerSample;

    final BytesBuilder info = BytesBuilder();
    info.add('INFO'.codeUnits);
    void tag(String id, String? value) {
      if (value == null) return;
      // INFO values are NUL-terminated, and chunks are word-aligned.
      final List<int> bytes = <int>[...value.codeUnits, 0x00];
      info.add(id.codeUnits);
      info.add(_uint32le(bytes.length));
      info.add(bytes);
      if (bytes.length.isOdd) info.add(<int>[0x00]);
    }

    tag('INAM', title);
    tag('IART', artist);
    tag('IPRD', album);
    tag('ITRK', track);
    final Uint8List infoChunk = info.toBytes();

    final BytesBuilder fmt = BytesBuilder();
    fmt.add(_uint16le(1)); // PCM
    fmt.add(_uint16le(channels));
    fmt.add(_uint32le(sampleRate));
    fmt.add(_uint32le(byteRate));
    fmt.add(_uint16le(channels * bytesPerSample));
    fmt.add(_uint16le(bytesPerSample * 8));
    final Uint8List fmtChunk = fmt.toBytes();

    final BytesBuilder body = BytesBuilder();
    body.add('WAVE'.codeUnits);
    body.add('fmt '.codeUnits);
    body.add(_uint32le(fmtChunk.length));
    body.add(fmtChunk);
    body.add('LIST'.codeUnits);
    body.add(_uint32le(infoChunk.length));
    body.add(infoChunk);
    body.add('data'.codeUnits);
    body.add(_uint32le(dataSize));
    body.add(Uint8List(dataSize));
    final Uint8List bodyBytes = body.toBytes();

    final BytesBuilder file = BytesBuilder();
    file.add('RIFF'.codeUnits);
    file.add(_uint32le(bodyBytes.length));
    file.add(bodyBytes);
    return file.toBytes();
  }

  /// An M4A (MP4 audio) carrying iTunes-style `ilst` atoms.
  ///
  /// MP4 is a tree of boxes, each a 4-byte big-endian size (header included)
  /// then a four-character type. The tags live at `moov/udta/meta/ilst`, one
  /// box per field, each wrapping a `data` box whose payload starts with a type
  /// indicator (1 = UTF-8) and a locale. `meta` is a "full box": a
  /// version/flags word comes before its children. The duration comes from
  /// `mvhd` (a timescale and a duration in its units).
  ///
  /// Shaped like a real tagged file rather than the bare minimum: a sound
  /// track down to its `mp4a` sample description, and a freeform `----` atom
  /// holding two values the way mutagen (and so Picard) writes a multi-valued
  /// field. The tag parser walks both, so a check in front of it has to let
  /// both through.
  ///
  /// [metaVersionFlags] false writes `meta` the QuickTime way, children
  /// directly, as some Android and MediaStore files do. [appendTo] adds raw
  /// bytes at the end of the named container's payload (`moov`, `udta`, `meta`
  /// or `ilst`), and [trailing] adds them after the last top-level box: the
  /// hooks the malformed-file tests use to plant one bad box in an otherwise
  /// sound file.
  static Uint8List m4a({
    String? title,
    String? artist,
    String? album,
    int? track,
    Duration duration = const Duration(seconds: 3),
    bool metaVersionFlags = true,
    Map<String, List<int>> appendTo = const <String, List<int>>{},
    List<int> trailing = const <int>[],
  }) {
    assert(
      appendTo.keys.every(<String>{'moov', 'udta', 'meta', 'ilst'}.contains),
      'appendTo only knows moov, udta, meta and ilst',
    );
    List<int> extra(String container) => appendTo[container] ?? const <int>[];

    final Uint8List ilst = mp4Box('ilst', <int>[
      if (title != null) ..._mp4Text('©nam', title),
      if (artist != null) ..._mp4Text('©ART', artist),
      // Mid-list on purpose: the parser reads a freeform atom's first three
      // children itself and meets any further `data` as the next list item.
      ..._mp4Freeform('MusicBrainz Artist Id', <String>['id-1', 'id-2']),
      if (album != null) ..._mp4Text('©alb', album),
      if (track != null)
        // `trkn` is binary (type indicator 0): pad, track, total, pad.
        ...mp4Box(
            'trkn',
            mp4Box('data', <int>[
              ...<int>[0, 0, 0, 0, 0, 0, 0, 0],
              ...<int>[0, 0, ..._uint16be(track), 0, 0, 0, 0],
            ])),
      ...extra('ilst'),
    ]);
    final Uint8List meta = mp4Box('meta', <int>[
      if (metaVersionFlags) ...<int>[0, 0, 0, 0],
      // The handler that marks this `meta` as iTunes metadata ('mdir').
      ...mp4Box('hdlr', <int>[
        ...<int>[0, 0, 0, 0, 0, 0, 0, 0], // version/flags, pre_defined
        ...'mdirappl'.codeUnits,
        ...Uint8List(9), // reserved, then an empty NUL-terminated name
      ]),
      ...ilst,
      ...extra('meta'),
    ]);
    final Uint8List moov = mp4Box('moov', <int>[
      ..._mvhd(duration),
      ..._mp4SoundTrack(),
      ...mp4Box('udta', <int>[...meta, ...extra('udta')]),
      ...extra('moov'),
    ]);

    return Uint8List.fromList(<int>[
      ...mp4Ftyp(),
      ...moov,
      ...mp4Box('mdat', Uint8List(16)),
      ...trailing,
    ]);
  }

  /// One MP4 box: its size (the 8-byte header plus [payload]), its type, then
  /// [payload] verbatim. Types are four Latin-1 characters, so `©nam` is the
  /// bytes `A9 6E 61 6D` exactly as iTunes writes it.
  static Uint8List mp4Box(String type, [List<int> payload = const <int>[]]) =>
      Uint8List.fromList(
          <int>[...mp4BoxHeader(8 + payload.length, type), ...payload]);

  /// An 8-byte box header declaring [size] whatever actually follows it: the
  /// way to write a box whose size is wrong.
  static Uint8List mp4BoxHeader(int size, String type) {
    assert(
      type.length == 4 && type.codeUnits.every((int unit) => unit <= 0xFF),
      'a box type is four Latin-1 characters',
    );
    return Uint8List.fromList(<int>[..._uint32be(size), ...type.codeUnits]);
  }

  /// The `ftyp` box every MP4-family file opens with, the one thing the tag
  /// reader sniffs to pick its MP4 parser: an `M4A ` major brand plus the
  /// compatible brands iTunes lists.
  static Uint8List mp4Ftyp() => mp4Box('ftyp', <int>[
        ...'M4A '.codeUnits,
        ..._uint32be(0x200), // minor version
        ...'M4A mp42isom'.codeUnits,
      ]);

  /// An iTunes text atom: [type] wrapping a `data` box of UTF-8 [value].
  static Uint8List _mp4Text(String type, String value) => mp4Box(
      type, mp4Box('data', <int>[0, 0, 0, 1, 0, 0, 0, 0, ..._utf8(value)]));

  /// A freeform `----` atom: `mean` (the namespace), `name`, then one `data`
  /// box per value.
  static Uint8List _mp4Freeform(String name, List<String> values) =>
      mp4Box('----', <int>[
        ...mp4Box('mean', <int>[0, 0, 0, 0, ...'com.apple.iTunes'.codeUnits]),
        ...mp4Box('name', <int>[0, 0, 0, 0, ...name.codeUnits]),
        for (final String value in values)
          ...mp4Box('data', <int>[0, 0, 0, 1, 0, 0, 0, 0, ..._utf8(value)]),
      ]);

  /// A version-0 `mvhd`: 100 bytes of payload, of which the parser needs the
  /// timescale (ticks per second) and the duration in those ticks.
  static Uint8List _mvhd(Duration duration) {
    final ByteData payload = ByteData(100); // version 0, flags 0, times 0
    payload.setUint32(12, 1000); // timescale: milliseconds
    payload.setUint32(16, duration.inMilliseconds);
    payload.setUint32(20, 0x00010000); // playback rate 1.0
    payload.setUint16(24, 0x0100); // volume 1.0
    payload.setUint32(36, 0x00010000); // identity matrix: a, d and w
    payload.setUint32(52, 0x00010000);
    payload.setUint32(68, 0x40000000);
    payload.setUint32(96, 2); // next track ID
    return mp4Box('mvhd', payload.buffer.asUint8List());
  }

  /// `trak/mdia/minf/stbl/stsd` down to one `mp4a` (AAC) sample description:
  /// the path the parser descends to read the sample rate.
  static Uint8List _mp4SoundTrack() {
    final ByteData mp4a = ByteData(28);
    mp4a.setUint16(6, 1); // data reference index
    mp4a.setUint16(16, 2); // channels
    mp4a.setUint16(18, 16); // bits per sample
    mp4a.setUint32(24, 44100 << 16); // sample rate, 16.16 fixed point
    final Uint8List stsd = mp4Box('stsd', <int>[
      ...<int>[0, 0, 0, 0], // version/flags
      ..._uint32be(1), // entry count
      ...mp4Box('mp4a', mp4a.buffer.asUint8List()),
    ]);
    return mp4Box('trak', mp4Box('mdia', mp4Box('minf', mp4Box('stbl', stsd))));
  }

  /// An ID3v1 tag: the fixed 128-byte block some taggers append to the end
  /// of any file, whatever its format. `TAG`, then title, artist and album
  /// in 30 bytes each, year, comment, and a genre byte (255: none).
  static Uint8List id3v1({required String title}) {
    final Uint8List tag = Uint8List(128);
    tag.setRange(0, 3, 'TAG'.codeUnits);
    tag.setRange(3, 3 + title.length, title.codeUnits);
    tag[127] = 0xFF;
    return tag;
  }

  /// FLAC STREAMINFO: fixed 34 bytes, with the sample rate, channel count,
  /// bit depth and total sample count packed across a 64-bit field.
  static Uint8List _streamInfo({
    required int sampleRate,
    required int totalSamples,
  }) {
    final Uint8List block = Uint8List(34);
    final ByteData view = ByteData.sublistView(block);
    view.setUint16(0, 4096); // min block size
    view.setUint16(2, 4096); // max block size
    // min/max frame size stay zero ("unknown"), which is legal.

    // 20 bits sample rate, 3 bits (channels - 1), 5 bits (bits per sample - 1),
    // 36 bits total samples — 64 bits starting at byte 10.
    const int channels = 2;
    const int bitsPerSample = 16;
    final int high = (sampleRate << 12) |
        ((channels - 1) << 9) |
        ((bitsPerSample - 1) << 4) |
        ((totalSamples >> 32) & 0xF);
    view.setUint32(10, high);
    view.setUint32(14, totalSamples & 0xFFFFFFFF);
    return block;
  }

  /// A few MPEG-1 Layer III frames (sync word, 128 kbps, 44.1 kHz) of silence,
  /// so an MP3 fixture is a file a decoder can walk rather than a bare tag.
  ///
  /// More than one frame on purpose: a single frame leaves a demuxer seeking
  /// past the end of the file when it looks for the next sync word, and
  /// `ffprobe` rejects such a file outright. Three frames make the fixture
  /// something real tools accept.
  static Uint8List _mpegFrames({int count = 3}) {
    final BytesBuilder frames = BytesBuilder();
    for (int i = 0; i < count; i++) {
      frames.add(<int>[0xFF, 0xFB, 0x90, 0x00]);
      frames.add(Uint8List(413)); // 417-byte frame at 128 kbps / 44.1 kHz
    }
    return frames.toBytes();
  }

  static List<int> _uint32be(int value) => <int>[
        (value >> 24) & 0xFF,
        (value >> 16) & 0xFF,
        (value >> 8) & 0xFF,
        value & 0xFF,
      ];

  static List<int> _uint24be(int value) => <int>[
        (value >> 16) & 0xFF,
        (value >> 8) & 0xFF,
        value & 0xFF,
      ];

  static List<int> _uint32le(int value) => <int>[
        value & 0xFF,
        (value >> 8) & 0xFF,
        (value >> 16) & 0xFF,
        (value >> 24) & 0xFF,
      ];

  static List<int> _uint16be(int value) => <int>[
        (value >> 8) & 0xFF,
        value & 0xFF,
      ];

  static List<int> _uint16le(int value) => <int>[
        value & 0xFF,
        (value >> 8) & 0xFF,
      ];

  /// ID3v2 sizes are synchsafe: seven significant bits per byte.
  static List<int> _synchsafe(int value) => <int>[
        (value >> 21) & 0x7F,
        (value >> 14) & 0x7F,
        (value >> 7) & 0x7F,
        value & 0x7F,
      ];

  static List<int> _utf8(String value) => utf8.encode(value);
}
