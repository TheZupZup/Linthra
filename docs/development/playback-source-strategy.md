# Playback source strategy

When the same song exists on more than one provider, Linthra decides *which copy
to play* in layers (see [unified-library.md](unified-library.md)):

1. **Default source** — the user's chosen/most-recently-signed-in provider is
   preferred (PR1).
2. **Runtime fallback** — if the preferred copy fails to resolve or start,
   playback tries the next candidate of the same song (PR2).
3. **Capability metadata** — an honest, derive-only snapshot of *what each
   candidate is* (PR3a).
4. **Source strategy** — a user-selectable rule that *reorders* the candidates
   using that metadata before playback (PR3b, below).

The strategy only changes the **order** candidates are tried. It never invents a
candidate, never changes de-duplication, and never overrides runtime fallback or
the now-playing source indicator.

## The model: `PlaybackSourceCapability`

`core/catalog/source_capability.dart` defines a small, immutable
`PlaybackSourceCapability` — an honest snapshot of what Linthra knows about one
source candidate. It is derived from existing data only and **decides nothing**.

| Field | Meaning | Source today |
| ----- | ------- | ------------ |
| `sourceId` / `providerType` | Owning provider (`jellyfin` / `subsonic` / `local` / unknown) | the track URI scheme |
| `delivery` | How bytes arrive: `localFile` / `cache` / `remoteStream` / unknown | URI scheme, or the resolver's `PlaybackSource` |
| `isLocalFile` / `isCachedOffline` / `isRemoteStream` | Convenience flags over `delivery` | derived |
| `duration` | Track length when known | `Track.duration` |
| `codec`, `bitrateKbps`, `fileSizeBytes` | Audio quality / data cost | **not captured yet → `null` (unknown)** |
| `transcoded` | Whether the server would transcode | **unknown (`null`)** |
| `isLikelyLan` | LAN vs. public internet | **unknown (`null`)** — never guessed from a URL/IP |
| `transcodingKnown` / `qualityKnown` / `dataCostKnown` | Whether those are known at all | derived |

It is built two ways, both pure (no network, no disk, no background work):

- `PlaybackSourceCapability.fromTrack(track)` — owning provider, inherent
  delivery (local file vs. remote stream), and duration.
- `PlaybackSourceCapability.fromResolvedSource(track, playbackSource)` — refines
  delivery with what the resolver actually chose, so a downloaded copy is marked
  `cache` using the existing, safe `PlaybackSource.offlineCache` signal.

> Not to be confused with `MusicProviderCapabilities` (in
> `core/sources/music_provider.dart`), which describes a *provider's abilities*
> (can stream, can cache, can cast …). `PlaybackSourceCapability` describes a
> *single candidate* for *one* song.

## Principles (kept deliberately strict)

- **Unknown stays unknown.** Anything not safely derivable is `null` / `unknown`,
  never a fabricated value.
- **No new I/O.** No network calls, no probing, no background polling, no extra
  battery use — only existing in-memory `Track` / resolver data is read.
- **No private data.** The model stores only a non-identifying `sourceId` plus
  enums and numbers. The track URI, file path, server host, username, and tokens
  are never stored or printed; `toString()` is safe to log.
- **No decisions.** PR3a never ranks or selects a candidate.

## The strategy (PR3b): `PlaybackSourceStrategy`

`core/catalog/source_strategy.dart` defines the user-selectable strategy and one
pure function, `orderBySourceStrategy(candidates, strategy, profileOf)`, that
reorders a song's candidate list. The user picks the strategy in **Settings →
Playback source strategy**; it is persisted (`PlaybackSourceStrategyStore`) and
read by `playbackCandidatesProvider`, which reorders each multi-source song's
candidates before the runtime-fallback controller tries them.

| Strategy | Ordering |
| -------- | -------- |
| **Prefer default provider** | Identity — the PR1/PR2 default-source order, unchanged. |
| **Prefer local/cache** | Downloaded/offline copy first, then on-device file, then server copies. |
| **Prefer highest quality** | Known higher-bitrate copies first; unknown-quality copies keep their default slot. |
| **Prefer lower data usage** | Cache/local first, then known lower-bitrate server copies; unknown stays in default order. |
| **Automatic (balanced)** | Cache/local first, otherwise the default order — no server-vs-server guessing. |

### Guarantees

- **Deterministic & explainable.** Ordering is a stable transform with the
  original (default-provider) order as the **final tie-breaker**, so equal
  candidates never swap and `preferDefault` is the exact identity. The same
  inputs always produce the same order.
- **Default provider is the fallback tie-breaker.** Every strategy that can't
  distinguish two candidates leaves them in default-provider order.
- **Unknown stays unknown.** Quality/data rules move a candidate *only* when the
  value (e.g. `bitrateKbps`) is actually known. Unknown values never move a row
  and are never faked — so today, with bitrate/size not yet captured, the quality
  and lower-data strategies fall back to the default order (after the cache/local
  step). "Prefer highest quality" therefore never silently picks a lower-quality
  copy.
- **Runtime fallback still applies.** Strategy ordering happens *before* the PR2
  controller, which still tries the next candidate if the first fails.
- **The indicator shows the real source.** "Playing from …" reflects the copy
  that actually started, not the strategy's first pick.
- **Cheap, private, safe.** Cache/local preference uses the in-memory
  offline-available set (`offlineAvailableTrackIdsProvider`) — no network call,
  no disk scan, no background polling, no path or URL. The strategy is a
  non-secret enum name; nothing sensitive is stored or logged.

### What stays for later

- Plumb real `codec` / `bitrateKbps` / `fileSizeBytes` from the Subsonic/Jellyfin
  wire data onto `Track` (and thus into the profile). Once present, the quality
  and lower-data strategies start ordering server copies by real numbers — no
  code change to the ordering needed, because it already reads those fields and
  ignores them only while they are unknown.
