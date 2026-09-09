#!/usr/bin/env python3
"""Regression benchmark for Linthra-shaped SQLite queries at large scale."""

from __future__ import annotations

import argparse
import sqlite3
import statistics
import time
from collections.abc import Sequence
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class Query:
    """One benchmarked access pattern, and the index it is meant to ride.

    `uses_index` is the point of #341: timing alone cannot tell "used the index"
    apart from "scanned a table small enough, or a machine fast enough, to get
    away with it". Naming the expected index turns the query plan into an
    assertion — dropping the index, or rewriting the query so the planner
    cannot use it, fails here even when the wall clock does not notice.
    """

    name: str
    sql: str
    params: tuple[object, ...] = ()
    uses_index: str | None = None


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
    ),
    # A covering-index scan: SQLite reads the whole index but never touches the
    # table. It is a SCAN and it is fine, which is exactly the case the scan
    # guard has to keep telling apart from a real full table scan.
    Query(
        "track count",
        "SELECT COUNT(*) FROM tracks",
        (),
        uses_index="idx_tracks_recent",
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


@dataclass(frozen=True)
class PlanRow:
    """One line of `EXPLAIN QUERY PLAN`, with its nesting depth."""

    depth: int
    detail: str

    def rendered(self) -> str:
        return f"{'  ' * self.depth}{self.detail}"


def is_full_table_scan(detail: str) -> bool:
    """Whether a plan row reads a whole table without an index.

    Deliberately narrow. It answers only the question #341 asks — "did this
    quietly turn into a full table scan?" — and answers it per row, so a plan
    whose *other* steps use an index cannot hide a scan inside it. A `SCAN`
    that names an index (including a covering one) is a legitimate ordered or
    covering read and is not flagged.
    """
    stripped = detail.strip()
    if not stripped.startswith("SCAN"):
        return False
    return not any(marker in stripped for marker in INDEXED_ACCESS_MARKERS)


def plan_names_index(rows: Sequence[PlanRow], index: str) -> bool:
    """Whether any plan row reaches rows through [index]."""
    return any(index in row.detail for row in rows)


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
            for row in plan:
                if is_full_table_scan(row.detail):
                    print(f"ERROR: {query.name} reads the table without an index")
                    print(f"       {row.detail}")
                    failed = True
            # ...and a query that stopped using the index it was written for is
            # a regression too, even when it found some other index to ride.
            if query.uses_index and not plan_names_index(plan, query.uses_index):
                print(f"ERROR: {query.name} no longer uses {query.uses_index}")
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
