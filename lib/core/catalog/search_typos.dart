/// Typo tolerance for the library search: the Dart side of
/// `native/linthra_core/src/typos.rs`, held to it by the F and M cases in
/// `test/fixtures/search_cases.txt`.
///
/// A query word that starts no token anywhere is matched instead against
/// tokens a few typos away, so "motorhed" finds Motörhead. A word that starts
/// some token is never matched this way. Lengths count characters (runes), as
/// the Rust side counts `char`s.
library;

/// How many typos a query word of [length] characters may carry: none under
/// 4, one up to 6, two from 7.
int maxTypos(int length) => length <= 3 ? 0 : (length <= 6 ? 1 : 2);

/// Whether [term] matches [token], or the start of [token], within the typos
/// its length allows. The first character must match; a typo is a character
/// inserted, deleted or replaced, or two neighbours swapped.
bool matchesWithTypos(String term, String token) {
  final List<int> a = term.runes.toList(growable: false);
  final List<int> b = token.runes.toList(growable: false);
  final int allowed = maxTypos(a.length);
  if (allowed == 0 || b.isEmpty || a.first != b.first) return false;
  final int shortest = a.length - allowed < 1 ? 1 : a.length - allowed;
  final int longest =
      a.length + allowed < b.length ? a.length + allowed : b.length;
  if (b.length < shortest) return false;
  if (_distance(a, b, b.length) <= allowed) return true;
  for (int end = shortest; end <= longest; end++) {
    if (_distance(a, b, end) <= allowed) return true;
  }
  return false;
}

/// Optimal string alignment distance between [a] and the first [end]
/// characters of [b].
int _distance(List<int> a, List<int> b, int end) {
  final int width = end + 1;
  final List<int> d = List<int>.filled((a.length + 1) * width, 0);
  for (int i = 0; i <= a.length; i++) {
    d[i * width] = i;
  }
  for (int j = 0; j <= end; j++) {
    d[j] = j;
  }
  for (int i = 1; i <= a.length; i++) {
    for (int j = 1; j <= end; j++) {
      final int cost = a[i - 1] == b[j - 1] ? 0 : 1;
      int best = d[(i - 1) * width + j] + 1;
      final int insert = d[i * width + j - 1] + 1;
      if (insert < best) best = insert;
      final int replace = d[(i - 1) * width + j - 1] + cost;
      if (replace < best) best = replace;
      if (i > 1 && j > 1 && a[i - 1] == b[j - 2] && a[i - 2] == b[j - 1]) {
        final int swap = d[(i - 2) * width + j - 2] + 1;
        if (swap < best) best = swap;
      }
      d[i * width + j] = best;
    }
  }
  return d[a.length * width + end];
}

/// For each of [terms], how a token is matched against it, given every
/// token of the list being searched ([allTokens]): by prefix when the term
/// starts some token, within its typos otherwise.
///
/// Returns one matcher per term, or null when a term matches no token either
/// way, which rules the whole query out.
List<bool Function(String token)>? termMatchers(
  List<String> terms,
  Set<String> allTokens,
) {
  final List<bool Function(String token)> matchers =
      <bool Function(String token)>[];
  for (final String term in terms) {
    if (allTokens.any((String token) => token.startsWith(term))) {
      matchers.add((String token) => token.startsWith(term));
      continue;
    }
    final Set<String> near = <String>{
      for (final String token in allTokens)
        if (matchesWithTypos(term, token)) token,
    };
    if (near.isEmpty) return null;
    matchers.add(near.contains);
  }
  return matchers;
}
