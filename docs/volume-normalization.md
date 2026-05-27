# Volume normalization (ReplayGain)

Linthra can even out the loudness of tracks during playback so a quiet ballad
and a loud single sit closer together, instead of you reaching for the volume
between songs. It does this with **ReplayGain** metadata and is **off by
default** — audio is never altered unless you turn it on in
**Settings → Playback → Normalize volume**.

## What it does

- Reads a track's ReplayGain loudness metadata (gain in dB, plus an optional
  peak) into the `ReplayGain` model (`lib/core/models/replay_gain.dart`).
- At play time the engine applies a **safe linear volume multiplier** derived
  from that gain (`ReplayGain.linearVolume`).
- It is applied **per track** as each track loads, and re-applied immediately
  when you flip the setting — no track change needed.

## Safety guarantees

These are enforced in `ReplayGain.linearVolume` and covered by tests
(`test/core/models/replay_gain_test.dart`):

1. **Files are never modified.** Normalization only sets the player's runtime
   volume. Nothing is re-encoded, no tags are written, and nothing is uploaded.
2. **No clipping.** When a peak is known, the gain is capped so the loudest
   sample can't exceed full scale. And because the engine can only attenuate
   (see the limitation below), applying a gain can never push audio into
   clipping.
3. **Safe default.** When a track carries no ReplayGain data, or the setting is
   off, playback uses full volume (`1.0`) — i.e. the original, untouched audio.

## just_audio limitation: attenuation only

The playback engine is [`just_audio`], whose `setVolume` accepts a value in the
range **`0.0`–`1.0`**. It can turn a track **down** but **cannot amplify above
the source level**.

ReplayGain gains are usually **negative** (most masters are louder than the
reference level), so the common case — turning loud tracks **down** to match —
works as intended. But a **positive** gain (a quiet track that ReplayGain wants
to turn **up**) cannot be fully applied: it is clamped to full volume and plays
at its original level rather than being boosted.

In practice this means tracks converge **down toward the quieter ones**, not up.
This is a deliberate, clip-safe trade-off, not a bug. A future engine with
pre-amp/gain headroom (or an explicit pre-amp setting) could lift the ceiling;
until then the ceiling is `1.0`.

There is intentionally **no equalizer** and no album/track mode switch in the
UI yet — the model supports both `ReplayGainMode.track` and `.album` (album
mode falls back to track gain and vice-versa), but the playback path uses track
mode.

## Supported sources and formats

Normalization applies to whatever loudness metadata a `Track` carries in its
`replayGain` field. Population of that field depends on the source:

| Source                | ReplayGain populated? | Notes |
| --------------------- | --------------------- | ----- |
| On this device (local) | Not yet               | Local tag parsing (ID3 `TXXX:REPLAYGAIN_*`, Vorbis `REPLAYGAIN_*`/`R128_*`) has not landed yet (see `lib/core/sources/local/local_track_mapper.dart`). When it does, the gain/peak read from tags flows straight into `Track.replayGain`. |
| Jellyfin              | Not yet               | The current item DTO doesn't carry a normalization-gain field; reading one is a follow-up and is out of scope here ("no provider expansion"). |
| Navidrome / Subsonic  | Not yet               | Same as above. |

Because the plumbing is source-agnostic, **enabling tag/metadata reading in any
one source is all that's needed** for normalization to take effect there — no
change to the settings, the engine, or the gain math. Until then the toggle is
present and safe, and simply has nothing to act on (every track normalizes to
full volume).

Formats are not restricted by Linthra: any container/codec `just_audio` can play
is eligible; what matters is whether ReplayGain metadata is available for the
track.

## Local vs. remote playback

The gain is applied the same way regardless of where audio comes from — local
files, Android SAF documents, the offline cache, or a remote stream — because it
acts on the single engine volume after the source URI is resolved. Casting is
unaffected: while a cast receiver owns playback the local engine is suspended,
so Linthra does not touch the receiver's volume.

[`just_audio`]: https://pub.dev/packages/just_audio
