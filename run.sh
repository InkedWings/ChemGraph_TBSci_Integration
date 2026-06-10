#!/usr/bin/env bash
# run.sh — invoke `harbor run` with the right flags for our chemistry task.
#
# Defaults to the `chemgraph` agent (batch mode) over the 5-query pilot.
# Override with --agent / --task / --model. See `./run.sh --help`.
#
# By default, when running the `chemgraph` agent, this script also tails the
# chemgraph batch runner's progress log so you can watch each query land
# (e.g. "[3/5] id=8 cat=dipole_from_name ... -> ok in 45.4s") instead of
# staring at harbor's spinner. Pass --quiet to disable this and fall back
# to harbor's native output.

set -euo pipefail

HERE="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
cd "$HERE"

# --------------------------------------------------------------------------- #
# load .env (must contain ARGO_USER)
# --------------------------------------------------------------------------- #
if [ ! -f .env ]; then
    echo "error: .env not found. Run: cp .env.example .env  and fill in ARGO_USER." >&2
    exit 1
fi
# shellcheck disable=SC1091
set -a; . ./.env; set +a

: "${ARGO_USER:?ARGO_USER must be set in .env}"
: "${MODEL:=argo:o4-mini}"
: "${PER_QUERY_TIMEOUT_SEC:=600}"

# --------------------------------------------------------------------------- #
# defaults + flag parsing
# --------------------------------------------------------------------------- #

AGENT="chemgraph"
TASK_PATH="${HERE}/terminal-bench-science/tasks/physical-sciences/chemistry-and-materials/chemgraph-eval-suite-lite"
MODEL_OVERRIDE=""
SHOW_PROGRESS=true

usage() {
    cat <<EOF
usage: ./run.sh [--agent NAME] [--task PATH] [--model MODEL] [--quiet]

Defaults:
  --agent  chemgraph
  --task   ${TASK_PATH#${HERE}/}
  --model  ${MODEL}  (from .env)

Behavior:
  By default, for the chemgraph agent, per-query progress is streamed to your
  terminal (init time, each query's elapsed seconds, etc.) so you can see what
  the agent is doing. Use --quiet to disable and fall back to harbor's spinner.
  Non-chemgraph agents always use harbor's native output (no batch progress log).

Examples:
  ./run.sh                                  # chemgraph @ argo:o4-mini, stream progress
  ./run.sh --quiet                          # chemgraph, just harbor's spinner
  ./run.sh --agent oracle                   # run the reference solution
  ./run.sh --agent claude-code -m argo:claude-opus-4.6
  ./run.sh --model argo:gpt-5               # try a stronger model
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        -a|--agent) AGENT="$2"; shift 2 ;;
        -p|--task)  TASK_PATH="$2"; shift 2 ;;
        -m|--model) MODEL_OVERRIDE="$2"; shift 2 ;;
        -q|--quiet) SHOW_PROGRESS=false; shift ;;
        -h|--help)  usage; exit 0 ;;
        *)          echo "unknown flag: $1"; usage; exit 1 ;;
    esac
done

[ -n "$MODEL_OVERRIDE" ] && MODEL="$MODEL_OVERRIDE"

# --------------------------------------------------------------------------- #
# sanity checks
# --------------------------------------------------------------------------- #
[ -d "$TASK_PATH" ]                  || { echo "task path not found: $TASK_PATH" >&2; exit 1; }
[ -d "${HERE}/harbor/.venv" ]        || { echo "harbor not synced yet. Run: ./setup.sh" >&2; exit 1; }
docker image inspect chemgraph-arm:latest >/dev/null 2>&1 \
    || { echo "chemgraph-arm:latest image missing. Run: ./setup.sh" >&2; exit 1; }

# --------------------------------------------------------------------------- #
# build harbor args
#
# --ae forwards env to the AGENT container; --ve to the VERIFIER container.
# Both need ARGO_USER (chemgraph reads it; verifier's LLM judge reads it).
# OPENAI_API_KEY is set to the same string because langchain_openai's
# ChatOpenAI requires a non-empty api_key field even when Argo authenticates
# via the `user` field instead.
# --------------------------------------------------------------------------- #

COMMON_ENV=(
    --ae "ARGO_USER=${ARGO_USER}"
    --ae "OPENAI_API_KEY=${ARGO_USER}"
    --ve "ARGO_USER=${ARGO_USER}"
    --ve "OPENAI_API_KEY=${ARGO_USER}"
)

if [ "$AGENT" = "chemgraph" ]; then
    AGENT_KWARGS=(
        --agent-kwarg "mode=batch"
        --agent-kwarg "queries_path=/root/data/queries.json"
        --agent-kwarg "output_path=/root/results/answers.json"
        --agent-kwarg "per_query_timeout_sec=${PER_QUERY_TIMEOUT_SEC}"
    )
else
    AGENT_KWARGS=()
fi

# --------------------------------------------------------------------------- #
# go
# --------------------------------------------------------------------------- #

echo "==> harbor run -a ${AGENT} -m ${MODEL}"
echo "    task:  ${TASK_PATH}"
echo "    ARGO_USER=${ARGO_USER}"
echo

# Quiet mode, or any non-chemgraph agent: just exec harbor and let it own
# the terminal. No streaming.
if [ "$SHOW_PROGRESS" = false ] || [ "$AGENT" != "chemgraph" ]; then
    cd "$HERE/harbor"
    exec uv run harbor run \
        -p "$TASK_PATH" \
        -a "$AGENT" \
        -m "$MODEL" \
        "${COMMON_ENV[@]}" \
        "${AGENT_KWARGS[@]}"
fi

# --------------------------------------------------------------------------- #
# Streaming mode (default for chemgraph): run harbor in the background, find
# the chemgraph_batch.log it writes inside the new trial dir, and tail it.
#
# We anchor "new" using a marker file so we don't accidentally tail a stale
# log from a previous run.
# --------------------------------------------------------------------------- #

JOBS_DIR="${HERE}/harbor/jobs"
mkdir -p "$JOBS_DIR"
MARKER="$(mktemp -t chemgraph-run-marker.XXXXXX)"  # mtime = "run start"
HARBOR_LOG="$(mktemp -t chemgraph-harbor-log.XXXXXX)"

cleanup() {
    local rc=$?
    # Kill background harbor + tail if still alive, then remove temp files.
    [ -n "${TAIL_PID:-}" ] && kill "$TAIL_PID" 2>/dev/null || true
    [ -n "${HARBOR_PID:-}" ] && kill -0 "$HARBOR_PID" 2>/dev/null && {
        kill "$HARBOR_PID" 2>/dev/null || true
        wait "$HARBOR_PID" 2>/dev/null || true
    }
    rm -f "$MARKER" "$HARBOR_LOG"
    exit $rc
}
trap cleanup EXIT INT TERM

# Launch harbor in the background. Output goes to a temp log so we can show
# the final reward table at the end without interleaving with the tailed
# batch progress.
(
    cd "$HERE/harbor"
    uv run harbor run \
        -p "$TASK_PATH" \
        -a "$AGENT" \
        -m "$MODEL" \
        "${COMMON_ENV[@]}" \
        "${AGENT_KWARGS[@]}"
) > "$HARBOR_LOG" 2>&1 &
HARBOR_PID=$!

# Poll for the new chemgraph_batch.log. Harbor takes ~10-60s for the first
# build + container start before the batch runner writes its first line.
echo "==> waiting for chemgraph batch runner to start..."
BATCH_LOG=""
for _ in $(seq 1 180); do  # up to 3 min
    BATCH_LOG=$(
        find "$JOBS_DIR" -name 'chemgraph_batch.log' -newer "$MARKER" 2>/dev/null \
            | head -1
    )
    if [ -n "$BATCH_LOG" ] && [ -s "$BATCH_LOG" ]; then
        break
    fi
    # If harbor itself died early, bail out of the wait loop.
    if ! kill -0 "$HARBOR_PID" 2>/dev/null; then
        BATCH_LOG=""
        break
    fi
    sleep 1
done

if [ -n "$BATCH_LOG" ]; then
    echo "==> tailing $BATCH_LOG"
    echo
    # tail -n +1 -f starts from the first byte so we don't miss early lines.
    tail -n +1 -f "$BATCH_LOG" &
    TAIL_PID=$!
else
    echo "==> note: chemgraph_batch.log never appeared; showing harbor output instead." >&2
fi

# Wait for harbor to finish (this is what blocks the script).
wait "$HARBOR_PID"
HARBOR_EXIT=$?

# Give the tail a beat to flush the last lines, then stop it.
if [ -n "${TAIL_PID:-}" ]; then
    sleep 1
    kill "$TAIL_PID" 2>/dev/null || true
    wait "$TAIL_PID" 2>/dev/null || true
    TAIL_PID=""
fi

# Show harbor's summary (reward table, runtime, jobs path).
echo
echo "==> harbor summary:"
tail -25 "$HARBOR_LOG"

HARBOR_PID=""  # so cleanup() doesn't try to kill an already-exited process
exit "$HARBOR_EXIT"
