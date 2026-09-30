# Lido multichain

Tooling and records for Lido's wstETH multichain deployments: a deployment
catalogue, the verification tooling built on it, and the dashboard that
presents it. The intended repository shape and its reasoning are in
[APPROACH.md](./APPROACH.md).

## Layout

- [`ledger.json`](./ledger.json) — the shared deployment catalogue.
- [`components/ledger/`](./components/ledger/README.md) — its
  [schema](./components/ledger/ledger.schema.json), validators, formatter, and the
  Diffyscan and state-mate projections that check the catalogue against
  sources and chain state.
- [`components/dashboard/`](./components/dashboard/README.md) — the dashboard: templates, build
  script, network metadata, and tests. The generated site is written to
  `docs/`, which GitHub Pages serves.
- [`components/`](./components/README.md) — domain packages for tokens, staking, bridges,
  governance, the ledger, and the dashboard.
- [`libs/`](./libs/README.md) — supporting libraries and tools for implementation,
  building, testing, scripting, and verification.
- [`orchestration/wsteth-ccip/`](./orchestration/wsteth-ccip/README.md) — the imported
  deployment scripts and recipes that coordinate those repositories.
- [`targets/wsteth-ccip-sepolia-mantle-dev/`](./targets/wsteth-ccip-sepolia-mantle-dev/README.md)
  — Sepolia–Mantle Sepolia development configuration and state checks.
- [`runs/wsteth-2.0/`](./runs/wsteth-2.0/README.md) — preserved historical records
  and private local snapshots from the import.
- `.githooks/` — the pre-commit dispatcher. It runs each module's own hook
  under `<module>/hooks/`; today only the ledger has one.
- `.github/workflows/` — CI for the ledger and the dashboard.

## Tooling

Python tooling is managed with [uv](https://docs.astral.sh/uv/) from one
environment at the repository root. Sync once and point this clone at the
repo-managed git hooks:

```sh
uv sync
git config core.hooksPath .githooks
```

Common commands are `just` recipes; `just` alone lists them.

```sh
just test            # formatting check, validators, projection coverage, tests
just dashboard       # rebuild the dashboard and preview it
just wsteth          # list deployment/build/verification recipes
```

## Where things go

The ledger records supported claims about deployed addresses; it is a
catalogue, not an on-chain registry. Component repositories provide sources;
orchestration coordinates operations; targets own intended configuration and
checks; run records retain execution evidence. The imported records have not
been published into the ledger.
