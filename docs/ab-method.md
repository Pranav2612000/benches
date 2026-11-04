# How to A/B two engine commits without fooling yourself

Every rule here was learned by getting it wrong first. None of the
mistakes announced themselves — each produced a clean-looking table of
numbers that happened to be meaningless. That is the hazard worth
naming: a broken A/B does not crash, it answers.

## 1. One measurement harness, two engines

`git checkout <old-commit>` brings that commit's `benches/` with it. Run
the bench on each commit and you have changed two things at once: the
engine *and* the code measuring it. If the diagnostic was added by the
commit under test, the baseline cannot run it at all.

`ab.sh` detaches the engine at each commit, then overlays `benches/`
from `--harness-ref` (the candidate, by default) on top. Only the engine
differs between phases.

The inverse of this works too and is sometimes simpler: keep the tree at
the newer commit and swap *only* the engine files the commit touched —
`git checkout <old> -- src/path/that/changed.rs`. Valid only when you
have confirmed the rest of the diff is test-only code, which the
compiler will not tell you.

## 2. One table, reopened by both phases

A `Supertable` handle that has just built and optimized a table in the
same process does not serve identically to one that opened that table
cold. Measured on a 1M-row Cohere table, the same unfiltered query set
scored **0.995 on a freshly-built handle and 0.975 on a reopened one** —
a 0.02 swing from process state alone, on a code path no commit had
touched.

So: build the table once, before either phase, and have both phases
reopen it. `ab.sh` does this when you pass `--table`. If the baseline
phase happens to be the one that builds, its numbers are flattered and
the comparison is junk.

## 3. A control row that cannot move

Every sweep should measure something the change under test *cannot*
affect, and report it alongside. For a filtered-search sweep that is the
unfiltered query. For a compaction change it might be a cold open.

The control is what turns "these numbers differ" into "the commit did
this". In the filtered-recall run, the control row came out at 0.978 on
both commits, to three decimals — so the filtered rows moving by up to
0.444 could be attributed to the commit and nothing else.

When the control *does* move, stop. Something other than the commit
changed: cache warmth, process state, a different table, a different
corpus. The number it moved by is the floor on what you can resolve.

## 4. Warm both phases the same way

Partial warmth is worse than none, because it is invisible. Prewarm the
entire query battery before the timed pass, not the first query — a
half-warm run moves recall, not just latency, if any part of the serving
path is bounded by time or budget rather than by work.

## 5. Clear the metrics file between phases

Infino's report layer *merges* each run into
`target/infino-bench/<bench>.json`, keeping keys the current run did not
measure. Two phases writing the same file means the second inherits
whatever the first left behind, and a row that silently stopped being
measured still shows up — with stale numbers, read later as a result.

`ab.sh` parks the accumulated file, gives each phase an empty directory,
snapshots it afterwards, and restores your history on exit.

## 6. Measure the regime the change targets

The most expensive mistake available, because it looks like a finished
experiment.

The filtered-recall work first swept filter selectivity from 0.2% to
50%. Both commits scored 0.978–0.998 across the whole ladder: no effect,
two hours spent. The failures the commit addressed were filters keeping
*hundreds* of rows out of ten million — 0.001% to 0.1%, three orders of
magnitude finer than anything measured. Extending the ladder downward
turned a flat result into a 0.444 recall difference on the first rung.

Before concluding a change does nothing, confirm the sweep actually
reaches the conditions it was written for. The issue or PR that
motivated the change usually states them outright.

## 7. Calibrate the noise floor with a null A/B

Run the driver with the same commit on both sides before you trust a
real comparison:

    ./scripts/ab.sh --baseline HEAD --candidate HEAD --label null -- tombstone

Every delta it reports is noise, by construction. On the host this repo
was built on, that run moved an FTS p50 by 6% and RSS by several MiB
with the engine held fixed (`results/null-ab-selftest`). Anything
smaller than that on a real run is not a result.

This is also why `compare.py` applies two thresholds. Recall, counts and
cardinalities are deterministic given the same table and query set, so a
third-decimal move is real; latency and memory are not, and get a much
wider band. If your host is noisier, widen `NOISY_FRACTION` until a null
run reports nothing.

## 8. Let the baseline fail

A bench that gates on a regression is supposed to fail on the commit
before the fix. That non-zero exit is the result you came for. `ab.sh`
records each phase's exit code and keeps going; don't wrap the run in
something that treats it as an error and discards the output.

## A note on timeouts

A long run launched from a tool or CI step that later times out can be
killed along with its parent's process group, hours in, with partial
output. `ab.sh` is safe to run under `nohup`/`setsid`; for very long
sweeps, detach it and poll the log rather than holding a foreground
process open.
