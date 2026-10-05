import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Reads Vorbis comments out of a FLAC file *with their field names intact*.
///
/// `audio_metadata_reader` folds `ARTIST` and `ALBUMARTIST` into one list
/// (`vorbis_comment.dart`: `case 'ARTIST' || "ALBUMARTIST"`), which loses the
/// only thing that tells a compilation's performer from its album name. No
/// heuristic recovers it: `[Alice, Bob]` is two `ARTIST` values on a
/// collaboration, `[Guest, Various Artists]` is `ARTIST` plus `ALBUMARTIST`,
/// and from the merged list those are the same shape. So this reads the block
/// directly rather than guessing.
///
/// FLAC only, deliberately. Its metadata blocks sit in the clear right after
/// the magic, so this is a short, well-specified read. OGG and Opus carry the
/// same comments inside Ogg pages, which needs page and packet framing for a
/// far less common local format; those keep the conservative path in
/// [FilesystemLocalMetadataReader] instead.
///
/// Deliberately total: a non-FLAC file, a truncated header, a declared length
/// that runs past the file, or invalid UTF-8 all return null so the caller
/// falls back. It never throws and never logs the path.
class VorbisCommentFields {
  const VorbisCommentFields._();

  /// A sanity bound on a *single* comment, so a corrupt 32-bit length cannot
  /// ask for an arbitrary allocation. Nothing bounds the block itself: a tagger
  /// that stores long lyrics or base64 artwork in a comment produces a
  /// perfectly valid block of many MiB, and rejecting it would lose the short
  /// artist fields sitting right beside the big value. An oversized entry is
  /// seeked past; its neighbours are kept.
  static const int _maxCommentBytes = 1 << 20; // 1 MiB

  /// Comments keyed by upper-cased field name, or null when [file] is not a
  /// FLAC whose comment block could be read.
  ///
  /// Values keep their order and their duplicates: `ARTIST=Alice`,
  /// `ARTIST=Bob` yields `{'ARTIST': ['Alice', 'Bob']}`, which is the spec's
  /// way of writing a collaboration.
  ///
  /// Walks the block chain and *seeks* past everything that is not the comment
  /// block, rather than reading a fixed prefix. FLAC puts no ordering
  /// requirement on metadata blocks, and a file with embedded cover art carries
  /// a PICTURE block that is routinely megabytes; reading a fixed prefix would
  /// silently miss the comments on exactly those files and fall back to the
  /// package's merged list. Only the comment block is ever read into memory,
  /// never the art and never the audio.
  static Future<Map<String, List<String>>?> read(File file) async {
    RandomAccessFile? handle;
    try {
      handle = await file.open();
      final Uint8List magic = await handle.read(4);
      if (!_isFlac(magic)) return null;

      while (true) {
        final Uint8List header = await handle.read(4);
        if (header.length < 4) return null; // truncated
        final bool isLast = (header[0] & 0x80) != 0;
        final int type = header[0] & 0x7F;
        final int length = (header[1] << 16) | (header[2] << 8) | header[3];

        if (type == _vorbisCommentBlock) {
          // Awaited, not returned: `finally` closes the handle, and returning
          // the future directly would close it out from under the read.
          return await _readComments(handle, length);
        }
        if (isLast) return null; // no comment block in this file
        await handle.setPosition(await handle.position() + length);
      }
    } on FileSystemException {
      return null;
    } finally {
      await handle?.close();
    }
  }

  /// Reads the entries of a comment block [blockLength] bytes long one at a
  /// time, so a large block never becomes a large allocation.
  ///
  /// Each entry is a 32-bit little-endian length and that many UTF-8 bytes. An
  /// entry longer than [_maxCommentBytes] is seeked past rather than read, and
  /// rather than failing the file: a field name is short, so an entry that big
  /// is never one of the fields this is after, and the entries around it are.
  static Future<Map<String, List<String>>?> _readComments(
    RandomAccessFile handle,
    int blockLength,
  ) async {
    final int end = await handle.position() + blockLength;

    Future<int?> readUint32le() async {
      if (await handle.position() + 4 > end) return null;
      final Uint8List bytes = await handle.read(4);
      if (bytes.length < 4) return null;
      final int value =
          bytes[0] | (bytes[1] << 8) | (bytes[2] << 16) | (bytes[3] << 24);
      return value < 0 ? null : value;
    }

    final int? vendorLength = await readUint32le();
    if (vendorLength == null || await handle.position() + vendorLength > end) {
      return null;
    }
    await handle.setPosition(await handle.position() + vendorLength);

    final int? count = await readUint32le();
    if (count == null) return null;

    final Map<String, List<String>> fields = <String, List<String>>{};
    for (int i = 0; i < count; i++) {
      final int? length = await readUint32le();
      if (length == null) return null;
      final int next = await handle.position() + length;
      if (next > end) return null; // declared past the block
      if (length > _maxCommentBytes) {
        await handle.setPosition(next);
        continue;
      }
      final Uint8List raw = await handle.read(length);
      if (raw.length < length) return null; // truncated
      _collect(fields, raw);
    }
    return fields;
  }

  static const int _vorbisCommentBlock = 4;

  static bool _isFlac(Uint8List bytes) =>
      bytes.length >= 4 &&
      bytes[0] == 0x66 && // f
      bytes[1] == 0x4C && // L
      bytes[2] == 0x61 && // a
      bytes[3] == 0x43; // C

  /// The parsing half, separated so it is testable on bytes alone.
  ///
  /// FLAC layout: `fLaC`, then metadata blocks, each a header byte (the top bit
  /// marks the last block, the low seven the type) plus a 24-bit big-endian
  /// length, then that many bytes. Type 4 is VORBIS_COMMENT, whose payload is
  /// little-endian: vendor length, vendor, comment count, then each comment as
  /// a length and `FIELD=value` in UTF-8.
  static Map<String, List<String>>? parse(Uint8List bytes) {
    if (!_isFlac(bytes)) return null;

    int offset = 4;
    while (offset + 4 <= bytes.length) {
      final int header = bytes[offset];
      final bool isLast = (header & 0x80) != 0;
      final int type = header & 0x7F;
      final int length = (bytes[offset + 1] << 16) |
          (bytes[offset + 2] << 8) |
          bytes[offset + 3];
      final int start = offset + 4;
      final int end = start + length;
      // A block that runs past what was read is not something to guess at.
      if (end > bytes.length) return null;
      if (type == _vorbisCommentBlock) {
        return _parseComments(Uint8List.sublistView(bytes, start, end));
      }
      if (isLast) return null;
      offset = end;
    }
    return null;
  }

  static Map<String, List<String>>? _parseComments(Uint8List block) {
    int offset = 0;

    int? readUint32le() {
      if (offset + 4 > block.length) return null;
      final int value = block[offset] |
          (block[offset + 1] << 8) |
          (block[offset + 2] << 16) |
          (block[offset + 3] << 24);
      offset += 4;
      // A negative or absurd length is corruption, not a field.
      return value < 0 ? null : value;
    }

    final int? vendorLength = readUint32le();
    if (vendorLength == null || offset + vendorLength > block.length) {
      return null;
    }
    offset += vendorLength;

    final int? count = readUint32le();
    if (count == null) return null;

    final Map<String, List<String>> fields = <String, List<String>>{};
    for (int i = 0; i < count; i++) {
      final int? length = readUint32le();
      if (length == null || offset + length > block.length) return null;
      final Uint8List raw =
          Uint8List.sublistView(block, offset, offset + length);
      offset += length;
      _collect(fields, raw);
    }
    return fields;
  }

  /// Decodes one `FIELD=value` entry into [fields], keyed by upper-cased name.
  ///
  /// A comment with no separator, an empty name, or invalid UTF-8 is skipped:
  /// one unreadable entry must not cost the rest of the block. Everything after
  /// the first `=` is the value, so a value containing `=` survives.
  static void _collect(Map<String, List<String>> fields, Uint8List raw) {
    final String comment;
    try {
      comment = utf8.decode(raw);
    } on FormatException {
      return;
    }
    final int equals = comment.indexOf('=');
    if (equals <= 0) return;
    final String name = comment.substring(0, equals).toUpperCase();
    (fields[name] ??= <String>[]).add(comment.substring(equals + 1));
  }
}

/// The length of a FLAC file, from its STREAMINFO block: the total number of
/// samples over the sample rate.
///
/// STREAMINFO is the one block every FLAC must have, and it always comes
/// first, so this reads a few dozen bytes from the start of the file. Total
/// like [VorbisCommentFields]: anything that isn't a FLAC opening with a whole
/// STREAMINFO, or one that doesn't say how long it is, gives null.
abstract final class FlacStreamInfo {
  static const int _streamInfoBlock = 0;
  static const int _streamInfoLength = 34;

  static Future<Duration?> duration(File file) async {
    RandomAccessFile? handle;
    try {
      handle = await file.open();
      final Uint8List head = await handle.read(8 + _streamInfoLength);
      if (head.length < 8 + _streamInfoLength) return null;
      if (!VorbisCommentFields._isFlac(head)) return null;
      final int length = (head[5] << 16) | (head[6] << 8) | head[7];
      if ((head[4] & 0x7F) != _streamInfoBlock || length != _streamInfoLength) {
        return null;
      }
      // 20 bits of sample rate, 3 of channels, 5 of bits per sample, then 36
      // bits of total samples, from byte 10 of the block.
      const int at = 8 + 10;
      final int sampleRate =
          (head[at] << 12) | (head[at + 1] << 4) | (head[at + 2] >> 4);
      final int samples = ((head[at + 3] & 0x0F) << 32) |
          (head[at + 4] << 24) |
          (head[at + 5] << 16) |
          (head[at + 6] << 8) |
          head[at + 7];
      // Zero samples means the encoder didn't know the length.
      if (sampleRate == 0 || samples == 0) return null;
      return Duration(
        microseconds: samples * Duration.microsecondsPerSecond ~/ sampleRate,
      );
    } on FileSystemException {
      return null;
    } finally {
      await handle?.close();
    }
  }
}
