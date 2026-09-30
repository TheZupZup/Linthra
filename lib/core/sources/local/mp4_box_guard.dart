import 'dart:io';
import 'dart:typed_data';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';

/// Keeps MP4-family files that would hang `audio_metadata_reader`'s MP4
/// parser away from it.
///
/// That parser (1.7.1) moves from box to box by each box's declared size and
/// never checks that the size moves it forward. A box sized 0 sends it back to
/// the same header forever. Size 0 is legal ("this box runs to the end of the
/// file"), and it is what ffmpeg writes in `mdat` as a placeholder until it
/// finishes, so any interrupted encode or cut-off download has one. Size 1 (a
/// 64-bit size follows, which the parser does not read), sizes 2 to 7, a box
/// running past its parent, and stray bytes at the end of a container all
/// leave it reading headers out of the middle of other data, where a zero size
/// is one unlucky byte run away. It is synchronous and throws nothing while it
/// spins, so the caller's `catch` never gets a chance: one such file froze the
/// desktop UI at 100% CPU on every scan of the folder it sat in.
///
/// So [isSafeToParse] walks the boxes the parser would walk, reading 8-byte
/// headers and never a payload, and refuses the file when any of them is one
/// the parser could not get past. A refused file keeps its place in the
/// library, from its filename; only its tags are lost. Files the parser never
/// sees (everything without `ftyp`, and the few MP4s another parser claims
/// first) pass untouched.
///
/// The walk mirrors the parser it guards, and so is tied to it: when
/// `audio_metadata_reader` is upgraded, check `MP4Parser` (`parse`,
/// `processBox`, `parseRecurvise`) against [_BoxWalk] again.
abstract final class Mp4BoxGuard {
  /// The most boxes one walk reads before refusing the file. The walk ends on
  /// its own anyway, since every box it accepts moves it at least 8 bytes on;
  /// this caps the cost of a large file made of tiny boxes. A real one needs a
  /// few dozen, or a few thousand for a long fragmented stream.
  static const int _maxBoxes = 1 << 16;

  /// The deepest nesting the walk follows. The parser's deepest real path,
  /// `moov/trak/mdia/minf/stbl/stsd`, is 6.
  static const int _maxDepth = 16;

  /// Whether [file] can be handed to `readAllMetadata` without risking the
  /// MP4 parser's loop: true for any file that parser would not see, and for
  /// an MP4 whose boxes it can walk to the end.
  ///
  /// Throws what opening or reading [file] throws, as `readAllMetadata`
  /// would.
  static bool isSafeToParse(File file) {
    final RandomAccessFile handle = file.openSync();
    try {
      return !_reachesMp4Parser(handle) || _BoxWalk(handle).isSound();
    } finally {
      handle.closeSync();
    }
  }

  /// Whether `readAllMetadata` would pick its MP4 parser for this file, asked
  /// through the package's own detectors in the order it asks them.
  ///
  /// It picks by content, not by extension, so an AAC file named `.mp3` is
  /// guarded too, while an MP4 carrying an ID3v1 or APEv2 tag at its end goes
  /// to the parser for that tag instead and must not be refused on account of
  /// a trailer that is not a box.
  static bool _reachesMp4Parser(RandomAccessFile handle) =>
      MP4Parser.canUserParser(handle) &&
      !(ApeParser.canUserParser(handle) && !MP3Parser.hasID3v2Tag(handle)) &&
      !MP3Parser.canUserParser(handle) &&
      !FlacParser.canUserParser(handle);
}

/// One walk over an MP4 file's boxes, following the parser: the top level,
/// then down into every box type the parser descends into, wherever it sits,
/// with the same bytes skipped at the start of each.
///
/// The file is sound when every box on that walk is at least a header long
/// and ends inside its parent, and when every container's children fill it
/// exactly. From a box start, the parser then only ever lands on another box
/// start, whatever order it reads things in, so every header it reads is one
/// checked here.
final class _BoxWalk {
  _BoxWalk(this._file) : _length = _file.lengthSync();

  final RandomAccessFile _file;
  final int _length;
  int _boxesLeft = Mp4BoxGuard._maxBoxes;

  bool isSound() => _children(0, _length, 0);

  /// Whether the bytes from [start] to [end] are a run of sound boxes.
  bool _children(int start, int end, int depth) {
    if (depth > Mp4BoxGuard._maxDepth) return false;
    int at = start;
    while (at < end) {
      if (--_boxesLeft < 0) return false;
      // Fewer than 8 bytes left: the parser would read a header that runs
      // past the end of its container (or of the file).
      if (end - at < 8) return false;
      final Uint8List? header = _read(at, 8);
      if (header == null) return false;
      final int size = ByteData.sublistView(header).getUint32(0);
      // 0 ("to the end of the file") and 1 (a 64-bit size follows) are
      // legal, but the parser reads neither; 2 to 7 are not even a header.
      if (size < 8 || size > end - at) return false;
      final String type = String.fromCharCodes(header, 4);
      if (!_contents(at, size, type, depth)) return false;
      at += size;
    }
    return true;
  }

  /// Whether the box of [type] at [at] is sound inside: its children, for a
  /// box the parser descends into, and its size, for the one box the parser
  /// reads a fixed amount of whatever its size says.
  bool _contents(int at, int size, String type, int depth) {
    final int payload = at + 8;
    final int end = at + size;
    switch (type) {
      // `----` included: the parser reads the `mean`, `name` and `data`
      // boxes inside it by their own sizes.
      case 'moov' ||
            'udta' ||
            'ilst' ||
            'trak' ||
            'mdia' ||
            'minf' ||
            'stbl' ||
            '----':
        return _children(payload, end, depth + 1);
      case 'stsd':
        // A version/flags word and an entry count come before the entries.
        return size >= 16 && _children(payload + 8, end, depth + 1);
      case 'meta':
        final int? skip = _metaPrefix(payload, size - 8);
        return skip != null &&
            skip <= size - 8 &&
            _children(payload + skip, end, depth + 1);
      case 'mvhd':
        // The parser reads 100 bytes after the header (112 for version 1)
        // whatever the size says, so any other size puts it off the grid.
        final Uint8List? version = _read(payload, 1);
        return version != null && size == (version[0] == 1 ? 120 : 108);
      default:
        return true;
    }
  }

  /// How many bytes the parser skips at the start of a `meta` box's payload
  /// before its children, making the same probe it does: 4 (a version/flags
  /// word) unless the first 8 bytes already read as a plausible child header,
  /// since files in the wild are written both ways. Null when that probe
  /// would run off the end of the file, which the parser does not survive.
  int? _metaPrefix(int payload, int payloadLength) {
    final Uint8List? probe = _read(payload, 8);
    if (probe == null) return null;
    final int firstSize = ByteData.sublistView(probe).getUint32(0);
    final bool childFirst = firstSize >= 8 &&
        firstSize <= payloadLength &&
        probe.skip(4).every((int byte) => byte >= 0x20 && byte <= 0x7E);
    return childFirst ? 0 : 4;
  }

  /// The [count] bytes at [at], or null when the file ends before them.
  Uint8List? _read(int at, int count) {
    _file.setPositionSync(at);
    final Uint8List bytes = _file.readSync(count);
    return bytes.length == count ? bytes : null;
  }
}
