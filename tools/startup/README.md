# Linux startup benchmark (#462)

How long after launch is Linthra actually *usable*, and does that fall off a
cliff when the library is large?

```bash
./tools/startup/run_startup_benchmark.sh
```

That is the whole command. It runs the benchmark three times (a baseline, an
identical control, and one with a deliberate slowdown injected) and tells you
whether the comparison between them behaved. Five to ten minutes depending on
the machine; `--iterations`, `--small-tracks` and `--large-tracks` make it
smaller.

Nothing here needs a Jellyfin, Plex or Navidrome server, a network, or a music
collection. The libraries are generated locally into real SQLite catalogs, and
the app under measurement has no source configured that could reach a server.

## What is measured

**Time from the widget tree being handed to Flutter (the test binding's
`runApp`) to the first frame the user could actually use.** Not
"the process started", and not "a frame was painted": both of those happen
while the Library is still a spinner, and a startup number that stops there
says nothing about waiting for your music to appear.

So the milestone is content, per workload:

| Library | First usable frame is |
| --- | --- |
| empty | the onboarding prompt is up (*No music folder selected*) |
| small, large | the first real track row is painted |

The Library shows its tabs and its song list in the same frame, so the frame
holding the first `TrackTile` is the first frame you could scroll or tap.

Everything between those two points is real work in real production code: the
Riverpod graph, the app shell, the router, the Drift database open, the
`SELECT` over the `tracks` table, the row-to-model mapping, the de-duplication
and grouping the Library reads through, and building the widgets. The
repository binding is `recordingDriftMusicLibraryRepositoryOverride`, the same
one `main()` applies, over a real on-disk SQLite file in the production
schema.

`first frame` is also recorded, as context. It is the app shell coming up, and
it barely moves with library size; the gap between the two columns is the
catalog work.

## What is **not** measured

Worth reading before quoting a number at anybody.

- **Process launch and engine start.** This runs under `flutter test`, so the
  Dart VM, the Flutter engine, the GTK window, the GPU surface and font loading
  are all already up before the clock starts. A real `linthra` launch pays all
  of that first. This measures the app, not the platform.
- **A release build.** `flutter test` is the JIT VM, so these are debug
  numbers: several times slower than what a user of a `--release` build sees,
  and slower in a way that is not a constant factor. The build mode is recorded
  in every sample set and the reporter refuses to compare across it.
- **libmpv, audio, MPRIS, the tray.** The playback controller is a fake, on
  purpose: this is a question about the library, and the audio engine would
  bring machine-specific `dlopen` cost into every number.
- **Anything over the network.** No server is configured, so nothing syncs. A
  real first launch against a fresh Jellyfin library is dominated by that sync,
  which is a different measurement and deliberately not this one.
- **Scrolling, navigation and memory.** Startup only. What happens after you
  start using the app is `test/benchmarks/large_library_memory_bench.dart` and
  `tools/large_library/`.
- **Library generation.** Each workload's catalog is written before the clock
  starts, and its cost is reported separately as `fixture_build_ms` so you can
  see it was not folded in.

## The three workloads

| Name | Tracks | What it stands for |
| --- | --- | --- |
| `empty` | 0 | a fresh install, nothing scanned yet |
| `small` | 1,000 | an ordinary personal collection |
| `large` | 20,000 | a collection big enough to change the shape |

Each is a real SQLite file in the production Drift schema, 12 tracks to an
album and 8 albums to an artist, so grouping does the work it would really do.
Titles are zero-padded, which keeps the alphabetical order (and therefore
which rows the first usable frame builds) identical on every launch.

20,000 is a compromise, not a target. `tools/large_library/` works at 200,000,
but that is raw SQL; here every row becomes a Dart object and a widget tree in
the JIT VM, and the cost grows faster than the row count (see the curve below).
`--large-tracks 50000` is available when you want the deeper look and have a
few minutes.

## How to compare two runs

The verdict is never "startup is under N milliseconds". That number belongs to
one machine, one build mode and one moment; a laptop on battery, a shared CI
runner and a desktop with an NVMe disk do not agree on it even when nothing has
changed. What travels between machines is the **ratio**, so that is what is
compared.

Record a baseline on the commit before your change, then measure your change
the same way on the same machine:

```bash
git stash                       # or check out the base commit
LINTHRA_STARTUP_OUT=/tmp/before.json LINTHRA_STARTUP_LABEL=before \
  flutter test test/benchmarks/startup_time_bench.dart

git stash pop
LINTHRA_STARTUP_OUT=/tmp/after.json LINTHRA_STARTUP_LABEL=after \
  flutter test test/benchmarks/startup_time_bench.dart

python3 tools/startup/startup_report.py /tmp/after.json \
  --baseline /tmp/before.json --expect same
```

A workload is called slower only when it exceeds **both** allowances: more than
25 ms slower *and* more than 30% slower. Two clauses, because one alone gets it
wrong in one direction or the other. Timing noise scales with the number being
measured, so a fixed millisecond band is far too tight on the large workload
and far too loose on the empty one; and a ratio on a small number is mostly
rounding, where a single scheduling hiccup on a 100 ms measurement is 40% and
no kind of regression. `--relative-allowance` and `--absolute-allowance-ms`
move them.

The reporter refuses outright to compare two runs that did not measure the same
thing: a different build mode, a different window size, a different milestone,
or a workload holding a different number of tracks. Printing a ratio across any
of those would be inventing a result rather than measuring one.

## Why the runner measures three times

A timing check nobody has tested is a timing check nobody should believe, so
both ways of being wrong are part of the run:

- **control against baseline** must come back `NO REGRESSION`. Two identical
  runs that disagree mean this machine is too noisy today, and any red result
  from the canary below would prove nothing. This is the false-positive
  control.
- **canary against baseline** must come back `REGRESSION`. The canary run sets
  `LINTHRA_STARTUP_SLOW_CATALOG_MS=250`, which wraps the real repository so
  every catalog read takes a quarter second longer. A slow catalog read is the
  most likely real startup regression there is. A check that only ever says
  "fine" is
  indistinguishable from one that has quietly stopped measuring, and handing it
  something it *must* catch is the only way to tell those apart. This is the
  false-negative control.

The slowdown is injected through a provider override from the test side. No
production code knows it exists, and neither does any other part of this.

Both allowances come from that run rather than from taste. One machine, one
sitting, five launches per workload:

| comparison | empty | small | large | verdict |
| --- | --- | --- | --- | --- |
| control vs baseline | 0.97x | 1.06x | 1.02x | no regression |
| canary (+250 ms a read) vs baseline | 6.47x | 2.69x | 1.10x | regression |

Two identical runs stayed inside 6% of each other, and inside 131 ms even on
the large workload; the injected delay landed at 2.7x and 6.5x. A 30% band with
a 25 ms floor sits between the two with room on both sides. Re-measure before
trusting it on very different hardware.

That table also shows why the run-level verdict is "**any** workload
regressed" rather than "all of them". A fixed 250 ms delay is enormous next to
a 117 ms empty-library startup and nearly invisible next to an 8-second one, so
a rule that needed every workload to agree would have missed a regression the
empty workload was shouting about.

## Budgets

`--budget large=15000` fails the run if a workload's median is over that many
milliseconds. It is off by default and CI never sets one, because a budget is
the one check here that does not travel: it encodes what one particular machine
can do. On a machine you own and keep quiet (a dedicated perf box, or your own
laptop with a number you measured yourself) it is a useful tripwire. Anywhere
else it is a future muted check.

## What CI does, and does not

`.github/workflows/startup-benchmark.yml` runs the reporter's unit tests, then
a **smoke** run of the harness: small libraries, two launches each, and a
structure check. It times nothing and asserts no duration.

That is deliberate. A GitHub runner is a shared machine of unknown load; a
millisecond figure taken on one says more about its neighbours that minute than
about Linthra. What CI *can* prove is that the benchmark still works: that it
still launches the app, still reaches a usable frame on all three workloads,
and still writes a sample set the reporter can read. A harness that has quietly
stopped matching the Library screen fails there rather than the next time
somebody needs it.

```bash
./tools/startup/run_startup_benchmark.sh --smoke   # the same thing, locally
```

## Reading the report

```
startup to first_usable_frame  (run: baseline)
  build mode:       debug - flutter test (Dart VM, JIT)
  host:             linux, 4 cores, Dart 3.12.2
  window:           1600x1000 @ 1x
  launches:         5 per workload (1 warm-up, ignored)
  network sources:  0

workload      tracks     first frame   first usable      min      max   spread
  empty            0            23.9          117.3     99.3    143.7      38%
  small        1,000            17.0          308.4    253.4    344.0      29%
  large       20,000            12.2         7794.1   7620.0  11507.9      50%
      spread is wide: this machine was busy, so read the medians with care
```

- **median, not mean.** One launch that lands on a garbage collection or a
  background process should not move the number, and a median ignores it.
- **the first launch of each workload is warm-up and is dropped.** It is not a
  startup measurement, it is a measurement of the VM compiling a widget tree it
  has never run before, and on a JIT run it is routinely several times the rest.
- **spread** is `(max - min) / median`: how much the machine disagreed with
  itself. It is reported, never enforced. A wide spread is the report telling
  you to close what is running before believing anything else in it.
- **fewer than three judged launches** makes a comparison report a regression
  rather than a pass. A truncated run must never read as a clean bill of
  health.

## Limitations

- **A baseline only means something on the machine and commit that produced
  it.** Comparing against someone else's file, or one from two months ago,
  measures the difference between those instead of your change.
- **Debug numbers are not release numbers.** They are useful for "did this
  commit make startup worse", useless for "how long does Linthra take to
  start". A real answer to the second needs a `--release` desktop build and a
  stopwatch outside the process. The reporter refuses to compare across build
  modes rather than let the two be mixed up.
- **The window size is part of the workload.** A taller window builds more rows
  into the first usable frame. It is fixed at 1600x1000 and recorded, and two
  runs at different sizes are refused.
- **This is one process, not a cold boot.** Page cache, the VM and the SQLite
  library are all warm by the second launch. That is the right shape for
  comparing two commits and the wrong shape for predicting a first-ever launch.
- **No personal data is involved anywhere.** The libraries are generated, the
  output is timings and counts, and nothing reads a real music folder.
- **No profiling hook ships.** The harness pumps the real widget tree and
  watches it with ordinary test finders. There is no instrumented build, no
  debug flag, and no production code that knows any of this exists.

## The pieces

| Piece | Job |
| --- | --- |
| `test/benchmarks/startup_time_bench.dart` | Launches the real app over each library and records the milestones. Decides nothing. |
| `tools/startup/startup_report.py` | Reads a sample set, reports it, compares two of them, and gives the verdict. |
| `tools/startup/run_startup_benchmark.sh` | The one command: baseline, control, canary, and both verdicts. |

The reporter's own tests need no Flutter and no measurement:

```bash
python3 test/tooling/startup_report_test.py
```

The harness is deliberately named `_bench.dart`, not `_test.dart`, so
`flutter test` does not pick it up: the numbers are machine-dependent and would
make a flaky CI gate.

## What the first run showed

A size sweep taken while building this, on one 4-core Linux container in the
debug JIT VM, median of the judged launches:

| Tracks | First usable frame |
| --- | --- |
| 0 | 117 ms |
| 1,000 | 308 ms |
| 2,000 | 457 ms |
| 5,000 | 806 ms |
| 10,000 | 2,831 ms |
| 20,000 | 7,794 ms |
| 50,000 | 57,105 ms |

Startup cost grows faster than the library does: past roughly 5,000 tracks,
doubling the catalog more than triples the time to a usable Library. `first
frame` stays flat across all of it (12 to 46 ms), so this is the catalog path
and not the shell, which is the whole reason the milestone is the first
*usable* frame rather than the first one.

That is a finding, not a verdict, and chasing it is separate work: this issue
is the instrument. What it does mean is that the large workload is the number
to watch, because a change that adds a pass over the catalog shows up there
first and largest.

**Read that column as a shape, not as figures.** Those rows come from several
sittings on a shared container, and the same 20,000-track workload measured
7.8 s in one and 12.1 s in another with nothing about Linthra changed. Inside a
single sitting, two identical runs agreed to within 6%. The gap between "same
machine, same sitting" and "same machine, different day" is exactly why the
check is a ratio against a baseline you recorded yourself minutes earlier, and
never a number written down in a file.
