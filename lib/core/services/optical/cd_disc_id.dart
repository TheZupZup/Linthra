import '../../models/audio_cd.dart';
import '../../native/native_optical.dart';
import 'cdrom_toc_source.dart';

/// A stable identifier for the disc [toc] came off, or null when the table of
/// contents cannot produce one.
///
/// ## Why this identifier and not one of Linthra's own
///
/// A disc needs an identity that is the *disc's*, not the drive's:
/// `/dev/sr0` names the tray, and using it would make every disc anybody ever
/// puts in that drive the same disc. The standard answer to that is the
/// **MusicBrainz Disc ID** — a hash of the track offsets, which is to say of
/// the disc's own geometry. It is computed here exactly as `libdiscid`
/// computes it (`src/toc.c` and `src/disc.c`), so Linthra's value for a disc
/// is the value every other tool produces for it.
///
/// Reusing the standard rather than inventing a fingerprint costs nothing and
/// buys the one thing an invented one could not: a later, *opt-in* metadata
/// lookup would need this exact string, and would otherwise have to be
/// designed around a second identifier that means almost the same thing.
///
/// **Computing it is not looking it up.** This is arithmetic over bytes the
/// drive already handed us. Nothing in Linthra sends it anywhere, and PR 2
/// makes no network request of any kind.
///
/// ## How it is computed
///
/// SHA-1 over an 804-character ASCII string: the first audio track number and
/// the last audio track number as two uppercase hex digits each, then 100
/// eight-digit uppercase hex offsets. Offset 0 is the lead-out; offsets 1-99
/// are the tracks, in frames from the start of the lead-in (LBA +
/// [cdLeadInFrames]), and every slot with no track in it is zero. The 20-byte
/// digest is then base64-encoded with `+`, `/` and `=` replaced by `.`, `_`
/// and `-`, so the result is safe in a URL.
///
/// Two details are what make it agree with everyone else's:
///
///  * **The last track is the last *audio* track.** A CD-Extra's data track is
///    not part of the identity.
///  * **The lead-out is the audio session's lead-out.** When a data track
///    follows the last audio track, the data track's start minus
///    [cdXaInterval] stands in for it, because the real lead-out is at the end
///    of the data session.
///
/// The first track number, by contrast, is the disc's, not the first audio
/// track's — a disc whose track 1 is data still starts at track 1. That is
/// deliberate on MusicBrainz's side (a release is expected to start at track
/// 1) and copying it is the whole point of using the standard.
///
/// One deliberate difference from `libdiscid`: where it walks the last track
/// backwards until the lead-out is past it, Linthra returns null. That loop
/// exists for discs whose last entry is neither valid audio nor valid data,
/// and inventing an identity for a disc whose TOC contradicts itself is worse
/// than having none — the tracks are still read and still playable, they are
/// simply not claimed to be a disc anybody else would recognise.
///
/// Computed by the Rust core (native/linthra_core/src/optical.rs).
String? musicBrainzDiscId(RawCdToc toc) => NativeOptical.discId(toc);
