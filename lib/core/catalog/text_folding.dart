// Pure, dependency-free text folding shared by Library search and the
// album/artist grouping.
//
// Folding is intentionally small and offline (a fixed Latin diacritics table
// rather than a Unicode-normalization package), so it adds no dependency and
// never reaches the network — there is nothing here that could expose a token
// or an authenticated URL. It lives in `core` so both the UI search box and the
// Android Auto browse tree (which derives albums/artists from the catalog) fold
// identically, without the browse tree reaching up into the library feature.

/// Common single-codepoint Latin diacritics mapped to their unaccented base, so
/// folding stays a cheap table lookup. Keys are lower-case; callers lower-case
/// first. Anything not listed passes through unchanged.
const Map<String, String> _diacritics = <String, String>{
  'á': 'a',
  'à': 'a',
  'â': 'a',
  'ä': 'a',
  'ã': 'a',
  'å': 'a',
  'ā': 'a',
  'ă': 'a',
  'ą': 'a',
  'ç': 'c',
  'ć': 'c',
  'č': 'c',
  'ċ': 'c',
  'ď': 'd',
  'đ': 'd',
  'é': 'e',
  'è': 'e',
  'ê': 'e',
  'ë': 'e',
  'ē': 'e',
  'ė': 'e',
  'ę': 'e',
  'ě': 'e',
  'ğ': 'g',
  'í': 'i',
  'ì': 'i',
  'î': 'i',
  'ï': 'i',
  'ī': 'i',
  'į': 'i',
  'ı': 'i',
  'ł': 'l',
  'ľ': 'l',
  'ñ': 'n',
  'ń': 'n',
  'ň': 'n',
  'ó': 'o',
  'ò': 'o',
  'ô': 'o',
  'ö': 'o',
  'õ': 'o',
  'ø': 'o',
  'ō': 'o',
  'ő': 'o',
  'ŕ': 'r',
  'ř': 'r',
  'š': 's',
  'ś': 's',
  'ş': 's',
  'ș': 's',
  'ť': 't',
  'ț': 't',
  'ú': 'u',
  'ù': 'u',
  'û': 'u',
  'ü': 'u',
  'ū': 'u',
  'ů': 'u',
  'ű': 'u',
  'ý': 'y',
  'ÿ': 'y',
  'ž': 'z',
  'ź': 'z',
  'ż': 'z',
  'ß': 'ss',
  'œ': 'oe',
  'æ': 'ae',
};

/// Lower-cases [input], strips common diacritics, and collapses runs of
/// whitespace to a single space (trimmed). The result is the canonical form
/// used both for matching and for stable grouping keys, so "  The   Café " and
/// "the cafe" fold to the same value.
String foldText(String input) {
  final String lower = input.toLowerCase();
  final StringBuffer out = StringBuffer();
  bool lastWasSpace = false;
  for (int i = 0; i < lower.length; i++) {
    final String ch = lower[i];
    if (ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r') {
      if (!lastWasSpace) {
        out.write(' ');
        lastWasSpace = true;
      }
      continue;
    }
    lastWasSpace = false;
    out.write(_diacritics[ch] ?? ch);
  }
  return out.toString().trim();
}
