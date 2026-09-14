#!/usr/bin/env python3
"""Unit tests for tools/startup/startup_report.py.

The reporter is the half of the startup benchmark that makes a judgement, so it
is the half that has to be tested against sample sets whose answer is known.
Nothing here needs Flutter, a stopwatch or a quiet machine: it builds synthetic
runs and checks what the reporter says about them, including the two ways a
verdict can be wrong (calling an identical run a regression, and calling an
injected slowdown fine).

    python3 test/tooling/startup_report_test.py
"""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools" / "startup"))

import startup_report  # noqa: E402

SCRIPT = ROOT / "tools" / "startup" / "startup_report.py"


def samples(
    values_ms: list[float],
    *,
    warmup: int = 1,
    rows: int = 13,
    first_frame_ms: float = 20.0,
    simulated_ms: float = 8.0,
) -> list[dict[str, object]]:
    """Turns a list of first-usable-frame readings into recorded launches."""
    return [
        {
            "iteration": index,
            "warmup": index < warmup,
            "first_frame_ms": first_frame_ms,
            "first_usable_frame_ms": value,
            "simulated_ms": simulated_ms,
            "frames": int(simulated_ms / 4) + 1,
            "rows_rendered": rows,
        }
        for index, value in enumerate(values_ms)
    ]


def workload(
    name: str,
    tracks: int,
    values_ms: list[float],
    **kwargs: object,
) -> dict[str, object]:
    rows = 0 if tracks == 0 else 13
    albums = 0 if tracks == 0 else (tracks + 11) // 12
    return {
        "name": name,
        "tracks": tracks,
        "albums": albums,
        "artists": 0 if albums == 0 else (albums + 7) // 8,
        "fixture_build_ms": 12.0,
        "fixture_bytes": 4096,
        "usable_signal": "first track row painted",
        "samples": samples(values_ms, rows=rows, **kwargs),  # type: ignore[arg-type]
    }


def run_payload(
    *workloads: dict[str, object], **overrides: object
) -> dict[str, object]:
    payload: dict[str, object] = {
        "schema": startup_report.SCHEMA,
        "label": "test",
        "milestone": "first_usable_frame",
        "build_mode": "debug",
        "runtime": "flutter test (Dart VM, JIT)",
        "dart_version": "3.12.2 (stable)",
        "operating_system": "linux",
        "cpu_cores": 8,
        "iterations": 4,
        "warmup": 1,
        "pump_interval_ms": 4,
        "window": {"width": 1600.0, "height": 1000.0, "device_pixel_ratio": 1.0},
        "slow_catalog_ms": 0,
        "network_sources": 0,
        "workloads": list(workloads)
        or [
            workload("empty", 0, [100.0, 100.0, 100.0, 100.0]),
            workload("small", 1000, [300.0, 310.0, 305.0, 300.0]),
            workload("large", 20000, [4000.0, 4100.0, 4050.0, 4000.0]),
        ],
    }
    payload.update(overrides)
    return payload


class ParsingTest(unittest.TestCase):
    def test_a_complete_run_parses(self) -> None:
        run = startup_report.parse(run_payload())
        self.assertEqual([w.name for w in run.workloads], ["empty", "small", "large"])
        self.assertEqual(run.build_mode, "debug")
        self.assertEqual(run.workload("large").tracks, 20000)

    def test_an_unknown_schema_is_refused(self) -> None:
        payload = run_payload(schema="linthra.startup.v99")
        with self.assertRaises(startup_report.InvalidReport) as raised:
            startup_report.parse(payload)
        self.assertIn("v99", str(raised.exception))

    def test_a_run_with_no_workloads_is_refused(self) -> None:
        with self.assertRaises(startup_report.InvalidReport):
            startup_report.parse(run_payload(workloads=[]))

    def test_a_workload_with_no_launches_is_refused(self) -> None:
        broken = workload("small", 1000, [])
        with self.assertRaises(startup_report.InvalidReport) as raised:
            startup_report.parse(run_payload(broken))
        self.assertIn("recorded no launches", str(raised.exception))

    def test_a_duplicated_workload_is_refused(self) -> None:
        """Two 'large' blocks would make workload(name) silently pick one."""
        payload = run_payload(
            workload("large", 20000, [4000.0] * 4),
            workload("large", 50000, [9000.0] * 4),
        )
        with self.assertRaises(startup_report.InvalidReport) as raised:
            startup_report.parse(payload)
        self.assertIn("recorded twice", str(raised.exception))

    def test_a_usable_frame_before_the_first_frame_is_refused(self) -> None:
        """Impossible by construction, so a file saying it is not trustworthy."""
        broken = workload("small", 1000, [300.0] * 4, first_frame_ms=900.0)
        with self.assertRaises(startup_report.InvalidReport) as raised:
            startup_report.parse(run_payload(broken))
        self.assertIn("precedes", str(raised.exception))

    def test_tracks_with_no_rows_painted_is_refused(self) -> None:
        """The milestone for a non-empty library IS a painted row.

        A run that reports timings for 1,000 tracks and never painted one
        measured something else, and its numbers would compare against a real
        run as an enormous, entirely fictional improvement.
        """
        broken = workload("small", 1000, [300.0] * 4)
        for sample in broken["samples"]:  # type: ignore[index]
            sample["rows_rendered"] = 0
        with self.assertRaises(startup_report.InvalidReport) as raised:
            startup_report.parse(run_payload(broken))
        self.assertIn("painted no rows", str(raised.exception))

    def test_an_empty_library_is_allowed_to_paint_no_rows(self) -> None:
        run = startup_report.parse(run_payload(workload("empty", 0, [90.0] * 4)))
        self.assertEqual(run.workload("empty").tracks, 0)

    def test_a_missing_window_is_refused(self) -> None:
        payload = run_payload()
        del payload["window"]
        with self.assertRaises(startup_report.InvalidReport):
            startup_report.parse(payload)

    def test_a_non_numeric_timing_is_refused(self) -> None:
        broken = workload("small", 1000, [300.0] * 4)
        broken["samples"][0]["first_usable_frame_ms"] = "fast"  # type: ignore[index]
        with self.assertRaises(startup_report.InvalidReport) as raised:
            startup_report.parse(run_payload(broken))
        self.assertIn("not a number", str(raised.exception))


class WarmUpTest(unittest.TestCase):
    """Both filters apply: the leading count, and the harness's own flags."""

    def test_a_flagged_launch_is_dropped_whatever_the_count_says(self) -> None:
        run = startup_report.parse(
            run_payload(workload("small", 1000, [9000.0, 300.0, 300.0, 300.0]))
        )
        stats = startup_report.summarise(run.workload("small"), 0)
        self.assertEqual(stats.count, 3)
        self.assertAlmostEqual(stats.median_ms, 300.0)

    def test_the_count_drops_leading_launches_that_carry_no_flag(self) -> None:
        block = workload("small", 1000, [9000.0, 300.0, 300.0, 300.0], warmup=0)
        run = startup_report.parse(run_payload(block))
        self.assertEqual(startup_report.summarise(run.workload("small"), 0).count, 4)
        self.assertEqual(startup_report.summarise(run.workload("small"), 1).count, 3)


class StatsTest(unittest.TestCase):
    def test_the_median_ignores_one_slow_launch(self) -> None:
        block = workload("small", 1000, [9000.0, 300.0, 305.0, 310.0, 4000.0])
        stats = startup_report.summarise(startup_report.parse(run_payload(block)).workload("small"), 1)
        self.assertAlmostEqual(stats.median_ms, 307.5)

    def test_spread_reports_how_much_the_machine_disagreed_with_itself(self) -> None:
        block = workload("small", 1000, [9000.0, 100.0, 100.0, 200.0])
        stats = startup_report.summarise(startup_report.parse(run_payload(block)).workload("small"), 1)
        self.assertAlmostEqual(stats.spread, 1.0)
        self.assertTrue(stats.noisy)

    def test_a_steady_run_is_not_noisy(self) -> None:
        block = workload("small", 1000, [9000.0, 300.0, 305.0, 310.0])
        stats = startup_report.summarise(startup_report.parse(run_payload(block)).workload("small"), 1)
        self.assertFalse(stats.noisy)

    def test_too_few_launches_is_not_trustworthy(self) -> None:
        block = workload("small", 1000, [9000.0, 300.0, 305.0])
        stats = startup_report.summarise(startup_report.parse(run_payload(block)).workload("small"), 1)
        self.assertEqual(stats.count, 2)
        self.assertFalse(stats.trustworthy)


def comparison(
    baseline_ms: list[float], candidate_ms: list[float], **kwargs: float
) -> startup_report.Comparison:
    base = startup_report.parse(run_payload(workload("small", 1000, baseline_ms)))
    cand = startup_report.parse(run_payload(workload("small", 1000, candidate_ms)))
    return startup_report.compare(base, cand, warmup=1, **kwargs)  # type: ignore[arg-type]


class ComparisonTest(unittest.TestCase):
    def test_an_identical_run_is_not_a_regression(self) -> None:
        steady = [9000.0, 300.0, 305.0, 300.0, 310.0]
        self.assertFalse(comparison(steady, list(steady)).regressed)

    def test_ordinary_jitter_is_not_a_regression(self) -> None:
        base = [9000.0, 300.0, 305.0, 300.0, 310.0]
        jittery = [9000.0, 318.0, 296.0, 330.0, 302.0]
        self.assertFalse(comparison(base, jittery).regressed)

    def test_a_real_slowdown_is_caught(self) -> None:
        base = [9000.0, 300.0, 305.0, 300.0, 310.0]
        slower = [9000.0, 550.0, 560.0, 545.0, 555.0]
        result = comparison(base, slower)
        self.assertTrue(result.regressed)
        self.assertGreater(result.workloads[0].ratio, 1.7)

    def test_a_large_ratio_on_a_tiny_number_is_not_a_regression(self) -> None:
        """The absolute floor. 30 ms to 54 ms is 80% slower and is noise."""
        result = comparison([9000.0, 30.0, 30.0, 30.0], [9000.0, 54.0, 54.0, 54.0])
        self.assertGreater(result.workloads[0].ratio, 1.7)
        self.assertFalse(result.regressed)

    def test_a_large_absolute_delta_on_a_large_number_is_not_a_regression(self) -> None:
        """The relative clause. 4,000 ms to 4,200 ms is 200 ms and is noise."""
        base = [9000.0, 4000.0, 4000.0, 4000.0]
        slower = [9000.0, 4200.0, 4200.0, 4200.0]
        self.assertGreater(comparison(base, slower).workloads[0].delta_ms, 100)
        self.assertFalse(comparison(base, slower).regressed)

    def test_a_truncated_run_is_indeterminate_rather_than_regressed(self) -> None:
        """Missing evidence is its own answer, in neither direction.

        Calling it a regression looks like a fail-safe and is only safe one
        way: it does keep a truncated run from passing `--expect same`, but it
        also lets a canary whose samples went missing satisfy `--expect
        regressed` without having detected anything.
        """
        base = [9000.0, 300.0, 300.0, 300.0]
        for short in (comparison(base, [9000.0, 300.0]), comparison([9000.0, 300.0], base)):
            self.assertTrue(short.indeterminate)
            self.assertEqual(short.unjudgeable, ("small",))
            self.assertFalse(short.regressed)
            self.assertFalse(short.regressed_everywhere)

    def test_a_complete_comparison_is_determinate(self) -> None:
        steady = [9000.0, 300.0, 305.0, 300.0]
        self.assertFalse(comparison(steady, list(steady)).indeterminate)

    def test_one_slow_workload_regresses_the_run(self) -> None:
        base = startup_report.parse(
            run_payload(
                workload("empty", 0, [9000.0, 100.0, 100.0, 100.0]),
                workload("small", 1000, [9000.0, 300.0, 300.0, 300.0]),
            )
        )
        cand = startup_report.parse(
            run_payload(
                workload("empty", 0, [9000.0, 100.0, 100.0, 100.0]),
                workload("small", 1000, [9000.0, 900.0, 900.0, 900.0]),
            )
        )
        result = startup_report.compare(base, cand, warmup=1)
        self.assertFalse(result.workloads[0].regressed)
        self.assertTrue(result.workloads[1].regressed)
        self.assertTrue(result.regressed)

    def test_the_allowances_are_adjustable(self) -> None:
        base = [9000.0, 300.0, 300.0, 300.0]
        slower = [9000.0, 360.0, 360.0, 360.0]
        self.assertFalse(comparison(base, slower).regressed)
        self.assertTrue(
            comparison(base, slower, relative_allowance=0.1).regressed
        )


class SimulatedClockTest(unittest.TestCase):
    """The clock a wall clock in a widget test cannot see.

    `tester.pump(d)` advances the binding's fake clock instead of waiting, so a
    regression that adds an awaited timer costs no measurable wall time and
    shows up only as more trips round the pump loop. Measured on the real
    harness: a clean launch takes 3 frames on every workload, and the canary's
    250 ms delay takes 65, while the large workload's wall clock moved 1.10x.
    A check watching only the stopwatch would have called that fine.
    """

    def runs(
        self, baseline_sim: float, candidate_sim: float
    ) -> startup_report.Comparison:
        steady = [9000.0, 300.0, 305.0, 300.0]
        base = startup_report.parse(
            run_payload(
                {
                    **workload("small", 1000, steady),
                    "samples": samples(steady, simulated_ms=baseline_sim),
                }
            )
        )
        cand = startup_report.parse(
            run_payload(
                {
                    **workload("small", 1000, steady),
                    "samples": samples(steady, simulated_ms=candidate_sim),
                }
            )
        )
        return startup_report.compare(base, cand)

    def test_an_added_await_is_caught_with_no_extra_wall_time(self) -> None:
        result = self.runs(8.0, 256.0)
        self.assertAlmostEqual(result.workloads[0].delta_ms, 0.0)
        self.assertFalse(result.workloads[0].worked_longer)
        self.assertTrue(result.workloads[0].waited_longer)
        self.assertTrue(result.regressed)

    def test_the_same_awaited_time_is_not_a_regression(self) -> None:
        self.assertFalse(self.runs(8.0, 8.0).regressed)

    def test_a_frame_or_two_of_difference_is_noise(self) -> None:
        self.assertFalse(self.runs(8.0, 16.0).regressed)

    def test_the_allowance_is_adjustable(self) -> None:
        steady = [9000.0, 300.0, 300.0, 300.0]
        base = startup_report.parse(
            run_payload(
                {
                    **workload("small", 1000, steady),
                    "samples": samples(steady, simulated_ms=8.0),
                }
            )
        )
        cand = startup_report.parse(
            run_payload(
                {
                    **workload("small", 1000, steady),
                    "samples": samples(steady, simulated_ms=20.0),
                }
            )
        )
        self.assertFalse(startup_report.compare(base, cand).regressed)
        self.assertTrue(
            startup_report.compare(
                base, cand, simulated_allowance_ms=4.0
            ).regressed
        )

    def test_a_sample_set_with_no_simulated_time_is_refused(self) -> None:
        broken = workload("small", 1000, [9000.0, 300.0, 300.0, 300.0])
        for sample in broken["samples"]:  # type: ignore[index]
            del sample["simulated_ms"]
        with self.assertRaises(startup_report.InvalidReport) as raised:
            startup_report.parse(run_payload(broken))
        self.assertIn("simulated_ms", str(raised.exception))


class RecordedWarmUpTest(unittest.TestCase):
    """The run's own warm-up count is the authority, including when it is 0."""

    def test_a_run_that_warmed_up_nothing_keeps_its_first_launch(self) -> None:
        block = workload("small", 1000, [300.0, 305.0, 310.0, 300.0], warmup=0)
        run = startup_report.parse(run_payload(block, warmup=0))
        self.assertEqual(startup_report.effective_warmup(run, None), 0)
        self.assertEqual(
            startup_report.summarise(run.workload("small"), 0).count, 4
        )

    def test_a_run_that_warmed_up_two_drops_two(self) -> None:
        block = workload("small", 1000, [9000.0, 8000.0, 300.0, 305.0], warmup=2)
        run = startup_report.parse(run_payload(block, warmup=2))
        self.assertEqual(startup_report.effective_warmup(run, None), 2)
        self.assertEqual(
            startup_report.summarise(run.workload("small"), 2).count, 2
        )

    def test_an_explicit_override_still_wins(self) -> None:
        run = startup_report.parse(run_payload(warmup=0))
        self.assertEqual(startup_report.effective_warmup(run, 2), 2)

    def test_each_run_reads_with_its_own_count(self) -> None:
        """Read alone, a run is summarised by the count it recorded."""
        steady = [300.0, 300.0, 300.0, 300.0]
        zero = startup_report.parse(
            run_payload(workload("small", 1000, steady, warmup=0), warmup=0)
        )
        one = startup_report.parse(
            run_payload(workload("small", 1000, [9000.0, 300.0, 300.0, 300.0]))
        )
        self.assertEqual(
            startup_report.summarise(
                zero.workload("small"), startup_report.effective_warmup(zero, None)
            ).count,
            4,
        )
        self.assertEqual(
            startup_report.summarise(
                one.workload("small"), startup_report.effective_warmup(one, None)
            ).count,
            3,
        )

    def test_but_two_runs_with_different_counts_are_not_compared(self) -> None:
        """Their judged launches sit at different levels of JIT warming."""
        steady = [300.0, 300.0, 300.0, 300.0]
        zero = startup_report.parse(
            run_payload(workload("small", 1000, steady, warmup=0), warmup=0)
        )
        one = startup_report.parse(
            run_payload(workload("small", 1000, [9000.0, 300.0, 300.0, 300.0]))
        )
        with self.assertRaises(startup_report.InvalidReport) as raised:
            startup_report.compare(zero, one)
        self.assertIn("warm-up count", str(raised.exception))


class CompletenessTest(unittest.TestCase):
    """What --validate is really for: proving the harness measured something."""

    def test_a_complete_run_has_no_problems(self) -> None:
        run = startup_report.parse(run_payload())
        self.assertEqual(startup_report.completeness_problems(run, 1), [])

    def test_a_truncated_workload_is_a_problem(self) -> None:
        run = startup_report.parse(
            run_payload(
                workload("small", 1000, [9000.0, 300.0]),
                iterations=4,
            )
        )
        problems = startup_report.completeness_problems(run, 1)
        self.assertEqual(len(problems), 1)
        self.assertIn("recorded 2 launch(es)", problems[0])

    def test_a_run_of_nothing_but_warm_up_is_a_problem(self) -> None:
        """The shape the smoke run would take if the harness died early."""
        run = startup_report.parse(
            run_payload(workload("small", 1000, [9000.0]), iterations=1)
        )
        problems = startup_report.completeness_problems(run, 1)
        self.assertEqual(len(problems), 1)
        self.assertIn("nothing was actually measured", problems[0])


class IndeterminateExpectationTest(unittest.TestCase):
    """No expectation is answerable when a side has too little evidence."""

    def write(self, path: Path, payload: dict[str, object]) -> Path:
        path.write_text(json.dumps(payload), encoding="utf-8")
        return path

    def run_script(self, *args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(SCRIPT), *args],
            capture_output=True,
            text=True,
            check=False,
        )

    def test_every_expectation_refuses_a_truncated_candidate(self) -> None:
        full = run_payload(workload("small", 1000, [9000.0, 300.0, 300.0, 300.0]))
        short = run_payload(workload("small", 1000, [9000.0, 300.0]), iterations=2)
        with tempfile.TemporaryDirectory() as directory:
            base = self.write(Path(directory) / "base.json", full)
            cut = self.write(Path(directory) / "cut.json", short)
            for expectation in ("same", "regressed", "regressed-everywhere"):
                result = self.run_script(
                    str(cut), "--baseline", str(base), "--expect", expectation
                )
                self.assertEqual(result.returncode, 1, expectation)
                self.assertIn("cannot judge", result.stderr)

    def test_the_report_says_so_rather_than_inventing_a_verdict(self) -> None:
        full = run_payload(workload("small", 1000, [9000.0, 300.0, 300.0, 300.0]))
        short = run_payload(workload("small", 1000, [9000.0, 300.0]), iterations=2)
        with tempfile.TemporaryDirectory() as directory:
            base = self.write(Path(directory) / "base.json", full)
            cut = self.write(Path(directory) / "cut.json", short)
            result = self.run_script(str(cut), "--baseline", str(base))
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("NOT ENOUGH DATA", result.stdout)


class WorkloadShapeTest(unittest.TestCase):
    """Everything the fixture decided is compared, not an allowlist of it.

    Track count, album count, artist count and the milestone signal were each
    found as a separate hole. Comparing the whole recorded shape is what stops
    the next field being another one.
    """

    def refuses(self, field: str, value: object) -> str:
        steady = [9000.0, 300.0, 300.0, 300.0]
        base = startup_report.parse(run_payload(workload("small", 1000, steady)))
        changed = workload("small", 1000, steady)
        changed[field] = value
        cand = startup_report.parse(run_payload(changed))
        with self.assertRaises(startup_report.InvalidReport) as raised:
            startup_report.compare(base, cand)
        return str(raised.exception)

    def test_a_different_album_count_is_refused(self) -> None:
        self.assertIn("different albums", self.refuses("albums", 1000))

    def test_a_different_artist_count_is_refused(self) -> None:
        """`_albumsPerArtist` moving changes what the Artists tab groups."""
        self.assertIn("different artists", self.refuses("artists", 1000))

    def test_a_different_milestone_signal_is_refused(self) -> None:
        """Moving the finder earlier makes every candidate timing faster."""
        message = self.refuses("usable_signal", "first library widget built")
        self.assertIn("different usable signal", message)

    def test_the_shape_covers_every_recorded_decision(self) -> None:
        """A field added to the fixture is compared without editing a list."""
        run = startup_report.parse(run_payload())
        self.assertEqual(
            sorted(run.workload("small").shape),
            ["albums", "artists", "tracks", "usable signal"],
        )

    def test_generator_timings_are_not_part_of_the_shape(self) -> None:
        """They measure the generator and the disk, and vary run to run."""
        shape = startup_report.parse(run_payload()).workload("small").shape
        self.assertNotIn("fixture_build_ms", shape)
        self.assertNotIn("fixture_bytes", shape)


class ComparabilityTest(unittest.TestCase):
    """Two runs are only each other's control when they measured the same thing."""

    def refuses(self, **overrides: object) -> str:
        base = startup_report.parse(run_payload())
        cand = startup_report.parse(run_payload(**overrides))
        with self.assertRaises(startup_report.InvalidReport) as raised:
            startup_report.compare(base, cand, warmup=1)
        return str(raised.exception)

    def test_a_different_build_mode_is_refused(self) -> None:
        self.assertIn("build mode", self.refuses(build_mode="release"))

    def test_a_different_milestone_is_refused(self) -> None:
        self.assertIn("first_frame", self.refuses(milestone="first_frame"))

    def test_a_different_window_is_refused(self) -> None:
        message = self.refuses(
            window={"width": 800.0, "height": 600.0, "device_pixel_ratio": 1.0}
        )
        self.assertIn("window", message)

    def test_a_different_library_size_is_refused(self) -> None:
        message = self.refuses(
            workloads=[
                workload("empty", 0, [100.0] * 4),
                workload("small", 1000, [300.0] * 4),
                workload("large", 50000, [4000.0] * 4),
            ]
        )
        self.assertIn("different tracks", message)
        self.assertIn("50000", message)

    def test_a_missing_workload_is_refused(self) -> None:
        """A run-level verdict has to cover every workload it claims to.

        LINTHRA_STARTUP_WORKLOADS makes a subset easy to produce, and silently
        skipping the one that is missing would let `--expect same` pass a
        candidate whose large workload was never measured.
        """
        message = self.refuses(
            workloads=[
                workload("empty", 0, [100.0] * 4),
                workload("small", 1000, [300.0] * 4),
            ]
        )
        self.assertIn("different workloads", message)
        self.assertIn("large", message)

    def test_an_extra_workload_is_refused(self) -> None:
        message = self.refuses(
            workloads=[
                workload("empty", 0, [100.0] * 4),
                workload("small", 1000, [300.0] * 4),
                workload("large", 20000, [4000.0] * 4),
                workload("huge", 200000, [9000.0] * 4),
            ]
        )
        self.assertIn("baseline is missing huge", message)

    def test_no_shared_workload_is_refused(self) -> None:
        message = self.refuses(workloads=[workload("huge", 200000, [9000.0] * 4)])
        self.assertIn("different workloads", message)

    def test_the_canary_stays_comparable_to_its_baseline(self) -> None:
        """The armed run differs on purpose, and must still be comparable."""
        base = startup_report.parse(run_payload())
        cand = startup_report.parse(run_payload(slow_catalog_ms=250))
        self.assertIsNone(startup_report.comparability_problem(base, cand))


class ComparableRunsTest(unittest.TestCase):
    def test_two_runs_of_the_same_protocol_compare(self) -> None:
        base = startup_report.parse(run_payload())
        cand = startup_report.parse(run_payload())
        self.assertIsNone(startup_report.comparability_problem(base, cand))


class RequiredWorkloadsTest(unittest.TestCase):
    """--validate can only speak for what is in the file unless told what to expect."""

    def test_a_complete_run_is_missing_nothing(self) -> None:
        run = startup_report.parse(run_payload())
        self.assertEqual(
            startup_report.missing_workloads(run, ["empty", "small", "large"]), []
        )

    def test_a_subset_names_what_is_absent(self) -> None:
        run = startup_report.parse(
            run_payload(
                workload("empty", 0, [100.0] * 4),
                workload("small", 1000, [300.0] * 4),
            )
        )
        self.assertEqual(
            startup_report.missing_workloads(run, ["empty", "small", "large"]),
            ["large"],
        )


class CanaryScopeTest(unittest.TestCase):
    """The canary delays every read, so every workload has to see it.

    An `any()` policy would pass a canary that still fires on `empty` and has
    stopped firing on the other two, which is two thirds of the check silently
    retiring.
    """

    def comparison_of(
        self, candidate_ms: dict[str, list[float]]
    ) -> startup_report.Comparison:
        steady = {
            "empty": [9000.0, 100.0, 100.0, 100.0],
            "small": [9000.0, 300.0, 300.0, 300.0],
            "large": [9000.0, 4000.0, 4000.0, 4000.0],
        }
        tracks = {"empty": 0, "small": 1000, "large": 20000}
        base = startup_report.parse(
            run_payload(*(workload(n, tracks[n], v) for n, v in steady.items()))
        )
        cand = startup_report.parse(
            run_payload(
                *(workload(n, tracks[n], candidate_ms[n]) for n in steady)
            )
        )
        return startup_report.compare(base, cand)

    def test_every_workload_slower_satisfies_both(self) -> None:
        result = self.comparison_of(
            {
                "empty": [9000.0, 700.0, 700.0, 700.0],
                "small": [9000.0, 900.0, 900.0, 900.0],
                "large": [9000.0, 9000.0, 9000.0, 9000.0],
            }
        )
        self.assertTrue(result.regressed)
        self.assertTrue(result.regressed_everywhere)

    def test_one_workload_slower_is_not_everywhere(self) -> None:
        result = self.comparison_of(
            {
                "empty": [9000.0, 700.0, 700.0, 700.0],
                "small": [9000.0, 300.0, 300.0, 300.0],
                "large": [9000.0, 4000.0, 4000.0, 4000.0],
            }
        )
        self.assertTrue(result.regressed)
        self.assertFalse(result.regressed_everywhere)

    def test_nothing_slower_is_neither(self) -> None:
        result = self.comparison_of(
            {
                "empty": [9000.0, 100.0, 100.0, 100.0],
                "small": [9000.0, 300.0, 300.0, 300.0],
                "large": [9000.0, 4000.0, 4000.0, 4000.0],
            }
        )
        self.assertFalse(result.regressed)
        self.assertFalse(result.regressed_everywhere)


class MilestoneRowTest(unittest.TestCase):
    """The milestone for a non-empty library IS a painted row."""

    def test_a_launch_that_painted_nothing_is_refused(self) -> None:
        """Not just "all of them": the judged launches are what is used."""
        broken = workload("small", 1000, [9000.0, 300.0, 300.0, 300.0])
        for sample in broken["samples"][1:]:  # type: ignore[index]
            sample["rows_rendered"] = 0
        with self.assertRaises(startup_report.InvalidReport) as raised:
            startup_report.parse(run_payload(broken))
        self.assertIn("painted no rows", str(raised.exception))
        self.assertIn("[1, 2, 3]", str(raised.exception))

    def test_a_warm_up_that_painted_nothing_is_refused_too(self) -> None:
        broken = workload("small", 1000, [9000.0, 300.0, 300.0, 300.0])
        broken["samples"][0]["rows_rendered"] = 0  # type: ignore[index]
        with self.assertRaises(startup_report.InvalidReport):
            startup_report.parse(run_payload(broken))


class ProtocolTest(unittest.TestCase):
    """How a run measured is compared as a whole, like the workload's shape."""

    def refuses(self, **overrides: object) -> str:
        base = startup_report.parse(run_payload())
        cand = startup_report.parse(run_payload(**overrides))
        with self.assertRaises(startup_report.InvalidReport) as raised:
            startup_report.compare(base, cand)
        return str(raised.exception)

    def test_a_different_warm_up_count_is_refused(self) -> None:
        """Judged launches would sit at different levels of JIT warming."""
        self.assertIn("warm-up count", self.refuses(warmup=2))

    def test_a_different_pump_interval_is_refused(self) -> None:
        self.assertIn("pump interval", self.refuses(pump_interval_ms=16))

    def test_a_different_build_mode_is_refused(self) -> None:
        self.assertIn("build mode", self.refuses(build_mode="release"))

    def test_the_protocol_covers_every_measurement_decision(self) -> None:
        run = startup_report.parse(run_payload())
        self.assertEqual(
            sorted(run.protocol),
            ["build mode", "milestone", "pump interval", "warm-up count", "window"],
        )

    def test_the_canary_s_own_differences_are_not_part_of_it(self) -> None:
        """It differs by label and injected delay on purpose."""
        protocol = startup_report.parse(run_payload()).protocol
        for excluded in ("label", "slow_catalog_ms", "iterations"):
            self.assertNotIn(excluded, protocol)


class TwoSidedControlTest(unittest.TestCase):
    """An identical re-run has to agree, not merely fail to be slower."""

    def comparison_of(self, candidate_ms: list[float]) -> startup_report.Comparison:
        base = startup_report.parse(
            run_payload(workload("small", 1000, [9000.0, 300.0, 300.0, 300.0]))
        )
        cand = startup_report.parse(
            run_payload(workload("small", 1000, candidate_ms))
        )
        return startup_report.compare(base, cand)

    def test_an_identical_run_has_not_diverged(self) -> None:
        self.assertFalse(
            self.comparison_of([9000.0, 300.0, 305.0, 300.0]).diverged
        )

    def test_a_much_faster_control_has_diverged(self) -> None:
        """`same` passes it; the control's `equivalent` does not."""
        result = self.comparison_of([9000.0, 100.0, 100.0, 100.0])
        self.assertFalse(result.regressed)
        self.assertTrue(result.diverged)
        self.assertEqual(result.divergent, ("small",))

    def test_a_slower_control_has_diverged_as_well(self) -> None:
        result = self.comparison_of([9000.0, 900.0, 900.0, 900.0])
        self.assertTrue(result.regressed)
        self.assertTrue(result.diverged)

    def test_a_small_absolute_speed_up_is_still_noise(self) -> None:
        """The floor applies in both directions."""
        self.assertFalse(
            self.comparison_of([9000.0, 285.0, 285.0, 285.0]).diverged
        )


class BudgetTest(unittest.TestCase):
    def test_a_run_inside_its_budget_reports_nothing(self) -> None:
        run = startup_report.parse(run_payload())
        self.assertEqual(startup_report.check_budgets(run, [("small", 500.0)], 1), [])

    def test_a_run_over_its_budget_is_reported(self) -> None:
        run = startup_report.parse(run_payload())
        failures = startup_report.check_budgets(run, [("small", 100.0)], 1)
        self.assertEqual(len(failures), 1)
        self.assertIn("over the", failures[0])

    def test_a_budget_cannot_pass_on_a_workload_nothing_measured(self) -> None:
        """A median of zero is under any budget, and means nothing happened."""
        run = startup_report.parse(
            run_payload(workload("small", 1000, [9000.0], warmup=1), iterations=1)
        )
        failures = startup_report.check_budgets(run, [("small", 5000.0)], 1)
        self.assertEqual(len(failures), 1)
        self.assertIn("no judged launch", failures[0])

    def test_a_budget_for_a_workload_that_is_not_there_is_a_failure(self) -> None:
        run = startup_report.parse(run_payload())
        failures = startup_report.check_budgets(run, [("gigantic", 100.0)], 1)
        self.assertIn("no workload named", failures[0])


class CommandLineTest(unittest.TestCase):
    """Runs the real script, the way the runner script and CI run it."""

    def write(self, path: Path, payload: dict[str, object]) -> Path:
        path.write_text(json.dumps(payload), encoding="utf-8")
        return path

    def run_script(self, *args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(SCRIPT), *args],
            capture_output=True,
            text=True,
            check=False,
        )

    def test_it_reports_a_run_without_a_baseline(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = self.write(Path(directory) / "run.json", run_payload())
            result = self.run_script(str(path))
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("first_usable_frame", result.stdout)
            self.assertIn("20,000", result.stdout)

    def test_validate_accepts_a_complete_sample_set(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = self.write(Path(directory) / "run.json", run_payload())
            result = self.run_script(str(path), "--validate")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("structure ok", result.stdout)

    def test_validate_rejects_a_truncated_sample_set(self) -> None:
        """What CI is really checking: that the harness still produced this."""
        payload = run_payload()
        payload["workloads"] = []
        with tempfile.TemporaryDirectory() as directory:
            path = self.write(Path(directory) / "run.json", payload)
            result = self.run_script(str(path), "--validate")
            self.assertEqual(result.returncode, 1)
            self.assertIn("no workloads", result.stderr)

    def test_validate_rejects_a_truncated_workload(self) -> None:
        """The check CI leans on: declared four launches, recorded two."""
        payload = run_payload(
            workload("empty", 0, [100.0] * 4),
            workload("small", 1000, [300.0] * 4),
            workload("large", 20000, [9000.0, 4000.0]),
        )
        with tempfile.TemporaryDirectory() as directory:
            path = self.write(Path(directory) / "run.json", payload)
            result = self.run_script(str(path), "--validate")
            self.assertEqual(result.returncode, 1)
            self.assertIn("recorded 2 launch(es)", result.stderr)

    def test_validate_rejects_a_run_that_only_warmed_up(self) -> None:
        payload = run_payload(
            workload("small", 1000, [9000.0]),
            iterations=1,
        )
        with tempfile.TemporaryDirectory() as directory:
            path = self.write(Path(directory) / "run.json", payload)
            result = self.run_script(str(path), "--validate")
            self.assertEqual(result.returncode, 1)
            self.assertIn("nothing was actually measured", result.stderr)

    def test_a_zero_warm_up_run_keeps_every_launch(self) -> None:
        payload = run_payload(
            workload("small", 1000, [300.0, 300.0, 300.0, 300.0], warmup=0),
            warmup=0,
        )
        with tempfile.TemporaryDirectory() as directory:
            path = self.write(Path(directory) / "run.json", payload)
            result = self.run_script(str(path), "--validate")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("4 judged", result.stdout)

    def test_validate_rejects_a_file_that_is_not_a_sample_set(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "run.json"
            path.write_text('{"hello": "world"}', encoding="utf-8")
            result = self.run_script(str(path), "--validate")
            self.assertEqual(result.returncode, 1)
            self.assertIn("schema", result.stderr)

    def test_an_expectation_needs_a_baseline(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = self.write(Path(directory) / "run.json", run_payload())
            result = self.run_script(str(path), "--expect", "same")
            self.assertEqual(result.returncode, 2)
            self.assertIn("needs --baseline", result.stderr)

    def test_expect_same_passes_on_a_repeat_of_the_baseline(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = self.write(Path(directory) / "base.json", run_payload())
            result = self.run_script(str(base), "--baseline", str(base), "--expect", "same")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("NO REGRESSION", result.stdout)

    def test_expect_same_fails_on_a_slowed_run(self) -> None:
        slowed = run_payload(
            workload("empty", 0, [9000.0, 400.0, 400.0, 400.0]),
            workload("small", 1000, [9000.0, 700.0, 700.0, 700.0]),
            workload("large", 20000, [9000.0, 4050.0, 4050.0, 4050.0]),
        )
        with tempfile.TemporaryDirectory() as directory:
            base = self.write(Path(directory) / "base.json", run_payload())
            after = self.write(Path(directory) / "after.json", slowed)
            result = self.run_script(str(after), "--baseline", str(base), "--expect", "same")
            self.assertEqual(result.returncode, 1)
            self.assertIn("expected same, got regressed", result.stderr)

    def test_expect_regressed_is_how_the_canary_proves_itself(self) -> None:
        """If this ever passes on an unchanged run, the check detects nothing."""
        slowed = run_payload(
            workload("empty", 0, [9000.0, 400.0, 400.0, 400.0]),
            workload("small", 1000, [9000.0, 700.0, 700.0, 700.0]),
            workload("large", 20000, [9000.0, 4050.0, 4050.0, 4050.0]),
            slow_catalog_ms=250,
        )
        with tempfile.TemporaryDirectory() as directory:
            base = self.write(Path(directory) / "base.json", run_payload())
            canary = self.write(Path(directory) / "canary.json", slowed)
            self.assertEqual(
                self.run_script(str(canary), "--baseline", str(base), "--expect", "regressed").returncode,
                0,
            )
            self.assertEqual(
                self.run_script(str(base), "--baseline", str(base), "--expect", "regressed").returncode,
                1,
            )

    def test_comparing_runs_that_measured_different_things_fails_loudly(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = self.write(Path(directory) / "base.json", run_payload())
            other = self.write(
                Path(directory) / "release.json", run_payload(build_mode="release")
            )
            result = self.run_script(str(other), "--baseline", str(base))
            self.assertEqual(result.returncode, 1)
            self.assertIn("not comparable", result.stderr)

    def test_validate_rejects_a_run_missing_a_required_workload(self) -> None:
        payload = run_payload(
            workload("empty", 0, [100.0] * 4),
            workload("small", 1000, [300.0] * 4),
        )
        with tempfile.TemporaryDirectory() as directory:
            path = self.write(Path(directory) / "run.json", payload)
            result = self.run_script(
                str(path), "--validate", "--require-workloads", "empty,small,large"
            )
            self.assertEqual(result.returncode, 1)
            self.assertIn("required workload 'large'", result.stderr)

    def test_require_workloads_needs_validate(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = self.write(Path(directory) / "run.json", run_payload())
            result = self.run_script(str(path), "--require-workloads", "empty")
            self.assertEqual(result.returncode, 2)

    def test_expect_regressed_everywhere_needs_every_workload(self) -> None:
        """What the canary is held to."""
        one_slow = run_payload(
            workload("empty", 0, [9000.0, 700.0, 700.0, 700.0]),
            workload("small", 1000, [9000.0, 300.0, 300.0, 300.0]),
            workload("large", 20000, [9000.0, 4000.0, 4000.0, 4000.0]),
        )
        all_slow = run_payload(
            workload("empty", 0, [9000.0, 700.0, 700.0, 700.0]),
            workload("small", 1000, [9000.0, 900.0, 900.0, 900.0]),
            workload("large", 20000, [9000.0, 9000.0, 9000.0, 9000.0]),
        )
        base = run_payload(
            workload("empty", 0, [9000.0, 100.0, 100.0, 100.0]),
            workload("small", 1000, [9000.0, 300.0, 300.0, 300.0]),
            workload("large", 20000, [9000.0, 4000.0, 4000.0, 4000.0]),
        )
        with tempfile.TemporaryDirectory() as directory:
            b = self.write(Path(directory) / "base.json", base)
            one = self.write(Path(directory) / "one.json", one_slow)
            every = self.write(Path(directory) / "every.json", all_slow)
            # The ordinary policy is happy with one, the canary's is not.
            self.assertEqual(
                self.run_script(
                    str(one), "--baseline", str(b), "--expect", "regressed"
                ).returncode,
                0,
            )
            partial = self.run_script(
                str(one), "--baseline", str(b), "--expect", "regressed-everywhere"
            )
            self.assertEqual(partial.returncode, 1)
            self.assertIn("regressed somewhere: empty", partial.stderr)
            self.assertEqual(
                self.run_script(
                    str(every),
                    "--baseline",
                    str(b),
                    "--expect",
                    "regressed-everywhere",
                ).returncode,
                0,
            )

    def test_comparing_across_pump_intervals_fails_loudly(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = self.write(Path(directory) / "base.json", run_payload())
            other = self.write(
                Path(directory) / "coarse.json", run_payload(pump_interval_ms=16)
            )
            result = self.run_script(str(other), "--baseline", str(base))
            self.assertEqual(result.returncode, 1)
            self.assertIn("not comparable", result.stderr)

    def test_it_reports_the_minimum_a_comparison_needs(self) -> None:
        """The runner asks for this instead of hardcoding it."""
        result = self.run_script("--minimum-samples")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            int(result.stdout.strip()), startup_report.MINIMUM_SAMPLES
        )

    def test_a_budget_miss_fails_the_run(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = self.write(Path(directory) / "run.json", run_payload())
            result = self.run_script(str(path), "--budget", "small=100")
            self.assertEqual(result.returncode, 1)
            self.assertIn("over the", result.stderr)

    def test_a_budget_that_is_met_passes(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = self.write(Path(directory) / "run.json", run_payload())
            result = self.run_script(str(path), "--budget", "small=5000")
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_expect_equivalent_is_two_sided(self) -> None:
        base = run_payload(workload("small", 1000, [9000.0, 300.0, 300.0, 300.0]))
        faster = run_payload(workload("small", 1000, [9000.0, 100.0, 100.0, 100.0]))
        with tempfile.TemporaryDirectory() as directory:
            b = self.write(Path(directory) / "base.json", base)
            f = self.write(Path(directory) / "fast.json", faster)
            # A real change that got faster is a pass.
            self.assertEqual(
                self.run_script(str(f), "--baseline", str(b), "--expect", "same").returncode,
                0,
            )
            # The same numbers from an identical re-run are not.
            result = self.run_script(
                str(f), "--baseline", str(b), "--expect", "equivalent"
            )
            self.assertEqual(result.returncode, 1)
            self.assertIn("moved on small", result.stderr)

    def test_a_budget_that_could_never_fail_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = self.write(Path(directory) / "run.json", run_payload())
            for value in ("nan", "inf", "-1"):
                result = self.run_script(str(path), "--budget", f"small={value}")
                self.assertEqual(result.returncode, 2, value)

    def test_a_malformed_budget_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = self.write(Path(directory) / "run.json", run_payload())
            result = self.run_script(str(path), "--budget", "small")
            self.assertEqual(result.returncode, 2)


if __name__ == "__main__":
    unittest.main(verbosity=2)
