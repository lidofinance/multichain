set shell := ["bash", "-uc"]

# Extra flags forwarded to every diffyscan invocation, e.g.
#   just diffyscan_flags="--cache-explorer --cache-github" diffyscan-sources
diffyscan_flags := ""

# Path to a state-mate checkout (https://github.com/lidofinance/state-mate).
# state-mate is a yarn/TypeScript project, so unlike diffyscan there is no
# installed binary to find on PATH.
state_mate_dir := env_var_or_default("STATE_MATE_DIR", "../state-mate")

# List available recipes
default:
    @just --list

# Build using this ledger and the latest wsteth-ccip main (requires repository read access)
[positional-arguments]
dashboard-build *args:
    uv run --locked python scripts/build_dashboard.py "$@"

# Build and preview Lane Watch; --upstream PATH selects a local source directory
[positional-arguments]
dashboard *args:
    uv run --locked python scripts/build_dashboard.py --serve "$@"

# Render Diffyscan configs for every ready ledger cohort
render:
    uv run --locked python scripts/render_diffyscan_config.py --from-ledger

# Report ledger -> Diffyscan projection coverage
coverage:
    uv run --locked python scripts/render_diffyscan_config.py --coverage

# Run the ledger validators and tests the way CI does
test:
    uv run --locked python scripts/format_ledger.py check
    uv run --locked python scripts/validate_ledger.py
    uv run --locked python scripts/render_diffyscan_config.py --coverage
    uv run --locked python scripts/render_state_mate_config.py --coverage
    uv run --locked python -m pytest -q

# Re-render configs, then run source-only Diffyscan per cohort (optional name filter)
diffyscan-sources filter="":
    #!/usr/bin/env bash
    # Bytecode comparison is skipped: it needs per-chain RPCs and constructor
    # args the ledger does not carry yet. Sources are checked for every cohort.
    set -uo pipefail
    cd "{{ justfile_directory() }}"

    if ! command -v diffyscan >/dev/null 2>&1; then
        echo "diffyscan not on PATH; install with:" >&2
        echo "  uv tool install git+https://github.com/lidofinance/diffyscan@<tag>" >&2
        exit 127
    fi

    # Configs are generated, never hand-edited: re-render so every run checks
    # what the ledger says today.
    render_log="$(mktemp)"
    trap 'rm -f "$render_log"' EXIT
    uv run --locked python scripts/render_diffyscan_config.py --from-ledger \
        | tee "$render_log"
    render_status=${PIPESTATUS[0]}
    # 3 means the configs were written but some deployments did not project;
    # those cohorts are worth verifying anyway. Anything else means we would be
    # verifying whatever the previous run left behind and calling it a pass.
    if (( render_status != 0 && render_status != 3 )); then
        echo "render failed (exit $render_status); refusing to verify stale configs" >&2
        exit 1
    fi

    mkdir -p diffyscan/logs
    shopt -s nullglob
    passed=(); failed=()
    tmp_passed="$(mktemp)"
    trap 'rm -f "$tmp_passed" "$render_log"' EXIT
    for config in diffyscan/generated/*.json; do
        name="$(basename "$config" .json)"
        if [[ -n "{{ filter }}" && "$name" != *"{{ filter }}"* ]]; then
            continue
        fi
        # --from-ledger only prunes cohort-shaped names, so a config left over
        # from an overlay that no longer exists would otherwise be verified
        # against a stale pin and counted as a pass.
        if [[ ! "$name" =~ ^[a-z0-9-]+__[a-z0-9-]+__[0-9a-f]{7,64}$ ]] \
            && [[ ! -f "diffyscan/overlays/$name.json" ]]; then
            echo "==> $name ... SKIPPED (orphaned: no ledger cohort, no overlay)" >&2
            continue
        fi
        log="diffyscan/logs/$name.log"
        printf '==> %s ... ' "$name"
        if diffyscan --skip-binary-comparison --yes {{ diffyscan_flags }} \
            "$config" >"$log" 2>&1; then
            passed+=("$name")
            echo "$name" >> "$tmp_passed"
            echo "sources match"
        else
            failed+=("$name")
            echo "FAILED (see $log)"
        fi
    done

    if (( ${#passed[@]} + ${#failed[@]} == 0 )); then
        echo "no generated cohort matched filter '{{ filter }}'" >&2
        exit 2
    fi

    echo
    # Cohorts vary from 1 to 8 contracts, so a cohort count alone does not say
    # how much was actually verified. Report contracts as well.
    uv run --locked python3 -c '
    import json, pathlib, sys
    names = [n for n in pathlib.Path(sys.argv[1]).read_text().split() if n]
    total = sum(
        len(json.loads(p.read_text())["contracts"])
        for p in (pathlib.Path("diffyscan/generated") / f"{n}.json" for n in names)
        if p.is_file()
    )
    print(f"contracts verified in passing cohorts: {total}")
    ' "$tmp_passed"

    # A green run says nothing about deployments Diffyscan was never asked
    # about, so carry that number into the summary instead of leaving it in the
    # render output above.
    grep -a "not projected:" "$render_log" | sed 's/^  */deployments /' || true

    echo "cohorts passed: ${#passed[@]}, failed: ${#failed[@]}"
    # bash 3.2 (macOS) treats "${failed[@]}" on an empty array as unbound.
    if (( ${#failed[@]} > 0 )); then
        for name in "${failed[@]}"; do
            echo "  failed: $name"
        done
        exit 1
    fi
    if (( render_status == 3 )); then
        echo "note: every verified cohort passed, but some deployments did not project (see above)" >&2
        exit 3
    fi

# Re-render state-mate linkage configs from the ledger
state-mate-render:
    uv run --locked python scripts/render_state_mate_config.py --from-ledger

# Report ledger -> state-mate linkage projection coverage
state-mate-coverage:
    uv run --locked python scripts/render_state_mate_config.py --coverage

# Re-render, then run state-mate linkage checks per network (optional slug filter)
state-mate filter="":
    #!/usr/bin/env bash
    # Checks proxy -> implementation / admin linkage only. Nothing semantic is
    # asserted, and the ABIs are first-party stubs, so a green run says the
    # upgrade slots hold the addresses the ledger records and nothing more.
    set -uo pipefail
    cd "{{ justfile_directory() }}"

    sm="{{ state_mate_dir }}"
    if [[ ! -f "$sm/package.json" ]]; then
        echo "state-mate checkout not found at $sm" >&2
        echo "  git clone https://github.com/lidofinance/state-mate" >&2
        echo "  (cd state-mate && corepack enable && yarn install)" >&2
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
    uv run --locked python scripts/render_state_mate_config.py --from-ledger
    render_status=$?
    if (( render_status != 0 && render_status != 3 )); then
        echo "render failed (exit $render_status); refusing to check stale configs" >&2
        exit 1
    fi

    mkdir -p state-mate/logs
    shopt -s nullglob
    passed=(); failed=(); skipped=()
    for config in state-mate/generated/*/config.yaml; do
        slug="$(basename "$(dirname "$config")")"
        if [[ -n "{{ filter }}" && "$slug" != *"{{ filter }}"* ]]; then
            continue
        fi

        rpc_var="$(uv run --locked python scripts/render_state_mate_config.py \
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
        log="state-mate/logs/$slug.log"
        printf '==> %s ... ' "$slug"
        {
            echo "# network-slug: $slug"
            echo "# rpc-env-var:  $rpc_var"
            echo "# started-utc:  $(date -u +%Y-%m-%dT%H:%M:%SZ)"
            echo "# block-before: $(block_at)"
        } >"$log"
        if (cd "$sm" && yarn start \
            "{{ justfile_directory() }}/$config") >>"$log" 2>&1; then
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
        echo "no generated network matched filter '{{ filter }}'" >&2
        exit 2
    fi

    echo
    # A network count says nothing about how many proxies were checked, and the
    # per-network counts range from 1 to 10.
    uv run --locked python3 -c '
    import json, pathlib, sys
    total = 0
    for slug in sys.argv[1:]:
        p = pathlib.Path("state-mate/generated") / slug / "manifest.json"
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
