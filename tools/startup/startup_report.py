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

# Launches to ignore before judging, when the run does not say.
#
# The first launch in a process is not a startup measurement, it is a
# measurement of the Dart VM compiling the widget tree it has never run before.
# On a JIT run that first launch is routinely several times the ones after it,
# and averaging it in would drown the thing being measured.
#
# Every run records the count it actually used, and that is the authority: a
# run that deliberately warmed up zero times must not have its first launch
# discarded anyway. This is only the fallback for a file with no count at all.
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

# How much more simulated time a run may take before it counts as a regression,
# in milliseconds.
#
# The second clock, and the one that catches a regression a wall clock in a
# widget test cannot see. `tester.pump(d)` advances the binding's *fake* clock
# rather than waiting, so time the app spends awaiting a timer or a delayed
# future costs no wall time at all here: it shows up only as more trips round
# the pump loop. A change that adds a 250 ms await is therefore invisible to
# the stopwatch and unmissable here.
#
# The allowance is small because this clock is quantized and deterministic
# rather than noisy: every clean launch of a given workload takes the same
# number of frames on any machine, so anything beyond a few frames of
# difference is an await that was not there before, not measurement noise.
DEFAULT_SIMULATED_ALLOWANCE_MS = 16.0


class InvalidReport(ValueError):
    """The sample file is not something this reporter can read."""


@dataclass(frozen=True)
class Sample:
    """One launch."""

    iteration: int
    warmup: bool
    first_frame_ms: float
    first_usable_frame_ms: float
    simulated_ms: float
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

        ``warmup`` is a *count*, normally the one the run recorded, and both
        filters apply: the leading ``warmup`` launches are dropped, and so is
        anything the harness marked as warm-up itself. Counting rather than
        sniffing the flags is what makes ``LINTHRA_STARTUP_WARMUP=0`` mean
        zero: a run that warmed up no launches writes ``warmup: false`` on all
        of them, and reading that as "no flags, so guess" silently threw away
        the first real measurement.
        """
        return tuple(s for s in self.samples[warmup:] if not s.warmup)


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
    pump_interval_ms: float
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
    simulated_median_ms: float

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
    frames = int(_number(payload, "frames"))
    simulated = payload.get("simulated_ms")
    if simulated is None:
        raise InvalidReport("missing 'simulated_ms'")
    if not isinstance(simulated, (int, float)) or isinstance(simulated, bool):
        raise InvalidReport(f"'simulated_ms' is not a number: {simulated!r}")
    if simulated < 0:
        raise InvalidReport("simulated time cannot be negative")
    return Sample(
        iteration=int(_number(payload, "iteration")),
        warmup=bool(payload.get("warmup", False)),
        first_frame_ms=first_frame,
        first_usable_frame_ms=usable,
        simulated_ms=float(simulated),
        frames=frames,
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
        pump_interval_ms=float(payload.get("pump_interval_ms", 0) or 0),
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
    simulated = [sample.simulated_ms for sample in judged]
    return Stats(
        count=len(judged),
        median_ms=median(usable),
        min_ms=min(usable) if usable else 0.0,
        max_ms=max(usable) if usable else 0.0,
        first_frame_median_ms=median(first),
        simulated_median_ms=median(simulated),
    )


def effective_warmup(run: Run, override: int | None) -> int:
    """How many leading launches to drop for [run].

    The run's own count wins, because it is the only thing that knows what the
    harness actually did; ``--warmup`` is an explicit override for a reader who
    wants to discard more, and DEFAULT_WARMUP is the last resort for a file
    that records no count at all.
    """
    if override is not None:
        return override
    return run.warmup if run.warmup >= 0 else DEFAULT_WARMUP


@dataclass(frozen=True)
class WorkloadComparison:
    """One workload, measured against the same workload in a baseline run."""

    name: str
    baseline: Stats
    candidate: Stats
    relative_allowance: float
    absolute_allowance_ms: float
    simulated_allowance_ms: float

    @property
    def delta_ms(self) -> float:
        return self.candidate.median_ms - self.baseline.median_ms

    @property
    def ratio(self) -> float:
        if self.baseline.median_ms <= 0:
            return 0.0
        return self.candidate.median_ms / self.baseline.median_ms

    @property
    def simulated_delta_ms(self) -> float:
        return self.candidate.simulated_median_ms - self.baseline.simulated_median_ms

    @property
    def worked_longer(self) -> bool:
        """Whether the CPU did measurably more before the library was usable.

        Both allowances have to be exceeded. A run that is 40% slower but only
        3 ms slower is a scheduling hiccup on a small number; one that is 200 ms
        slower but 5% slower is the large workload behaving normally.
        """
        if self.delta_ms <= self.absolute_allowance_ms:
            return False
        return self.ratio > 1.0 + self.relative_allowance

    @property
    def waited_longer(self) -> bool:
        """Whether the app spent measurably longer awaiting something.

        The clock the stopwatch cannot see. One allowance and no ratio: this
        number is quantized to whole frames and identical between machines, so
        a few frames is the whole of the noise and a percentage of it would
        mean nothing.
        """
        return self.simulated_delta_ms > self.simulated_allowance_ms

    @property
    def comparable(self) -> bool:
        """Whether both sides have enough judged launches to be compared."""
        return self.baseline.trustworthy and self.candidate.trustworthy

    @property
    def regressed(self) -> bool:
        """Whether this workload now reaches a usable library later.

        Either clock is enough. A regression is a regression whether the app
        got there late because it did more work or because it waited longer,
        and a check that only watched one of them would wave the other through.

        Missing evidence is **not** a regression. Calling it one reads as a
        sensible fail-safe and is only safe in one direction: it does keep a
        truncated run from passing `--expect same`, but it also lets a canary
        whose samples went missing satisfy `--expect regressed`, so the
        false-negative control could be met by a file with nothing in it.
        Too little evidence is [comparable] instead, and every expectation
        refuses to answer on it.
        """
        return self.comparable and (self.worked_longer or self.waited_longer)


@dataclass(frozen=True)
class Comparison:
    baseline: Run
    candidate: Run
    workloads: tuple[WorkloadComparison, ...]

    @property
    def indeterminate(self) -> bool:
        """Whether any workload lacks the evidence to be judged at all.

        A verdict over a run containing one of these means nothing, in either
        direction, so the caller is told to fix the measurement rather than
        given an answer.
        """
        return not self.workloads or any(
            not entry.comparable for entry in self.workloads
        )

    @property
    def unjudgeable(self) -> tuple[str, ...]:
        return tuple(entry.name for entry in self.workloads if not entry.comparable)

    @property
    def regressed(self) -> bool:
        return any(entry.regressed for entry in self.workloads)

    @property
    def regressed_everywhere(self) -> bool:
        """Whether *every* workload got slower.

        What the canary has to satisfy. It delays every catalog read, so every
        workload must see it; a canary that only still fires on `empty` has
        proved that the check stopped detecting the delay on the other two,
        and `any()` would call that a pass.
        """
        return bool(self.workloads) and all(entry.regressed for entry in self.workloads)


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
    if baseline.pump_interval_ms != candidate.pump_interval_ms:
        # `simulated_ms` is frames times this interval, so changing it rescales
        # the whole awaited clock: an unchanged three-frame startup reads 8 ms
        # at 4 ms a pump and 32 ms at 16, which clears the default allowance
        # and invents a regression. The reverse hides a real one.
        return (
            f"the baseline pumped {baseline.pump_interval_ms:g} ms a frame and "
            f"this run pumped {candidate.pump_interval_ms:g} ms, so their "
            "awaited times are not the same unit"
        )
    mine_names = {w.name for w in candidate.workloads}
    their_names = {w.name for w in baseline.workloads}
    if mine_names != their_names:
        # Not "enough in common to say something": a run-level verdict covers
        # every workload, so one that is missing from either side is a workload
        # nobody checked, and LINTHRA_STARTUP_WORKLOADS makes producing such a
        # subset easy. An `--expect same` that quietly skipped the large
        # workload would pass a regression that only the large workload shows.
        missing = sorted(their_names - mine_names)
        extra = sorted(mine_names - their_names)
        parts = []
        if missing:
            parts.append(f"this run is missing {', '.join(missing)}")
        if extra:
            parts.append(f"the baseline is missing {', '.join(extra)}")
        return "the two runs measured different workloads: " + "; ".join(parts)
    for name in sorted(mine_names):
        mine = candidate.workload(name)
        theirs = baseline.workload(name)
        assert mine is not None and theirs is not None
        if mine.tracks != theirs.tracks:
            return (
                f"workload {name!r} held {theirs.tracks:,} tracks in the "
                f"baseline and {mine.tracks:,} here"
            )
        if mine.albums != theirs.albums:
            # Same rows, different shape. The Library groups and renders by
            # album, so 1,000 tracks in 84 albums and 1,000 tracks in 1,000
            # albums are different amounts of work, and a fixture change
            # between the two commits would be charged to the app.
            return (
                f"workload {name!r} grouped {theirs.tracks:,} tracks into "
                f"{theirs.albums:,} albums in the baseline and {mine.albums:,} "
                "here"
            )
    return None


def compare(
    baseline: Run,
    candidate: Run,
    *,
    warmup: int | None = None,
    relative_allowance: float = DEFAULT_RELATIVE_ALLOWANCE,
    absolute_allowance_ms: float = DEFAULT_ABSOLUTE_ALLOWANCE_MS,
    simulated_allowance_ms: float = DEFAULT_SIMULATED_ALLOWANCE_MS,
) -> Comparison:
    problem = comparability_problem(baseline, candidate)
    if problem is not None:
        raise InvalidReport(f"these runs are not comparable: {problem}")
    # Each side is warmed up by its own recorded count, because the two runs
    # are allowed to have used different ones.
    base_warmup = effective_warmup(baseline, warmup)
    cand_warmup = effective_warmup(candidate, warmup)
    entries: list[WorkloadComparison] = []
    for workload in candidate.workloads:
        other = baseline.workload(workload.name)
        if other is None:
            continue
        entries.append(
            WorkloadComparison(
                name=workload.name,
                baseline=summarise(other, base_warmup),
                candidate=summarise(workload, cand_warmup),
                relative_allowance=relative_allowance,
                absolute_allowance_ms=absolute_allowance_ms,
                simulated_allowance_ms=simulated_allowance_ms,
            )
        )
    return Comparison(baseline=baseline, candidate=candidate, workloads=tuple(entries))


def missing_workloads(run: Run, required: list[str]) -> list[str]:
    """Which of [required] this run does not contain.

    `--validate` on its own can only check what is in the file, and
    `LINTHRA_STARTUP_WORKLOADS` makes a subset easy to produce, so "every
    workload present is well-formed" is not the same claim as "all three paths
    still work". The caller that cares about the second says which it wants.
    """
    present = {workload.name for workload in run.workloads}
    return [name for name in required if name not in present]


def completeness_problems(run: Run, warmup: int) -> list[str]:
    """Ways the sample set is not the one the run says it is.

    This is what CI actually enforces, so "well-formed" is not enough: a
    harness that dies after its warm-up launch, or that writes one workload
    short, still produces a file every field of which parses. The run's own
    metadata is the thing to hold it to.
    """
    problems: list[str] = []
    for workload in run.workloads:
        recorded = len(workload.samples)
        if recorded != run.iterations:
            problems.append(
                f"workload {workload.name!r} recorded {recorded} launch(es) "
                f"but the run declares {run.iterations}"
            )
        if len(workload.judged(warmup)) < 1:
            problems.append(
                f"workload {workload.name!r} has no launch left after "
                f"{warmup} warm-up(s): nothing was actually measured"
            )
    return problems


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
        "workload      tracks   first frame  first usable   awaited"
        "      min      max  spread"
    )
    for workload in run.workloads:
        stats = summarise(workload, warmup)
        lines.append(
            f"  {workload.name:<11}{workload.tracks:>7,}"
            f"{stats.first_frame_median_ms:>14.1f}"
            f"{stats.median_ms:>14.1f}"
            f"{stats.simulated_median_ms:>10.0f}"
            f"{stats.min_ms:>9.1f}{stats.max_ms:>9.1f}"
            f"{stats.spread:>8.0%}"
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
    lines.append("  'awaited' is simulated time: what the app spent waiting on timers")
    lines.append(
        "  rather than working, which a wall clock in a widget test cannot see"
    )
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
        "workload      baseline      this run       delta   ratio   awaited  verdict",
    ]
    for entry in comparison.workloads:
        if not entry.comparable:
            verdict = "NOT ENOUGH DATA"
        elif entry.worked_longer and entry.waited_longer:
            verdict = "SLOWER (work + wait)"
        elif entry.worked_longer:
            verdict = "SLOWER (more work)"
        elif entry.waited_longer:
            verdict = "SLOWER (waits longer)"
        else:
            verdict = "ok"
        lines.append(
            f"  {entry.name:<11}{entry.baseline.median_ms:>11.1f}"
            f"{entry.candidate.median_ms:>14.1f}"
            f"{entry.delta_ms:>+12.1f}"
            f"{entry.ratio:>8.2f}x"
            f"{entry.simulated_delta_ms:>+10.0f}"
            f"  {verdict}"
        )
    lines.append("")
    if comparison.workloads:
        first = comparison.workloads[0]
        lines.append(
            "  allowance: work, slower by more than "
            f"{first.absolute_allowance_ms:.0f} ms *and* by more than "
            f"{first.relative_allowance:.0%}"
        )
        lines.append(
            "             wait, more than "
            f"{first.simulated_allowance_ms:.0f} ms of extra simulated time"
        )
    else:
        lines.append("  the two runs share no workload")
    if comparison.indeterminate:
        lines.append(
            "  verdict:   NOT ENOUGH DATA ("
            + ", ".join(comparison.unjudgeable or ("no shared workload",))
            + ")"
        )
    else:
        lines.append(
            f"  verdict:   {'REGRESSION' if comparison.regressed else 'NO REGRESSION'}"
        )
    return "\n".join(lines)


def render_validation(run: Run, warmup: int) -> str:
    lines = [
        f"structure ok: {SCHEMA}",
        f"  run:        {run.label} ({run.build_mode}, {run.milestone})",
        f"  declared:   {run.iterations} launch(es) per workload, {run.warmup} warm-up",
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
        if stats.count < 1:
            # A workload whose every launch was warm-up summarises to a median
            # of zero, which is under any budget anyone would set. Passing a
            # budget on a measurement that did not happen is worse than having
            # no budget, and `--budget` does not imply `--validate`.
            failures.append(
                f"{name}: no judged launch, so there is nothing to hold to a "
                f"{limit:.1f} ms budget"
            )
            continue
        if stats.median_ms > limit:
            failures.append(
                f"{name}: {stats.median_ms:.1f} ms median is over the "
                f"{limit:.1f} ms budget"
            )
    return failures


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    # Optional only so `--minimum-samples` can answer without a file; every
    # other path still requires it, checked below.
    parser.add_argument(
        "samples", type=Path, nargs="?", help="JSON written by the harness"
    )
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
        default=None,
        help=(
            "leading launches to ignore, overriding the count the run recorded "
            "for itself. Leave it alone unless you want to discard more than "
            "the harness did"
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
        "--simulated-allowance-ms",
        type=float,
        default=DEFAULT_SIMULATED_ALLOWANCE_MS,
        help=(
            "extra simulated (awaited) time that is still noise. This is the "
            "clock that sees an added timer, which a wall clock in a widget "
            "test cannot"
        ),
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
        choices=("same", "regressed", "regressed-everywhere"),
        help=(
            "fail unless the comparison says this. Needs --baseline. "
            "'regressed' is the ordinary run-level policy (any workload); "
            "'regressed-everywhere' is what the canary needs, because a "
            "delay injected into every read must be seen on every workload"
        ),
    )
    parser.add_argument(
        "--require-workloads",
        metavar="NAMES",
        help=(
            "comma-separated workload names that must be present, checked "
            "with --validate. Without it, validation can only speak for the "
            "workloads the file happens to contain"
        ),
    )
    parser.add_argument(
        "--minimum-samples",
        action="store_true",
        help=(
            "print the fewest judged launches a comparison will trust, and "
            "exit. Lets a caller size its run without hardcoding the number"
        ),
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

    if args.minimum_samples:
        print(MINIMUM_SAMPLES)
        return 0
    if args.samples is None:
        parser.error("the samples file is required")
    if args.warmup is not None and args.warmup < 0:
        parser.error("--warmup must not be negative")
    if args.expect is not None and args.baseline is None:
        parser.error(f"--expect {args.expect} needs --baseline")
    if args.require_workloads and not args.validate:
        parser.error("--require-workloads only applies with --validate")

    try:
        run = load(args.samples)
    except InvalidReport as error:
        print(f"ERROR: {args.samples}: {error}", file=sys.stderr)
        return 1

    warmup = effective_warmup(run, args.warmup)

    if args.validate:
        required = [
            name.strip()
            for name in (args.require_workloads or "").split(",")
            if name.strip()
        ]
        problems = [
            f"required workload {name!r} is not in this run"
            for name in missing_workloads(run, required)
        ]
        problems += completeness_problems(run, warmup)
        if problems:
            for problem in problems:
                print(f"ERROR: {args.samples}: {problem}", file=sys.stderr)
            return 1
        print(render_validation(run, warmup))
        return 0

    print(render(run, warmup))

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
                simulated_allowance_ms=args.simulated_allowance_ms,
            )
        except InvalidReport as error:
            print(f"ERROR: {error}", file=sys.stderr)
            return 1
        print(render_comparison(comparison))

    failures = check_budgets(run, args.budget, warmup)
    for failure in failures:
        print(f"\nERROR: {failure}", file=sys.stderr)

    if args.expect is not None:
        assert comparison is not None
        if comparison.indeterminate:
            # Refused rather than answered, in either direction. The old
            # behaviour called this a regression, which kept a truncated run
            # from passing `--expect same` but let a truncated canary satisfy
            # `--expect regressed` without measuring anything.
            print(
                "\nERROR: cannot judge "
                + (
                    ", ".join(comparison.unjudgeable)
                    if comparison.unjudgeable
                    else "a comparison with no shared workload"
                )
                + f": fewer than {MINIMUM_SAMPLES} judged launches on one "
                "side. Re-measure rather than trusting this run.",
                file=sys.stderr,
            )
            return 1
        if args.expect == "regressed-everywhere":
            met = comparison.regressed_everywhere
            actual = (
                "regressed everywhere"
                if met
                else (
                    "regressed somewhere: "
                    + ", ".join(
                        entry.name for entry in comparison.workloads if entry.regressed
                    )
                    if comparison.regressed
                    else "same"
                )
            )
        else:
            met = ("regressed" if comparison.regressed else "same") == args.expect
            actual = "regressed" if comparison.regressed else "same"
        if not met:
            print(
                f"\nERROR: expected {args.expect}, got {actual}",
                file=sys.stderr,
            )
            return 1
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
