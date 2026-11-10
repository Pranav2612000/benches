# HSEB MS MARCO: infino v0.11.19 → main

[HSEB](https://huggingface.co/datasets/hseb-benchmark/msmarco) ("hybrid
search engine benchmark") is kNN plus a tag filter over MS MARCO
passages. This run uses the `all-MiniLM-L6-v2` (384-dim) embeddings at
the dataset's 100K and 1M corpus sizes. The 1M split is exactly
1,000,000 passages and is the largest single corpus in the dataset; the
2,400,985 rows the dataset page shows are all 18 configs summed (3
models × 3 sizes × corpus/queries).

Each of the 10,000 queries runs at k = 10 and k = 100 under three
filters: none, a tag carried by 91% of passages, and a tag carried by
11%. Recall is |returned ∩ exact top-k| / k against HSEB's precomputed
exact filtered top-100, as HSEB scores it. Latency is single-thread,
one query at a time, after 200 warmup queries; 8-core shared host.

Harness: `scripts/hseb.py` (`build` then `query`). Tags are stored as an
FTS column (`"tag10 tag90 tag100"`) and filtered via
`vector_search(..., filter_column="tags", filter_query="tagN")`.

## Builds compared

| label | engine commit | what it has |
| --- | --- | --- |
| v0.11.19 | tag `v0.11.19` (`6157b9f9`) | before the filtered-search fixes |
| pypi-7a52f471 | `7a52f471` (engine 0.11.22) | the PyPI wheel `infino==0.11.19` — has #1173 and #1178, not #1185; stock (non-LTO) release profile |
| main | `54593948` | everything, incl. #1185 and the LTO release profile (#1201) |

The PyPI version number is the binding's, not the engine's: the wheel
labelled 0.11.19 contains engine 0.11.22.

## Results, each build on its own table (1M)

Recall:

| k | filter | v0.11.19 | pypi-7a52f471 | main |
| ---: | --- | ---: | ---: | ---: |
| 10 | none | 0.9812 | 0.9911 | 0.9912 |
| 10 | keeps 90% | 0.9832 | 0.9757 | 0.9762 |
| 10 | keeps 10% | 0.9748 | 0.9639 | 0.9781 |
| 100 | none | 0.9250 | 0.9248 | 0.9247 |
| 100 | keeps 90% | 0.9810 | 0.9801 | 0.9792 |
| 100 | keeps 10% | 0.9724 | 0.9710 | 0.9999 |

p50 latency (ms):

| k | filter | v0.11.19 | pypi-7a52f471 | main |
| ---: | --- | ---: | ---: | ---: |
| 10 | none | 42.9 | 37.8 | 37.0 |
| 10 | keeps 90% | 179.3 | 177.3 | 125.9 |
| 10 | keeps 10% | 92.1 | 57.1 | 59.4 |
| 100 | none | 62.4 | 41.9 | 41.5 |
| 100 | keeps 90% | 203.6 | 197.1 | 143.1 |
| 100 | keeps 10% | 123.8 | 68.6 | 98.1 |

Build (1M, all three): ~75 s load + append, ~36 s optimize.

At 100K the picture is the same: main reaches 1.000 / 0.9999 on the 10%
filter where v0.11.19 has 0.974 / 0.966, latencies within noise
(`*/all-MiniLM-L6-v2-100K.json`).

## Isolating #1185 (`isolate-1185/`)

Own-table runs mix query-time changes with how each engine built its
table, so #1185 was measured alone: its parent `55ac24b8` and
`fa97ebca` both query the same (PyPI-built) 1M table, first 2,000
queries.

| k | filter | 55ac24b8 recall / p50 | fa97ebca recall / p50 |
| ---: | --- | ---: | ---: |
| 10 | none | 0.9911 / 37.8 | 0.9911 / 37.8 |
| 10 | keeps 90% | 0.9759 / 126.5 | 0.9771 / 127.2 |
| 10 | keeps 10% | 0.9662 / 53.7 | 0.9810 / 61.4 |
| 100 | none | 0.9251 / 42.3 | 0.9251 / 42.0 |
| 100 | keeps 90% | 0.9809 / 144.0 | 0.9816 / 145.6 |
| 100 | keeps 10% | 0.9715 / 64.4 | 0.9999 / 100.6 |

- #1185 lifts the 10% filter by +0.015 (k=10) and +0.028 (k=100), at
  +14% / +56% p50. It does nothing at 90% or unfiltered.
- The 90% speedup (177 → 126 ms) is all #1201 (thin LTO,
  codegen-units = 1): the parent already has it.

Same-table checks on a v0.11.19-built table (`same-table-v0.11.19-built/`)
agree: main vs v0.11.19 moves only k=100 / 10% (0.9724 → 0.9999, p50
123 → 158 ms). v0.11.19's slow 10% cells (92 / 124 ms) reproduce on an
idle host on its own table, so they are a property of that table, not
load. v0.11.19 cannot open tables built by newer engines (term-index
layout v6 vs v5), so there is no reverse pair.

## Why #1185 moves HSEB so little

- HSEB's filters keep 11% and 91% of rows. #1185 targets filters
  keeping roughly ≤0.1%, 2–4 orders of magnitude narrower — where the
  scattered 1-of-100003 case in
  `../2026-11-03-filtered-recall-b57eb157-vs-0f1485fb` went 0.556 → 1.000.
- The tags are assigned by row id (exactly 1,100 tag10 rows per 10K
  block) and are uncorrelated with content: the tag10 share of each
  query's unfiltered top-100 is 0.110 ± 0.032, binomial. Scattered
  broad filters are the easy case; the parent was already at
  0.966–0.972.
- The filtered k-th neighbour sits at unfiltered rank ~11 (90%, k=10),
  ~88 (10%, k=10) and ~900 (10%, k=100) — only the last strains a
  routing budget, which is exactly the one cell that moves.
- The weakest cell, unfiltered k=100 at 0.925, is plain ANN recall and
  untouched by any filtered-search change.

## Files

- `<build>-own-table/all-MiniLM-L6-v2-{100K,1M}.json` — per-cell
  recall mean / p5, under-filled count, p50 / p95 / p99 / mean, qps.
- `same-table-*/`, `isolate-1185/` — the same-table runs above.
