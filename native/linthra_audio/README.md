# linthra_audio (C++)

`linthra_audio` is Linthra's realtime DSP core. It gives C++/audio contributors a real part of the project to own while keeping the existing player stable until the mobile binding is ready.

## Current DSP

- fixed-size, allocation-free processing state
- mono/stereo float PCM
- preamp
- up to 8 parametric peaking-EQ bands
- stereo-linked peak limiter with immediate attack and smooth release
- transparent bypass when processing is disabled
- C ABI for a future Android/JNI or Dart FFI boundary
- 48 kHz stereo realtime regression benchmark

The processing callback does not allocate memory and does not take locks. Configuration computes coefficients outside the callback.

## Build and test

```bash
cmake -S native/linthra_audio -B build/linthra_audio -DCMAKE_BUILD_TYPE=Release
cmake --build build/linthra_audio --parallel
ctest --test-dir build/linthra_audio --output-on-failure
```

CI runs the same commands in Release and Debug. The realtime budget is excluded
from the Debug run, because an unoptimized build says nothing useful about the
performance of the build users actually get.

### What the test binaries cover

| Test | Covers |
| --- | --- |
| `linthra_audio_tests` | The chain end to end: bypass, preamp, one limited frame, an EQ impulse response, and the C ABI. |
| `linthra_audio_limiter` | Limiter response (#337) — see below. |
| `linthra_audio_bypass` | Bypass transparency (#342) — see below. |
| `linthra_audio_allocation` | Replaces global `operator new` and proves `process()` and `reset()` allocate nothing. |
| `linthra_audio_realtime_budget` | 60 s of 48 kHz stereo has to process well inside realtime. |

**Limiter response.** The ceiling holds across a full second of signal 6 dB over
it, not just on the first frame; a louder input does not produce a louder
output; a lower threshold lowers the ceiling; attack is immediate, so the frame
that goes over is already back under; release is a one-pole recovery with
`limiter_release_ms` as its time constant (~63% of the way back after one tau,
>99% after five), and a shorter release really does recover sooner; the gain is
stereo-linked, so the L/R ratio survives limiting; mono is limited too; an EQ
boost cannot push past the ceiling; and both `reset()` and `configure()` drop
the ducking so one stream cannot inherit another's.

**Bypass transparency.** "Transparent" means **bit-exact**, compared with `==`
rather than a tolerance, and the tests state why that is honest: every stage
that is off multiplies by exactly `1.0F`. That holds for mono and stereo, for
silence in both signs, for a flat or disabled EQ band, and — the case that
actually ships — while the limiter is armed but the signal stays under the
ceiling, including a sample sitting exactly *on* it. Unsupported channel counts,
zero frames and a null buffer leave the caller's memory alone.

The one place exactness is not claimed is right after the limiter has engaged:
its release is smooth, so a quiet passage following a loud one is still being
attenuated on the way back to unity. That is tested as the limit of the
guarantee rather than hidden behind a tolerance, together with `reset()`
restoring exactness immediately.

## Important boundary

This PR does not replace `just_audio` or silently alter playback. Linthra currently uses `just_audio`/the platform decoder pipeline, so inserting native PCM DSP safely requires a dedicated Android audio-processor binding. The C++ core is intentionally validated first; the binding can then be reviewed for audio focus, buffering, F-Droid reproducibility, and bypass correctness without also reviewing the DSP math.

## Good contribution areas

C++ contributors can work on SIMD implementations, filter types, channel-layout support, loudness/peak analysis, and the future Android audio-processor bridge without needing Flutter UI knowledge.
