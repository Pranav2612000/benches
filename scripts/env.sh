# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: Copyright The Infino Authors
#
# Shared environment + preflight for every script here. Sourced, not run.
#
# Everything in this file exists because a run failed without it. Each
# export says which failure it prevents, so none of it is cargo cult.

# ─── Layout ───────────────────────────────────────────────────────────
#
# These scripts live in a sibling of `infino/` under the workspace
# umbrella. `INFINO_DIR` overrides that for a checkout elsewhere.

LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKSPACE_DIR="$(cd "$LAB_DIR/.." && pwd)"
INFINO_DIR="${INFINO_DIR:-$WORKSPACE_DIR/infino}"
export LAB_DIR WORKSPACE_DIR INFINO_DIR

# Where datasets are staged and where tables get built. Both are large
# (tens of GiB); keep them off the repo and off any small volume.
LAB_DATA_DIR="${LAB_DATA_DIR:-$HOME/infino-bench}"
export LAB_DATA_DIR

# ─── Scratch ──────────────────────────────────────────────────────────
#
# The engine's drain writes scratch under the system temp dir
# (`storage.scratch_root`, which defaults to it). On a shared host
# `/tmp/infino-drain` may already exist owned by another user, and the
# drain then dies with "drain scratch create: Permission denied" twenty
# minutes into a build. A private temp dir avoids that, and also keeps
# the corpus mmap (tens of GiB, created via TempDir) on a volume you
# chose rather than on whatever /tmp happens to be.
export TMPDIR="${TMPDIR_OVERRIDE:-$LAB_DATA_DIR/tmp}"
mkdir -p "$TMPDIR"

# ─── Open files ───────────────────────────────────────────────────────
#
# Benches mmap many files at once and exhaust the default 1024 soft
# limit (EMFILE, surfacing as a panic inside the vector builder).
ulimit -n 65536 2>/dev/null || ulimit -n "$(ulimit -Hn)" 2>/dev/null || true

# ─── Toolchain ────────────────────────────────────────────────────────
#
# Cron and other minimal-PATH contexts don't see cargo. `~/.local/bin`
# is on the path because `cmake` is often installed there via
# `pip install --user cmake` — the bench crate builds a vendored HDF5
# through cmake, and without it `cargo bench` fails at the build script
# with "is `cmake` not installed?".
export PATH="$HOME/.cargo/bin:$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin:${PATH:-}"

# ─── Preflight ────────────────────────────────────────────────────────

lab_require() {
    local tool=$1 hint=$2
    command -v "$tool" >/dev/null 2>&1 && return 0
    echo "error: '$tool' not found on PATH. $hint" >&2
    return 1
}

lab_preflight() {
    local failed=0
    lab_require cargo "Install Rust: https://rustup.rs" || failed=1
    lab_require cmake "pip install --user cmake (the bench crate builds a vendored HDF5)" || failed=1
    lab_require git "Install git." || failed=1
    if [[ ! -d $INFINO_DIR/.git ]]; then
        echo "error: no infino checkout at $INFINO_DIR (set INFINO_DIR)." >&2
        failed=1
    fi
    return $failed
}

# Human-readable free space on the filesystem holding a path.
lab_free_space() {
    df -h "$1" 2>/dev/null | awk 'NR==2 {print $4}'
}
