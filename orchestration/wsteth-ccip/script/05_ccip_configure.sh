#!/usr/bin/env bash
# Step 05 — configure the CCIP pools by driving the vendored 2_Configure.s.sol on each chain.
# Wires lanes + rate limits, siloed lockboxes, initial dummy CCV, the timelock's blocked
# selectors, and transfers pool/hook/verifier/resolver/lockbox ownership to the LidoTimelock
# (two-step, accepted in one bypass batch while the deployer still holds ADMIN_ROLE).
# The controlled fresh-testnet profile then applies its declared Chainlink + local
# resolver requirements through our owned step, before the step-07 admin handover.
# Prereq: 1_Deploy ran on BOTH chains.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
cd "${ROOT}"
. "${HERE}/_common.sh"
: "${DEPLOYER_PRIVATE_KEY:?set DEPLOYER_PRIVATE_KEY}"

# Upstream scripts read this run's populated configs (with .ccip/.deployed from step 04).

run_configure() {
    local name="$1" rpc="$2"
    echo "▸ 2_Configure on ${name} (${rpc})"
    run_ccip_script "${name}" "${rpc}" "2_Configure.s.sol:ConfigureScript"
    if [ -n "${WSTETH_ACCESS_PROFILE:-}" ]; then
        node "${HERE}/testnet/operations.cjs" initial-ccv "${name}"
    fi
}

scope="${WSTETH_DEPLOY_SCOPE:-both}"
case "$scope" in both|hub|spoke) ;; *) echo "Invalid WSTETH_DEPLOY_SCOPE"; exit 1;; esac
if [ "${WSTETH_SKIP_L1:-0}" != 1 ] && [ "$scope" != spoke ]; then run_configure "${L1_CHAIN}" "${L1_RPC}"; fi
if [ "$scope" != hub ]; then run_configure "${L2_CHAIN}" "${L2_RPC}"; fi



echo ""
echo "✓ step 05 done — pools configured, ownership transferred to the LidoTimelock."
