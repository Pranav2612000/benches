# infino-bench-lab

A workbench for answering one question: **did this commit change the
numbers, and by how much?**

Infino's own bench suite lives in `infino/benches/` and measures one
build of the engine. This repo measures *two*, against each other, on
one prebuilt table — the setup you need to show that a change did what
it claimed, or that it cost nothing.

It holds no measurement code. The benches and diagnostics stay in
`infino/benches/`, single-sourced; this repo stages datasets, drives two
commits through the same harness, and diffs the result.

```
scripts/stage-dataset.sh   download a real embedding dataset as parquet shards
scripts/ab.sh              run one bench selector against two commits
scripts/compare.py         diff two phases into a markdown table
docs/ab-method.md          why the driver is shaped the way it is — read this
docs/filtered-recall.md    worked example: the filtered-vector-recall sweep
results/                   recorded runs, logs and metrics included
```

## Layout

This repo expects to sit beside an `infino/` checkout:

```
workspace/
├── infino/            the engine (and its benches)
└── infino-bench-lab/  this repo
```

Set `INFINO_DIR` if your checkout is elsewhere. Large artifacts —
datasets, built tables, scratch — go under `$LAB_DATA_DIR`
(default `~/infino-bench`), never into either repo.

## Prerequisites

- Rust (the toolchain `infino/rust-toolchain.toml` pins)
- `cmake` — the bench crate builds a vendored HDF5. Without it
  `cargo bench` dies in a build script with ``is `cmake` not
  installed?``. No root needed: `pip install --user cmake`.
- `python3` for `compare.py`
- Disk. A 10M-row, 768-dim run wants ~110 GB: ~31 GB of parquet, ~31 GB
  of corpus scratch, ~41 GB of built table.

`scripts/env.sh` checks these and explains anything missing. It is
sourced by the other scripts; you never run it directly.

## Quickstart

```sh
# 1. Stage a dataset (~31 GB; resumable, skips what is already there)
./scripts/stage-dataset.sh cohere-10m

# 2. A/B two commits of the engine over one bench selector
./scripts/ab.sh --baseline HEAD~1 --candidate HEAD \
  --table ~/infino-bench/cohere-10m/table \
  -- filtered-recall corpus=parquet:$HOME/infino-bench/corpora/cohere-10m
```

The first run builds the table and the exact-answer oracle, which is the
expensive part (~35 min at 9.4M rows). Every later run against that same
`--table` reuses both, so a repeat A/B is just the two measurement
passes.

Results land in `results/<label>/`:

```
results/2026-11-03-filtered-recall-b57eb157-vs-0f1485fb/
├── run.txt            what was run, on what, when
├── baseline.log       full engine output for each phase
├── candidate.log
├── baseline/          metrics JSON + exit code
├── candidate/
└── comparison.md      the diff table
```

A phase exiting non-zero is a result, not a failure: a bench that gates
on a regression is *supposed* to fail on the baseline. `ab.sh` records
the exit code and carries on.

## Using it on anything else

The driver takes whatever `cargo bench --` takes, so any cell or
diagnostic works:

```sh
./scripts/ab.sh --baseline v0.11.19 --candidate main -- supertable vector warm
./scripts/ab.sh --baseline main --candidate my-branch -- superfile fts
./scripts/ab.sh --baseline HEAD~5 --candidate HEAD -- scale
```

`--table` is specific to the filtered-recall sweep, which is currently
the one diagnostic that keeps a reusable table. Other cells build their
own corpus per run; for those, drop `--table` and expect each phase to
pay full build cost.

## Reading a result

Three things decide whether a comparison means anything. The driver
enforces the first two; **the third is on you**:

1. **One harness, two engines.** Both phases run the measurement code
   from `--harness-ref`, overlaid on each engine commit. Otherwise you
   are comparing two engines *and* two harnesses.
2. **One table, reopened by both.** Built once, before either phase.
3. **A control row that cannot move.** Every sweep should report
   something the change under test cannot affect. If it differs between
   phases, something other than the commit did — discard the run and
   find it.

`docs/ab-method.md` explains each of these and what going without them
looks like, which is rarely an obvious failure and usually a plausible
wrong answer.

## Troubleshooting

**`drain scratch create: Permission denied`** — the engine's drain
writes under the system temp dir, and on a shared host
`/tmp/infino-drain` may already belong to another user. `env.sh` points
`TMPDIR` at `$LAB_DATA_DIR/tmp` to avoid it. It surfaces ~20 minutes
into a build, so it is worth not hitting twice.

**``is `cmake` not installed?``** — see Prerequisites.

**"Too many open files"** — benches mmap many files at once; `env.sh`
raises the soft limit to 65536.

**A metric appears under "measured by only one phase"** — the phases did
not measure the same thing. Usually the harness overlay missed a path;
try `--harness-path benches --harness-path Cargo.toml` if the bench
target itself only exists on one side.

**Numbers that barely move, on a change you expected to matter** — check
you are measuring the regime the change targets before concluding
anything. `docs/filtered-recall.md` has a worked example where the first
ladder of filters was three orders of magnitude too coarse and showed
nothing for two hours.
