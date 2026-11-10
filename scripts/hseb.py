#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: Copyright The Infino Authors
"""Run Infino against the HSEB MS MARCO filtered-vector benchmark.

Dataset: https://huggingface.co/datasets/hseb-benchmark/msmarco

Each corpus row carries nested selectivity tags (a row tagged 10 is also
tagged 90 and 100), and each query ships the exact top-100 under each
filter. "Hybrid" in HSEB means kNN restricted by a tag predicate. Here
the tags are an FTS-indexed column and the predicate is pushed down
through `vector_search(filter_column=..., filter_query=...)`.

  hseb.py build --model all-MiniLM-L6-v2 --size 1M
  hseb.py query --model all-MiniLM-L6-v2 --size 1M --out results/x.json

Raw files are expected under $LAB_DATA_DIR/hseb/raw/<model>/<size>/
(corpus.jsonl.gz, queries.jsonl.gz — the dataset's
data/<model>/<size>/ files, e.g. via
`huggingface-cli download hseb-benchmark/msmarco --repo-type dataset
--include "data/all-MiniLM-L6-v2/1M/*"`); tables go to
$LAB_DATA_DIR/hseb/tables/[<label>-]<model>-<size>. `--label` keeps one
table per engine build, so two builds of infino can each build their own
or query the same one.

Needs: infino (the wheel under test), pyarrow, numpy, orjson.

`optimize()` leaves the pre-optimize segments on disk until `gc()` runs,
so measure on-disk size after `t.gc(0)`.
"""

import argparse
import gzip
import json
import os
import platform
import sys
import time
from pathlib import Path

import numpy as np
import orjson
import pyarrow as pa

import infino

DIMS = {"all-MiniLM-L6-v2": 384, "e5-base-v2": 768, "Qwen3-Embedding-4B": 2560}
SELECTIVITIES = (100, 90, 10)
LAB = Path(os.environ.get("LAB_DATA_DIR", Path.home() / "infino-bench"))


def paths(model, size, label=""):
    raw = LAB / "hseb" / "raw" / model / size
    name = f"{label}-{model}-{size}" if label else f"{model}-{size}"
    return raw / "corpus.jsonl.gz", raw / "queries.jsonl.gz", LAB / "hseb" / "tables" / name


def log(*a):
    print(f"[hseb {time.strftime('%H:%M:%S')}]", *a, flush=True)


def build(args):
    corpus, _, table_dir = paths(args.model, args.size, args.label)
    dim = DIMS[args.model]
    if table_dir.exists():
        sys.exit(f"{table_dir} exists; remove it to rebuild")
    table_dir.mkdir(parents=True)
    db = infino.connect(str(table_dir))
    schema = pa.schema([
        pa.field("id", pa.int64(), nullable=False),
        pa.field("tags", pa.large_utf8(), nullable=False),
        pa.field("embedding", pa.list_(pa.float32(), dim), nullable=False),
    ])
    t = db.create_table("hseb", schema, infino.IndexSpec().fts("tags").vector("embedding", dim, "cosine"))

    def flush(ids, tags, embs):
        emb = pa.FixedSizeListArray.from_arrays(pa.array(np.asarray(embs, dtype=np.float32).ravel()), dim)
        t.append(pa.Table.from_arrays([pa.array(ids, pa.int64()), pa.array(tags, pa.large_utf8()), emb], schema=schema))

    t0 = time.perf_counter()
    ids, tags, embs, n, append_s = [], [], [], 0, 0.0
    with gzip.open(corpus, "rb") as f:
        for line in f:
            d = orjson.loads(line)
            ids.append(d["id"])
            tags.append(" ".join(f"tag{x}" for x in d["tag"]))
            embs.append(d["embedding"])
            if len(ids) == args.batch:
                a = time.perf_counter(); flush(ids, tags, embs); append_s += time.perf_counter() - a
                n += len(ids); ids, tags, embs = [], [], []
                log(f"appended {n:,} rows")
    if ids:
        a = time.perf_counter(); flush(ids, tags, embs); append_s += time.perf_counter() - a
        n += len(ids)
    load_s = time.perf_counter() - t0
    log(f"{n:,} rows loaded in {load_s:.0f}s ({append_s:.0f}s inside append); optimizing")
    a = time.perf_counter()
    t.optimize()
    opt_s = time.perf_counter() - a
    log(f"optimize {opt_s:.0f}s")
    counts = {s: t.count("tags", f"tag{s}") for s in SELECTIVITIES}
    log("tag counts", counts)
    (table_dir / "build.json").write_text(json.dumps({
        "rows": n, "load_and_append_s": load_s, "append_s": append_s, "optimize_s": opt_s,
        "tag_counts": counts, "infino": infino.__version__,
    }, indent=2))


def load_queries(path, limit):
    qs = []
    with gzip.open(path, "rb") as f:
        for line in f:
            d = orjson.loads(line)
            qs.append((d["id"], np.asarray(d["embedding"], dtype=np.float32),
                       {s: d[f"results_{s}_docs"] for s in SELECTIVITIES}))
            if limit and len(qs) == limit:
                break
    return qs


def query(args):
    _, qpath, table_dir = paths(args.model, args.size, args.label)
    db = infino.connect(str(table_dir))
    t = db.open_table("hseb")
    qs = load_queries(qpath, args.limit)
    log(f"{len(qs):,} queries")

    def search(vec, k, sel):
        kw = {} if sel == 100 else {"filter_column": "tags", "filter_query": f"tag{sel}"}
        return t.vector_search("embedding", vec.tolist(), k, projection=["id"], **kw).column("id").to_pylist()

    # Warm the cache and any lazily-opened state on queries we then also
    # measure; the first pass over a fresh process is not what steady state
    # looks like.
    for _, vec, _ in qs[: args.warmup]:
        for sel in SELECTIVITIES:
            search(vec, max(args.k), sel)

    report = {"model": args.model, "size": args.size, "infino": infino.__version__, "label": args.label,
              "host": {"cpu": platform.processor() or platform.machine(), "cores": os.cpu_count()},
              "build": json.loads((table_dir / "build.json").read_text()), "cells": []}
    for k in args.k:
        for sel in SELECTIVITIES:
            lat, recall, short = [], [], 0
            for _, vec, gt in qs:
                a = time.perf_counter()
                got = search(vec, k, sel)
                lat.append(time.perf_counter() - a)
                truth = set(gt[sel][:k])
                recall.append(len(truth.intersection(got)) / k)
                short += len(got) < k
            lat_ms = np.asarray(lat) * 1e3
            cell = {"k": k, "selectivity": sel, "queries": len(qs),
                    "recall_mean": float(np.mean(recall)),
                    "recall_p5": float(np.percentile(recall, 5)),
                    "under_filled": short,
                    "p50_ms": float(np.percentile(lat_ms, 50)), "p95_ms": float(np.percentile(lat_ms, 95)),
                    "p99_ms": float(np.percentile(lat_ms, 99)), "mean_ms": float(lat_ms.mean()),
                    "qps_1thread": float(len(lat) / lat_ms.sum() * 1e3)}
            report["cells"].append(cell)
            log(f"k={k:<3} sel={sel:>3}%  recall={cell['recall_mean']:.4f}  p50={cell['p50_ms']:.2f}ms  "
                f"p99={cell['p99_ms']:.2f}ms  under-filled={short}")
    if args.out:
        Path(args.out).parent.mkdir(parents=True, exist_ok=True)
        Path(args.out).write_text(json.dumps(report, indent=2))
        log("wrote", args.out)


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    for name in ("build", "query"):
        s = sub.add_parser(name)
        s.add_argument("--model", default="all-MiniLM-L6-v2", choices=DIMS)
        s.add_argument("--size", default="1M", choices=["1K", "100K", "1M"])
        s.add_argument("--label", default="", help="engine build label; each label gets its own table")
    sub.choices["build"].add_argument("--batch", type=int, default=100_000)
    q = sub.choices["query"]
    q.add_argument("--k", type=int, nargs="+", default=[10, 100])
    q.add_argument("--limit", type=int, default=0, help="first N queries only (0 = all 10K)")
    q.add_argument("--warmup", type=int, default=200)
    q.add_argument("--out")
    args = p.parse_args()
    build(args) if args.cmd == "build" else query(args)


if __name__ == "__main__":
    main()
