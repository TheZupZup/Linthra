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
smaller. `--iterations` has a floor: a comparison ignores the warm-up launch
and will not judge fewer than three, so too small a number would make the
control fail however identical the timings are. The runner asks the reporter
what that minimum is and refuses before running anything rather than after
three scenarios.

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

### Two clocks, because one of them is blind

`flutter test` drives time itself. `tester.pump(d)` advances the binding's
*fake* clock by `d` and runs a frame; it does not wait `d` of real time. That
splits startup into two quantities, and a check that watched only one of them
would wave the other through:

| Clock | What it sees | Column |
| --- | --- | --- |
| wall clock | work the CPU actually did: the query, the mapping, building the widgets | `first usable` |
| simulated | time the app spent **awaiting** something: a timer, a delayed future, a retry backoff | `awaited` |

A regression that adds 250 ms of awaiting costs no measurable wall time here,
and a regression that adds real work costs no simulated time. The reporter
compares both and calls either one a regression, naming which fired.

The measured shape of that, from the canary run below: a clean launch takes
3 frames on every workload, and one with 250 ms injected into each catalog read
takes 65, which is 256 ms of simulated time: the delay almost exactly. On the
large workload the same run came out at **0.90x** on the wall clock, which is
to say *faster* than the baseline it was slowing down, because a busy machine
moved a 12-second number more than the delay did. A wall clock alone would have
called that one fine. The simulated clock put it at +248 ms like every other
workload, and being quantized and machine-independent it does the same on a
quiet machine and a fast one.

## What is **not** measured

Worth reading before quoting a number at anybody.

- **Process launch and engine start.** This runs under `flutter test`, so the
  Dart VM, the Flutter engine, the GTK window, the GPU surface and font loading
  are all already up before the clock starts. A real `linthra` launch pays all
  of that first. This measures the app, not the platform.
- **The database's background isolate.** Production opens SQLite with
  `NativeDatabase.createInBackground`, which runs it on its own isolate; the
  harness opens the same file in-process. That is forced, not chosen:
  `createInBackground` waits on a message from that isolate, and the
  widget-test binding owns the clock and the event loop, so under `testWidgets`
  the open never completes and the test hangs until it times out. The isolate
  spawn and the per-query message round-trip are therefore missing, and the
  query runs on the UI isolate here rather than off it, which makes the
  catalog's share of the number a conservative *upper* bound.
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

A workload is called slower when **either clock** says so:

- **it worked longer.** The wall clock exceeds *both* allowances: more than
  25 ms slower *and* more than 30% slower. Two clauses, because one alone gets
  it wrong in one direction or the other. Timing noise scales with the number
  being measured, so a fixed millisecond band is far too tight on the large
  workload and far too loose on the empty one; and a ratio on a small number is
  mostly rounding, where a single scheduling hiccup on a 100 ms measurement is
  40% and no kind of regression.
- **it waited longer.** More than 16 ms of extra simulated time. One allowance
  and no ratio, because this number is quantized to whole frames and identical
  between machines: a few frames is the whole of the noise, and a percentage of
  it would mean nothing.

`--relative-allowance`, `--absolute-allowance-ms` and
`--simulated-allowance-ms` move them, on the reporter and on
`run_startup_benchmark.sh` alike.

The reporter refuses outright to compare two runs that did not measure the same
thing: a different build mode, a different window size, a different milestone,
a different pump interval (which is the unit `awaited` is counted in, so
changing it rescales that whole column), a workload holding a different number
of tracks, or a different *set* of workloads. That last one matters because `LINTHRA_STARTUP_WORKLOADS` makes a
subset easy to produce, and a run-level verdict that quietly skipped the
workload missing from one side would pass a regression nobody measured.
Printing a number across any of those would be inventing a result rather than
measuring one.

## Why the runner measures three times

A timing check nobody has tested is a timing check nobody should believe, so
both ways of being wrong are part of the run:

- **control against baseline** must come back `NO REGRESSION`. Two identical
  runs that disagree mean this machine is too noisy today, and any red result
  from the canary below would prove nothing. This is the false-positive
  control.
- **canary against baseline** must come back `REGRESSION` **on every
  workload**. The canary run sets `LINTHRA_STARTUP_SLOW_CATALOG_MS=250`, which
  wraps the real repository so every catalog read takes a quarter second
  longer. A slow catalog read is the most likely real startup regression there
  is. A check that only ever says "fine" is indistinguishable from one that has
  quietly stopped measuring, and handing it something it *must* catch is the
  only way to tell those apart. This is the false-negative control.

  Every workload, not just one, and this is the one place the ordinary
  any-workload policy is not enough: the delay goes into *every* read, so a
  canary that still fires on `empty` and no longer fires on `large` has shown
  that two thirds of the check stopped working, and `any()` would print "both
  controls passed" over it. `--expect regressed-everywhere` is what the runner
  holds it to.

The slowdown is injected through a provider override from the test side. No
production code knows it exists, and neither does any other part of this.

Both allowances come from that run rather than from taste. One machine, one
sitting, five launches per workload:

| comparison | empty | small | large | awaited | verdict |
| --- | --- | --- | --- | --- | --- |
| control vs baseline | 0.96x | 1.01x | 1.00x | +0 ms | no regression |
| canary (+250 ms a read) vs baseline | 6.48x | 2.65x | 0.90x | +248 ms | regression |

Two identical runs landed within 1% of each other on every workload and moved
the simulated clock not at all; the injected delay landed at 2.7x and 6.5x on
the wall clock, and at +248 ms of simulated time on all three. A 30% band with
a 25 ms floor sits between the two on the wall clock, and 16 ms does the same
on the simulated one. Re-measure before trusting them on very different
hardware.

The `large` column is why both clocks are there. A fixed 250 ms delay is
enormous next to a 113 ms empty-library startup and lost in the noise of a
12-second one: that run came out at **0.90x**, faster than the baseline it was
slowing down, and a wall clock alone would have passed it. The simulated clock
reported the same +248 ms there as everywhere else, because it measures the
await itself rather than what the await happened to cost in CPU.

It is also why the run-level verdict is "**any** workload regressed" rather
than "all of them": one workload seeing a change is a change.

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
completeness check. It times nothing and asserts no duration.

It runs on every pull request, with no path filter. The harness walks `main()`,
the app shell, the router, the Library screen, `TrackTile`, the library
controller and providers, the Drift repository and the database, so an
allowlist of those paths is a list that has to stay correct forever and the
first thing it misses is the first thing that retires the check. A rename of
`TrackTile` makes the milestone unreachable, and `flutter test` will not catch
that either, because the harness is deliberately not a test. The job is under a
minute.

Timing nothing is deliberate. A GitHub runner is a shared machine of unknown
load; a millisecond figure taken on one says more about its neighbours that
minute than about Linthra. What CI *can* prove is that the benchmark still
works: that it still launches the app, still reaches a usable frame on all
three workloads, and still writes a sample set that is complete. `--validate`
checks the run against its own metadata rather than merely parsing it, so a
harness that dies after its warm-up launch fails instead of printing
`structure ok` over nothing, and `--require-workloads empty,small,large` makes
the smoke assert the set rather than vouching only for whichever workloads the
file happens to contain.

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

workload      tracks   first frame  first usable   awaited      min      max  spread
  empty            0          31.0         112.9         8    104.9    194.7     79%
      spread is wide: this machine was busy, so read the medians with care
  small        1,000          16.7         344.6         8    259.8    385.2     36%
  large       20,000          15.7       12542.4         8  10250.8  16159.2     47%
```

- **median, not mean.** One launch that lands on a garbage collection or a
  background process should not move the number, and a median ignores it.
- **the first launch of each workload is warm-up and is dropped.** It is not a
  startup measurement, it is a measurement of the VM compiling a widget tree it
  has never run before, and on a JIT run it is routinely several times the rest.
- **spread** is `(max - min) / median`: how much the machine disagreed with
  itself. It is reported, never enforced. A wide spread is the report telling
  you to close what is running before believing anything else in it.
- **awaited** is the simulated clock: 8 ms is the two extra frames a healthy
  launch needs, and it stays at 8 ms whatever the library size, because nothing
  in a healthy startup waits on a timer. A number that climbs here is an await
  that was not there before.
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
