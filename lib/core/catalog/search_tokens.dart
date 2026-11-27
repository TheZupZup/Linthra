/// The search's words, cut in Dart for the Library's direct filters
/// (library_search.dart).
///
/// They have to find exactly what the Rust index (native/linthra_core) finds,
/// or a search would answer differently below and above the indexed size.
/// test/fixtures/search_cases.txt holds the cases both sides replay; Rust is
/// the reference, and a case belongs there before a behaviour is changed on
/// either side.
///
/// Not `foldText` (text_folding.dart): that folds whole strings for the
/// older substring search, with its own table. This one cuts text into words
/// the way the Rust core's normalize.rs does.
library;

/// Anything but a letter, a number, or a combining accent separates tokens.
/// `\p{Alphabetic}` and `\p{N}` are what Rust's `char::is_alphanumeric`
/// tests; combining accents stay in the word so they can fold away below.
final RegExp _separators =
    RegExp(r'[^\p{Alphabetic}\p{N}\u{0300}-\u{036F}]+', unicode: true);

/// Latin-1 Supplement and Latin Extended-A, lower case, to plain letters:
/// the same table as `fold_lowercase` in normalize.rs.
const Map<int, String> _fold = <int, String>{
  0xE0: 'a', 0xE1: 'a', 0xE2: 'a', 0xE3: 'a', 0xE4: 'a', 0xE5: 'a', //
  0x101: 'a', 0x103: 'a', 0x105: 'a',
  0xE6: 'ae',
  0xE7: 'c', 0x107: 'c', 0x109: 'c', 0x10B: 'c', 0x10D: 'c',
  0xF0: 'd', 0x10F: 'd', 0x111: 'd',
  0xE8: 'e', 0xE9: 'e', 0xEA: 'e', 0xEB: 'e', 0x113: 'e', 0x115: 'e', //
  0x117: 'e', 0x119: 'e', 0x11B: 'e',
  0x11D: 'g', 0x11F: 'g', 0x121: 'g', 0x123: 'g',
  0x125: 'h', 0x127: 'h',
  0xEC: 'i', 0xED: 'i', 0xEE: 'i', 0xEF: 'i', 0x129: 'i', 0x12B: 'i', //
  0x12D: 'i', 0x12F: 'i', 0x131: 'i',
  0x133: 'ij',
  0x135: 'j',
  0x137: 'k', 0x138: 'k',
  0x13A: 'l', 0x13C: 'l', 0x13E: 'l', 0x140: 'l', 0x142: 'l',
  0xF1: 'n', 0x144: 'n', 0x146: 'n', 0x148: 'n', 0x149: 'n', 0x14B: 'n',
  0xF2: 'o', 0xF3: 'o', 0xF4: 'o', 0xF5: 'o', 0xF6: 'o', 0xF8: 'o', //
  0x14D: 'o', 0x14F: 'o', 0x151: 'o',
  0x153: 'oe',
  0x155: 'r', 0x157: 'r', 0x159: 'r',
  0x15B: 's', 0x15D: 's', 0x15F: 's', 0x161: 's', 0x17F: 's',
  0xDF: 'ss',
  0x163: 't', 0x165: 't', 0x167: 't',
  0xFE: 'th',
  0xF9: 'u', 0xFA: 'u', 0xFB: 'u', 0xFC: 'u', 0x169: 'u', 0x16B: 'u', //
  0x16D: 'u', 0x16F: 'u', 0x171: 'u', 0x173: 'u',
  0x175: 'w',
  0xFD: 'y', 0xFF: 'y', 0x177: 'y',
  0x17A: 'z', 0x17C: 'z', 0x17E: 'z',
};

bool _isCombiningMark(int rune) => rune >= 0x300 && rune <= 0x36F;

final RegExp _ascii = RegExp(r'^[\x00-\x7F]*$');

/// [text] cut into lower-case, accent-folded tokens, exactly as the Rust
/// core cuts track metadata and queries.
List<String> searchTokens(String text) {
  final List<String> tokens = <String>[];
  for (final String word in text.split(_separators)) {
    if (word.isEmpty) continue;
    final String token = _foldWord(word);
    if (token.isNotEmpty) tokens.add(token);
  }
  return tokens;
}

String _foldWord(String word) {
  if (_ascii.hasMatch(word)) return word.toLowerCase();
  final StringBuffer folded = StringBuffer();
  for (final int rune in _lowerCase(word).runes) {
    if (_isCombiningMark(rune)) continue;
    final String? replacement = _fold[rune];
    if (replacement != null) {
      folded.write(replacement);
    } else {
      folded.writeCharCode(rune);
    }
  }
  return folded.toString();
}

final RegExp _cased = RegExp(r'^\p{Cased}$', unicode: true);
final RegExp _caseIgnorable = RegExp(r'^[\p{Mn}\p{Me}\p{Lm}]$', unicode: true);

/// [String.toLowerCase] rune by rune, plus the one context rule Rust's
/// `to_lowercase` applies and Dart's does not: a capital sigma preceded by a
/// cased letter and not followed by one becomes the final form ς ("ΣΑΣ" is
/// "σας", not "σασ"). Accents in between are skipped, as Unicode says.
String _lowerCase(String word) {
  if (!word.contains('Σ')) return word.toLowerCase();
  final List<int> runes = word.runes.toList(growable: false);
  bool casedAt(int i) => _cased.hasMatch(String.fromCharCode(runes[i]));
  bool ignorableAt(int i) =>
      _caseIgnorable.hasMatch(String.fromCharCode(runes[i]));
  bool casedBefore(int i) {
    for (int j = i - 1; j >= 0; j--) {
      if (!ignorableAt(j)) return casedAt(j);
    }
    return false;
  }

  bool casedAfter(int i) {
    for (int j = i + 1; j < runes.length; j++) {
      if (!ignorableAt(j)) return casedAt(j);
    }
    return false;
  }

  final StringBuffer out = StringBuffer();
  for (int i = 0; i < runes.length; i++) {
    if (runes[i] == 0x3A3 && casedBefore(i) && !casedAfter(i)) {
      out.write('ς');
    } else {
      out.write(String.fromCharCode(runes[i]).toLowerCase());
    }
  }
  return out.toString();
}
