import '../native/native_search_rank.dart';
import 'search_tokens.dart';
import 'search_typos.dart';

/// What a search result is. Its order is the order within a tier.
enum SearchResultKind { artist, album, song }

/// How well a result's own name matches the query. Its order is the ranking.
enum SearchMatchTier { full, exact, prefix, typo, other }

/// How [name] matches the query cut into [terms]: the name is the query word
/// for word; every word typed is a whole word of it; every word typed starts a
/// word of it; the same with typos; or not at all (the result was found by
/// another field, like a song by its artist).
SearchMatchTier nameTier(List<String> terms, String name) {
  if (terms.isEmpty) return SearchMatchTier.other;
  final List<String> tokens = searchTokens(name);
  bool starts(String term) =>
      tokens.any((String token) => token.startsWith(term));
  if (terms.every(starts)) {
    if (tokens.length == terms.length &&
        Iterable<int>.generate(terms.length)
            .every((int i) => tokens[i] == terms[i])) {
      return SearchMatchTier.full;
    }
    if (terms.every(tokens.contains)) return SearchMatchTier.exact;
    return SearchMatchTier.prefix;
  }
  if (terms.every(
    (String term) => tokens.any(
      (String token) => token.startsWith(term) || matchesWithTypos(term, token),
    ),
  )) {
    return SearchMatchTier.typo;
  }
  return SearchMatchTier.other;
}

/// The positions of [results] in the order the search shows them for
/// [query]: by [nameTier], then artist before album before song, then the
/// order given.
///
/// The same rule as `native/linthra_core/src/search_rank.rs`, held to it by
/// `test/fixtures/search_rank_cases.txt`. Decided by the Rust core when the
/// build has it; [useNative] false always takes the Dart path, for tests.
List<int> rankSearchResults(
  String query,
  List<(SearchResultKind, String)> results, {
  bool useNative = true,
}) {
  if (useNative) {
    final List<int>? native = NativeSearchRank.rank(
      query,
      <int>[for (final (SearchResultKind kind, _) in results) kind.index],
      <String>[for (final (_, String name) in results) name],
    );
    if (native != null) return native;
  }
  final List<String> terms = searchTokens(query);
  final List<(SearchMatchTier, SearchResultKind, int)> keyed =
      <(SearchMatchTier, SearchResultKind, int)>[
    for (int i = 0; i < results.length; i++)
      (nameTier(terms, results[i].$2), results[i].$1, i),
  ];
  keyed.sort(
    (a, b) => a.$1.index != b.$1.index
        ? a.$1.index - b.$1.index
        : a.$2.index != b.$2.index
            ? a.$2.index - b.$2.index
            : a.$3 - b.$3,
  );
  return <int>[for (final (_, _, int i) in keyed) i];
}
