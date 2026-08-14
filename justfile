set shell := ["bash", "-uc"]

# Extra flags forwarded to every diffyscan invocation, e.g.
#   just diffyscan_flags="--cache-explorer --cache-github" diffyscan-sources
diffyscan_flags := ""

# List available recipes
default:
    @just --list

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
