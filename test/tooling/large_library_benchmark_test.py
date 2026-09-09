#!/usr/bin/env python3
"""Unit tests for the benchmark summary block (#338) and query plans (#341).

    python3 test/tooling/large_library_benchmark_test.py

`tools/large_library/benchmark_sqlite.py` prints a small summary after the
per-query lines, and that block is what a contributor (or a CI log reader)
actually looks at. These tests pin the two things that make it useful: the
numbers are the ones the labels claim, and the block stays aligned and
deterministic.

The plan checks are here for the same reason: they are the part of the
benchmark that decides pass or fail, and getting them wrong is either a green
run hiding a full table scan or a red run over a perfectly healthy covering
index. Everything below runs on plain strings and an in-memory database, so
none of it needs the 200k fixture.
"""

from __future__ import annotations

import importlib.util
import re
import sqlite3
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
BENCHMARK = ROOT / "tools" / "large_library" / "benchmark_sqlite.py"
SCHEMA = ROOT / "tools" / "large_library" / "schema.sql"


def _load():
    spec = importlib.util.spec_from_file_location("benchmark_sqlite", BENCHMARK)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    # Registered before it executes: @dataclass resolves annotations through
    # sys.modules[cls.__module__], and a module loaded straight from a path is
    # not there yet.
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


benchmark_sqlite = _load()

# (name, average ms, p95 ms, max ms): the shape main() collects per query.
RESULTS = (
    ("title prefix", 1.5, 2.0, 4.25),
    ("artist exact", 0.5, 0.9, 1.75),
    ("provider album", 2.0, 3.0, 9.5),
    ("recently added", 0.25, 0.4, 0.75),
)


class SummaryLinesTest(unittest.TestCase):
    def summary(self, results=RESULTS, track_count=200_000, iterations=200):
        return benchmark_sqlite.summary_lines(track_count, results, iterations)

    def labelled(self, label: str) -> str:
        matches = [line for line in self.summary() if line.strip().startswith(label)]
        self.assertEqual(len(matches), 1, f"expected exactly one {label!r} line")
        return matches[0]

    def test_counts_are_grouped_for_reading(self):
        self.assertIn("200,000", self.labelled("tracks:"))
        self.assertIn("4", self.labelled("queries:"))
        self.assertIn("200", self.labelled("iterations per query:"))

    def test_summed_averages_add_up_the_per_query_averages(self):
        # 1.5 + 0.5 + 2.0 + 0.25, not the wall-clock time of 200 iterations.
        self.assertIn("4.250 ms", self.labelled("sum of query averages:"))

    def test_average_per_query_is_the_mean_of_those_averages(self):
        self.assertIn("1.062 ms", self.labelled("average per query:"))

    def test_slowest_single_run_reports_the_max_sample_and_its_query(self):
        line = self.labelled("slowest single run:")
        self.assertIn("9.500 ms", line)
        self.assertIn("(provider album)", line)

    def test_no_label_claims_a_total_the_benchmark_never_measures(self):
        # The old "total query time" label read as wall-clock time while the
        # value was the sum of the per-query averages (#338).
        joined = "\n".join(self.summary())
        self.assertNotIn("total query time", joined)

    def test_values_line_up_in_one_column(self):
        rows = [line for line in self.summary() if line.startswith("  ")]
        self.assertEqual(len(rows), 6)
        # Counts have no unit and end the line; timings are followed by " ms".
        # Both end their value in the same column, which is what makes the
        # block scannable in a CI log.
        ends = {len(line) if " ms" not in line else line.index(" ms") for line in rows}
        self.assertEqual(len(ends), 1, f"values end at {ends}")

    def test_no_tabs_anywhere(self):
        # A stray tab used to make the iterations line jump around (#338).
        self.assertNotIn("\t", "\n".join(self.summary()))

    def test_output_is_deterministic(self):
        self.assertEqual(self.summary(), self.summary())

    def test_single_query_run_still_renders(self):
        lines = self.summary(results=(("title prefix", 1.0, 1.2, 1.5),))
        joined = "\n".join(lines)
        self.assertIn("sum of query averages:", joined)
        self.assertIn("1.000 ms", joined)
        self.assertIn("1.500 ms (title prefix)", joined)


class FullTableScanTest(unittest.TestCase):
    """The check that decides whether a run passes (#341)."""

    def scan(self, detail: str) -> bool:
        return benchmark_sqlite.is_full_table_scan(detail)

    def test_a_bare_scan_is_the_regression_we_are_looking_for(self):
        self.assertTrue(self.scan("SCAN tracks"))
        self.assertTrue(self.scan("SCAN tracks AS t"))

    def test_an_ordered_index_scan_is_healthy(self):
        # "recently added" reads the whole date_added index in order. It is a
        # SCAN, and it is exactly what the index is for.
        self.assertFalse(self.scan("SCAN tracks USING INDEX idx_tracks_recent"))

    def test_a_covering_index_scan_is_healthy(self):
        # The false positive this check was written to avoid: "USING COVERING
        # INDEX" does not contain the substring "USING INDEX", so a check
        # written against that one string reads COUNT(*) as a full table scan.
        self.assertFalse(
            self.scan("SCAN tracks USING COVERING INDEX idx_tracks_recent")
        )

    def test_a_rowid_or_primary_key_read_is_healthy(self):
        self.assertFalse(self.scan("SCAN tracks USING INTEGER PRIMARY KEY (rowid=?)"))
        self.assertFalse(self.scan("SCAN tracks USING PRIMARY KEY"))

    def test_a_search_is_never_a_full_scan(self):
        self.assertFalse(
            self.scan("SEARCH tracks USING INDEX idx_tracks_artist (normalized_artist=?)")
        )

    def test_non_access_plan_rows_are_ignored(self):
        self.assertFalse(self.scan("USE TEMP B-TREE FOR ORDER BY"))
        self.assertFalse(self.scan("CO-ROUTINE (subquery-1)"))


class PlanIndexTest(unittest.TestCase):
    def rows(self, *details: str):
        return [benchmark_sqlite.PlanRow(0, detail) for detail in details]

    def test_an_index_named_anywhere_in_the_plan_counts(self):
        plan = self.rows(
            "SEARCH tracks USING INDEX idx_tracks_album (normalized_album=?)",
            "USE TEMP B-TREE FOR ORDER BY",
        )
        self.assertTrue(benchmark_sqlite.plan_names_index(plan, "idx_tracks_album"))

    def test_a_plan_that_found_some_other_index_still_fails(self):
        # Timing alone would not catch this: the query is still fast, it is
        # just no longer riding the index it was written for.
        plan = self.rows("SEARCH tracks USING INDEX idx_tracks_title (normalized_title=?)")
        self.assertFalse(benchmark_sqlite.plan_names_index(plan, "idx_tracks_artist"))

    def test_a_scanning_plan_names_no_index(self):
        self.assertFalse(
            benchmark_sqlite.plan_names_index(self.rows("SCAN tracks"), "idx_tracks_artist")
        )


class QueryPlanShapeTest(unittest.TestCase):
    """`query_plan` against a real (tiny) database, so the row shape is real."""

    def setUp(self):
        self.connection = sqlite3.connect(":memory:")
        self.connection.executescript(
            """
            CREATE TABLE tracks (id INTEGER PRIMARY KEY, normalized_artist TEXT NOT NULL);
            CREATE INDEX idx_tracks_artist ON tracks(normalized_artist);
            INSERT INTO tracks (normalized_artist) VALUES ('a'), ('b');
            """
        )
        self.addCleanup(self.connection.close)

    def plan(self, sql: str, params: tuple[object, ...] = ()):
        return benchmark_sqlite.query_plan(self.connection, sql, params)

    def test_a_flat_plan_is_all_at_depth_zero(self):
        plan = self.plan("SELECT id FROM tracks WHERE normalized_artist = ?", ("a",))
        self.assertTrue(plan)
        self.assertEqual({row.depth for row in plan}, {0})
        self.assertTrue(any("idx_tracks_artist" in row.detail for row in plan))

    def test_a_nested_plan_indents_its_children(self):
        plan = self.plan(
            "SELECT id FROM tracks WHERE id IN "
            "(SELECT id FROM tracks WHERE normalized_artist = ?)",
            ("a",),
        )
        self.assertGreater(max(row.depth for row in plan), 0)
        deeper = [row for row in plan if row.depth > 0]
        self.assertTrue(all(row.rendered().startswith("  ") for row in deeper))

    def test_an_unindexed_predicate_is_reported_as_a_full_scan(self):
        plan = self.plan("SELECT id FROM tracks WHERE normalized_artist LIKE ?", ("%a%",))
        self.assertTrue(
            any(benchmark_sqlite.is_full_table_scan(row.detail) for row in plan)
        )


class QueryCatalogueTest(unittest.TestCase):
    """The queries themselves, checked without building a 200k fixture."""

    def schema_indexes(self) -> set[str]:
        return set(re.findall(r"CREATE (?:UNIQUE )?INDEX IF NOT EXISTS (\w+)", SCHEMA.read_text()))

    def test_every_query_expects_an_index_that_schema_sql_defines(self):
        # A typo in `uses_index` would otherwise fail every run for the wrong
        # reason, and look like a planner regression.
        defined = self.schema_indexes()
        for query in benchmark_sqlite.QUERIES:
            with self.subTest(query=query.name):
                self.assertIn(query.uses_index, defined)

    def test_query_names_are_unique_and_short_enough_to_line_up(self):
        names = [query.name for query in benchmark_sqlite.QUERIES]
        self.assertEqual(len(names), len(set(names)))
        for name in names:
            self.assertLessEqual(len(name), 18, name)

    def test_every_schema_index_is_exercised_by_some_query(self):
        # #341 is about showing the indexes are used. An index nothing
        # benchmarks is one nothing would notice losing.
        exercised = {query.uses_index for query in benchmark_sqlite.QUERIES}
        self.assertEqual(self.schema_indexes() - exercised, set())


if __name__ == "__main__":
    unittest.main()
