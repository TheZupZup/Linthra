#!/usr/bin/env python3
"""Regression benchmark for Linthra-shaped SQLite queries at large scale."""

from __future__ import annotations

import argparse
import re
import sqlite3
import statistics
import time
from collections import Counter
from collections.abc import Iterable, Sequence
from dataclasses import dataclass
from pathlib import Path

#: A seek: the plan jumps straight to the matching rows.
SEEK = "SEARCH"

#: An ordered read of a whole index: what `ORDER BY ... LIMIT` wants, and a
#: regression anywhere it was not asked for.
INDEX_SCAN = "SCAN"


@dataclass(frozen=True)
class Query:
    """One benchmarked access pattern, and the index it is meant to ride.

    `uses_index` is the point of #341: timing alone cannot tell "used the index"
    apart from "scanned a table small enough, or a machine fast enough, to get
    away with it". Naming the expected index turns the query plan into an
    assertion (dropping the index, or rewriting the query so the planner
    cannot use it, fails here even when the wall clock does not notice.
    """

    name: str
    sql: str
    params: tuple[object, ...] = ()

    #: The index the plan has to name, when the query is written for one.
    uses_index: str | None = None

    #: How that index has to be reached. Naming it is not enough: a predicate
    #: that stops being sargable while its columns stay covered turns
    #: `SEARCH ... USING COVERING INDEX idx` into `SCAN ... USING COVERING
    #: INDEX idx`: same index, same green scan guard, and the whole index read
    #: instead of a seek. On the 200k fixture that is 0.06 ms becoming 11 ms,
    #: still inside the budget.
    access: str = SEEK

    #: Set instead of `uses_index` when any covering index will do. `COUNT(*)`
    #: is the case: it has no semantic reason to prefer one covering index over
    #: another, so the planner is free to switch to a newly added one, so pinning
    #: a name there would fail the run for a schema change that is healthy.
    covering_index_only: bool = False

    #: Aliases this query reads a CTE or subquery under.
    #:
    #: SQLite prints the alias in the scan row (`SCAN p`) but declares only the
    #: CTE's own name (`MATERIALIZE picked`), and nothing in the plan links the
    #: two, and a *table* aliased `p` produces the identical row. Guessing from the
    #: SQL would mean parsing it, and a wrong guess excuses a real full scan,
    #: which is the failure that matters. So the query says so instead: one
    #: reviewable line, written by whoever knows the alias is a CTE.
    transient_aliases: tuple[str, ...] = ()


QUERIES: tuple[Query, ...] = (
    Query(
        "title prefix",
        "SELECT id, title FROM tracks WHERE normalized_title LIKE ? LIMIT 50",
        ("track 199%",),
        uses_index="idx_tracks_title",
    ),
    Query(
        "artist exact",
        "SELECT id, title FROM tracks WHERE normalized_artist = ? LIMIT 100",
        ("artist 421",),
        uses_index="idx_tracks_artist",
    ),
    Query(
        "album exact",
        "SELECT id, title FROM tracks WHERE normalized_album = ? ORDER BY title LIMIT 100",
        ("album 1207",),
        uses_index="idx_tracks_album",
    ),
    Query(
        "album artist",
        "SELECT id, title FROM tracks WHERE normalized_album_artist = ? LIMIT 100",
        ("various artists",),
        uses_index="idx_tracks_album_artist",
    ),
    Query(
        "provider album",
        "SELECT id, title FROM tracks WHERE provider = ? AND album_id = ? LIMIT 100",
        ("navidrome", "navidrome:album:311"),
        uses_index="idx_tracks_provider_album",
    ),
    # The lookup every sync does: "do I already have this server item?"
    Query(
        "provider identity",
        "SELECT id, title FROM tracks WHERE provider = ? AND provider_track_id = ?",
        ("jellyfin", "jellyfin-track-150001"),
        uses_index="idx_tracks_provider_identity",
    ),
    Query(
        "recently added",
        "SELECT id, title FROM tracks ORDER BY date_added DESC LIMIT 50",
        (),
        uses_index="idx_tracks_recent",
        # Reading the index in order is the whole point here: it is what lets
        # the query skip a sort.
        access=INDEX_SCAN,
    ),
    # A covering-index scan: SQLite reads the whole index but never touches the
    # table. It is a SCAN and it is fine, which is exactly the case the scan
    # guard has to keep telling apart from a real full table scan.
    Query(
        "track count",
        "SELECT COUNT(*) FROM tracks",
        (),
        covering_index_only=True,
        # Recorded rather than checked (there is no index name to check it
        # against), but COUNT(*) can only read an index end to end, and a
        # field left at its default would say the opposite.
        access=INDEX_SCAN,
    ),
)

# What SQLite writes when a plan step reaches rows through an index (or the
# rowid) rather than by reading the table.
#
# "USING COVERING INDEX" is listed separately on purpose: it does not contain
# the substring "USING INDEX", so a check written only against the latter reads
# a perfectly healthy covering scan as a full table scan. That false positive is
# why this is a list rather than one string.
INDEXED_ACCESS_MARKERS: tuple[str, ...] = (
    "USING INDEX",
    "USING COVERING INDEX",
    "USING INTEGER PRIMARY KEY",
    "USING PRIMARY KEY",
    "USING ROWID SEARCH",
)

#: The index a plan row reaches rows through, e.g. "SEARCH tracks USING INDEX
#: idx_tracks_album (normalized_album=?)". Names are captured whole: a plain
#: substring test would let `idx_tracks_album_artist` satisfy an expectation of
#: `idx_tracks_album`, which is a green run on the wrong index.
INDEX_NAME_PATTERN = re.compile(r"USING (?:AUTOMATIC )?(?:COVERING )?INDEX (\w+)")

#: The subset of the above that never touches the table at all.
COVERING_INDEX_PATTERN = re.compile(r"USING (?:AUTOMATIC )?COVERING INDEX (\w+)")

#: What a SCAN row is scanning. SQLite prints the *alias* when a query has one,
#: so an aliased table reads as "SCAN u", not "SCAN tracks AS u", which is why
#: the guard below cannot simply compare against the table name.
SCANNED_OBJECT_PATTERN = re.compile(r"^SCAN\s+(\S+)")

#: A scan of a literal row set rather than of any named object. SQLite writes
#: one row as `SCAN CONSTANT ROW` and several as `SCAN 2 CONSTANT ROWS`, so the
#: token after SCAN is a count, not a name. Reading it as one made an inline
#: `VALUES (1), (2)` look like a table nobody had indexed.
CONSTANT_ROWS_PATTERN = re.compile(r"^SCAN\s+(?:\d+\s+)?CONSTANT\s+ROWS?\b")

#: Rows that declare a transient object by name. SQLite materializes a CTE or a
#: subquery and then scans the result, and that scan row says only "SCAN recent"
#: indistinguishable by name from a full scan of a table aliased `recent`.
#: The declaration is the thing that tells them apart.
TRANSIENT_DECLARATION_PATTERN = re.compile(r"^(?:MATERIALIZE|CO-ROUTINE)\s+(\S+)")


@dataclass(frozen=True)
class PlanRow:
    """One line of `EXPLAIN QUERY PLAN`, with its nesting depth."""

    depth: int
    detail: str

    def rendered(self) -> str:
        return f"{'  ' * self.depth}{self.detail}"


def scan_target(detail: str) -> str | None:
    """The object a scan row reads, or `None` when there is no name to read.

    `None` covers three things: a row that is not a scan at all, a scan of a
    subquery result (`SCAN (subquery-1)`), and a scan of a literal row set
    (`SCAN CONSTANT ROW`, `SCAN 2 CONSTANT ROWS`). The last two are transient by
    shape whatever else the plan says, so they never need vouching for and never
    count toward a name being ambiguous.

    One function so the guard and the ambiguity count can never disagree about
    what a row is reading.
    """
    stripped = detail.strip()
    if CONSTANT_ROWS_PATTERN.match(stripped):
        return None
    match = SCANNED_OBJECT_PATTERN.match(stripped)
    if match is None:
        return None
    scanned = match.group(1)
    return None if scanned.startswith("(") else scanned


def scanned_objects(rows: Sequence[PlanRow]) -> Counter:
    """How many times each named object is scanned in this plan."""
    counts: Counter = Counter()
    for row in rows:
        target = scan_target(row.detail)
        if target is not None:
            counts[target] += 1
    return counts


def ambiguous_names(rows: Sequence[PlanRow], vouched: Iterable[str]) -> set[str]:
    """Vouched-for names the plan scans more than once.

    Something vouching for a name says one scan row reads a transient object.
    SQLite prints the same `SCAN p` for a CTE read as `p` and for a table
    aliased `p` in a nested scope, so a plan doing both would have its real
    table scan suppressed. The vouching does not stretch that far: an ambiguous
    name is not honoured at all, and every scan of it stays flagged.

    This applies to what the *plan* declares (`MATERIALIZE p`) exactly as it
    does to what a *query* declares (`transient_aliases`). A plan declaring a
    CTE named `p` while also aliasing `tracks` to `p` deeper down produces two
    `SCAN p` rows, and honouring the declaration plan-wide waved the real one
    through.

    The cost is a plan that genuinely scans one CTE twice, which a `UNION ALL`
    over a CTE does. That is flagged too, because nothing in the plan tells the
    two cases apart, and this guard's whole job is to fail loudly rather than
    guess quietly. See the README.
    """
    counts = scanned_objects(rows)
    return {name for name in vouched if counts[name] > 1}


def transient_objects(rows: Sequence[PlanRow]) -> set[str]:
    """The names this plan materializes rather than reads from disk."""
    return {
        match.group(1)
        for row in rows
        if (match := TRANSIENT_DECLARATION_PATTERN.match(row.detail.strip()))
    }


def full_table_scans(
    rows: Sequence[PlanRow], extra_transient: Sequence[str] = ()
) -> list[PlanRow]:
    """The rows of [rows] that read something end to end without an index.

    Takes the whole plan rather than one row, because whether `SCAN recent` is a
    table scan or a read of a materialized CTE is only answerable from the
    `MATERIALIZE recent` row elsewhere in the same plan.

    Two shapes are transient whatever else the plan says, and are recognised by
    [scan_target]: a subquery result, and a literal row set. Everything else
    that scans without naming an index is flagged, including an aliased table:
    SQLite prints `SCAN u` for `FROM tracks AS u`, so a guard that compared
    against the table name would wave a real full scan through, and in a
    self-join the *other* branch's index would keep the rest of the run green.

    [extra_transient] names anything the plan cannot: an alias a CTE is read
    under, which SQLite prints without saying what it refers to. Every vouched
    name, the plan's own `MATERIALIZE` declarations included, is honoured only
    when the plan scans it exactly once. See [ambiguous_names].

    Where it has to guess, it guesses toward flagging: a spurious error is loud
    and one line to fix, a missed scan silently retires the check.
    """
    vouched = transient_objects(rows) | set(extra_transient)
    transient = vouched - ambiguous_names(rows, vouched)
    scans: list[PlanRow] = []
    for row in rows:
        target = scan_target(row.detail)
        if target is None or target in transient:
            continue
        if any(marker in row.detail for marker in INDEXED_ACCESS_MARKERS):
            continue
        scans.append(row)
    return scans


def plan_indexes(rows: Sequence[PlanRow]) -> set[str]:
    """Every index named anywhere in [rows], as whole identifiers."""
    return {name for row in rows for name in INDEX_NAME_PATTERN.findall(row.detail)}


def plan_names_index(rows: Sequence[PlanRow], index: str) -> bool:
    """Whether any plan row reaches rows through exactly [index]."""
    return index in plan_indexes(rows)


def index_access(rows: Sequence[PlanRow], index: str) -> set[str]:
    """How [index] is reached in this plan: `SEARCH`, `SCAN`, or neither.

    The distinction the index name alone cannot make. A seek and a full read of
    the same index look identical to a name check, and the scan guard waves the
    second through because it does name an index, so a query that quietly
    stopped seeking stays green while reading every entry.
    """
    verbs: set[str] = set()
    for row in rows:
        stripped = row.detail.strip()
        match = re.match(r"^(SEARCH|SCAN)\b", stripped)
        if match is not None and index in INDEX_NAME_PATTERN.findall(stripped):
            verbs.add(match.group(1))
    return verbs


def unexpected_index_access(
    rows: Sequence[PlanRow], index: str, expected: str
) -> set[str]:
    """The ways this plan reaches [index] that [expected] does not allow.

    Empty when every access is the expected one. Asking which verbs are *wrong*
    rather than whether the right one appears is the whole point: a plan that
    seeks in one branch and reads the entire index in another reaches it with
    both, and accepting that on the strength of the seek is the same "reads
    everything" miss the seek/scan split exists to catch, one level down.

    Says nothing about an index the plan never reaches; that is a separate
    error, with a separate message.
    """
    return index_access(rows, index) - {expected}


def plan_uses_covering_index(rows: Sequence[PlanRow]) -> bool:
    """Whether any plan row reads through a covering index, whichever one."""
    return any(COVERING_INDEX_PATTERN.search(row.detail) for row in rows)


def query_plan(
    connection: sqlite3.Connection, sql: str, params: tuple[object, ...]
) -> list[PlanRow]:
    """The plan for [sql], as rows with their nesting depth.

    `EXPLAIN QUERY PLAN` returns `(id, parent, notused, detail)`. Walking the
    parent chain turns a flat result into the tree the plan actually is, which
    is what makes a multi-step plan readable in a CI log instead of one long
    joined line.
    """
    depths: dict[int, int] = {0: -1}
    rows: list[PlanRow] = []
    for row_id, parent, _, detail in connection.execute(
        f"EXPLAIN QUERY PLAN {sql}", params
    ):
        depth = depths.get(parent, 0) + 1
        depths[row_id] = depth
        rows.append(PlanRow(depth, str(detail)))
    return rows


def summary_lines(
    track_count: int,
    results: Sequence[tuple[str, float, float, float]],
    iterations: int,
) -> list[str]:
    """Render the summary block printed after the per-query lines.

    Separate from `main` so the wording, the numbers and the alignment can be
    checked without a database: everything here is derived from `results`.
    """
    summed_average_ms = sum(average_ms for _, average_ms, _, _ in results)
    average_query_ms = summed_average_ms / len(results)
    slowest_name, _, _, slowest_max_ms = max(results, key=lambda result: result[3])

    # Labels are padded to a fixed width and values are right-aligned inside
    # one column, so counts and timings line up whatever their magnitude.
    def row(label: str, value: str, unit: str = "") -> str:
        return f"  {label + ':':<24}{value:>9}{unit}"

    return [
        "benchmark summary",
        row("tracks", f"{track_count:,}"),
        row("queries", f"{len(results)}"),
        row("iterations per query", f"{iterations:,}"),
        # Each query is timed the same number of times and reported as a mean,
        # so this is the sum of those per-query averages, not the wall-clock
        # time the benchmark spent querying. Saying so keeps the number
        # comparable between runs that used a different --iterations.
        row("sum of query averages", f"{summed_average_ms:.3f}", " ms"),
        row("average per query", f"{average_query_ms:.3f}", " ms"),
        # The slowest single timed run, not the slowest query on average: it is
        # the outlier worth looking at when a run is unexpectedly spiky.
        row("slowest single run", f"{slowest_max_ms:.3f}", f" ms ({slowest_name})"),
    ]


def benchmark(
    connection: sqlite3.Connection,
    sql: str,
    params: tuple[object, ...],
    iterations: int,
) -> tuple[float, float, float]:
    samples_ms: list[float] = []
    for _ in range(iterations):
        started = time.perf_counter_ns()
        connection.execute(sql, params).fetchall()
        samples_ms.append((time.perf_counter_ns() - started) / 1_000_000)
    return (
        statistics.mean(samples_ms),
        statistics.quantiles(samples_ms, n=20)[18],
        max(samples_ms),
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--database", type=Path, required=True)
    parser.add_argument("--iterations", type=int, default=200)
    parser.add_argument("--max-average-ms", type=float, default=50.0)
    args = parser.parse_args()

    connection = sqlite3.connect(f"file:{args.database}?mode=ro", uri=True)
    connection.execute("PRAGMA case_sensitive_like = ON")
    try:
        count = connection.execute("SELECT COUNT(*) FROM tracks").fetchone()[0]
        print(f"catalog: {count:,} tracks")

        failed = False
        results: list[tuple[str, float, float, float]] = []
        for query in QUERIES:
            plan = query_plan(connection, query.sql, query.params)
            average_ms, p95_ms, max_ms = benchmark(
                connection, query.sql, query.params, args.iterations
            )
            results.append((query.name, average_ms, p95_ms, max_ms))
            # Timings on the query's own line; the plan underneath it, one step
            # per line and indented by its depth. The plan used to be joined
            # onto the end of the timing line, where it wrapped and stopped
            # being read.
            print(f"{query.name:18} avg={average_ms:8.3f} ms  p95={p95_ms:8.3f} ms")
            for row in plan:
                print(f"    {row.rendered()}")

            # Every benchmark query has a matching index in schema.sql. A full
            # table scan is therefore a schema/query regression, even if a fast
            # CI machine happens to hide it in wall-clock timing.
            for row in full_table_scans(plan, query.transient_aliases):
                print(f"ERROR: {query.name} reads a table without an index")
                print(f"       {row.detail}")
                # The one shape this cannot tell apart on its own, named here
                # so a contributor is not left guessing at a spurious error.
                print(
                    "       (if that is a CTE read under an alias, add it to "
                    "the query's transient_aliases)"
                )
                failed = True
            declared = set(query.transient_aliases)
            vouched = transient_objects(plan) | declared
            for name in sorted(ambiguous_names(plan, vouched)):
                source = (
                    f"{query.name} declares transient_aliases {name!r}"
                    if name in declared
                    else f"the plan for {query.name} materializes {name!r}"
                )
                print(f"ERROR: {source}, but it scans that name more than once")
                print(
                    "       (one declaration cannot vouch for two objects; "
                    "give them distinct aliases)"
                )
                failed = True
            # ...and a query that stopped using the index it was written for is
            # a regression too, even when it found some other index to ride.
            if query.uses_index:
                verbs = index_access(plan, query.uses_index)
                if not verbs:
                    print(f"ERROR: {query.name} no longer uses {query.uses_index}")
                    failed = True
                elif unexpected := unexpected_index_access(
                    plan, query.uses_index, query.access
                ):
                    print(
                        f"ERROR: {query.name} reads {query.uses_index} with "
                        f"{'/'.join(sorted(unexpected))}, expected "
                        f"{query.access}"
                    )
                    print(
                        "       (a SCAN of the index reads every entry; a "
                        "SEARCH seeks to the matching ones)"
                    )
                    failed = True
            if query.covering_index_only and not plan_uses_covering_index(plan):
                print(f"ERROR: {query.name} no longer reads through a covering index")
                failed = True
            if average_ms > args.max_average_ms:
                print(
                    f"ERROR: {query.name} exceeded the {args.max_average_ms:.1f} ms "
                    "average-query budget"
                )
                failed = True

        print()
        for line in summary_lines(count, results, args.iterations):
            print(line)
        if failed:
            raise SystemExit(1)
    finally:
        connection.close()


if __name__ == "__main__":
    main()
