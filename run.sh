#!/usr/bin/env bash
# run.sh — invoke `harbor run` with the right flags for our chemistry task.
#
# Defaults to the `chemgraph` agent (batch mode) over the 5-query pilot.
# Override with --agent / --task / --model. See `./run.sh --help`.

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

usage() {
    cat <<EOF
usage: ./run.sh [--agent NAME] [--task PATH] [--model MODEL]

Defaults:
  --agent  chemgraph
  --task   ${TASK_PATH#${HERE}/}
  --model  ${MODEL}  (from .env)

Common variations:
  ./run.sh                                  # chemgraph @ argo:o4-mini, batch over 5 queries
  ./run.sh --agent oracle                   # run the reference solution (always reward=1.0 if task is self-consistent)
  ./run.sh --agent claude-code -m argo:claude-opus-4.6
  ./run.sh --model argo:gpt-5               # try a stronger model
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        -a|--agent) AGENT="$2"; shift 2 ;;
        -p|--task)  TASK_PATH="$2"; shift 2 ;;
        -m|--model) MODEL_OVERRIDE="$2"; shift 2 ;;
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

cd "$HERE/harbor"
exec uv run harbor run \
    -p "$TASK_PATH" \
    -a "$AGENT" \
    -m "$MODEL" \
    "${COMMON_ENV[@]}" \
    "${AGENT_KWARGS[@]}"
