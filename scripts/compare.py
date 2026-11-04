#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: Copyright The Infino Authors
"""Diff two phases of an A/B run into a markdown table.

Reads the metric files the bench's report layer writes
(``target/infino-bench/<bench>.json``), as snapshotted per phase by
``ab.sh``. Each file is a flat map of

    "<anchor>|<subtitle>|<row label>|<column>" -> number

plus a ``__corpus`` fingerprint. Keys are compared only where both
phases measured them; anything measured by one side alone is reported
separately rather than silently dropped, because a key that vanished
usually means the two phases did not run the same thing.
"""

import argparse
import json
import pathlib
import sys

# The fingerprint the report layer stores so numbers from different
# corpora are never merged (`CORPUS_FINGERPRINT_KEY` in its report.rs).
# Compared, never diffed.
CORPUS_KEY = "__corpus"

# Columns whose units are nanoseconds, so the table can print them as
# milliseconds instead of ten-digit integers.
NANOSECOND_COLUMNS = {"p50", "p90", "p99", "mean", "wall", "cold", "warm"}

# Columns whose value is a measurement of the machine rather than of
# the engine's answers: latencies and memory. They move run to run even
# with the engine held fixed.
NOISY_COLUMNS = NANOSECOND_COLUMNS | {
    "Peak RSS",
    "Median RSS",
    "P90 RSS",
    "FTS p50",
    "SQL COUNT(*) p50",
}

# Relative change below which a metric is reported as unchanged.
#
# Two thresholds, because two kinds of metric. Recall, counts and
# cardinalities are deterministic given the same table and query set: a
# third-decimal move there is real. Latency and memory are not — a null
# A/B on this repo (the same commit on both sides, `results/
# null-ab-selftest`) moved an FTS p50 by 6% and RSS by several MiB with
# the engine held fixed. Reporting those as change would make every run
# look like a regression somewhere.
#
# Calibrate for your own host by running a null A/B and widening
# NOISY_FRACTION until it reports no change; see docs/ab-method.md.
DETERMINISTIC_FRACTION = 0.005
NOISY_FRACTION = 0.10


def load_phase(directory: pathlib.Path) -> tuple[dict, list[str]]:
    """Every metric in a phase directory, plus the files it came from."""
    metrics: dict[str, float] = {}
    files: list[str] = []
    for path in sorted(directory.glob("*.json")):
        with path.open() as handle:
            metrics.update(json.load(handle))
        files.append(path.name)
    return metrics, files


def format_value(column: str, value: float) -> str:
    if column in NANOSECOND_COLUMNS:
        return f"{value / 1e6:.2f} ms"
    if abs(value) < 10:
        return f"{value:.3f}"
    return f"{value:,.0f}"


def format_delta(column: str, before: float, after: float) -> str:
    delta = after - before
    threshold = NOISY_FRACTION if column in NOISY_COLUMNS else DETERMINISTIC_FRACTION
    if before and abs(delta / before) < threshold:
        return "—"
    if column in NANOSECOND_COLUMNS:
        return f"{delta / 1e6:+.2f} ms"
    if abs(delta) < 10:
        return f"{delta:+.3f}"
    return f"{delta:+,.0f}"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline-dir", required=True, type=pathlib.Path)
    parser.add_argument("--candidate-dir", required=True, type=pathlib.Path)
    parser.add_argument("--baseline-name", default="baseline")
    parser.add_argument("--candidate-name", default="candidate")
    parser.add_argument("--out", type=pathlib.Path)
    args = parser.parse_args()

    baseline, baseline_files = load_phase(args.baseline_dir)
    candidate, candidate_files = load_phase(args.candidate_dir)
    if not baseline or not candidate:
        print(
            f"error: no metrics in {args.baseline_dir} or {args.candidate_dir} — "
            "did the bench actually emit a report section?",
            file=sys.stderr,
        )
        return 1

    before_corpus = baseline.pop(CORPUS_KEY, None)
    after_corpus = candidate.pop(CORPUS_KEY, None)

    lines: list[str] = []
    lines.append(f"# {args.baseline_name} → {args.candidate_name}")
    lines.append("")
    lines.append(f"- baseline metrics: {', '.join(baseline_files) or 'none'}")
    lines.append(f"- candidate metrics: {', '.join(candidate_files) or 'none'}")
    if before_corpus != after_corpus:
        lines.append("")
        lines.append(
            "**The two phases ran on different corpora. The numbers below are "
            "not comparable — rebuild both on one dataset.**"
        )
    lines.append("")

    shared = sorted(set(baseline) & set(candidate))
    lines.append("| section | row | metric | baseline | candidate | change |")
    lines.append("| --- | --- | --- | --- | --- | --- |")
    for key in shared:
        anchor, _subtitle, label, column = (key.split("|") + ["", "", "", ""])[:4]
        section = anchor.rsplit("/", 1)[-1]
        lines.append(
            f"| {section} | {label or '—'} | {column} "
            f"| {format_value(column, baseline[key])} "
            f"| {format_value(column, candidate[key])} "
            f"| {format_delta(column, baseline[key], candidate[key])} |"
        )

    only_baseline = sorted(set(baseline) - set(candidate))
    only_candidate = sorted(set(candidate) - set(baseline))
    if only_baseline or only_candidate:
        lines.append("")
        lines.append("## Measured by only one phase")
        lines.append("")
        lines.append(
            "A metric on one side only means the phases did not measure the "
            "same thing — usually a harness that differs between them."
        )
        lines.append("")
        for key in only_baseline:
            lines.append(f"- baseline only: `{key}`")
        for key in only_candidate:
            lines.append(f"- candidate only: `{key}`")

    report = "\n".join(lines) + "\n"
    print(report)
    if args.out:
        args.out.write_text(report)
        print(f"written to {args.out}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
