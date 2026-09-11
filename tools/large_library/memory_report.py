#!/usr/bin/env python3
"""Read a large-library memory sample series and say whether it settles.

The companion to test/benchmarks/large_library_memory_bench.dart, which drives
the real Library UI over a large synthetic catalog and records the process's
resident set size at labelled points. This turns that series into a report, and
into a verdict.

The verdict is deliberately *not* "RSS is under N MiB". That number is not
comparable between two machines, two kernels or two Flutter versions, so a
threshold set on one developer's laptop is either meaningless or permanently
red on someone else's.

Nor is it "the line is flat". Measuring showed why: in a headless Dart VM under
sustained allocation the line is not flat even with nothing wrong, because
nothing forces a major collection and the heap high-water mark ratchets up. A
clean run of this harness drifts a few MiB per navigation cycle on its own. A
check that demanded flatness would need a noise band wide enough to swallow a
real leak, which is the same as having no check.

So the primary question is comparative: **does this run grow faster than a
baseline run of the same harness on the same machine?** Growth *rate* is the
thing that survives the comparison; the runtime's own drift appears in both
sides and cancels. Point it at a recorded clean run with ``--baseline`` and it
answers that. Without one it still reports the series and its trend, which is
what you want when you are reading rather than gating.
"""

from __future__ import annotations

import argparse
import json
import sys
from dataclasses import dataclass
from pathlib import Path

MIB = 1024 * 1024

# Cycles to ignore before judging the trend.
#
# The first passes through a library are not steady state, and nothing about
# them is a leak: Flutter's image cache is filling with covers, the glyph atlas
# is filling with the text of rows nobody has scrolled past yet, the Dart heap
# is growing to its working size, and the VM is still compiling. Every one of
# those rises once and then stops. Judging the trend from cycle zero would call
# all of it a leak.
DEFAULT_WARMUP = 3

# How much growth per cycle counts as noise rather than a leak, in MiB.
#
# Deliberately a *rate*, because a rate travels between machines in a way a
# total does not. RSS is also a high-water mark on every platform Linthra
# targets: freed pages usually stay mapped, glibc's malloc keeps its arenas, and
# the Dart heap does not hand pages back promptly. That means the healthy signal
# is "flat", never "falling", and a small positive drift is normal. Half a
# mebibyte per navigation cycle is comfortably above that drift and well below
# anything a real retained-object regression produces, since retaining anything
# per navigation of a large library means holding rows, images or route state,
# which is megabytes.
DEFAULT_NOISE_MIB_PER_CYCLE = 0.5

# How much faster than the baseline a run may grow before it counts as a
# regression, in MiB per navigation cycle.
#
# Set from measurement, not taste. Two clean runs of this harness on the same
# machine differ in their median cycle delta by well under a mebibyte, because
# the drift they share cancels; the deliberate 2 MiB/cycle leak the canary
# injects shows up as several. One mebibyte sits between the two with room on
# both sides.
DEFAULT_COMPARISON_NOISE_MIB_PER_CYCLE = 1.0


@dataclass(frozen=True)
class Sample:
    name: str
    rss_bytes: int
    elapsed_ms: int
    cycle: int | None = None


@dataclass(frozen=True)
class Trend:
    """What the repeated navigation cycles did after warm-up."""

    considered: int
    median_delta_bytes: float
    rising_fraction: float
    slope_bytes_per_cycle: float
    growth_bytes: float
    noise_bytes_per_cycle: float

    @property
    def settled(self) -> bool:
        """Whether the series stopped climbing.

        The signal is the **median cycle-to-cycle delta**, not the total and not
        the slope. That choice is the whole reason this can tell a leak from the
        ordinary lumpiness of a running process: a leak adds memory on *every*
        cycle, so its deltas are all positive and the median is the leak rate;
        a one-off step (a cache that filled a cycle later than expected, a route
        that allocated once) is a single large delta among zeros, and a median
        ignores it the way a mean or a least-squares slope cannot.

        A second clause catches a leak that only fires on some cycles, where the
        median can sit at zero: a positive slope *and* most cycles rising. On a
        one-off step only one cycle rises, so it stays settled; on jitter the
        slope is flat, so it stays settled too.
        """
        if self.considered < 4:
            # Too short to say anything. Reported as unsettled so a truncated
            # run is never mistaken for a clean bill of health.
            return False
        if self.median_delta_bytes > self.noise_bytes_per_cycle:
            return False
        intermittent = (
            self.slope_bytes_per_cycle > self.noise_bytes_per_cycle
            and self.rising_fraction >= 0.5
        )
        return not intermittent


def median(values: list[float]) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    middle = len(ordered) // 2
    if len(ordered) % 2:
        return ordered[middle]
    return (ordered[middle - 1] + ordered[middle]) / 2


def _mib(value: float) -> str:
    return f"{value / MIB:9.1f}"


def load(path: Path) -> dict[str, object]:
    with path.open(encoding="utf-8") as handle:
        return json.load(handle)


def samples_of(payload: dict[str, object], key: str) -> list[Sample]:
    raw = payload.get(key) or []
    if not isinstance(raw, list):
        raise ValueError(f"{key} is not a list")
    return [
        Sample(
            name=str(entry["name"]),
            rss_bytes=int(entry["rss_bytes"]),
            elapsed_ms=int(entry["elapsed_ms"]),
            cycle=None if entry.get("cycle") is None else int(entry["cycle"]),
        )
        for entry in raw
    ]


def slope(values: list[float]) -> float:
    """Least-squares slope of ``values`` against their index."""
    count = len(values)
    if count < 2:
        return 0.0
    mean_x = (count - 1) / 2
    mean_y = sum(values) / count
    numerator = sum((i - mean_x) * (y - mean_y) for i, y in enumerate(values))
    denominator = sum((i - mean_x) ** 2 for i in range(count))
    return 0.0 if denominator == 0 else numerator / denominator


def analyse(
    cycles: list[Sample],
    *,
    warmup: int = DEFAULT_WARMUP,
    noise_mib_per_cycle: float = DEFAULT_NOISE_MIB_PER_CYCLE,
) -> Trend:
    considered = [float(sample.rss_bytes) for sample in cycles[warmup:]]
    noise = noise_mib_per_cycle * MIB
    if len(considered) < 2:
        return Trend(len(considered), 0.0, 0.0, 0.0, 0.0, noise)
    deltas = [
        second - first
        for first, second in zip(considered, considered[1:], strict=False)
    ]
    rising = sum(1 for delta in deltas if delta > noise)
    return Trend(
        considered=len(considered),
        median_delta_bytes=median(deltas),
        rising_fraction=rising / len(deltas),
        slope_bytes_per_cycle=slope(considered),
        growth_bytes=considered[-1] - considered[0],
        noise_bytes_per_cycle=noise,
    )


@dataclass(frozen=True)
class Comparison:
    """One run measured against a baseline run of the same harness."""

    baseline: Trend
    candidate: Trend
    noise_bytes_per_cycle: float

    @property
    def extra_bytes_per_cycle(self) -> float:
        """How much faster the candidate grows, per navigation cycle."""
        return self.candidate.median_delta_bytes - self.baseline.median_delta_bytes

    @property
    def regressed(self) -> bool:
        """Whether the candidate retains meaningfully more than the baseline.

        Compared on the median cycle-to-cycle delta, for the reason
        [Trend.settled] explains, and only on the *difference*: the Dart VM's
        own heap drift, the image cache filling, the glyph atlas, glibc's
        arenas are all present in both runs at roughly the same rate, so they
        subtract out. What is left is what this run holds on to and the
        baseline did not.
        """
        if self.baseline.considered < 4 or self.candidate.considered < 4:
            # Not enough of either to say. Reported as a regression so a
            # truncated run is never mistaken for a clean bill of health.
            return True
        return self.extra_bytes_per_cycle > self.noise_bytes_per_cycle


def compare(
    baseline: Trend,
    candidate: Trend,
    *,
    noise_mib_per_cycle: float = DEFAULT_COMPARISON_NOISE_MIB_PER_CYCLE,
) -> Comparison:
    return Comparison(
        baseline=baseline,
        candidate=candidate,
        noise_bytes_per_cycle=noise_mib_per_cycle * MIB,
    )


def render_comparison(comparison: Comparison) -> str:
    return "\n".join(
        [
            "",
            "against the baseline",
            f"  baseline median delta:    {_mib(comparison.baseline.median_delta_bytes)}"
            " MiB/cycle",
            f"  this run median delta:    {_mib(comparison.candidate.median_delta_bytes)}"
            " MiB/cycle",
            f"  extra per cycle:          {_mib(comparison.extra_bytes_per_cycle)}"
            " MiB/cycle",
            f"  noise allowance:          {_mib(comparison.noise_bytes_per_cycle)}"
            " MiB/cycle",
            "  verdict:                  "
            f"{'REGRESSION' if comparison.regressed else 'NO REGRESSION'}",
        ]
    )


def render(payload: dict[str, object], trend: Trend, warmup: int) -> str:
    lines: list[str] = []
    library = payload.get("library")
    tracks = library.get("tracks") if isinstance(library, dict) else "?"
    scenario = payload.get("scenario", "?")

    lines.append(f"large-library memory profile  (scenario: {scenario})")
    if isinstance(tracks, int):
        lines.append(f"  synthetic tracks: {tracks:,}")
    lines.append("")
    lines.append("phase                          RSS MiB      delta")

    previous: int | None = None
    for sample in samples_of(payload, "phases"):
        delta = (
            "" if previous is None else f"{(sample.rss_bytes - previous) / MIB:+9.1f}"
        )
        lines.append(f"  {sample.name:<28}{_mib(sample.rss_bytes)}  {delta}")
        previous = sample.rss_bytes

    cycles = samples_of(payload, "cycle_samples")
    if cycles:
        lines.append("")
        lines.append("repeated navigation cycles     RSS MiB      delta")
        previous = None
        for sample in cycles:
            marker = " (warm-up)" if (sample.cycle or 0) < warmup else ""
            delta = (
                ""
                if previous is None
                else f"{(sample.rss_bytes - previous) / MIB:+9.1f}"
            )
            label = f"cycle {sample.cycle}{marker}"
            lines.append(f"  {label:<28}{_mib(sample.rss_bytes)}  {delta}")
            previous = sample.rss_bytes

    lines.append("")
    lines.append("trend after warm-up")
    lines.append(f"  cycles considered:        {trend.considered:9d}")
    lines.append(
        f"  slope:                    {_mib(trend.slope_bytes_per_cycle)} MiB/cycle"
    )
    lines.append(f"  total growth:             {_mib(trend.growth_bytes)} MiB")
    lines.append(
        f"  noise allowance:          {_mib(trend.noise_bytes_per_cycle)} MiB/cycle"
    )
    lines.append(
        f"  verdict:                  {'SETTLED' if trend.settled else 'STILL GROWING'}"
    )
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("samples", type=Path, help="JSON written by the Dart harness")
    parser.add_argument(
        "--warmup",
        type=int,
        default=DEFAULT_WARMUP,
        help="navigation cycles to ignore before judging the trend",
    )
    parser.add_argument(
        "--noise-mib-per-cycle",
        type=float,
        default=DEFAULT_NOISE_MIB_PER_CYCLE,
        help="growth per cycle treated as noise rather than a leak",
    )
    parser.add_argument(
        "--baseline",
        type=Path,
        help=(
            "a recorded clean run of the same harness on this machine. Turns the "
            "report into a comparison, which is the check worth gating on"
        ),
    )
    parser.add_argument(
        "--comparison-noise-mib-per-cycle",
        type=float,
        default=DEFAULT_COMPARISON_NOISE_MIB_PER_CYCLE,
        help="how much faster than the baseline is still noise",
    )
    parser.add_argument(
        "--expect",
        choices=("settled", "growing", "same", "regressed"),
        help=(
            "fail unless the verdict matches. 'same'/'regressed' judge the "
            "comparison and need --baseline; 'settled'/'growing' judge this run "
            "alone and are only meaningful with a noise band measured on this "
            "machine"
        ),
    )
    args = parser.parse_args()

    if args.warmup < 0:
        parser.error("--warmup must not be negative")
    if args.expect in ("same", "regressed") and args.baseline is None:
        parser.error(f"--expect {args.expect} needs --baseline")

    payload = load(args.samples)
    trend = analyse(
        samples_of(payload, "cycle_samples"),
        warmup=args.warmup,
        noise_mib_per_cycle=args.noise_mib_per_cycle,
    )
    print(render(payload, trend, args.warmup))

    comparison: Comparison | None = None
    if args.baseline is not None:
        baseline = analyse(
            samples_of(load(args.baseline), "cycle_samples"),
            warmup=args.warmup,
            noise_mib_per_cycle=args.noise_mib_per_cycle,
        )
        comparison = compare(
            baseline,
            trend,
            noise_mib_per_cycle=args.comparison_noise_mib_per_cycle,
        )
        print(render_comparison(comparison))

    if args.expect is None:
        return 0
    if args.expect in ("same", "regressed"):
        assert comparison is not None
        actual = "regressed" if comparison.regressed else "same"
    else:
        actual = "settled" if trend.settled else "growing"
    if actual == args.expect:
        return 0
    print(f"\nERROR: expected {args.expect}, got {actual}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
