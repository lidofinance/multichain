# Ledger verification runners

The root `justfile` exposes entrypoints, parameters, defaults, and command
composition. These scripts implement its multi-step verification procedures:

- `diffyscan-sources.sh [filter] [diffyscan flags...]` renders current configs,
  verifies matching cohorts, and summarizes coverage and failures.
- `state-mate.sh [filter]` renders linkage configs and checks matching networks.
  Defaults to pinned `libs/state-mate`; `STATE_MATE_DIR` overrides it. The root
  recipe passes its configured checkout as `STATE_MATE_CHECKOUT`, which takes
  precedence when invoking the script directly.

Use `just diffyscan-sources` and `just state-mate`; their existing filters and
configuration overrides are preserved. Schema and rendering logic remains in
`components/ledger/scripts/`, with generated configs and verification logs under `components/ledger/`.

FPF A.15 (CC-A15-1/2) informs the distinction between reusable procedures,
configured intent, actual execution, and records. Keeping entrypoints separate
from procedural implementation is this repository's design choice.
