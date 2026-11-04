# Worked example: filtered vector recall

The sweep this repo was built around, and the first thing it proved.

## What the diagnostic measures

`filtered-recall` lives in `infino/benches/utils/filtered_recall.rs` and
runs as `cargo bench -- filtered-recall`. It asks: when `vector_search`
runs under a `WHERE`-style predicate, does it still find the best of the
rows the filter keeps?

A filtered kNN reads the index near the query, so a matching row outside
that reach is never scored. The `k` nearest *matching* rows sit farther
out than the `k` nearest rows the index width was tuned for — and the
fewer the matches, the farther. Pushed far enough, the search returns
the wrong rows, fewer than `k`, or none.

The sweep walks selectivity across two spreads:

- **scattered** — a row's term is `doc_id % n`, so matches spread evenly
  over every cell of the index. No small set of cells to narrow to.
- **clustered** — a row's term is `doc_id / n`, so matches are
  consecutive rows. In a corpus whose order carries meaning they sit
  together in embedding space, usually far from the query.

Each rung is graded against brute-force exact filtered top-10, and the
run reports recall, rows returned, and p50 — plus an **unfiltered row**
on the same table, which is both the ceiling and the control.

## Running it

```sh
./scripts/stage-dataset.sh cohere-10m

./scripts/ab.sh --baseline HEAD~1 --candidate HEAD \
  --table ~/infino-bench/cohere-10m/table \
  -- filtered-recall corpus=parquet:$HOME/infino-bench/corpora/cohere-10m
```

Cost at 9.4M rows × 768 dims, on 8 cores: ~6 min to load the corpus,
~18 min to ingest and optimize, ~1 min for the exact oracle, then
~20–35 min per measurement phase. The table and oracle are cached, so
re-running either commit later skips straight to measurement.

Scale with `INFINO_BENCH_SUPERTABLE_DOCS`. A 1M-row run takes minutes
end to end and still separates the commits — a good smoke test before
committing to the full one.

## The result it was built to produce

Infino commit `0f1485fb`, *"feat vector: filtered vector_search when
filter keeps many matches"*, against its parent `b57eb157`. Cohere
9.4M × 768, both phases reopening one table, one oracle. The engine diff
between phases is a single file, `src/supertable/query/vector.rs`; the
commit's other two files are test-only.

| filter | rows kept | parent | with fix | change |
| --- | ---: | ---: | ---: | ---: |
| **unfiltered — control** | 9.4 M | **0.978** | **0.978** | **0.000** |
| scattered, 1 of 100003 | 95 | 0.556 | 1.000 | **+0.444** |
| scattered, 10 of 100003 | 950 | 0.844 | 0.940 | +0.096 |
| clustered, 1 × 1024 rows | 1.0 K | 0.901 | 0.972 | +0.071 |
| scattered, 1 of 1009 | 9.3 K | 0.964 | 0.992 | +0.028 |
| clustered, 10 × 1024 rows | 10.2 K | 0.974 | 0.991 | +0.017 |
| scattered, 10 of 1009 | 93.2 K | 0.977 | 0.993 | +0.016 |
| clustered, 100 × 1024 rows | 102.4 K | 0.975 | 0.993 | +0.018 |
| scattered, 1 of 11 | 855 K | 0.982 | 0.985 | +0.003 |
| scattered, 5 of 11 | 4.3 M | 0.983 | 0.983 | 0.000 |

Reading it:

- **The control is identical to three decimals.** That is what licenses
  attributing everything else to the commit.
- **The gain scales inversely with selectivity**, which is the
  mechanism: the fix routes at `k / selectivity`, so the fewer rows the
  filter keeps, the wider it reaches. Above ~1% both builds already sat
  at the ceiling.
- **The parent also under-fills.** At 95 matching rows it returned 9.9
  rows on average instead of 10 — the "returns fewer than k" symptom,
  seen from the other side.
- **The fix costs latency** where it helps most: p50 887 ms vs 617 ms at
  the 95-row rung, and roughly +25% through the low-selectivity band.
  That is the wider probe doing its work, and it belongs in any writeup
  of the change.

## The gate

The sweep fails if any filtered rung falls more than 0.05 below the
unfiltered ceiling *measured on the same table*. Relative, not an
absolute floor: the diagnostic runs on whatever corpus and scale you
point it at, and absolute recall is a property of those. What must hold
everywhere is the promise a filtered kNN makes — restricting the result
set should not stop the search finding the best of what is left.

On this run the parent failed it on exactly three rungs, naming each:

```
filtered recall fell more than 0.05 below the unfiltered ceiling of 0.978:
  scattered, 1 of 100003 (0.0010%): 0.556, 0.422 below the ceiling
  scattered, 10 of 100003 (0.0101%): 0.844, 0.134 below the ceiling
  clustered, 1 × 1024 rows (0.0109%): 0.901, 0.077 below the ceiling
```

## What nearly went wrong

The first ladder swept 0.2%–50% selectivity, built on the vector table's
existing 499-bucket filter column. Both commits scored 0.978–0.998
across all of it — a flat, publishable-looking, useless result. The
regime the commit targets is 0.001%–0.1%, which 499 buckets cannot
express. The fix was finer filter dials in the ingest, off by default so
no other bench cell's table changes.

The second near-miss: the parent's first numbers came from a phase that
had just built the table in-process, the candidate's from a reopened
one. That alone moved the untouched control row by 0.02 — comparable to
most of the differences being claimed. Both phases were re-run against a
reopened table before any of the above was believed.

`ab-method.md` generalizes both.
