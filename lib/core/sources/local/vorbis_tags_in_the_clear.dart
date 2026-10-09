import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'vorbis_comment_fields.dart';

/// What a FLAC, OGG or Opus file's tags say, read straight off the file: its
/// Vorbis comments by field name, its length, and its cover.
///
/// `audio_metadata_reader` gives up on a whole file over one comment it can't
/// parse: a TRACKNUMBER of `A1` on a vinyl rip, an empty `TRACKTOTAL=`, a
/// `DISCTOTAL=two`, a comment with no `=` or one that isn't UTF-8. The track
/// was then named after its file for good, with no length and no cover
/// (#776). These containers keep all of that in a few well-specified
/// structures, so [FilesystemLocalMetadataReader] reads them here when the
/// package gives up, and only then.
///
/// Total about what the file holds: anything that isn't a FLAC or an Ogg
/// Vorbis or Opus stream, or whose comments don't hold together, gives null.
/// Not about reading it: an I/O error is thrown, never read around. A read
/// that couldn't finish says nothing about the tags, and the scan keeps what
/// it is told for as long as the file doesn't change, so a drive dying under
/// it must not leave a track settled without its length or its cover.
final class VorbisTagsInTheClear {
  const VorbisTagsInTheClear._(this.fields, this.duration, this.cover);

  /// Comments keyed by upper-cased field name, as [VorbisCommentFields] reads
  /// them: one that isn't UTF-8 or has no `=` is skipped, never the rest.
  final Map<String, List<String>> fields;

  final Duration? duration;

  /// The picture marked as the front cover, or the first one when none is.
  /// Only looked for when asked to.
  final Uint8List? cover;

  /// [file]'s comments, length and, when [withCover], cover.
  static Future<VorbisTagsInTheClear?> read(
    File file, {
    required bool withCover,
  }) async {
    final RandomAccessFile handle = await file.open();
    try {
      final Uint8List magic = await handle.read(4);
      if (VorbisCommentFields.isFlac(magic)) {
        return await _flac(handle, withCover);
      }
      if (_isOggPage(magic, 0)) return await _ogg(handle, withCover);
      return null;
    } finally {
      await handle.close();
    }
  }

  static const int _pictureBlock = 6;

  /// Walks a FLAC's metadata blocks from just after its magic: STREAMINFO
  /// (always first) for the length, VORBIS_COMMENT for the fields, and, when
  /// [withCover], the PICTUREs until the front cover. Only the best picture
  /// so far is kept, never every one: a file can carry many large ones.
  /// Everything else is seeked past, and without a cover to find the walk
  /// stops at the comments.
  static Future<VorbisTagsInTheClear?> _flac(
    RandomAccessFile handle,
    bool withCover,
  ) async {
    Duration? duration;
    Map<String, List<String>>? fields;
    _Picture? cover;
    while (true) {
      final Uint8List header = await handle.read(4);
      if (header.length < 4) break; // truncated
      final bool isLast = (header[0] & 0x80) != 0;
      final int type = header[0] & 0x7F;
      final int length = (header[1] << 16) | (header[2] << 8) | header[3];
      final int next = await handle.position() + length;

      if (type == FlacStreamInfo.block) {
        duration = FlacStreamInfo.duration(await handle.read(length));
      } else if (type == VorbisCommentFields.vorbisCommentBlock) {
        fields ??= await VorbisCommentFields.readBlock(handle, length);
        if (fields == null) return null;
        if (!withCover) break;
      } else if (type == _pictureBlock &&
          withCover &&
          cover?.type != _Picture._frontCover) {
        final _Picture? picture = _Picture.parse(await handle.read(length));
        if (picture != null &&
            (cover == null || picture.type == _Picture._frontCover)) {
          cover = picture;
        }
      }
      if (isLast) break;
      await handle.setPosition(next);
    }
    if (fields == null) return null;
    return VorbisTagsInTheClear._(fields, duration, cover?.data);
  }

  /// Reads an Ogg Vorbis or Opus stream's identification and comment headers,
  /// the first two packets of its first logical stream, then its length from
  /// the last page's granule position: samples at the stream's rate for
  /// Vorbis; for Opus, 48 kHz samples whatever rate the source had, less the
  /// pre-skip, the decoder warm-up the stream opens with.
  static Future<VorbisTagsInTheClear?> _ogg(
    RandomAccessFile handle,
    bool withCover,
  ) async {
    await handle.setPosition(0);
    final _OggPackets packets = _OggPackets(handle);
    final Uint8List? identification = await packets.next();
    if (identification == null) return null;

    final int prefix;
    final int rate;
    final int preSkip;
    if (_startsWith(identification, _vorbisIdentification) &&
        identification.length >= 30) {
      prefix = _vorbisComments.length;
      rate = _uint32le(identification, 12);
      preSkip = 0;
    } else if (_startsWith(identification, _opusHead) &&
        identification.length >= 19) {
      prefix = _opusTags.length;
      rate = 48000;
      preSkip = identification[10] | (identification[11] << 8);
    } else {
      return null;
    }

    final Uint8List? comments = await packets.next();
    if (comments == null ||
        !_startsWith(comments,
            prefix == _opusTags.length ? _opusTags : _vorbisComments)) {
      return null;
    }
    final Map<String, List<String>>? fields =
        VorbisCommentFields.parseBlock(Uint8List.sublistView(comments, prefix));
    if (fields == null) return null;

    Uint8List? cover;
    if (withCover) {
      cover = _Picture.cover(<_Picture>[
        for (final String value
            in fields['METADATA_BLOCK_PICTURE'] ?? const <String>[])
          if (_Picture.parse(_base64(value)) case final _Picture picture)
            picture,
      ]);
    }

    final int? granule = await _lastGranule(handle, packets.serial!);
    final int samples = (granule ?? 0) - preSkip;
    final Duration? duration = rate <= 0 || samples <= 0
        ? null
        : Duration(
            seconds: samples ~/ rate,
            microseconds:
                (samples % rate) * Duration.microsecondsPerSecond ~/ rate,
          );
    return VorbisTagsInTheClear._(fields, duration, cover);
  }

  /// The largest a page can be: its 27-byte header, 255 lacing values, and
  /// 255 segments of 255 bytes.
  static const int _maxPageBytes = 27 + 255 + 255 * 255;

  /// The granule position of the last page of stream [serial] that has one,
  /// found by reading the file's last page-length of bytes and looking back
  /// from the end for a page whose checksum holds; null when there's none
  /// there.
  static Future<int?> _lastGranule(RandomAccessFile handle, int serial) async {
    final int length = await handle.length();
    final int start = length > _maxPageBytes ? length - _maxPageBytes : 0;
    await handle.setPosition(start);
    final Uint8List tail = await handle.read(length - start);
    for (int at = tail.length - 27; at >= 0; at--) {
      if (!_isOggPage(tail, at)) continue;
      final int? end = _pageEnd(tail, at);
      if (end == null || !_checksumHolds(tail, at, end)) continue;
      if (_uint32le(tail, at + 14) != serial) continue;
      final int granule = ByteData.sublistView(tail, at + 6, at + 14)
          .getInt64(0, Endian.little);
      // -1: no packet ends on this page, so it has no position of its own.
      if (granule != -1) return granule;
    }
    return null;
  }

  /// Where the page that starts at [at] in [bytes] ends, or null when its
  /// header or the data it declares runs past them.
  static int? _pageEnd(Uint8List bytes, int at) {
    if (at + 27 > bytes.length) return null;
    final int segments = bytes[at + 26];
    if (at + 27 + segments > bytes.length) return null;
    int end = at + 27 + segments;
    for (int i = 0; i < segments; i++) {
      end += bytes[at + 27 + i];
    }
    return end <= bytes.length ? end : null;
  }

  static final List<int> _crcTable = List<int>.generate(256, (int index) {
    int crc = index << 24;
    for (int bit = 0; bit < 8; bit++) {
      crc = (crc & 0x80000000) != 0 ? (crc << 1) ^ 0x04C11DB7 : crc << 1;
    }
    return crc & 0xFFFFFFFF;
  });

  /// Whether the page [start] to [end] in [bytes] carries its own checksum:
  /// what tells a page from the four bytes `OggS` turning up in audio data.
  static bool _checksumHolds(Uint8List bytes, int start, int end) {
    int crc = 0;
    for (int i = start; i < end; i++) {
      // The checksum field itself counts as zeros.
      final int byte = i >= start + 22 && i < start + 26 ? 0 : bytes[i];
      crc = ((crc << 8) & 0xFFFFFFFF) ^ _crcTable[((crc >> 24) ^ byte) & 0xFF];
    }
    return crc == _uint32le(bytes, start + 22);
  }

  /// Whether a page starts at [at] in [bytes]: `OggS`, then version 0 when
  /// [bytes] go that far.
  static bool _isOggPage(Uint8List bytes, int at) =>
      at + 4 <= bytes.length &&
      bytes[at] == 0x4F && // O
      bytes[at + 1] == 0x67 && // g
      bytes[at + 2] == 0x67 && // g
      bytes[at + 3] == 0x53 && // S
      (at + 4 == bytes.length || bytes[at + 4] == 0);

  static final List<int> _vorbisIdentification = <int>[
    0x01,
    ...'vorbis'.codeUnits,
  ];
  static final List<int> _vorbisComments = <int>[0x03, ...'vorbis'.codeUnits];
  static final List<int> _opusHead = 'OpusHead'.codeUnits;
  static final List<int> _opusTags = 'OpusTags'.codeUnits;

  static bool _startsWith(Uint8List bytes, List<int> prefix) {
    if (bytes.length < prefix.length) return false;
    for (int i = 0; i < prefix.length; i++) {
      if (bytes[i] != prefix[i]) return false;
    }
    return true;
  }

  static int _uint32le(Uint8List bytes, int at) =>
      bytes[at] |
      (bytes[at + 1] << 8) |
      (bytes[at + 2] << 16) |
      (bytes[at + 3] << 24);

  static Uint8List _base64(String value) {
    try {
      return base64.decode(value.trim());
    } on FormatException {
      return Uint8List(0);
    }
  }
}

/// The packets of the first logical stream in an Ogg file, reassembled page
/// by page from the start.
///
/// A page carries a table of lacing values and then the data they measure:
/// a packet is a run of 255-byte segments closed by one shorter than 255, and
/// runs on over the next page when the table ends on a 255. Pages of any
/// other stream multiplexed with it are skipped.
final class _OggPackets {
  _OggPackets(this._handle);

  final RandomAccessFile _handle;

  /// A sanity bound on one header packet, so a lacing table that never closes
  /// its packet can't read the whole file into memory. Comments with long
  /// lyrics or a large cover are a few MiB.
  static const int _maxPacketBytes = 32 << 20;

  /// The stream's serial number, from its first page.
  int? serial;

  Uint8List _lacing = Uint8List(0);
  Uint8List _data = Uint8List(0);
  int _segment = 0;
  int _offset = 0;

  /// The next packet, or null when the file ends before it does, or it runs
  /// past [_maxPacketBytes].
  Future<Uint8List?> next() async {
    final BytesBuilder packet = BytesBuilder(copy: false);
    while (true) {
      if (_segment == _lacing.length) {
        if (!await _nextPage()) return null;
        continue;
      }
      final int size = _lacing[_segment++];
      packet.add(Uint8List.sublistView(_data, _offset, _offset + size));
      _offset += size;
      if (packet.length > _maxPacketBytes) return null;
      if (size < 255) return packet.takeBytes();
    }
  }

  Future<bool> _nextPage() async {
    while (true) {
      final Uint8List header = await _handle.read(27);
      if (header.length < 27 || !VorbisTagsInTheClear._isOggPage(header, 0)) {
        return false;
      }
      final Uint8List lacing = await _handle.read(header[26]);
      if (lacing.length < header[26]) return false;
      final int size = lacing.fold(0, (int sum, int value) => sum + value);
      final Uint8List data = await _handle.read(size);
      if (data.length < size) return false;
      final int pageSerial = VorbisTagsInTheClear._uint32le(header, 14);
      if ((serial ??= pageSerial) != pageSerial) continue;
      _lacing = lacing;
      _data = data;
      _segment = 0;
      _offset = 0;
      return true;
    }
  }
}

/// One embedded picture: FLAC's PICTURE block, which Ogg carries base64'd in
/// a METADATA_BLOCK_PICTURE comment. Big-endian throughout: picture type, MIME
/// type, description, width, height, depth, colour count, then the image.
final class _Picture {
  const _Picture(this.type, this.data);

  final int type;
  final Uint8List data;

  static const int _frontCover = 3;

  /// The front cover among [pictures], or the first one when none is marked
  /// as the front cover; null when there are none.
  static Uint8List? cover(List<_Picture> pictures) {
    for (final _Picture picture in pictures) {
      if (picture.type == _frontCover) return picture.data;
    }
    return pictures.isEmpty ? null : pictures.first.data;
  }

  /// Null when the lengths in [block] don't hold together, or it has no
  /// image.
  static _Picture? parse(Uint8List block) {
    final ByteData view = ByteData.sublistView(block);
    int at = 0;
    int? uint32() {
      if (at + 4 > block.length) return null;
      final int value = view.getUint32(at);
      at += 4;
      return value;
    }

    final int? type = uint32();
    final int? mimeLength = uint32();
    if (type == null || mimeLength == null) return null;
    at += mimeLength;
    final int? descriptionLength = uint32();
    if (descriptionLength == null) return null;
    at += descriptionLength + 16; // description, then four dimensions
    final int? length = uint32();
    if (length == null || length == 0 || at + length > block.length) {
      return null;
    }
    return _Picture(type, Uint8List.sublistView(block, at, at + length));
  }
}
