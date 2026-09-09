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
    """The check that decides whether a run passes (#341).

    It takes the whole plan, not one row: whether `SCAN recent` reads a table
    or a materialized CTE is only answerable from the rest of the plan.
    """

    def rows(self, *details: str):
        return [benchmark_sqlite.PlanRow(0, detail) for detail in details]

    def scanned(self, *details: str) -> list[str]:
        return [
            row.detail for row in benchmark_sqlite.full_table_scans(self.rows(*details))
        ]

    def test_a_bare_scan_is_the_regression_we_are_looking_for(self):
        self.assertEqual(self.scanned("SCAN tracks"), ["SCAN tracks"])

    def test_an_aliased_table_scan_is_caught(self):
        # SQLite prints the alias, not the table: `FROM tracks AS u` scans as
        # "SCAN u". A guard comparing against the table name would wave this
        # through, and in a self-join the other branch's index would keep the
        # rest of the run green.
        self.assertEqual(self.scanned("SCAN u"), ["SCAN u"])
        self.assertEqual(
            self.scanned(
                "SEARCH a USING INDEX idx_tracks_artist (normalized_artist=?)",
                "SCAN b",
            ),
            ["SCAN b"],
        )

    def test_an_ordered_index_scan_is_healthy(self):
        # "recently added" reads the whole date_added index in order. It is a
        # SCAN, and it is exactly what the index is for.
        self.assertEqual(self.scanned("SCAN tracks USING INDEX idx_tracks_recent"), [])

    def test_a_covering_index_scan_is_healthy(self):
        # The false positive this check was written to avoid: "USING COVERING
        # INDEX" does not contain the substring "USING INDEX", so a check
        # written against that one string reads COUNT(*) as a full table scan.
        self.assertEqual(
            self.scanned("SCAN tracks USING COVERING INDEX idx_tracks_recent"), []
        )

    def test_a_rowid_or_primary_key_read_is_healthy(self):
        self.assertEqual(
            self.scanned("SCAN tracks USING INTEGER PRIMARY KEY (rowid=?)"), []
        )
        self.assertEqual(self.scanned("SCAN tracks USING PRIMARY KEY"), [])

    def test_a_search_is_never_a_full_scan(self):
        self.assertEqual(
            self.scanned(
                "SEARCH tracks USING INDEX idx_tracks_artist (normalized_artist=?)"
            ),
            [],
        )

    def test_non_access_plan_rows_are_ignored(self):
        self.assertEqual(self.scanned("USE TEMP B-TREE FOR ORDER BY"), [])
        self.assertEqual(self.scanned("CO-ROUTINE (subquery-1)"), [])

    def test_subquery_and_constant_rows_are_transient_by_shape(self):
        self.assertEqual(self.scanned("SCAN (subquery-1)"), [])
        self.assertEqual(self.scanned("SCAN CONSTANT ROW"), [])

    def test_a_materialized_cte_is_transient_because_the_plan_says_so(self):
        # The declaration is what distinguishes reading a materialized CTE from
        # a full scan of a table that happens to be aliased the same way.
        self.assertEqual(
            self.scanned(
                "MATERIALIZE recent",
                "SCAN tracks USING INDEX idx_tracks_recent",
                "SCAN recent",
            ),
            [],
        )

    def test_the_same_name_without_a_declaration_is_a_table_scan(self):
        # Same row, no MATERIALIZE: now it is a table aliased `recent`.
        self.assertEqual(self.scanned("SCAN recent"), ["SCAN recent"])

    def test_a_cte_read_under_an_alias_needs_declaring(self):
        # SQLite prints "SCAN p" and declares only "MATERIALIZE picked";
        # nothing in the plan links them, and a *table* aliased p looks the
        # same. Flagged by default, cleared by the query saying so.
        plan = self.rows(
            "MATERIALIZE picked",
            "SEARCH tracks USING COVERING INDEX idx_tracks_artist (normalized_artist=?)",
            "SCAN p",
        )
        self.assertEqual(
            [row.detail for row in benchmark_sqlite.full_table_scans(plan)],
            ["SCAN p"],
        )
        self.assertEqual(benchmark_sqlite.full_table_scans(plan, ("p",)), [])

    def test_declaring_an_alias_does_not_excuse_other_scans(self):
        plan = self.rows("MATERIALIZE picked", "SCAN p", "SCAN tracks")
        self.assertEqual(
            [row.detail for row in benchmark_sqlite.full_table_scans(plan, ("p",))],
            ["SCAN tracks"],
        )

    def test_a_scan_inside_a_subquery_still_counts(self):
        # The subquery's *result* is transient; the table it reads is not.
        self.assertEqual(
            self.scanned(
                "SEARCH tracks USING COVERING INDEX idx_tracks_artist (normalized_artist=?)",
                "LIST SUBQUERY 1",
                "SCAN tracks",
            ),
            ["SCAN tracks"],
        )


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
            benchmark_sqlite.plan_names_index(
                self.rows("SCAN tracks"), "idx_tracks_artist"
            )
        )

    def test_an_index_whose_name_merely_starts_the_same_does_not_count(self):
        # idx_tracks_album is a prefix of idx_tracks_album_artist, so substring
        # matching would report a green run on the wrong index — and the scan
        # guard stays quiet, because the plan really is using *an* index.
        plan = self.rows(
            "SEARCH tracks USING INDEX idx_tracks_album_artist (normalized_album_artist=?)"
        )
        self.assertFalse(benchmark_sqlite.plan_names_index(plan, "idx_tracks_album"))
        self.assertTrue(
            benchmark_sqlite.plan_names_index(plan, "idx_tracks_album_artist")
        )

    def test_an_index_named_by_a_covering_scan_counts(self):
        plan = self.rows("SCAN tracks USING COVERING INDEX idx_tracks_recent")
        self.assertTrue(benchmark_sqlite.plan_names_index(plan, "idx_tracks_recent"))

    def test_covering_access_is_recognised_whichever_index_it_is(self):
        # COUNT(*) may ride any covering index, so this check asks about the
        # access shape rather than a name.
        for index in ("idx_tracks_recent", "idx_tracks_title", "idx_anything_else"):
            with self.subTest(index=index):
                plan = self.rows(f"SCAN tracks USING COVERING INDEX {index}")
                self.assertTrue(benchmark_sqlite.plan_uses_covering_index(plan))

    def test_a_non_covering_plan_is_not_covering_access(self):
        plan = self.rows(
            "SEARCH tracks USING INDEX idx_tracks_artist (normalized_artist=?)",
            "SCAN tracks USING INDEX idx_tracks_recent",
        )
        self.assertFalse(benchmark_sqlite.plan_uses_covering_index(plan))


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
        plan = self.plan(
            "SELECT id FROM tracks WHERE normalized_artist LIKE ?", ("%a%",)
        )
        self.assertTrue(benchmark_sqlite.full_table_scans(plan))

    def test_a_real_aliased_scan_is_reported(self):
        # Against a real database, so the plan string is SQLite's, not mine —
        # this is the shape my first attempt at the guard invented wrongly.
        plan = self.plan("SELECT id FROM tracks AS u WHERE u.normalized_artist LIKE ?", ("%a%",))
        self.assertEqual([row.detail for row in plan], ["SCAN u"])
        self.assertTrue(benchmark_sqlite.full_table_scans(plan))

    def test_a_real_aliased_cte_is_reported_until_declared(self):
        plan = self.plan(
            "WITH picked AS MATERIALIZED "
            "(SELECT id FROM tracks WHERE normalized_artist = ?) "
            "SELECT id FROM picked AS p",
            ("a",),
        )
        self.assertIn("SCAN p", [row.detail for row in plan])
        self.assertTrue(benchmark_sqlite.full_table_scans(plan))
        self.assertEqual(benchmark_sqlite.full_table_scans(plan, ("p",)), [])

    def test_a_real_materialized_cte_is_not_reported(self):
        plan = self.plan(
            "WITH picked AS MATERIALIZED "
            "(SELECT id FROM tracks WHERE normalized_artist = ?) "
            "SELECT id FROM picked",
            ("a",),
        )
        self.assertTrue(any("MATERIALIZE" in row.detail for row in plan))
        self.assertEqual(benchmark_sqlite.full_table_scans(plan), [])


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
                if query.uses_index is None:
                    continue
                self.assertIn(query.uses_index, defined)

    def test_every_query_states_what_its_plan_has_to_do(self):
        # Either it names an index, or it says any covering index will do.
        # A query claiming neither would be timed and never plan-checked.
        for query in benchmark_sqlite.QUERIES:
            with self.subTest(query=query.name):
                self.assertTrue(
                    query.uses_index is not None or query.covering_index_only,
                    f"{query.name} asserts nothing about its plan",
                )

    def test_query_names_are_unique_and_short_enough_to_line_up(self):
        names = [query.name for query in benchmark_sqlite.QUERIES]
        self.assertEqual(len(names), len(set(names)))
        for name in names:
            self.assertLessEqual(len(name), 18, name)

    def test_every_schema_index_is_exercised_by_some_query(self):
        # #341 is about showing the indexes are used. An index nothing
        # benchmarks is one nothing would notice losing.
        exercised = {
            query.uses_index
            for query in benchmark_sqlite.QUERIES
            if query.uses_index is not None
        }
        self.assertEqual(self.schema_indexes() - exercised, set())


if __name__ == "__main__":
    unittest.main()
