# Playback source strategy (capability metadata)

When the same song exists on more than one provider, Linthra already decides
*which copy to play* in two ways (see [unified-library.md](unified-library.md)):

1. **Default source** — the user's chosen/most-recently-signed-in provider is
   preferred (PR1).
2. **Runtime fallback** — if the preferred copy fails to resolve or start,
   playback tries the next candidate of the same song (PR2).

A future **smart strategy** (PR3b) will go further and pick a copy by *cost and
quality*, e.g.:

- Prefer local/cache
- Prefer highest quality
- Prefer lower data usage
- Automatic (balanced)

To decide that well, the strategy needs to know *what each candidate is*. **PR3a
(this change) only captures that metadata.** It does not change which source is
chosen, the default-source behaviour, runtime fallback, or de-duplication.

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

## What PR3b will add (not in this change)

- Plumb real `codec` / `bitrateKbps` / `fileSizeBytes` from the Subsonic/Jellyfin
  wire data onto `Track` (and thus into the profile), where available.
- A strategy that ranks candidates from these profiles (prefer local/cache,
  highest quality, lowest data, or balanced), feeding the same ordered-candidate
  mechanism the default-source and runtime-fallback layers already use.
