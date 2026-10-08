set shell := ["bash", "-uc"]

# Keep entrypoints, defaults, and command composition here; procedural scripts
# belong under orchestration/.

# Extra flags forwarded to every diffyscan invocation, e.g.
#   just diffyscan_flags="--cache-explorer --cache-github" diffyscan-sources
diffyscan_flags := ""

# Path to a state-mate checkout (https://github.com/lidofinance/state-mate).
# state-mate is a yarn/TypeScript project, so unlike diffyscan there is no
# installed binary to find on PATH.
state_mate_dir := env_var_or_default("STATE_MATE_DIR", "libs/state-mate")

# List available recipes
default:
    @just --list

# List or run wstETH CCIP orchestration recipes
[positional-arguments]
wsteth *args:
    python3 orchestration/wsteth-ccip/workspace.py run "$@"

# Copy target inputs into a new run; preparation does not deploy
[positional-arguments]
wsteth-prepare target run *args:
    python3 orchestration/wsteth-ccip/workspace.py prepare "$@"

# Select an existing run without resetting its records
[positional-arguments]
wsteth-use run:
    python3 orchestration/wsteth-ccip/workspace.py use "$1"

# Build using this checkout's ledger, catalogues and dated testnet snapshot
[positional-arguments]
dashboard-build *args:
    uv run --locked python components/dashboard/scripts/build_dashboard.py "$@"

# Build and preview Lane Watch from repository inputs
[positional-arguments]
dashboard *args:
    uv run --locked python components/dashboard/scripts/build_dashboard.py --serve "$@"

# Render Diffyscan configs for every ready ledger cohort
render:
    uv run --locked python components/ledger/scripts/render_diffyscan_config.py --from-ledger

# Report ledger -> Diffyscan projection coverage
coverage:
    uv run --locked python components/ledger/scripts/render_diffyscan_config.py --coverage

# Run the ledger validators and tests the way CI does
test:
    uv run --locked python components/ledger/scripts/format_ledger.py check
    uv run --locked python components/ledger/scripts/validate_ledger.py
    uv run --locked python components/ledger/scripts/render_diffyscan_config.py --coverage
    uv run --locked python components/ledger/scripts/render_state_mate_config.py --coverage
    uv run --locked python -m pytest -q

# Re-render configs, then run source-only Diffyscan per cohort (optional name filter)
[positional-arguments]
diffyscan-sources filter="":
    bash orchestration/ledger/diffyscan-sources.sh "$1" {{diffyscan_flags}}

# Re-render state-mate linkage configs from the ledger
state-mate-render:
    uv run --locked python components/ledger/scripts/render_state_mate_config.py --from-ledger

# Report ledger -> state-mate linkage projection coverage
state-mate-coverage:
    uv run --locked python components/ledger/scripts/render_state_mate_config.py --coverage

# Re-render, then run state-mate linkage checks per network (optional slug filter)
[positional-arguments]
state-mate filter="":
    STATE_MATE_CHECKOUT="{{state_mate_dir}}" bash orchestration/ledger/state-mate.sh "$1"

# Test the locally maintained wstETH token and proxy, then check its storage layout snapshot
wsteth-token-test: wsteth-token-layout-check
    forge test --root components/wsteth-token --offline

# The implementation must keep ERC20Core alone in linear storage (slots 0-2); see components/wsteth-token/README.md
wsteth-token-layout-check:
    #!/usr/bin/env bash
    set -euo pipefail
    forge build --root components/wsteth-token --offline --silent
    # Materialize the inspect output first: a failing `forge inspect` inside a process substitution
    # is invisible to `set -e` and would surface as fake "layout drift" against an empty stream.
    actual="$(mktemp)"; trap 'rm -f "$actual"' EXIT
    forge inspect --root components/wsteth-token --offline contracts/token/ERC20BridgedPermit.sol:ERC20BridgedPermit storage-layout --json \
        | jq '{storage: [.storage[] | {label, slot, offset, type}]}' > "$actual"
    [ -s "$actual" ] || { echo "✗ forge inspect produced no storage layout"; exit 1; }
    diff "$actual" components/wsteth-token/storage-layout/ERC20BridgedPermit.json \
        && echo "✓ wsteth-token storage layout matches components/wsteth-token/storage-layout/ERC20BridgedPermit.json"
