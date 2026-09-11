#!/usr/bin/env python3
"""Unit tests for tools/large_library/memory_report.py.

The analyser is the part of the memory check that makes a judgement, so it is
the part that has to be tested on series whose answer is known. Nothing here
needs a database, a Flutter toolchain or a real measurement: it feeds the
analyser synthetic series and checks the verdict, including the two ways a
verdict can be wrong.

    python3 test/tooling/large_library_memory_report_test.py
"""

from __future__ import annotations

import json
import random
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools" / "large_library"))

import memory_report  # noqa: E402

MIB = memory_report.MIB


def series(values_mib: list[float]) -> list[memory_report.Sample]:
    """Turns a list of MiB readings into the cycle samples the analyser takes."""
    return [
        memory_report.Sample(
            name="cycle",
            rss_bytes=int(value * MIB),
            elapsed_ms=index * 1000,
            cycle=index,
        )
        for index, value in enumerate(values_mib)
    ]


def flat(count: int, *, base: float = 400.0, jitter: float = 0.0) -> list[float]:
    """A settled series: a fixed working set with optional symmetric jitter."""
    rng = random.Random(1234)
    return [base + rng.uniform(-jitter, jitter) for _ in range(count)]


def leaking(count: int, *, base: float = 400.0, per_cycle: float = 2.0) -> list[float]:
    return [base + per_cycle * index for index in range(count)]


class SlopeTest(unittest.TestCase):
    def test_flat_series_has_no_slope(self) -> None:
        self.assertAlmostEqual(memory_report.slope([5.0] * 8), 0.0)

    def test_a_straight_line_reports_its_step(self) -> None:
        self.assertAlmostEqual(memory_report.slope([0.0, 3.0, 6.0, 9.0]), 3.0)

    def test_one_sample_cannot_have_a_slope(self) -> None:
        self.assertEqual(memory_report.slope([1.0]), 0.0)


class SettlingTest(unittest.TestCase):
    def test_a_flat_series_settles(self) -> None:
        trend = memory_report.analyse(series(flat(12)), warmup=3)
        self.assertTrue(trend.settled)

    def test_warm_up_growth_does_not_count_against_it(self) -> None:
        # Exactly the healthy shape: caches fill for three cycles, then flat.
        values = [300.0, 360.0, 395.0] + flat(9)
        trend = memory_report.analyse(series(values), warmup=3)
        self.assertTrue(trend.settled)

    def test_jitter_within_the_noise_band_still_settles(self) -> None:
        trend = memory_report.analyse(series(flat(14, jitter=0.4)), warmup=3)
        self.assertTrue(trend.settled)

    def test_a_leak_is_caught(self) -> None:
        trend = memory_report.analyse(series(leaking(14)), warmup=3)
        self.assertFalse(trend.settled)
        self.assertGreater(trend.slope_bytes_per_cycle, 1.5 * MIB)

    def test_a_small_but_relentless_leak_is_caught(self) -> None:
        # The interesting case: 0.8 MiB per cycle is invisible in a total and
        # would be missed by anything watching a single high-water mark.
        trend = memory_report.analyse(series(leaking(16, per_cycle=0.8)), warmup=3)
        self.assertFalse(trend.settled)

    def test_a_leak_hidden_under_jitter_is_still_caught(self) -> None:
        rng = random.Random(7)
        values = [400.0 + 1.5 * i + rng.uniform(-0.5, 0.5) for i in range(16)]
        trend = memory_report.analyse(series(values), warmup=3)
        self.assertFalse(trend.settled)

    def test_a_one_off_step_is_not_a_leak(self) -> None:
        # A cache that filled late, or a route that allocated once. It moves the
        # line up and then stops, which is not what a leak looks like, and it is
        # exactly what a mean-of-halves or a least-squares slope gets wrong: a
        # 25 MiB step in the middle of the window tilts both. The median delta
        # sees one large jump among zeros and ignores it.
        values = flat(6) + [flat(1)[0] + 25.0] * 8
        trend = memory_report.analyse(series(values), warmup=3)
        self.assertTrue(trend.settled)
        self.assertGreater(
            trend.slope_bytes_per_cycle,
            trend.noise_bytes_per_cycle,
            "the slope alone would have called this a leak",
        )

    def test_an_intermittent_leak_is_still_caught(self) -> None:
        # Retains on every other navigation. The median delta can sit at zero
        # here, so the second clause (a real slope plus most cycles rising) is
        # what catches it.
        values = [400.0]
        for index in range(15):
            values.append(values[-1] + (3.0 if index % 2 == 0 else 0.0))
        trend = memory_report.analyse(series(values), warmup=3)
        self.assertFalse(trend.settled)

    def test_a_falling_series_settles(self) -> None:
        # Unusual (RSS rarely comes back down) but definitely not a leak.
        values = [430.0 - 2.0 * i for i in range(12)]
        trend = memory_report.analyse(series(values), warmup=3)
        self.assertTrue(trend.settled)

    def test_too_short_to_judge_is_reported_as_unsettled(self) -> None:
        # A truncated run must never read as a clean bill of health.
        trend = memory_report.analyse(series(flat(5)), warmup=3)
        self.assertEqual(trend.considered, 2)
        self.assertFalse(trend.settled)

    def test_no_cycles_at_all(self) -> None:
        trend = memory_report.analyse([], warmup=3)
        self.assertEqual(trend.considered, 0)
        self.assertFalse(trend.settled)

    def test_the_noise_band_is_adjustable(self) -> None:
        samples = series(leaking(14, per_cycle=0.8))
        self.assertFalse(memory_report.analyse(samples, warmup=3).settled)
        self.assertTrue(
            memory_report.analyse(
                samples, warmup=3, noise_mib_per_cycle=5.0
            ).settled
        )


class ComparisonTest(unittest.TestCase):
    """The check that is actually worth gating on: this run against a baseline.

    A headless Dart VM under sustained allocation drifts upward even with
    nothing wrong, because nothing forces a major collection. That drift is in
    both sides of a comparison at roughly the same rate, so it subtracts out,
    which is exactly why the comparison works where an absolute "is it flat"
    test cannot.
    """

    def trend(self, values: list[float]) -> memory_report.Trend:
        return memory_report.analyse(series(values), warmup=3)

    def test_two_runs_of_the_same_thing_agree(self) -> None:
        # Both drift at the runtime's own rate. Neither is a regression.
        drift_a = [400.0 + 2.5 * i for i in range(16)]
        drift_b = [412.0 + 2.9 * i for i in range(16)]
        result = memory_report.compare(self.trend(drift_a), self.trend(drift_b))
        self.assertFalse(result.regressed)

    def test_a_leak_on_top_of_that_drift_is_caught(self) -> None:
        drift = [400.0 + 2.5 * i for i in range(16)]
        leaked = [400.0 + 4.5 * i for i in range(16)]
        result = memory_report.compare(self.trend(drift), self.trend(leaked))
        self.assertTrue(result.regressed)
        self.assertGreater(result.extra_bytes_per_cycle, 1.5 * MIB)

    def test_a_run_that_grows_less_is_not_a_regression(self) -> None:
        drift = [400.0 + 3.0 * i for i in range(16)]
        better = [400.0 + 0.5 * i for i in range(16)]
        result = memory_report.compare(self.trend(drift), self.trend(better))
        self.assertFalse(result.regressed)
        self.assertLess(result.extra_bytes_per_cycle, 0)

    def test_a_truncated_run_is_never_a_pass(self) -> None:
        full = [400.0 + 2.0 * i for i in range(16)]
        self.assertTrue(
            memory_report.compare(self.trend(full), self.trend(flat(4))).regressed
        )
        self.assertTrue(
            memory_report.compare(self.trend(flat(4)), self.trend(full)).regressed
        )

    def test_the_comparison_band_is_adjustable(self) -> None:
        drift = [400.0 + 2.0 * i for i in range(16)]
        leaked = [400.0 + 3.5 * i for i in range(16)]
        self.assertTrue(
            memory_report.compare(self.trend(drift), self.trend(leaked)).regressed
        )
        self.assertFalse(
            memory_report.compare(
                self.trend(drift),
                self.trend(leaked),
                noise_mib_per_cycle=5.0,
            ).regressed
        )

    def test_the_comparison_is_rendered(self) -> None:
        drift = [400.0 + 2.0 * i for i in range(16)]
        leaked = [400.0 + 6.0 * i for i in range(16)]
        text = memory_report.render_comparison(
            memory_report.compare(self.trend(drift), self.trend(leaked))
        )
        self.assertIn("extra per cycle", text)
        self.assertIn("REGRESSION", text)


class ReportTest(unittest.TestCase):
    def payload(self, values: list[float], scenario: str = "clean") -> dict:
        return {
            "scenario": scenario,
            "library": {"tracks": 12000},
            "cycles_run": len(values),
            "phases": [
                {"name": "baseline", "rss_bytes": 200 * MIB, "elapsed_ms": 0},
                {"name": "startup", "rss_bytes": 280 * MIB, "elapsed_ms": 1800},
            ],
            "cycle_samples": [
                {
                    "name": "cycle",
                    "rss_bytes": int(value * MIB),
                    "elapsed_ms": index * 1000,
                    "cycle": index,
                }
                for index, value in enumerate(values)
            ],
        }

    def test_the_report_names_the_phases_and_the_verdict(self) -> None:
        payload = self.payload(flat(12))
        trend = memory_report.analyse(
            memory_report.samples_of(payload, "cycle_samples"), warmup=3
        )
        text = memory_report.render(payload, trend, 3)

        self.assertIn("baseline", text)
        self.assertIn("startup", text)
        self.assertIn("cycle 0 (warm-up)", text)
        self.assertIn("cycle 11", text)
        self.assertNotIn("cycle 11 (warm-up)", text)
        self.assertIn("SETTLED", text)
        self.assertIn("12,000", text)

    def test_a_growing_report_says_so(self) -> None:
        payload = self.payload(leaking(12), scenario="leak")
        trend = memory_report.analyse(
            memory_report.samples_of(payload, "cycle_samples"), warmup=3
        )
        text = memory_report.render(payload, trend, 3)

        self.assertIn("STILL GROWING", text)
        self.assertIn("scenario: leak", text)


class CommandLineTest(unittest.TestCase):
    script = ROOT / "tools" / "large_library" / "memory_report.py"

    @staticmethod
    def write(path: Path, values: list[float]) -> Path:
        path.write_text(
            json.dumps(
                {
                    "scenario": "clean",
                    "library": {"tracks": 100},
                    "phases": [],
                    "cycle_samples": [
                        {
                            "name": "cycle",
                            "rss_bytes": int(value * MIB),
                            "elapsed_ms": 0,
                            "cycle": index,
                        }
                        for index, value in enumerate(values)
                    ],
                }
            ),
            encoding="utf-8",
        )
        return path

    def run_on(self, values: list[float], *args: str) -> subprocess.CompletedProcess:
        with tempfile.TemporaryDirectory() as directory:
            path = self.write(Path(directory) / "samples.json", values)
            return subprocess.run(
                [sys.executable, str(self.script), str(path), *args],
                capture_output=True,
                text=True,
                check=False,
            )

    def test_it_exits_zero_without_an_expectation(self) -> None:
        self.assertEqual(self.run_on(leaking(12)).returncode, 0)

    def test_expect_settled_passes_on_a_flat_series(self) -> None:
        result = self.run_on(flat(12), "--expect", "settled")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_expect_settled_fails_on_a_leak(self) -> None:
        result = self.run_on(leaking(12), "--expect", "settled")
        self.assertEqual(result.returncode, 1)
        self.assertIn("expected settled, got growing", result.stderr)

    def test_expect_growing_is_how_the_canary_proves_itself(self) -> None:
        # If this ever passes on a clean series, the check has stopped
        # detecting anything and every green run since means nothing.
        self.assertEqual(self.run_on(leaking(12), "--expect", "growing").returncode, 0)
        self.assertEqual(self.run_on(flat(12), "--expect", "growing").returncode, 1)

    def test_a_baseline_expectation_needs_a_baseline(self) -> None:
        result = self.run_on(flat(12), "--expect", "same")
        self.assertEqual(result.returncode, 2)
        self.assertIn("needs --baseline", result.stderr)

    def test_comparing_against_a_baseline_file(self) -> None:
        drift = [400.0 + 2.0 * i for i in range(16)]
        leaked = [400.0 + 6.0 * i for i in range(16)]
        with tempfile.TemporaryDirectory() as directory:
            base = self.write(Path(directory) / "base.json", drift)
            self.assertEqual(
                self.run_on(drift, "--baseline", str(base), "--expect", "same")
                .returncode,
                0,
            )
            result = self.run_on(
                leaked, "--baseline", str(base), "--expect", "same"
            )
            self.assertEqual(result.returncode, 1)
            self.assertIn("expected same, got regressed", result.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
