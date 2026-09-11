# Large-library tooling (Python + SQL)

This directory gives Python/SQL contributors a deterministic way to work on Linthra's 100k–200k-track behaviour without needing a personal music server or a huge real library.

Generate a 200k-track SQLite fixture:

```bash
python3 tools/large_library/generate_sqlite_fixture.py \
  --output /tmp/linthra-200k.sqlite \
  --tracks 200000
```

Run representative indexed-query benchmarks:

```bash
python3 tools/large_library/benchmark_sqlite.py \
  --database /tmp/linthra-200k.sqlite
```

Each query prints its timings, then its query plan indented underneath:

```
title prefix       avg=   0.051 ms  p95=   0.102 ms
    SEARCH tracks USING INDEX idx_tracks_title (normalized_title>? AND normalized_title<?)
album exact        avg=   0.113 ms  p95=   0.177 ms
    SEARCH tracks USING INDEX idx_tracks_album (normalized_album=?)
    USE TEMP B-TREE FOR ORDER BY
```

then a summary block:

```
benchmark summary
  tracks:                   200,000
  queries:                        8
  iterations per query:         200
  sum of query averages:      2.166 ms
  average per query:          0.271 ms
  slowest single run:         2.845 ms (track count)
```

Every query is timed the same number of times and reported as a mean, so
`sum of query averages` adds up those per-query means rather than the
wall-clock time the run spent querying, and `slowest single run` is the single
slowest timed iteration, not the slowest query on average.

## Memory: large-library profiling (#463)

The SQL side above answers "does a query stay fast at 200k tracks". This
answers a different question: **does the app stop growing** once you have been
scrolling, navigating and playing for a while?

```bash
./tools/large_library/run_memory_check.sh
```

That runs the harness twice over a large synthetic library and analyses both
series. Roughly ten minutes; `--tracks` and `--cycles` make it smaller.

### What it does not do, and what it does instead

It does **not** assert an RSS figure. A number measured on one laptop is not
comparable to the same number on another machine, another kernel, another
glibc or another Flutter version, so a threshold picked on one of them is
either meaningless or permanently red on the rest. Any check built that way
gets muted within a month.

The first attempt here asked something milder: *is the line flat after
warm-up?* Measuring said no, and for a reason worth writing down. In a
headless Dart VM under sustained allocation the line is not flat even with
nothing wrong: nothing forces a major collection, so the heap high-water mark
ratchets up. A clean run of this harness drifts a couple of MiB per navigation
cycle on its own. A check that demanded flatness would need a noise band wide
enough to swallow a real leak, which is the same as having no check at all.

So the check is **comparative**. Record a baseline run, then measure a
candidate run of the same harness on the same machine, and compare their
growth *rates*. The runtime's own drift, the image cache filling, the glyph
atlas, glibc's arenas all appear on both sides at roughly the same rate and
subtract out. What is left is what the candidate holds on to and the baseline
did not.

```bash
python3 tools/large_library/memory_report.py after.json \
  --baseline before.json --expect same
```

Without `--baseline` it still reports the series, the phase deltas and the
trend, which is what you want when you are reading rather than gating.

### The two pieces

| Piece | Job |
| --- | --- |
| `test/benchmarks/large_library_memory_bench.dart` | Drives the real Library UI over a synthetic catalog and records RSS. Decides nothing. |
| `tools/large_library/memory_report.py` | Reads that series, reports phase deltas and the per-cycle trend, and gives the verdict. |

Run them by hand when you want one scenario:

```bash
LINTHRA_MEMORY_OUT=/tmp/clean.json \
  flutter test test/benchmarks/large_library_memory_bench.dart
python3 tools/large_library/memory_report.py /tmp/clean.json
```

The states it measures: startup with the catalog loaded, a long scroll through
Songs, browsing the Albums grid (which is where artwork decoding happens),
opening an album and coming back, browsing Artists, opening an artist and
coming back, queueing 200 tracks and skipping through 40 of them, and then the
whole navigation repeated as identical cycles.

Artwork is real: the harness writes a small PNG per album and gives each track
a `file://` cover, so covers are decoded and cached the way they are in the
app. A run with no artwork would miss the single biggest thing holding memory
during a scroll.

### Two controls, both required

`run_memory_check.sh` runs the harness three times, and both control results
have to pass before any of it means anything:

- **control against baseline** must be `NO REGRESSION`. Two identical runs that
  disagree mean the noise band is too tight for this machine, and any red
  result the check produces is worthless. This is the false-positive control.
- **leak against baseline** must be `REGRESSION`. The leak run sets
  `LINTHRA_MEMORY_LEAK=1`, which retains 2 MiB per navigation cycle. A check
  that only ever says "fine" is indistinguishable from one that has quietly
  stopped measuring, and handing it something it *must* catch is the only way
  to tell those apart. This is the false-negative control.

The 1 MiB default band comes from measuring, not from taste. Three clean runs
and one leak run, 12,000 tracks and 16 cycles each, on the machine this was
developed on:

| comparison | extra per cycle | verdict |
| --- | --- | --- |
| clean B vs clean A | +0.1 MiB | no regression |
| clean C vs clean A | -0.2 MiB | no regression |
| clean C vs clean B | -0.3 MiB | no regression |
| leak vs clean A | +1.7 MiB | regression |
| leak vs clean B | +1.6 MiB | regression |

Run-to-run noise stays inside ±0.3 MiB per cycle; the deliberate 2 MiB/cycle
leak lands at +1.6 to +1.7. A 1 MiB band sits between the two with room on
both sides. Re-measure before trusting it on very different hardware, and use
more cycles if the margin looks tight: the median steadies as the series gets
longer, which is why the default is 16 rather than the 12 the first attempt
used.

### What the noise is made of

RSS is a high-water mark. Every one of these makes it rise once and then stop,
and none of them is a leak:

- **Flutter's image cache** fills as covers are decoded. It is bounded (1000
  images or 100 MiB by default), so it plateaus.
- **The glyph atlas** fills with the text of rows as they are first drawn.
- **The Dart heap** grows to its working size and does not hand pages back to
  the OS promptly; freed objects usually mean reusable heap, not lower RSS.
- **glibc's malloc** keeps freed memory in its arenas.
- **The Dart VM and the test harness** are a large fixed baseline (a couple of
  hundred MiB here) that has nothing to do with the app.

Which is why the healthy signal is *flat*, never *falling*, and why the first
few cycles are dropped as warm-up (`--warmup`, default 3).

The analyser keys off the **median cycle-to-cycle delta** rather than the total
or a least-squares slope. A leak adds memory on every cycle, so its deltas are
all positive and the median is the leak rate. A one-off step (a cache that
filled a cycle late, a route that allocated once) is a single large delta among
zeros, and a median ignores it where a mean or a slope would not. A second
clause, a real slope plus most cycles rising, catches a leak that only fires on
some cycles.

That is also the number the comparison subtracts, which is why it survives the
runtime drift: both runs drift, so both medians include it, and the difference
does not.

### Cycles have to be idempotent

This bit cost a run to discover, and is worth knowing before changing the
harness. A tab keeps its scroll offset, so a cycle that only scrolls *down*
starts each pass where the last one stopped: it visits rows and covers it has
never seen, the image cache keeps filling toward its bound, and the series
climbs for reasons that are not a leak. Every scroll in a cycle therefore
returns to the top. If you add navigation to a cycle, make sure it leaves the
UI exactly as it found it, or the baseline stops meaning anything.

### Honest limits

- **This is Dart-side retention, in a headless test VM.** It does not include
  the GPU, the platform's own image pipeline, or the media_kit/libmpv decoder
  buffers a real playing session allocates natively. Those need a profiler
  attached to a real desktop build (`flutter run --profile` plus DevTools'
  memory view), and that is the right follow-up when this points at something.
- **Nothing forces a GC.** Dart offers no way to do it from pure Dart, so the
  series is "RSS as the VM happened to leave it". That is exactly why the
  verdict is a trend over many cycles compared against another run, and never a
  single reading.
- **A baseline is only valid on the machine and commit that produced it.**
  Comparing across machines, or against a months-old file, measures the
  difference between those instead of the change you are checking.
- **No personal data is involved anywhere.** The library is generated, the
  covers are a 1x1 PNG, and the output is counts and byte totals.
- **No profiling hook ships.** The harness is a test that reads
  `ProcessInfo.currentRss`; there is no instrumented build, no debug flag and
  no production code that knows any of this exists.

The analyser's own unit tests need no Flutter and no measurement:

```bash
python3 test/tooling/large_library_memory_report_test.py
```

## Query plans (#341)

Timing alone cannot tell "used the index" apart from "scanned a table small
enough, or ran on a machine fast enough, to get away with it". So every query
in `benchmark_sqlite.py` carries the index it is meant to ride, and the run
fails if the plan disagrees, even when the wall clock does not notice. Dropping
`idx_tracks_artist` from the 200k fixture, for instance, takes `artist exact`
from 0.10 ms to 23 ms: still comfortably inside the 50 ms budget, and caught
only by the plan.

### What a healthy plan looks like

| Plan row | Meaning | Healthy? |
| --- | --- | --- |
| `SEARCH tracks USING INDEX idx_… (col=?)` | Seeks straight to the matching rows. | Yes, the normal shape for a `WHERE` on an indexed column. |
| `SEARCH tracks USING INDEX idx_… (col>? AND col<?)` | A range seek. This is what a prefix `LIKE 'foo%'` compiles to. | Yes. |
| `SCAN tracks USING INDEX idx_tracks_recent` | Reads the whole index **in order**, which is how `ORDER BY date_added DESC LIMIT 50` avoids sorting. | Yes: a `SCAN` that names an index is not a table scan. |
| `SCAN tracks USING COVERING INDEX idx_…` | Reads the index and never touches the table, because the index already has every column the query asked for. `COUNT(*)` does this. | Yes. |
| `USE TEMP B-TREE FOR ORDER BY` | The index found the rows but cannot supply the ordering, so SQLite sorts them. | Acceptable at this scale: `album exact` does it after a `LIMIT 100`. Worth a look if it ever appears on an unbounded result. |
| `SCAN tracks` | Reads every row of the table. | **No.** This is the regression the guard fails on. |

The guard checks each plan row on its own, so a plan that uses an index in one
step cannot hide a scan in another. Three details keep it from crying wolf or
staying quiet when it shouldn't:

- `USING COVERING INDEX` is matched explicitly, because it does not contain the
  substring `USING INDEX`, and a check written against that one string reads a
  healthy `COUNT(*)` as a full table scan.
- Transient objects are excluded, but by what the plan *declares*, not by
  name. SQLite prints the **alias**, so `FROM tracks AS u` scans as `SCAN u`,
  and a guard comparing against the table name would wave a real full scan
  through, and in a self-join the other branch's index would keep the run
  green. `SCAN (subquery-1)` is transient by shape, and so is a literal row
  set: SQLite writes one as `SCAN CONSTANT ROW` and several as
  `SCAN 2 CONSTANT ROWS`, so the token after `SCAN` is a count rather than a
  name and reading it as one made an inline `VALUES` list look like an
  unindexed table. A materialized CTE is transient because a
  `MATERIALIZE recent` row says so. Anything else that scans without naming an
  index is flagged. Where the guard has to guess it guesses toward flagging: a
  spurious error is loud and one line to fix, a missed scan silently retires
  the check.

There is one shape the plan cannot resolve on its own. A CTE read under an
alias scans as `SCAN p` while the declaration says `MATERIALIZE picked`, and
nothing links the two, and a *table* aliased `p` produces the identical row.
Guessing would mean parsing the SQL, and a wrong guess excuses a real full
scan, so the query declares it instead: `transient_aliases=("p",)`. The error
message says so when it fires, and no query needs it today.

**Vouching covers exactly one scan row, whoever does the vouching.** If the
plan scans a name more than once, nothing that vouches for it is honoured and
every scan of it stays flagged, because one "trust me" cannot cover two
objects. That applies to what the plan declares as much as to what a query
declares: `WITH p AS MATERIALIZED (...)` alongside a `tracks AS p` deeper down
produces two `SCAN p` rows, and honouring `MATERIALIZE p` plan-wide waved the
real one through.

The cost is that a `UNION ALL` over one CTE, which scans it twice under its own
name, is flagged as well. Nothing in the plan tells that apart from the case
above; scoping the exemption to a branch would mean deciding which `SCAN p` is
which from the tree, and a wrong guess there fails silently, which is how this
hole appeared in the first place. So it fails loudly instead, and a query that
hits it needs restructuring rather than a flag.
- Index names are matched as **whole identifiers**. `idx_tracks_album` is a
  prefix of `idx_tracks_album_artist`, so a substring test would report a green
  run on the wrong index, and the scan guard would stay quiet about it because
  the plan really is using *an* index.

### Naming the index is not enough

A query that stops being sargable while its columns stay covered keeps the same
index and changes only the verb:

```
SEARCH tracks USING COVERING INDEX idx_tracks_artist (normalized_artist=?)   0.06 ms
SCAN   tracks USING COVERING INDEX idx_tracks_artist                        11.16 ms
```

Same index name, and the scan guard is happy either way because the plan does
use an index. So each query also records **how** it reaches its index:
`access=SEEK` (the default) or `access=INDEX_SCAN`. Only `recently added`
and `track count` are allowed to read one end to end.

The check asks which verbs are *wrong*, not whether the right one appears. A
multi-branch plan can reach the same index both ways at once (an indexed
lookup in one branch, a non-sargable read of the same covering index in
another), and accepting that on the strength of the seek is the same "reads
everything" miss, one level further down.

### Adding a query

Add a `Query(...)` to `QUERIES` and say what its plan has to do: either
`uses_index="idx_..."` (plus `access=` if it is meant to read the index in
order rather than seek) for a query written for one particular index, or
`covering_index_only=True` when any covering index will do. `COUNT(*)` is the
second kind: it has no reason to prefer one covering index over another, so
pinning a name there would fail the run for a schema change that is perfectly
healthy.

Do not add an index to `schema.sql` just to make a plan look better: show the
plan first, and say what access pattern it is for. The unit tests keep the two
in step. Every query has to assert *something* about its plan, every named
index has to be one the schema defines, and every index in the schema has to be
exercised by some query.

The summary rendering and the plan checks have unit tests, and neither needs a
database:

```bash
python3 test/tooling/large_library_benchmark_test.py
```

The scripts use only Python's standard library. `schema.sql` is a performance sandbox shaped like the fields Linthra cares about; it is **not** a replacement for the Drift production schema. A useful SQL contribution should show the access pattern it improves and, where practical, the `EXPLAIN QUERY PLAN` result that proves the intended index is used.
