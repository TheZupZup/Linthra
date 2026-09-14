#!/usr/bin/env python3
"""Read a startup sample set and say what it measured, then what changed.

The companion to test/benchmarks/startup_time_bench.dart, which launches the
real app over empty, small and large synthetic catalogs and records how long
each launch took to reach its first *usable* frame. This turns those samples
into a report, and, given a second run to compare against, into a verdict.

The verdict is deliberately not "startup is under N milliseconds". That number
belongs to one machine, one build mode and one moment: a laptop on battery, a
shared CI runner and a desktop with an NVMe disk do not agree about it even
when nothing has changed, and a threshold picked on one of them is either
meaningless or permanently red on the rest. #462 asks for a check that survives
being run by somebody else, so the primary question is comparative:

    **does this run reach a usable library slower than a baseline run of the
    same workload, on the same machine, in the same build mode?**

What travels between machines is the ratio, not the millisecond count, so that
is what is compared. Everything that makes one machine faster than another -
CPU, disk, whether the Dart VM has JIT-compiled the widget tree yet - is in both
sides of the comparison and divides out; what is left is the change.

Without a baseline it still reports the series, which is what you want when you
are reading rather than gating. And with ``--validate`` it checks only that the
harness produced a well-formed, complete sample set, which is the part CI can
honestly enforce.
"""

from __future__ import annotations

import argparse
import json
import sys
from dataclasses import dataclass
from pathlib import Path

SCHEMA = "linthra.startup.v1"

# Launches to ignore before judging, when the samples do not say.
#
# The first launch in a process is not a startup measurement, it is a
# measurement of the Dart VM compiling the widget tree it has never run before.
# On a JIT run that first launch is routinely several times the ones after it,
# and averaging it in would drown the thing being measured. The harness records
# a `warmup` flag per sample; this is only the fallback for a file that has
# none.
DEFAULT_WARMUP = 1

# The smallest number of judged launches a comparison is willing to trust.
#
# A median of two is a mean of two, and a mean of two on a timing measurement is
# a coin toss. Below this the comparison reports a regression rather than a
# pass, for the same reason the memory analyser does: a truncated run must never
# read as a clean bill of health.
MINIMUM_SAMPLES = 3

# How much slower than the baseline still counts as noise.
#
# Two clauses, and a run has to fail both to be called a regression:
#
#   * relative, because timing noise scales with the number being measured.
#     A machine that is 10% jittery is 10% jittery at 40 ms and at 4,000 ms.
#   * absolute, because a ratio on a small number is mostly rounding. The empty
#     workload finishes in tens of milliseconds, where a single scheduling
#     hiccup is a large percentage and no kind of regression.
#
# Both defaults come from measuring (see tools/startup/README.md): repeated
# clean runs of the same harness on one machine land inside them, and the
# canary's injected delay lands well outside.
DEFAULT_RELATIVE_ALLOWANCE = 0.30
DEFAULT_ABSOLUTE_ALLOWANCE_MS = 25.0

# Spread at which the run is called too noisy to read.
#
# (max - min) / median over the judged launches. This is reported, not enforced:
# it is the number that tells you whether to believe the rest of the report, and
# a machine that is compiling, indexing or syncing in the background will say so
# here before it says anything misleading anywhere else.
NOISY_SPREAD = 0.5


class InvalidReport(ValueError):
    """The sample file is not something this reporter can read."""


@dataclass(frozen=True)
class Sample:
    """One launch."""

    iteration: int
    warmup: bool
    first_frame_ms: float
    first_usable_frame_ms: float
    frames: int
    rows_rendered: int


@dataclass(frozen=True)
class Workload:
    """One library size, and every launch measured against it."""

    name: str
    tracks: int
    albums: int
    fixture_build_ms: float
    fixture_bytes: int
    usable_signal: str
    samples: tuple[Sample, ...]

    def judged(self, warmup: int) -> tuple[Sample, ...]:
        """The launches a verdict may use.

        The harness marks its own warm-up launches, and when it has, that is
        the authority: it is the thing that knows how many it ran and in what
        order. ``warmup`` is the fallback for a file that carries no flags at
        all, which is the only case where this has to guess.
        """
        if any(sample.warmup for sample in self.samples):
            return tuple(s for s in self.samples if not s.warmup)
        return self.samples[warmup:]


@dataclass(frozen=True)
class Run:
    """One invocation of the harness: its context, and every workload it ran."""

    label: str
    milestone: str
    build_mode: str
    runtime: str
    dart_version: str
    operating_system: str
    cpu_cores: int
    iterations: int
    warmup: int
    window: tuple[float, float, float]
    slow_catalog_ms: int
    network_sources: int
    workloads: tuple[Workload, ...]

    def workload(self, name: str) -> Workload | None:
        for workload in self.workloads:
            if workload.name == name:
                return workload
        return None


@dataclass(frozen=True)
class Stats:
    """What the judged launches of one workload came to."""

    count: int
    median_ms: float
    min_ms: float
    max_ms: float
    first_frame_median_ms: float

    @property
    def spread(self) -> float:
        """(max - min) / median: how much this machine disagreed with itself."""
        if self.median_ms <= 0:
            return 0.0
        return (self.max_ms - self.min_ms) / self.median_ms

    @property
    def noisy(self) -> bool:
        return self.spread > NOISY_SPREAD

    @property
    def trustworthy(self) -> bool:
        return self.count >= MINIMUM_SAMPLES


def median(values: list[float]) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    middle = len(ordered) // 2
    if len(ordered) % 2:
        return ordered[middle]
    return (ordered[middle - 1] + ordered[middle]) / 2


def _require(payload: dict[str, object], key: str) -> object:
    if key not in payload:
        raise InvalidReport(f"missing {key!r}")
    return payload[key]


def _number(payload: dict[str, object], key: str) -> float:
    value = _require(payload, key)
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise InvalidReport(f"{key!r} is not a number: {value!r}")
    return float(value)


def parse_sample(payload: dict[str, object]) -> Sample:
    first_frame = _number(payload, "first_frame_ms")
    usable = _number(payload, "first_usable_frame_ms")
    if first_frame < 0 or usable < 0:
        raise InvalidReport("a milestone cannot be negative")
    if usable < first_frame:
        # The first usable frame is by definition not before the first frame.
        # A file that says otherwise was not produced by a working harness, and
        # every number in it is suspect.
        raise InvalidReport(
            "first_usable_frame_ms ({:.3f}) precedes first_frame_ms ({:.3f})".format(
                usable, first_frame
            )
        )
    return Sample(
        iteration=int(_number(payload, "iteration")),
        warmup=bool(payload.get("warmup", False)),
        first_frame_ms=first_frame,
        first_usable_frame_ms=usable,
        frames=int(_number(payload, "frames")),
        rows_rendered=int(_number(payload, "rows_rendered")),
    )


def parse_workload(payload: dict[str, object]) -> Workload:
    name = str(_require(payload, "name"))
    raw = _require(payload, "samples")
    if not isinstance(raw, list) or not raw:
        raise InvalidReport(f"workload {name!r} recorded no launches")
    tracks = int(_number(payload, "tracks"))
    rendered = [parse_sample(entry) for entry in raw]
    # A workload with tracks that never painted a row did not reach the
    # milestone it claims to have measured, whatever its timings say.
    if tracks > 0 and all(sample.rows_rendered == 0 for sample in rendered):
        raise InvalidReport(
            f"workload {name!r} has {tracks} tracks but painted no rows"
        )
    return Workload(
        name=name,
        tracks=tracks,
        albums=int(_number(payload, "albums")),
        fixture_build_ms=_number(payload, "fixture_build_ms"),
        fixture_bytes=int(_number(payload, "fixture_bytes")),
        usable_signal=str(payload.get("usable_signal", "")),
        samples=tuple(rendered),
    )


def parse(payload: object) -> Run:
    """Turns the harness's JSON into a [Run], or says exactly what is wrong."""
    if not isinstance(payload, dict):
        raise InvalidReport("the sample file is not a JSON object")
    schema = payload.get("schema")
    if schema != SCHEMA:
        raise InvalidReport(f"expected schema {SCHEMA!r}, found {schema!r}")
    workloads = _require(payload, "workloads")
    if not isinstance(workloads, list) or not workloads:
        raise InvalidReport("no workloads were recorded")
    window = payload.get("window")
    if not isinstance(window, dict):
        raise InvalidReport("missing window")
    names = [str(entry.get("name")) for entry in workloads]
    if len(set(names)) != len(names):
        raise InvalidReport(f"a workload is recorded twice: {sorted(names)}")
    return Run(
        label=str(payload.get("label", "run")),
        milestone=str(_require(payload, "milestone")),
        build_mode=str(_require(payload, "build_mode")),
        runtime=str(payload.get("runtime", "unknown")),
        dart_version=str(payload.get("dart_version", "unknown")),
        operating_system=str(payload.get("operating_system", "unknown")),
        cpu_cores=int(_number(payload, "cpu_cores")),
        iterations=int(_number(payload, "iterations")),
        warmup=int(_number(payload, "warmup")),
        window=(
            _number(window, "width"),
            _number(window, "height"),
            _number(window, "device_pixel_ratio"),
        ),
        slow_catalog_ms=int(payload.get("slow_catalog_ms", 0) or 0),
        network_sources=int(payload.get("network_sources", 0) or 0),
        workloads=tuple(parse_workload(entry) for entry in workloads),
    )


def load(path: Path) -> Run:
    with path.open(encoding="utf-8") as handle:
        return parse(json.load(handle))


def summarise(workload: Workload, warmup: int) -> Stats:
    judged = workload.judged(warmup)
    usable = [sample.first_usable_frame_ms for sample in judged]
    first = [sample.first_frame_ms for sample in judged]
    return Stats(
        count=len(judged),
        median_ms=median(usable),
        min_ms=min(usable) if usable else 0.0,
        max_ms=max(usable) if usable else 0.0,
        first_frame_median_ms=median(first),
    )


@dataclass(frozen=True)
class WorkloadComparison:
    """One workload, measured against the same workload in a baseline run."""

    name: str
    baseline: Stats
    candidate: Stats
    relative_allowance: float
    absolute_allowance_ms: float

    @property
    def delta_ms(self) -> float:
        return self.candidate.median_ms - self.baseline.median_ms

    @property
    def ratio(self) -> float:
        if self.baseline.median_ms <= 0:
            return 0.0
        return self.candidate.median_ms / self.baseline.median_ms

    @property
    def regressed(self) -> bool:
        """Whether this workload now reaches a usable library later.

        Both allowances have to be exceeded. A run that is 40% slower but only
        3 ms slower is a scheduling hiccup on a small number; one that is 200 ms
        slower but 5% slower is the large workload behaving normally.
        """
        if not (self.baseline.trustworthy and self.candidate.trustworthy):
            # Not enough launches on one side to have an opinion. Reported as a
            # regression so a truncated run is never mistaken for a pass.
            return True
        if self.delta_ms <= self.absolute_allowance_ms:
            return False
        return self.ratio > 1.0 + self.relative_allowance


@dataclass(frozen=True)
class Comparison:
    baseline: Run
    candidate: Run
    workloads: tuple[WorkloadComparison, ...]

    @property
    def regressed(self) -> bool:
        return any(entry.regressed for entry in self.workloads)


def comparability_problem(baseline: Run, candidate: Run) -> str | None:
    """Why these two runs cannot be compared, or None when they can.

    Two runs are only each other's control when they measured the same thing.
    A debug run against a release run, a 1,000-track workload against a
    50,000-track one, or one window size against another are all differences
    large enough to swamp any change being looked for, and reporting a ratio
    across them would be inventing a result rather than measuring one.
    """
    if baseline.milestone != candidate.milestone:
        return (
            f"the baseline measured {baseline.milestone!r} and this run "
            f"measured {candidate.milestone!r}"
        )
    if baseline.build_mode != candidate.build_mode:
        return (
            f"the baseline is a {baseline.build_mode} build and this run is a "
            f"{candidate.build_mode} build"
        )
    if baseline.window != candidate.window:
        return (
            f"the baseline used a {baseline.window} window and this run used "
            f"{candidate.window}"
        )
    shared = [w.name for w in candidate.workloads if baseline.workload(w.name)]
    if not shared:
        return "the two runs have no workload in common"
    for name in shared:
        mine = candidate.workload(name)
        theirs = baseline.workload(name)
        assert mine is not None and theirs is not None
        if mine.tracks != theirs.tracks:
            return (
                f"workload {name!r} held {theirs.tracks:,} tracks in the "
                f"baseline and {mine.tracks:,} here"
            )
    return None


def compare(
    baseline: Run,
    candidate: Run,
    *,
    warmup: int,
    relative_allowance: float = DEFAULT_RELATIVE_ALLOWANCE,
    absolute_allowance_ms: float = DEFAULT_ABSOLUTE_ALLOWANCE_MS,
) -> Comparison:
    problem = comparability_problem(baseline, candidate)
    if problem is not None:
        raise InvalidReport(f"these runs are not comparable: {problem}")
    entries: list[WorkloadComparison] = []
    for workload in candidate.workloads:
        other = baseline.workload(workload.name)
        if other is None:
            continue
        entries.append(
            WorkloadComparison(
                name=workload.name,
                baseline=summarise(other, warmup),
                candidate=summarise(workload, warmup),
                relative_allowance=relative_allowance,
                absolute_allowance_ms=absolute_allowance_ms,
            )
        )
    return Comparison(baseline=baseline, candidate=candidate, workloads=tuple(entries))


def render(run: Run, warmup: int) -> str:
    lines = [
        f"startup to {run.milestone}  (run: {run.label})",
        f"  build mode:       {run.build_mode} - {run.runtime}",
        f"  host:             {run.operating_system}, "
        f"{run.cpu_cores} cores, Dart {run.dart_version.split(' ')[0]}",
        "  window:           "
        f"{run.window[0]:.0f}x{run.window[1]:.0f} @ {run.window[2]:g}x",
        f"  launches:         {run.iterations} per workload "
        f"({run.warmup} warm-up, ignored)",
        f"  network sources:  {run.network_sources}",
    ]
    if run.slow_catalog_ms:
        lines.append(
            f"  CANARY ARMED:     catalog reads delayed by {run.slow_catalog_ms} ms"
        )
    lines.append("")
    lines.append(
        "workload      tracks     first frame   first usable      min      max   spread"
    )
    for workload in run.workloads:
        stats = summarise(workload, warmup)
        lines.append(
            f"  {workload.name:<11}{workload.tracks:>7,}"
            f"{stats.first_frame_median_ms:>16.1f}"
            f"{stats.median_ms:>15.1f}"
            f"{stats.min_ms:>9.1f}{stats.max_ms:>9.1f}"
            f"{stats.spread:>9.0%}"
        )
        if not stats.trustworthy:
            lines.append(
                f"      only {stats.count} judged launch(es): too few to "
                f"compare (needs {MINIMUM_SAMPLES})"
            )
        elif stats.noisy:
            lines.append(
                "      spread is wide: this machine was busy, so read the "
                "medians with care"
            )
    lines.append("")
    lines.append("  all times in milliseconds, median of the judged launches")
    lines.append("  generating a library is setup, not startup, and is in none of the")
    lines.append(
        "  numbers above: "
        + ", ".join(f"{w.name} {w.fixture_build_ms:.0f} ms" for w in run.workloads)
    )
    return "\n".join(lines)


def render_comparison(comparison: Comparison) -> str:
    lines = [
        "",
        f"against the baseline ({comparison.baseline.label})",
        "workload       baseline       this run        delta    ratio  verdict",
    ]
    for entry in comparison.workloads:
        lines.append(
            f"  {entry.name:<11}{entry.baseline.median_ms:>13.1f}"
            f"{entry.candidate.median_ms:>15.1f}"
            f"{entry.delta_ms:>+13.1f}"
            f"{entry.ratio:>9.2f}x"
            f"  {'SLOWER' if entry.regressed else 'ok'}"
        )
    lines.append("")
    if comparison.workloads:
        first = comparison.workloads[0]
        lines.append(
            "  allowance: slower by more than "
            f"{first.absolute_allowance_ms:.0f} ms *and* by more than "
            f"{first.relative_allowance:.0%}"
        )
    else:
        lines.append("  the two runs share no workload")
    lines.append(
        f"  verdict:   {'REGRESSION' if comparison.regressed else 'NO REGRESSION'}"
    )
    return "\n".join(lines)


def render_validation(run: Run, warmup: int) -> str:
    lines = [
        f"structure ok: {SCHEMA}",
        f"  run:        {run.label} ({run.build_mode}, {run.milestone})",
        f"  workloads:  {', '.join(w.name for w in run.workloads)}",
    ]
    for workload in run.workloads:
        stats = summarise(workload, warmup)
        rows = max(sample.rows_rendered for sample in workload.samples)
        lines.append(
            f"  {workload.name:<11}{len(workload.samples):>3} launch(es), "
            f"{stats.count} judged, {workload.tracks:,} tracks, "
            f"{rows} row(s) painted at the milestone"
        )
    return "\n".join(lines)


def _budget(raw: str) -> tuple[str, float]:
    name, _, value = raw.partition("=")
    if not name or not value:
        raise argparse.ArgumentTypeError(f"expected WORKLOAD=MILLISECONDS, got {raw!r}")
    try:
        return name, float(value)
    except ValueError:
        raise argparse.ArgumentTypeError(f"{value!r} is not a number") from None


def check_budgets(run: Run, budgets: list[tuple[str, float]], warmup: int) -> list[str]:
    """Workloads whose median is over an explicitly requested budget.

    Off unless asked for, and documented as a thing to use on a machine you
    control. A budget is the one check here that does not travel: it encodes
    what one machine is capable of, which is exactly why CI does not set one.
    """
    failures: list[str] = []
    for name, limit in budgets:
        workload = run.workload(name)
        if workload is None:
            failures.append(f"no workload named {name!r} in this run")
            continue
        stats = summarise(workload, warmup)
        if stats.median_ms > limit:
            failures.append(
                f"{name}: {stats.median_ms:.1f} ms median is over the "
                f"{limit:.1f} ms budget"
            )
    return failures


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("samples", type=Path, help="JSON written by the harness")
    parser.add_argument(
        "--baseline",
        type=Path,
        help=(
            "a recorded run of the same workloads on this machine. Turns the "
            "report into a comparison, which is the check worth gating on"
        ),
    )
    parser.add_argument(
        "--warmup",
        type=int,
        default=DEFAULT_WARMUP,
        help=(
            "leading launches to ignore. Only consulted when the samples carry "
            "no warm-up flags of their own; when they do, the harness's own "
            "marking wins"
        ),
    )
    parser.add_argument(
        "--relative-allowance",
        type=float,
        default=DEFAULT_RELATIVE_ALLOWANCE,
        help="how much slower than the baseline is still noise, as a fraction",
    )
    parser.add_argument(
        "--absolute-allowance-ms",
        type=float,
        default=DEFAULT_ABSOLUTE_ALLOWANCE_MS,
        help="milliseconds a run may be slower before the ratio is consulted",
    )
    parser.add_argument(
        "--budget",
        type=_budget,
        action="append",
        default=[],
        metavar="WORKLOAD=MS",
        help=(
            "fail if a workload's median is over this many milliseconds. "
            "Machine-specific by nature: use it on a machine you control, "
            "never in shared CI"
        ),
    )
    parser.add_argument(
        "--expect",
        choices=("same", "regressed"),
        help="fail unless the comparison says this. Needs --baseline",
    )
    parser.add_argument(
        "--validate",
        action="store_true",
        help=(
            "check only that the harness produced a complete, well-formed "
            "sample set, and print what it contains. This is the part CI can "
            "enforce without timing anything"
        ),
    )
    args = parser.parse_args(argv)

    if args.warmup < 0:
        parser.error("--warmup must not be negative")
    if args.expect is not None and args.baseline is None:
        parser.error(f"--expect {args.expect} needs --baseline")

    try:
        run = load(args.samples)
    except InvalidReport as error:
        print(f"ERROR: {args.samples}: {error}", file=sys.stderr)
        return 1

    if args.validate:
        print(render_validation(run, args.warmup))
        return 0

    print(render(run, args.warmup))

    comparison: Comparison | None = None
    if args.baseline is not None:
        try:
            baseline = load(args.baseline)
            comparison = compare(
                baseline,
                run,
                warmup=args.warmup,
                relative_allowance=args.relative_allowance,
                absolute_allowance_ms=args.absolute_allowance_ms,
            )
        except InvalidReport as error:
            print(f"ERROR: {error}", file=sys.stderr)
            return 1
        print(render_comparison(comparison))

    failures = check_budgets(run, args.budget, args.warmup)
    for failure in failures:
        print(f"\nERROR: {failure}", file=sys.stderr)

    if args.expect is not None:
        assert comparison is not None
        actual = "regressed" if comparison.regressed else "same"
        if actual != args.expect:
            print(
                f"\nERROR: expected {args.expect}, got {actual}",
                file=sys.stderr,
            )
            return 1
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
