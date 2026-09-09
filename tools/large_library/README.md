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

## Query plans (#341)

Timing alone cannot tell "used the index" apart from "scanned a table small
enough, or ran on a machine fast enough, to get away with it". So every query
in `benchmark_sqlite.py` carries the index it is meant to ride, and the run
fails if the plan disagrees — even when the wall clock does not notice. Dropping
`idx_tracks_artist` from the 200k fixture, for instance, takes `artist exact`
from 0.10 ms to 23 ms: still comfortably inside the 50 ms budget, and caught
only by the plan.

### What a healthy plan looks like

| Plan row | Meaning | Healthy? |
| --- | --- | --- |
| `SEARCH tracks USING INDEX idx_… (col=?)` | Seeks straight to the matching rows. | Yes — the normal shape for a `WHERE` on an indexed column. |
| `SEARCH tracks USING INDEX idx_… (col>? AND col<?)` | A range seek. This is what a prefix `LIKE 'foo%'` compiles to. | Yes. |
| `SCAN tracks USING INDEX idx_tracks_recent` | Reads the whole index **in order**, which is how `ORDER BY date_added DESC LIMIT 50` avoids sorting. | Yes — a `SCAN` that names an index is not a table scan. |
| `SCAN tracks USING COVERING INDEX idx_…` | Reads the index and never touches the table, because the index already has every column the query asked for. `COUNT(*)` does this. | Yes. |
| `USE TEMP B-TREE FOR ORDER BY` | The index found the rows but cannot supply the ordering, so SQLite sorts them. | Acceptable at this scale — `album exact` does it after a `LIMIT 100`. Worth a look if it ever appears on an unbounded result. |
| `SCAN tracks` | Reads every row of the table. | **No.** This is the regression the guard fails on. |

The guard checks each plan row on its own, so a plan that uses an index in one
step cannot hide a scan in another. Three details keep it from crying wolf or
staying quiet when it shouldn't:

- `USING COVERING INDEX` is matched explicitly, because it does not contain the
  substring `USING INDEX` — a check written against that one string reads a
  healthy `COUNT(*)` as a full table scan.
- Transient objects are excluded, but by what the plan *declares*, not by
  name. SQLite prints the **alias**, so `FROM tracks AS u` scans as `SCAN u` —
  a guard comparing against the table name would wave a real full scan
  through, and in a self-join the other branch's index would keep the run
  green. `SCAN (subquery-1)` and `SCAN CONSTANT ROW` are transient by shape; a
  materialized CTE is transient because a `MATERIALIZE recent` row says so.
  Anything else that scans without naming an index is flagged. Where the guard
  has to guess it guesses toward flagging: a spurious error is loud and one
  line to fix, a missed scan silently retires the check.
- Index names are matched as **whole identifiers**. `idx_tracks_album` is a
  prefix of `idx_tracks_album_artist`, so a substring test would report a green
  run on the wrong index, and the scan guard would stay quiet about it because
  the plan really is using *an* index.

### Adding a query

Add a `Query(...)` to `QUERIES` and say what its plan has to do — either
`uses_index="idx_..."` for a query written for one particular index, or
`covering_index_only=True` when any covering index will do. `COUNT(*)` is the
second kind: it has no reason to prefer one covering index over another, so
pinning a name there would fail the run for a schema change that is perfectly
healthy.

Do not add an index to `schema.sql` just to make a plan look better: show the
plan first, and say what access pattern it is for. The unit tests keep the two
in step — every query has to assert *something* about its plan, every named
index has to be one the schema defines, and every index in the schema has to be
exercised by some query.

The summary rendering and the plan checks have unit tests, and neither needs a
database:

```bash
python3 test/tooling/large_library_benchmark_test.py
```

The scripts use only Python's standard library. `schema.sql` is a performance sandbox shaped like the fields Linthra cares about; it is **not** a replacement for the Drift production schema. A useful SQL contribution should show the access pattern it improves and, where practical, the `EXPLAIN QUERY PLAN` result that proves the intended index is used.
