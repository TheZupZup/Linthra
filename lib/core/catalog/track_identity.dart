import 'package:flutter/foundation.dart';

import '../models/track.dart';
import '../sources/music_provider.dart';
import 'text_folding.dart';

/// Cross-provider identity for a [Track]: the `sourceId` that owns it and a
/// conservative "is this the same song?" decision used to unify duplicates that
/// the same library exposes through more than one provider (e.g. the same album
/// served by both Jellyfin and Navidrome/Subsonic).
///
/// ## Why scored matching (not one exact key)
///
/// The first cut keyed unification on an *exact* folded `title|artist|album` plus
/// a duration bucket. On a real Jellyfin/Navidrome pair that key is too strict
/// and leaves duplicates behind, because the two servers rarely tag a song
/// byte-for-byte identically:
///
///  * **Featured artists drift.** One server stores `CAREFUL`, the other
///    `CAREFUL feat. Cordae`; one stores artist `NF`, the other `NF, Cordae`.
///    Any of these splits the exact key, so the song shows twice.
///  * **Album editions drift.** `25` vs `25 (Deluxe)`.
///  * **Duration bucket boundaries.** A 2-second *bucket* (not a 2-second
///    *difference*) still split a 1-second rounding gap that straddled a bucket
///    edge (e.g. 181s in bucket 90, 182s in bucket 91).
///
/// So matching is now a conservative **score with hard vetoes**. Two eligible
/// tracks are compared on the strong, tag-derived signals the request calls out
/// — near-same duration, normalized album, title-token overlap, artist-token
/// overlap, and track number — and merge only when the weighted score clears a
/// high threshold *and* no veto fires. The guiding rule is unchanged: prefer
/// keeping two rows separate over merging songs that might be different.

/// The `sourceId` of the provider that owns [track], derived from its opaque
/// `scheme:` URI (`jellyfin:` / `subsonic:` / a local path). This is the same
/// mapping the capability model and the playback resolvers key off, so source
/// identity can never disagree across the app.
String trackSourceId(Track track) =>
    MusicProviders.forTrackUri(track.uri).sourceId;

/// Two providers reading the same file report the same whole-second duration
/// (both floor it). A re-encode/transcode can nudge it by a second, so copies
/// within this many seconds of each other are treated as the same length; any
/// wider gap is a hard veto (a radio edit vs an extended mix is a different
/// song). Compared as an absolute *difference*, so there is no bucket-edge gap.
const int _nearDurationSeconds = 2;

/// Signal weights (sum to 1.0). Title carries the most weight (it is the most
/// discriminating field), then album, then artist. Tuned with [kTrackMatchScore]
/// so that the real-world drifts above merge while the conservative cases below
/// stay separate:
///  * same title, same artist, *different* album (containment 0.5) → 0.85 < th.
///  * same title+album+artist but `(Live)`/`(Remix)` (title Jaccard 0.5) → < th.
const double _wTitle = 0.45;
const double _wAlbum = 0.30;
const double _wArtist = 0.25;

/// The minimum [trackMatchScore] (after vetoes) for two copies to be considered
/// the same song. High by design: at 0.9 a single strong field disagreeing is
/// enough to keep two rows separate, so we under-merge rather than over-merge.
const double kTrackMatchScore = 0.9;

/// Whether [track] carries enough trustworthy metadata to *ever* be unified with
/// a copy from another provider: a foldable title, artist, and album, plus a
/// known (non-zero) duration. Tracks missing any of these — most untagged local
/// files — can never match and always stand as their own library row, exactly as
/// before unification existed.
bool canMatchAcrossProviders(Track track) => matchBlockKey(track) != null;

/// A coarse, order-independent *blocking* key that co-locates plausible matches
/// so scoring is cheap (only tracks in the same block are ever compared), or
/// `null` when [track] is ineligible (see [canMatchAcrossProviders]).
///
/// The key is the folded *primary* artist token plus the folded *first* title
/// token (with any `feat.`/`ft.`/`featuring` qualifier stripped). Both are stable
/// across providers for the same song even when the *full* artist or title drift
/// (a featured-artist suffix, a `(Deluxe)` album), so true matches share a block
/// while the block stays small. Scoring inside the block does the precise work.
String? matchBlockKey(Track track) {
  if (track.duration.inSeconds <= 0) return null;
  final List<String> artist = _tokenize(foldText(track.artistName ?? ''));
  final List<String> album = _tokenize(foldText(track.albumName ?? ''));
  final List<String> title = _coreTitleTokens(track.title);
  if (artist.isEmpty || album.isEmpty || title.isEmpty) return null;
  // A separator so two tokens can never run together into a third key
  // ('ab|c' vs 'a|bc'); blocking only needs to be coarse, but stays clean.
  return '${artist.first}|${title.first}';
}

/// A conservative similarity score in `[0.0, 1.0]` for whether [a] and [b] are
/// the same song. `0.0` for any *veto*: either is ineligible, the durations are
/// more than [_nearDurationSeconds] apart, or both carry a track number and the
/// numbers differ (different positions on the same album → different songs).
///
/// Otherwise it is the weighted sum of three signals:
///  * **title** — `1.0` when the feat-stripped titles match token-for-token,
///    else the Jaccard overlap of their token sets (so `(Live)`/`(Remix)` extra
///    tokens cost score and keep versions distinct);
///  * **album** — the containment of the smaller album-token set in the larger,
///    so `25` ⊆ `25 (Deluxe)` scores `1.0` but `Album A` vs `Album B` scores 0.5;
///  * **artist** — the containment of the smaller artist-token set in the larger,
///    so `NF` ⊆ `NF, Cordae` scores `1.0` (featured artists), while two genuinely
///    different artists share no tokens and score `0.0`.
double trackMatchScore(Track a, Track b) {
  if (!canMatchAcrossProviders(a) || !canMatchAcrossProviders(b)) return 0;
  // Hard vetoes — signals the weighted score cannot express on its own.
  if ((a.duration.inSeconds - b.duration.inSeconds).abs() >
      _nearDurationSeconds) {
    return 0;
  }
  if (_trackNumbersConflict(a, b)) return 0;

  final double title = _titleScore(a.title, b.title);
  final double album = _containment(
    _tokenize(foldText(a.albumName ?? '')),
    _tokenize(foldText(b.albumName ?? '')),
  );
  final double artist = _containment(
    _artistTokens(a.artistName),
    _artistTokens(b.artistName),
  );
  return _wTitle * title + _wAlbum * album + _wArtist * artist;
}

/// Whether [a] and [b] are confidently the same song — [trackMatchScore] at or
/// above [kTrackMatchScore]. The single predicate the unifier merges on.
bool isLikelySameTrack(Track a, Track b) =>
    trackMatchScore(a, b) >= kTrackMatchScore;

// --- scoring helpers --------------------------------------------------------

/// `1.0` when the feat-stripped, folded titles are token-identical; otherwise
/// the Jaccard overlap of their token *sets*. Jaccard (not containment) is used
/// for titles because extra title tokens usually signal a different *version*
/// (`(Live)`, `(Radio Edit)`), which should cost score rather than be forgiven.
double _titleScore(String a, String b) {
  final List<String> ta = _coreTitleTokens(a);
  final List<String> tb = _coreTitleTokens(b);
  if (listEquals(ta, tb)) return 1.0;
  return _jaccard(ta.toSet(), tb.toSet());
}

/// `feat.`/`ft.`/`featuring` qualifiers anywhere in the title, in `(parens)` or
/// `[brackets]` or trailing bare — but stopping at an opening bracket so a
/// following version marker (`(Live)`) is preserved.
final RegExp _parenFeat =
    RegExp(r'[\(\[][^\)\]]*\b(?:feat|ft|featuring)\b[^\)\]]*[\)\]]');
final RegExp _trailingFeat = RegExp(r'\b(?:feat|ft|featuring)\b[^\(\[]*$');

/// The folded title with featured-artist qualifiers removed, tokenized. So
/// `CAREFUL`, `CAREFUL feat. Cordae`, and `Careful (feat. Cordae)` all reduce to
/// `[careful]`, while `Hello (Live)` keeps `[hello, live]`.
List<String> _coreTitleTokens(String title) {
  String s = foldText(title);
  s = s.replaceAll(_parenFeat, ' ');
  s = s.replaceAll(_trailingFeat, ' ');
  return _tokenize(s);
}

/// Connective words dropped from artist tokens so `NF feat. Cordae`, `NF, Cordae`
/// and `Hall and Oates` / `Hall & Oates` normalize consistently. Deliberately
/// small — ambiguous joiners (`x`, `vs`, `with`) are kept so they can still
/// distinguish acts.
const Set<String> _artistStopwords = <String>{'feat', 'ft', 'featuring', 'and'};

/// Folded artist tokens with the connective stopwords removed, as a set. `NF` →
/// `{nf}`; `NF, Cordae` → `{nf, cordae}`; `Hall & Oates` → `{hall, oates}`.
Set<String> _artistTokens(String? artist) {
  return <String>{
    for (final String t in _tokenize(foldText(artist ?? '')))
      if (!_artistStopwords.contains(t)) t,
  };
}

/// Both tracks carry a track number and the numbers differ — a strong signal of
/// two different tracks (e.g. on the same album), so a veto. A missing number on
/// either side is not evidence and never vetoes.
bool _trackNumbersConflict(Track a, Track b) {
  final int? na = a.trackNumber;
  final int? nb = b.trackNumber;
  return na != null && nb != null && na != nb;
}

/// `|a ∩ b| / |a ∪ b|`, the symmetric overlap of two token sets, in `[0, 1]`.
double _jaccard(Set<String> a, Set<String> b) {
  if (a.isEmpty && b.isEmpty) return 1.0;
  if (a.isEmpty || b.isEmpty) return 0.0;
  final int intersection = a.where(b.contains).length;
  final int union = a.length + b.length - intersection;
  return union == 0 ? 0.0 : intersection / union;
}

/// `|a ∩ b| / |smaller|`, how fully the smaller token collection sits inside the
/// larger, in `[0, 1]`. Lenient by design (a subset scores `1.0`) so an added
/// `(Deluxe)` album word or a featured artist does not cost score; takes
/// [Iterable]s so it works for both list- and set-shaped token collections.
double _containment(Iterable<String> a, Iterable<String> b) {
  final Set<String> sa = a.toSet();
  final Set<String> sb = b.toSet();
  if (sa.isEmpty || sb.isEmpty) return 0.0;
  final int intersection = sa.where(sb.contains).length;
  final int smaller = sa.length < sb.length ? sa.length : sb.length;
  return smaller == 0 ? 0.0 : intersection / smaller;
}

/// Splits folded text into alphanumeric tokens, dropping all punctuation and
/// whitespace. `"25 (deluxe)"` → `["25", "deluxe"]`.
List<String> _tokenize(String folded) => folded
    .split(RegExp(r'[^a-z0-9]+'))
    .where((String t) => t.isNotEmpty)
    .toList();
