# Flatpak audio playback smoke

Linthra's Linux audio runs on libmpv through media_kit. Outside a sandbox that
library comes from the distribution; inside the Flatpak it is built by the
manifest. Those are different libraries in different places, and a package can
be wrong about the second one while every native test still passes — because
the native tests were quietly using the first.

This smoke closes that gap (issue
[#446](https://github.com/TheZupZup/Linthra/issues/446)). It walks the real
playback lifecycle from inside an installed Flatpak, on the libmpv that Flatpak
shipped.

## What it actually validates

The lifecycle lives in `tool/linux_audio_backend_smoke.dart`, and it is the
same code the native Linux workflow runs. Each step asserts before the next one
starts, so a failure names the transition rather than the whole run:

| Step | What is asserted |
| --- | --- |
| initialize | A `LinuxPlaybackController` constructs and libmpv is really mapped into the process, from the required prefix |
| load | The fixture opens, the source is `localFile`, and the reported duration matches the file that was written |
| play | The engine reaches `playing` **and** the position advances past zero |
| pause | The engine reports `paused` **and** the position stops moving for a full second |
| seek | The position lands within 600 ms of the 2 s target, then playback resumes past **where it landed** (not past the target, which the tolerance band may already exceed) |
| stop | The loaded source is cleared and the engine settles back to `idle` |
| dispose | Runs in a `finally`, so a failed cycle cannot leave libmpv holding the device |

Three cycles run by default, which is what catches an initialize/dispose leak
rather than a single-shot failure.

### A finding: the app hangs on a wrong libmpv

Handed a library that loads under libmpv's name but exports none of its
symbols, the packaged app does not fail — it **hangs**, holding a window open.
CI held one for 46 minutes before the job was cancelled. media_kit takes what
`dlopen` gives it, and nothing downstream ever concludes that the thing it got
is not libmpv.

This is a packaging-failure mode rather than something a user can reach: a
Flatpak always ships its own libmpv. It is recorded here because it shapes the
negative control below, and because making the app check its own libmpv would
be a change to shipped code — its own issue, not a test's.

### The libmpv identity check

Set `LINTHRA_AUDIO_SMOKE_REQUIRE_LIBMPV_PREFIX` and the smoke reads
`/proc/self/maps` and fails if the libmpv the loader actually opened came from
anywhere else. The Flatpak run sets it to `/app/`.

This is the point of the whole exercise: a host libmpv is exactly what would
let a package that ships a broken or missing one still look healthy.

### The negative controls

A test that cannot fail proves nothing, so `scripts/flatpak_audio_smoke.sh`
runs the smoke twice more and requires both runs to **fail**, naming why.

1. **A libmpv that is not libmpv.** A real shared library is copied over
   *every* name media_kit will try — `libmpv.so`, `libmpv.so.2`,
   `libmpv.so.1`, in that order — in a directory prepended to
   `LD_LIBRARY_PATH`, so the first candidate opened is the shadow, and it
   cannot supply mpv's symbols.

   Because the app hangs rather than exits in that case, this control requires
   only that the run does **not pass**, and the run bound is what turns "hangs
   forever" into a result. That is the property that matters: a broken libmpv
   cannot produce a passing smoke.

   Three CI rounds shaped this control, each correcting the last. It first
   shadowed only the versioned soname, leaving the unversioned symlink the
   package also installs as the first thing media_kit opens. It then used a
   zero-byte file, which is not a broken library but an invalid one — an
   unreadable ELF header is skipped rather than loaded. Both made the control
   *pass*, which is the one thing a negative control must never do.

2. **The identity check itself.** The same run with
   `LINTHRA_AUDIO_SMOKE_REQUIRE_LIBMPV_PREFIX` pointed at a path nothing can
   satisfy has to fail on it — otherwise a passing positive run would not tell
   you the check ran at all. This one must fail *promptly and name libmpv*: a
   hang here would be a failure of the control.

The shadow lives in the sandbox's own cache directory, so `/app` is never
touched, and a control that could not be set up fails the job rather than
counting as a pass.

## What it does not validate

**It does not prove sound comes out of a speaker.** No CI runner has an audio
device, so both runs use libmpv's own `null` output, which discards the samples
but still paces them against the system clock — which is exactly what the
position, pause and seek assertions need. (ALSA's null PCM is not a substitute:
it takes data as fast as the decoder produces it, so there is no playback left
to observe.) Decode, timing, seeking and the transport are all real; the final
hop to hardware is not exercised.

That hop is a manual check. On a normal desktop, install the Flatpak and play a
track — the `--socket=pulseaudio` grant covers PulseAudio and PipeWire's
pulse shim, and the output-device picker under Settings is the quickest way to
confirm libmpv enumerated real devices.

It also does not validate remote/streaming playback, which needs a server, and
does not touch the network or any credential at any point.

## The fixture

A few dozen kilobytes of 8 kHz mono PCM — a quiet 440 Hz tone — generated into
the sandbox's own temp directory when the smoke starts.

Generated rather than committed on purpose: there is no media licence to track,
nothing to keep in sync with the test that reads it, no binary in review diffs,
and a reviewer can see exactly what the decoder is being handed.

## Why CI builds a second manifest

The smoke needs a second Flutter binary inside the package, and the submission
manifest must not carry one — a test harness in a published Flathub app is
dead weight a reviewer would rightly ask about.

So `scripts/make_flatpak_smoke_manifest.py` derives a build-only manifest from
the submission manifest: it appends the smoke build and install to the
`linthra` module, putting the binary at
`/app/libexec/linthra-audio-smoke/linthra`. It then re-parses its own output,
removes those commands again, and requires the result to equal the submission
manifest exactly. The runtime, the SDK, every library module, every source and
every `finish-args` entry are therefore identical by construction, and a
manifest regenerated by flatpak-flutter into a different shape fails the
generator instead of quietly producing a package the smoke no longer describes.

The generated manifest is git-ignored. It is never committed and never
submitted.

## Running it

In CI this is the `Audio lifecycle smoke in the sandbox` job in
`.github/workflows/flatpak-build.yml`, which runs beside the existing build
rather than after it, so the wall clock is unchanged.

Locally, from a clean checkout with `flatpak`, `flatpak-builder`, `xvfb-run`,
`dbus-run-session` and PyYAML available:

```sh
python3 scripts/make_flatpak_smoke_manifest.py

cd flatpak
flatpak-builder --user --install-deps-from=flathub --install-deps-only \
  --force-clean flatpak-builder-audio-smoke \
  io.github.thezupzup.linthra.audio-smoke.yml

flatpak-builder --user --force-clean --disable-cache --disable-rofiles-fuse \
  --repo=repo-audio-smoke flatpak-builder-audio-smoke \
  io.github.thezupzup.linthra.audio-smoke.yml
flatpak build-update-repo repo-audio-smoke

bash ../scripts/flatpak_audio_smoke.sh repo-audio-smoke
```

The harness refuses to run if Linthra is already installed, so it can never
uninstall or test a build you care about. Everything it does install, it
removes on exit, app data included.

Every sandbox run is time-bounded (`LINTHRA_FLATPAK_SMOKE_TIMEOUT`, 300s by
default), including the probe that checks the smoke binary is installed. The
Dart side bounds each transport step, but only once Dart is running — a hang in
the loader, the GTK realize, or media_kit bringing up a library that turns out
not to be libmpv has nothing else watching it, and a hung CI job serves no log
at all until it ends.

What hitting the bound *means* differs by run, and only one case accepts it:

| Run | Hitting the bound |
| --- | --- |
| The lifecycle run, and the install probe | a failure |
| The shadow control (a wrong libmpv) | **accepted** — the app is known to hang here, and what the control proves is that such a libmpv cannot produce a *passing* smoke |
| The identity control (a required prefix nothing satisfies) | a failure — this one must fail promptly and name libmpv |

An exit-0 run is never accepted, for any of them.

### Running just the lifecycle natively

Faster, and useful while changing the lifecycle itself. It uses the host's
libmpv, so it says nothing about packaging:

```sh
flutter build linux --release --target=tool/linux_audio_backend_smoke.dart
build/linux/x64/release/bundle/linthra
```

On a machine with a sound device, `LINTHRA_AUDIO_SMOKE_AO=pulse` plays it out
loud.

### Environment knobs

| Variable | Default | Purpose |
| --- | --- | --- |
| `LINTHRA_AUDIO_SMOKE_AO` | `null` | libmpv audio output. The default discards samples but still paces them against the system clock; set `pulse` to actually hear it |
| `LINTHRA_AUDIO_SMOKE_CYCLES` | `3` | How many full lifecycles to run |
| `LINTHRA_AUDIO_SMOKE_REQUIRE_LIBMPV_PREFIX` | unset | Directory the loaded libmpv must sit under |

## Failure output is sanitized

Both layers rewrite host identity out of anything they print: the home
directory, the login name, `/home/<name>` paths and `/run/user/<uid>`. libmpv
quotes file paths in its own error strings, the sandbox still sees the host's
`HOME` string, and this output ends up pasted into issues.

## Related

- [flatpak-ci.md](./flatpak-ci.md) — what the Flatpak build job proves
- [flatpak-filesystem-audit.md](./flatpak-filesystem-audit.md) — sandbox
  filesystem policy and its smoke
- [flatpak-development.md](./flatpak-development.md) — building the Flatpak
  locally
