#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: Copyright The Infino Authors
#
# Run one bench selector against two commits of the engine and diff the
# numbers.
#
#   ./scripts/ab.sh --baseline HEAD~1 --candidate HEAD \
#     --table ~/infino-bench/cohere-10m/table \
#     -- filtered-recall corpus=parquet:$HOME/infino-bench/corpora/cohere-10m
#
# Three properties make the comparison mean something. Each one cost a
# wasted multi-hour run to learn; see docs/ab-method.md for the full
# account.
#
#   1. ONE MEASUREMENT HARNESS, TWO ENGINES. Checking out an old commit
#      brings that commit's `benches/` with it, so the two runs would be
#      measured by different code — and a bench that only exists on the
#      newer commit could not run at all. Every phase therefore overlays
#      `benches/` from `--harness-ref` on top of the engine commit. Only
#      the engine differs.
#
#   2. ONE TABLE, REOPENED BY BOTH. A handle that has just built and
#      optimized a table in-process serves differently from one that
#      opened it cold — enough to move numbers the change under test
#      cannot touch. So the table is built once, before either phase,
#      and both phases reopen it.
#
#   3. A CONTROL ROW. Whatever the bench reports that the change cannot
#      affect (for a filtered sweep, the unfiltered row) must come out
#      identical across the two phases. If it moves, something other
#      than the commit moved with it and the run is void.

set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

usage() {
    cat >&2 <<'EOF'
usage: ab.sh --baseline <ref> --candidate <ref> [options] -- <bench selector...>

  --baseline <ref>      engine commit to measure first (the control)
  --candidate <ref>     engine commit to measure second (the change)
  --harness-ref <ref>   tree to take the measurement code from for BOTH
                        phases (default: the candidate)
  --harness-path <p>    path the overlay copies, repeatable
                        (default: benches)
  --table <dir>         table directory both phases reuse. Strongly
                        recommended: without it each phase builds its
                        own, which is slow and reintroduces the
                        freshly-built-handle skew.
  --label <name>        results subdirectory (default: derived from the
                        selector and the date)
  --skip-prepare        do not pre-build the table even if it is missing
  --                    everything after this goes to `cargo bench --`

examples:
  ab.sh --baseline HEAD~1 --candidate HEAD --table ~/t \
    -- filtered-recall corpus=parquet:$HOME/infino-bench/corpora/cohere-10m

  ab.sh --baseline v0.11.19 --candidate main \
    -- supertable vector warm
EOF
}

baseline="" candidate="" harness_ref="" table="" label="" skip_prepare=0
harness_paths=()
bench_args=()
while [[ $# -gt 0 ]]; do
    case $1 in
        --baseline) baseline=$2; shift 2 ;;
        --candidate) candidate=$2; shift 2 ;;
        --harness-ref) harness_ref=$2; shift 2 ;;
        --harness-path) harness_paths+=("$2"); shift 2 ;;
        --table) table=$2; shift 2 ;;
        --label) label=$2; shift 2 ;;
        --skip-prepare) skip_prepare=1; shift ;;
        -h|--help) usage; exit 0 ;;
        --) shift; bench_args=("$@"); break ;;
        *) echo "unknown option: $1" >&2; usage; exit 2 ;;
    esac
done

if [[ -z $baseline || -z $candidate || ${#bench_args[@]} -eq 0 ]]; then
    usage
    exit 2
fi
harness_ref=${harness_ref:-$candidate}
[[ ${#harness_paths[@]} -eq 0 ]] && harness_paths=(benches)

lab_preflight || exit 1

git -C "$INFINO_DIR" rev-parse --verify -q "$baseline^{commit}" >/dev/null || {
    echo "error: --baseline '$baseline' is not a commit in $INFINO_DIR" >&2; exit 2; }
git -C "$INFINO_DIR" rev-parse --verify -q "$candidate^{commit}" >/dev/null || {
    echo "error: --candidate '$candidate' is not a commit in $INFINO_DIR" >&2; exit 2; }
git -C "$INFINO_DIR" rev-parse --verify -q "$harness_ref^{commit}" >/dev/null || {
    echo "error: --harness-ref '$harness_ref' is not a commit in $INFINO_DIR" >&2; exit 2; }

baseline_sha=$(git -C "$INFINO_DIR" rev-parse --short "$baseline")
candidate_sha=$(git -C "$INFINO_DIR" rev-parse --short "$candidate")
harness_sha=$(git -C "$INFINO_DIR" rev-parse --short "$harness_ref")

if [[ -z $label ]]; then
    label="$(date +%Y-%m-%d)-${bench_args[0]//[^a-zA-Z0-9_-]/_}-${baseline_sha}-vs-${candidate_sha}"
fi
run_dir="$LAB_DIR/results/$label"
mkdir -p "$run_dir"

# ─── Restore the engine checkout however we exit ──────────────────────
#
# The phases detach HEAD and overwrite the harness paths in the
# worktree. Everything undone here, LIFO, on every exit path — including
# Ctrl-C — so a killed run never leaves the checkout on a stray commit.

orig_ref=$(git -C "$INFINO_DIR" symbolic-ref --quiet --short HEAD \
    || git -C "$INFINO_DIR" rev-parse HEAD)
stashed=0
if [[ -n $(git -C "$INFINO_DIR" status --porcelain) ]]; then
    echo "[ab] stashing work in progress in $INFINO_DIR"
    git -C "$INFINO_DIR" stash push -q -u -m "ab.sh $label" && stashed=1
fi

metrics_dir="$INFINO_DIR/target/infino-bench"
metrics_backup="$INFINO_DIR/target/infino-bench.ab-backup"
backed_up=0
if [[ -d $metrics_dir ]]; then
    # The report layer MERGES each run into the existing metrics file, so
    # a phase would inherit untouched keys from whatever ran before it.
    # Park the accumulated history and give each phase an empty slate;
    # the history comes back on exit.
    rm -rf "$metrics_backup"
    mv "$metrics_dir" "$metrics_backup"
    backed_up=1
fi
mkdir -p "$metrics_dir"

restore() {
    local status=$?
    echo "[ab] restoring $INFINO_DIR"
    git -C "$INFINO_DIR" reset --hard -q
    git -C "$INFINO_DIR" checkout -q "$orig_ref"
    [[ $stashed -eq 1 ]] && git -C "$INFINO_DIR" stash pop -q
    if [[ $backed_up -eq 1 ]]; then
        rm -rf "$metrics_dir"
        mv "$metrics_backup" "$metrics_dir"
    fi
    exit $status
}
trap restore EXIT INT TERM

# ─── Phases ───────────────────────────────────────────────────────────

# Put the engine at $1 and the measurement harness at $harness_ref.
checkout_phase() {
    local engine=$1
    git -C "$INFINO_DIR" reset --hard -q
    git -C "$INFINO_DIR" checkout -q --detach "$engine"
    git -C "$INFINO_DIR" checkout -q "$harness_ref" -- "${harness_paths[@]}"
}

# Run the bench and keep whatever it produced. A non-zero exit is a
# result, not an error: a bench that gates on a regression is SUPPOSED
# to fail on the baseline, and that is often the whole point of the run.
run_phase() {
    local phase=$1 engine_sha=$2
    local log="$run_dir/$phase.log"
    echo
    echo "[ab] ── $phase: engine $engine_sha, harness $harness_sha ──"
    checkout_phase "$engine_sha"
    rm -f "$metrics_dir"/*.json
    (
        cd "$INFINO_DIR"
        [[ -n $table ]] && export INFINO_BENCH_FILTERED_RECALL_TABLE="$table"
        cargo bench --bench bench -- "${bench_args[@]}"
    ) 2>&1 | tee "$log"
    local status=${PIPESTATUS[0]}
    mkdir -p "$run_dir/$phase"
    cp "$metrics_dir"/*.json "$run_dir/$phase/" 2>/dev/null || true
    echo "$status" > "$run_dir/$phase/exit-code"
    echo "[ab] $phase finished (exit $status); log + metrics in $run_dir/$phase"
}

{
    echo "label:      $label"
    echo "baseline:   $baseline ($baseline_sha)"
    echo "candidate:  $candidate ($candidate_sha)"
    echo "harness:    $harness_ref ($harness_sha)"
    echo "selector:   ${bench_args[*]}"
    echo "table:      ${table:-<per-phase temporary>}"
    echo "host:       $(uname -sm), $(nproc) cpus"
    echo "started:    $(date -Is)"
} | tee "$run_dir/run.txt"

# Build the table once, before either phase, so both phases reopen it.
if [[ -n $table && $skip_prepare -eq 0 ]]; then
    if [[ -e $table/_supertable/current ]]; then
        echo "[ab] table already built at $table"
    else
        echo "[ab] preparing the table at $table (once, before both phases)"
        run_phase prepare "$candidate_sha"
    fi
fi

run_phase baseline "$baseline_sha"
run_phase candidate "$candidate_sha"

echo
python3 "$LAB_DIR/scripts/compare.py" \
    --baseline-dir "$run_dir/baseline" \
    --candidate-dir "$run_dir/candidate" \
    --baseline-name "$baseline ($baseline_sha)" \
    --candidate-name "$candidate ($candidate_sha)" \
    --out "$run_dir/comparison.md" | tee -a "$run_dir/run.txt"

echo
echo "[ab] results: $run_dir"
