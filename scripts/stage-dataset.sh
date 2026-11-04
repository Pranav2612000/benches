#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: Copyright The Infino Authors
#
# Stage a real embedding dataset as a directory of parquet shards, which
# is what `corpus=parquet:<dir>` consumes.
#
# The directory name becomes the corpus label in every report and in the
# oracle cache key, so it is named for the dataset rather than for
# whatever directory the files arrived in.
#
#   ./scripts/stage-dataset.sh                 # cohere-10m (default)
#   ./scripts/stage-dataset.sh cohere-1m
#   ./scripts/stage-dataset.sh --list

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

# ─── Catalogue ────────────────────────────────────────────────────────
#
# name|base url|shard count|rows|dim
#
# Published embedding datasets with a stable layout of
# `train-NN-of-NN.parquet` shards carrying `id` and `emb` columns. Shard
# names are derived, not listed, so adding a dataset is one line.
DATASETS=(
    "cohere-10m|https://assets.zilliz.com/benchmark/cohere_large_10m|10|10000000|768"
    "cohere-1m|https://assets.zilliz.com/benchmark/cohere_medium_1m|1|1000000|768"
    "openai-5m|https://assets.zilliz.com/benchmark/openai_large_5m|10|5000000|1536"
)

usage() {
    cat >&2 <<EOF
usage: $(basename "$0") [dataset] [--dir <path>]

Stages a dataset as parquet shards for \`corpus=parquet:<dir>\`.
Re-running is cheap: present shards are left alone.

  dataset     one of the names below (default: cohere-10m)
  --dir       where to stage (default: \$LAB_DATA_DIR/corpora/<dataset>)
  --list      print the catalogue and exit

Datasets:
EOF
    local entry name rows dim shards
    for entry in "${DATASETS[@]}"; do
        IFS='|' read -r name _ shards rows dim <<<"$entry"
        printf '  %-12s %s rows x %s dims, %s shards\n' "$name" "$rows" "$dim" "$shards" >&2
    done
}

dataset=cohere-10m
dir=""
while [[ $# -gt 0 ]]; do
    case $1 in
        --list|-h|--help) usage; exit 0 ;;
        --dir) dir=$2; shift 2 ;;
        -*) echo "unknown option: $1" >&2; usage; exit 2 ;;
        *) dataset=$1; shift ;;
    esac
done

entry=""
for candidate in "${DATASETS[@]}"; do
    [[ ${candidate%%|*} == "$dataset" ]] && entry=$candidate && break
done
if [[ -z $entry ]]; then
    echo "error: unknown dataset '$dataset'" >&2
    usage
    exit 2
fi
IFS='|' read -r name base shards rows dim <<<"$entry"
dir=${dir:-$LAB_DATA_DIR/corpora/$name}

lab_require curl "Install curl." || exit 1
mkdir -p "$dir"

echo "[stage] $name: $rows rows x $dim dims, $shards shards -> $dir"
echo "[stage] free space on target: $(lab_free_space "$dir")"

for ((i = 0; i < shards; i++)); do
    shard=$(printf 'train-%02d-of-%02d.parquet' "$i" "$shards")
    if [[ -s $dir/$shard ]]; then
        echo "[stage]   $shard present"
        continue
    fi
    echo "[stage]   fetching $shard..."
    # Download to .part and rename, so an interrupted transfer never
    # leaves a truncated file that later reads as a short corpus.
    curl -fsS --retry 3 -o "$dir/$shard.part" "$base/$shard"
    mv -f "$dir/$shard.part" "$dir/$shard"
done

echo "[stage] done: $(du -sh "$dir" | cut -f1) in $dir"
echo
echo "Use it with:"
echo "  corpus=parquet:$dir"
