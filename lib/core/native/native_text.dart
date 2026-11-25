import 'dart:convert';
import 'dart:typed_data';

/// One UTF-8 buffer holding every field, and the spans that point into it.
///
/// ASCII (most metadata) is written byte by byte with no allocation; anything
/// else goes through the codec.
class NativeTextWriter {
  /// Sized for [tracks] typical tracks, so a normal catalog never grows it.
  NativeTextWriter(int tracks) : _bytes = Uint8List(64 + tracks * 48);

  Uint8List _bytes;
  int _length = 0;

  /// Whether a string held an unpaired surrogate, which UTF-8 cannot carry:
  /// the codec writes U+FFFD instead, so Rust would see different text.
  bool lossy = false;

  /// Writes [part] and its span (start, length) into [spans] at [at].
  void add(Uint32List spans, int at, String part) {
    final int start = _length;
    spans[at] = start;
    // At most three UTF-8 bytes per UTF-16 code unit.
    _reserve(part.length * 3);
    for (int i = 0; i < part.length; i++) {
      final int unit = part.codeUnitAt(i);
      if (unit >= 0x80) {
        _length = start;
        if (_hasUnpairedSurrogate(part, i)) lossy = true;
        final Uint8List encoded = utf8.encode(part);
        _bytes.setRange(_length, _length + encoded.length, encoded);
        _length += encoded.length;
        break;
      }
      _bytes[_length++] = unit;
    }
    spans[at + 1] = _length - start;
  }

  void _reserve(int more) {
    if (_length + more <= _bytes.length) return;
    int capacity = _bytes.length * 2;
    while (capacity < _length + more) {
      capacity *= 2;
    }
    _bytes = Uint8List(capacity)..setRange(0, _length, _bytes);
  }

  /// The bytes written so far, as a view (no copy).
  Uint8List bytes() => Uint8List.sublistView(_bytes, 0, _length);
}

/// Whether [text], from [from] on, has a surrogate without its other half.
bool _hasUnpairedSurrogate(String text, int from) {
  for (int i = from; i < text.length; i++) {
    final int unit = text.codeUnitAt(i);
    if (unit < 0xD800 || unit > 0xDFFF) continue;
    if (unit > 0xDBFF) return true;
    if (i + 1 == text.length) return true;
    final int next = text.codeUnitAt(i + 1);
    if (next < 0xDC00 || next > 0xDFFF) return true;
    i++;
  }
  return false;
}
