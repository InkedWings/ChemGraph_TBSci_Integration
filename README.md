# ChemGraph × Terminal-Bench Science Integration

End-to-end harness that lets you evaluate the [ChemGraph](https://github.com/argonne-lcf/ChemGraph) agent on a [Terminal-Bench Science](https://github.com/harbor-framework/terminal-bench-science)-style chemistry task using the [Harbor](https://github.com/laude-institute/harbor) framework.

This meta-repo glues three pieces together:

| Piece | Source | Role |
|-------|--------|------|
| **Harbor (with chemgraph agent)** | [InkedWings/Harbor_ChemGraph](https://github.com/InkedWings/Harbor_ChemGraph) (`add-chemgraph-agent`) | The runtime / CLI. Adds a `chemgraph` agent so `harbor run -a chemgraph` works. |
| **TB-Science task** | [InkedWings/TB_Sci_ChemGraph](https://github.com/InkedWings/TB_Sci_ChemGraph) (`add-chemgraph-eval-suite-lite`) | A 5-query computational-chemistry pilot task (SMILES lookup, MACE-MP optimization, GFN2-xTB dipole / thermo, reaction energy). |
| **ChemGraph** | [argonne-lcf/ChemGraph](https://github.com/argonne-lcf/ChemGraph) (`main`) | The agent framework being evaluated. Used unchanged. |

## Prerequisites

| Tool | Notes |
|------|-------|
| **git** | any recent version |
| **docker** | Docker Desktop / colima / podman — daemon must be running |
| **uv** | install: `curl -LsSf https://astral.sh/uv/install.sh \| sh` |
| **~10 GB disk** | for the chemgraph base image |
| **Argo access** | requires Argonne network (on-site or VPN) and a valid ANL username |

Architecture is auto-detected:
- Apple Silicon / ARM Linux → `ChemGraph/Dockerfile.arm`
- x86_64 Linux → `ChemGraph/Dockerfile`

## Quick Start

```bash
git clone https://github.com/InkedWings/ChemGraph_TBSci_Integration.git
cd ChemGraph_TBSci_Integration

cp .env.example .env
# Edit .env: set ARGO_USER to your ANL username (e.g. `jsmith`)

./setup.sh   # ~15-25 min on first run (mostly the chemgraph docker build)
./run.sh     # ~5-10 min: chemgraph solves the 5 pilot queries via Argo
```

A successful end-to-end run ends with something like:

```
adhoc • chemgraph • argo:o4-mini
┏━━━━━━━━┳━━━━━━━━━━━━┳━━━━━━━┓
┃ Trials ┃ Exceptions ┃  Mean ┃
┡━━━━━━━━╇━━━━━━━━━━━━╇━━━━━━━┩
│      1 │          0 │ 1.000 │
└────────┴────────────┴───────┘
Total runtime: 6m 7s
Results written to harbor/jobs/<timestamp>/result.json
```

## Layout After `setup.sh`

```
ChemGraph_TBSci_Integration/
├── README.md                       (you are here)
├── setup.sh                        bootstraps everything below
├── run.sh                          invokes `harbor run` with the right flags
├── .env                            your ANL username + model choice (git-ignored)
├── .env.example                    template
│
├── harbor/                         InkedWings/Harbor_ChemGraph (add-chemgraph-agent)
│   └── src/harbor/agents/installed/chemgraph.py   ← the chemgraph agent
│
├── terminal-bench-science/         InkedWings/TB_Sci_ChemGraph (add-chemgraph-eval-suite-lite)
│   └── tasks/physical-sciences/chemistry-and-materials/
│       └── chemgraph-eval-suite-lite/             ← the task
│
└── ChemGraph/                      argonne-lcf/ChemGraph (main)
    └── (used only to build the chemgraph-arm:latest docker image)
```

## Common Operations

```bash
# Default: chemgraph agent, argo:o4-mini, batch over 5 queries.
./run.sh

# Try a stronger model.
./run.sh --model argo:gpt-5

# Run the oracle (always 1.0 if the task is self-consistent — useful for sanity).
./run.sh --agent oracle

# Cross-check against Claude Code (TB-Science also tests with this).
./run.sh --agent claude-code --model argo:claude-opus-4.6

# Help.
./run.sh --help

# Inspect a past trial.
cd harbor && uv run harbor view jobs
```

Per-query traces (tool calls, token usage, judge rationales) land in:
- `harbor/jobs/<timestamp>/chemgraph-eval-suite-lite__<id>/agent/chemgraph_batch.log`
- `harbor/jobs/<timestamp>/chemgraph-eval-suite-lite__<id>/verifier/trace_judge.json`

## How the Whole Thing Hangs Together

```
./run.sh -a chemgraph -m argo:o4-mini
        │
        ▼
  harbor run         (Python CLI, lives in harbor/.venv)
        │
        ▼
  build agent image      (FROM chemgraph-arm:latest + COPY queries.json)
  build verifier image   (FROM ubuntu:24.04 + pip pytest rdkit pydantic langchain-openai)
        │
        ▼
  agent container ─────► chemgraph batch runner
                         (single Python process; ChemGraph() init once,
                          run() per query; calls Argo through langchain;
                          uses ase / rdkit / mace-torch / tblite / pubchempy)
        │
        ▼ writes /root/results/answers.json
        │
        ▼ harbor tears down agent, copies answers.json into verifier container
        │
        ▼
  verifier container ──► pytest over ground_truth.json
                         - structured judge (5% rtol, RDKit canonical) → reward
                         - LLM judge (Argo) → diagnostic only, not reward
        │
        ▼
  reward.txt, trace_judge.json, ctrf.json
```

## Troubleshooting

**`docker daemon is not running`** — start Docker Desktop (or `colima start`, etc.).

**`uv: command not found`** — install with `curl -LsSf https://astral.sh/uv/install.sh | sh`, then open a new shell.

**`Could not resolve host: apps.inside.anl.gov`** — you are off the Argonne network. Connect to ANL VPN.

**`ACCESS DENIED` from Argo** — the `ARGO_USER` in `.env` is not a valid ANL username, or you don't have Argo access. Confirm by running:
```bash
curl -sS https://apps.inside.anl.gov/argoapi/v1/models | head -c 200
```

**`Invalid model: gpt4omini`** — Argo's catalog does NOT include `gpt-4o-mini`. Use `argo:o4-mini`, `argo:gpt-4o`, or any model listed in [ChemGraph's `ARGO_MODEL_MAP`](https://github.com/argonne-lcf/ChemGraph/blob/main/src/chemgraph/models/openai.py).

**Image build fails partway** — usually a transient network or conda-forge mirror issue. Re-run `./setup.sh` (idempotent; resumes where it left off).

**Want a clean rebuild of the chemgraph image** —
```bash
docker rmi chemgraph-arm:latest
./setup.sh
```

## What This Is Not

- Not a TB-Science PR yet. The pilot task uses a placeholder oracle (copies reference answers) and queries are taken verbatim from ChemGraph's own evaluation set — both blocking for an upstream PR. See the [companion task spec](terminal-bench-science/tasks/physical-sciences/chemistry-and-materials/chemgraph-eval-suite-lite/task.toml) for the current state.
- Not a benchmark verdict. ChemGraph hitting 1.0 on five hand-picked queries doesn't show it outperforms generic agents; that comparison needs the Claude Code / Codex cross-check on the same task.

## License

This integration script is MIT-licensed. The bundled repositories retain their own licenses (Harbor: Apache 2.0; TB-Science: Apache 2.0; ChemGraph: see ChemGraph repo).
