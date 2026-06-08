import '../models/track.dart';
import '../sources/music_provider.dart';
import 'text_folding.dart';

/// Cross-provider identity for a [Track]: the `sourceId` that owns it and a
/// conservative "is this the same song?" match key used to unify duplicates that
/// the same library exposes through more than one provider (e.g. the same album
/// served by both Jellyfin and Navidrome/Subsonic).
///
/// Why a *key* rather than pairwise similarity: a single normalized key makes
/// unification a deterministic, order-independent `O(n)` grouping that is an
/// equivalence relation (so the result never depends on which two rows were
/// compared first). It also makes the matching trivially unit-testable.
///
/// The guiding rule is conservative: prefer keeping two rows separate over
/// merging songs that might be different. A merge therefore requires every
/// strong, tag-derived signal to agree, never the title alone.

/// The `sourceId` of the provider that owns [track], derived from its opaque
/// `scheme:` URI (`jellyfin:` / `subsonic:` / a local path). This is the same
/// mapping the capability model and the playback resolvers key off, so source
/// identity can never disagree across the app.
String trackSourceId(Track track) =>
    MusicProviders.forTrackUri(track.uri).sourceId;

/// Duration bucket width, in seconds. Two providers reading the same file report
/// the same whole-second duration (both floor it), so a 2-second bucket folds
/// any incidental rounding together while still separating genuinely different
/// lengths (a radio edit vs an extended mix) into different keys.
const int _durationBucketSeconds = 2;

/// A conservative match key for [track], or `null` when the track does not carry
/// enough trustworthy metadata to be matched against another provider's copy.
///
/// A non-null key requires all of: a folded title, a folded artist, a folded
/// album, and a known (non-zero) duration. Tracks missing any of these — most
/// untagged local files, for instance — return `null` and are therefore never
/// merged with anything; they always stand as their own library row. This is
/// what keeps local-only and lightly-tagged libraries behaving exactly as they
/// did before unification existed.
///
/// When every signal is present the key is built from the folded title, artist,
/// and album plus a coarse duration bucket. Each text part is length-prefixed
/// (the idiom `library_grouping` uses) so no separator char is needed and two
/// different splits can never collide. Case and accents are folded (via
/// [foldText]) so "Beyonce" and the accented "Beyoncé" match, but distinguishing
/// words are kept — "(Live)", "(Remix)", "(Radio Edit)" stay in the title — so
/// different versions of a song never collapse into one row.
String? logicalMatchKey(Track track) {
  final String title = foldText(track.title);
  final String artist = foldText(track.artistName ?? '');
  final String album = foldText(track.albumName ?? '');
  final int seconds = track.duration.inSeconds;
  if (title.isEmpty || artist.isEmpty || album.isEmpty || seconds <= 0) {
    return null;
  }
  final int bucket = seconds ~/ _durationBucketSeconds;
  return 'v1|${title.length}|$title|${artist.length}|$artist|'
      '${album.length}|$album|$bucket';
}

/// Whether [track] carries enough metadata to ever be unified with a copy from
/// another provider. Sugar over [logicalMatchKey] for call sites that only need
/// the yes/no.
bool canMatchAcrossProviders(Track track) => logicalMatchKey(track) != null;
