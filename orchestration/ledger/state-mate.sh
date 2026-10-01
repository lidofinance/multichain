#!/usr/bin/env bash
# Checks proxy -> implementation / admin linkage only. Nothing semantic is
# asserted, and the ABIs are first-party stubs, so a green run says the
# upgrade slots hold the addresses the ledger records and nothing more.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1
repo_root="$PWD"
filter="${1:-}"

sm="${STATE_MATE_CHECKOUT:-${STATE_MATE_DIR:-libs/state-mate}}"
if [[ ! -f "$sm/package.json" ]]; then
    echo "state-mate checkout not found at $sm" >&2
    echo "  git submodule update --init libs/state-mate" >&2
    echo "  (cd libs/state-mate && corepack yarn install)" >&2
    echo "  then export STATE_MATE_DIR=/path/to/state-mate" >&2
    exit 127
fi
sm="$(cd "$sm" && pwd)"

# The generated configs name RPC env vars rather than URLs, so the endpoint
# stays the runner's choice and never lands in git. state-mate reads its own
# cwd's .env, which is the state-mate checkout, not this repo — so export
# ours into the environment instead of relying on dotenv.
if [[ -f .env ]]; then set -a; . ./.env; set +a; fi

# Configs are generated, never hand-edited: re-render so every run checks
# what the ledger says today. 3 means "written, but some proxies did not
# project" — those are reported by --coverage and are not a render failure.
uv run --locked python components/ledger/scripts/render_state_mate_config.py --from-ledger
render_status=$?
if (( render_status != 0 && render_status != 3 )); then
    echo "render failed (exit $render_status); refusing to check stale configs" >&2
    exit 1
fi

mkdir -p components/ledger/state-mate/logs
shopt -s nullglob
passed=(); failed=(); skipped=()
for config in components/ledger/state-mate/generated/*/config.yaml; do
    slug="$(basename "$(dirname "$config")")"
    if [[ -n "${filter}" && "$slug" != *"${filter}"* ]]; then
        continue
    fi

    rpc_var="$(uv run --locked python components/ledger/scripts/render_state_mate_config.py \
        --rpc-url "$slug")" || { echo "==> $slug ... SKIPPED (no RPC entry)"; skipped+=("$slug"); continue; }
    rpc_url="${!rpc_var:-}"
    if [[ -z "$rpc_url" ]]; then
        echo "==> $slug ... SKIPPED ($rpc_var is not set)"
        skipped+=("$slug")
        continue
    fi

    # state-mate reads "latest" and reports no block height, so two runs are
    # not the same observation. Stamp the window the run saw, or the log
    # cannot be dated to anything more precise than the file mtime.
    block_at() {
        curl -s --max-time 20 -X POST -H 'content-type: application/json' \
            --data '{"jsonrpc":"2.0","id":1,"method":"eth_blockNumber","params":[]}' \
            "$rpc_url" | sed -n 's/.*"result":"\([^"]*\)".*/\1/p'
    }
    log="components/ledger/state-mate/logs/$slug.log"
    printf '==> %s ... ' "$slug"
    {
        echo "# network-slug: $slug"
        echo "# rpc-env-var:  $rpc_var"
        echo "# started-utc:  $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "# block-before: $(block_at)"
    } >"$log"
    if (cd "$sm" && yarn start \
        "${repo_root}/$config") >>"$log" 2>&1; then
        passed+=("$slug"); echo "linkage holds"
    else
        failed+=("$slug"); echo "FAILED (see $log)"
    fi
    {
        echo "# block-after:  $(block_at)"
        echo "# ended-utc:    $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } >>"$log"
done

if (( ${#passed[@]} + ${#failed[@]} + ${#skipped[@]} == 0 )); then
    echo "no generated network matched filter '${filter}'" >&2
    exit 2
fi

echo
# A network count says nothing about how many proxies were checked, and the
# per-network counts range from 1 to 10.
uv run --locked python3 -c '
import json, pathlib, sys
total = 0
for slug in sys.argv[1:]:
    p = pathlib.Path("components/ledger/state-mate/generated") / slug / "manifest.json"
    if p.is_file():
        total += len(json.loads(p.read_text())["proxies"])
print(f"proxies checked in passing networks: {total}")
' "${passed[@]:-}"

echo "networks passed: ${#passed[@]}, failed: ${#failed[@]}, skipped: ${#skipped[@]}"
if (( ${#skipped[@]} > 0 )); then
    # A skipped network is not a pass. Saying so here is the difference
    # between "linkage holds" and "linkage holds where we looked".
    for slug in "${skipped[@]}"; do echo "  skipped: $slug"; done
fi
if (( ${#failed[@]} > 0 )); then
    for slug in "${failed[@]}"; do echo "  failed: $slug"; done
    exit 1
fi
