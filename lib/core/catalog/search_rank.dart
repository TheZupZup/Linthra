import '../native/native_search_rank.dart';

/// What a search result is. Its order is the order within a tier.
enum SearchResultKind { artist, album, song }

/// The positions of [results] in the order the search shows them for
/// [query]: by how well each name matches it, then artist before album before
/// song, then the order given.
///
/// Decided by the Rust core (native/linthra_core/src/search_rank.rs), held
/// to `test/fixtures/search_rank_cases.txt`.
List<int> rankSearchResults(
  String query,
  List<(SearchResultKind, String)> results,
) =>
    NativeSearchRank.rank(
      query,
      <int>[for (final (SearchResultKind kind, _) in results) kind.index],
      <String>[for (final (_, String name) in results) name],
    );
