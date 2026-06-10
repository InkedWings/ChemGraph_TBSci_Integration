#!/usr/bin/env bash
# setup.sh — one-shot environment bring-up for the ChemGraph × TB-Science integration.
#
# What this does, in order:
#   1. Sanity check host tools: git, docker, uv.
#   2. Clone the three repos as siblings under this directory:
#        ./harbor                   (your fork, add-chemgraph-agent branch)
#        ./terminal-bench-science   (your fork, add-chemgraph-eval-suite-lite branch)
#        ./ChemGraph                (upstream, main)
#   3. `uv sync` inside harbor so `uv run harbor` works.
#   4. Build the `chemgraph-arm:latest` (or `chemgraph-amd:latest`) docker image
#      that the task's environment Dockerfile FROMs. Architecture is auto-detected.
#
# Idempotent: re-running skips work that is already done. Safe to run after
# `git pull` updates.

set -euo pipefail

# Resolve the directory this script lives in (works regardless of CWD).
HERE="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
cd "$HERE"

# Load .env if present so we can use ARGO_USER for the optional smoke test.
if [ -f .env ]; then
    # shellcheck disable=SC1091
    set -a; . ./.env; set +a
fi

HARBOR_REPO_URL="https://github.com/InkedWings/Harbor_ChemGraph.git"
HARBOR_BRANCH="add-chemgraph-agent"
HARBOR_DIR="harbor"

TBSCI_REPO_URL="https://github.com/InkedWings/TB_Sci_ChemGraph.git"
TBSCI_BRANCH="add-chemgraph-eval-suite-lite"
TBSCI_DIR="terminal-bench-science"

CHEMGRAPH_REPO_URL="https://github.com/argonne-lcf/ChemGraph.git"
CHEMGRAPH_BRANCH="main"
CHEMGRAPH_DIR="ChemGraph"

log()  { printf '\033[1;34m[setup]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn ]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[fail ]\033[0m %s\n' "$*" >&2; exit 1; }

# --------------------------------------------------------------------------- #
# 1. host tool checks
# --------------------------------------------------------------------------- #

log "checking host tools..."

command -v git    >/dev/null 2>&1 || die "git not found in PATH"
command -v docker >/dev/null 2>&1 || die "docker not found in PATH"
command -v uv     >/dev/null 2>&1 || die "uv not found; install with: curl -LsSf https://astral.sh/uv/install.sh | sh"

if ! docker info >/dev/null 2>&1; then
    die "docker daemon is not running (start Docker Desktop / colima / podman first)"
fi

log "host tools ok (git $(git --version | awk '{print $3}'), docker $(docker --version | awk '{print $3}' | tr -d ','), uv $(uv --version | awk '{print $2}'))"

# --------------------------------------------------------------------------- #
# 2. clone or update the three repos
# --------------------------------------------------------------------------- #

clone_or_update() {
    local url="$1" branch="$2" dir="$3"
    if [ -d "$dir/.git" ]; then
        log "${dir}: already cloned — fetching and checking out ${branch}"
        git -C "$dir" fetch origin "$branch" --quiet
        git -C "$dir" checkout "$branch" --quiet
        git -C "$dir" pull --ff-only origin "$branch" --quiet || \
            warn "${dir}: pull --ff-only refused (local diverges from origin); leaving as-is"
    else
        log "${dir}: cloning ${url} (branch ${branch}) ..."
        git clone --branch "$branch" "$url" "$dir"
    fi
}

clone_or_update "$HARBOR_REPO_URL"    "$HARBOR_BRANCH"    "$HARBOR_DIR"
clone_or_update "$TBSCI_REPO_URL"     "$TBSCI_BRANCH"     "$TBSCI_DIR"
clone_or_update "$CHEMGRAPH_REPO_URL" "$CHEMGRAPH_BRANCH" "$CHEMGRAPH_DIR"

# --------------------------------------------------------------------------- #
# 3. uv sync inside harbor
# --------------------------------------------------------------------------- #

log "syncing harbor python deps via uv ..."
( cd "$HARBOR_DIR" && uv sync --all-extras --dev --quiet )
log "harbor cli ready: $(cd "$HARBOR_DIR" && uv run harbor --version 2>/dev/null | head -1 || echo '(version unknown)')"

# --------------------------------------------------------------------------- #
# 4. build the chemgraph base docker image
#
# The task's environment Dockerfile starts with `FROM chemgraph-arm:latest`
# (a name we picked when first building this on ARM). To stay compatible on
# x86 hosts we ALSO tag the image as `chemgraph-arm:latest` even if the
# underlying source was Dockerfile (amd64). Architecture only changes which
# Dockerfile we pass to `docker build`, not the resulting tag.
# --------------------------------------------------------------------------- #

ARCH="$(uname -m)"
case "$ARCH" in
    arm64|aarch64)  CHEMGRAPH_DOCKERFILE="Dockerfile.arm" ;;
    x86_64|amd64)   CHEMGRAPH_DOCKERFILE="Dockerfile" ;;
    *)              die "unsupported architecture: $ARCH" ;;
esac

IMAGE_TAG="chemgraph-arm:latest"

if docker image inspect "$IMAGE_TAG" >/dev/null 2>&1; then
    log "${IMAGE_TAG} already present locally — skipping build"
    log "  (delete with: docker rmi ${IMAGE_TAG}  if you want a clean rebuild)"
else
    log "building ${IMAGE_TAG} from ChemGraph/${CHEMGRAPH_DOCKERFILE} (~15-25 min)..."
    log "  this is the heavy step: conda installs nwchem, pip installs torch+mace+chemistry libs,"
    log "  and tblite is built from source. Output is verbose — that's expected."
    docker build \
        -f "$CHEMGRAPH_DIR/$CHEMGRAPH_DOCKERFILE" \
        -t "$IMAGE_TAG" \
        "$CHEMGRAPH_DIR"
fi

# --------------------------------------------------------------------------- #
# done
# --------------------------------------------------------------------------- #

log "setup complete."
log ""
log "next steps:"
log "  1. cp .env.example .env   # if you haven't already"
log "  2. edit .env to set ARGO_USER (your ANL username)"
log "  3. ./run.sh               # runs the chemgraph agent over the 5-query pilot"
log ""
log "verify the image is OK:"
log "  docker run --rm ${IMAGE_TAG} python -c 'import chemgraph; print(chemgraph.__version__)'"
