#!/usr/bin/env bash
# Step 05 — configure the CCIP pools by driving the vendored 2_Configure.s.sol on each chain.
# Wires lanes + rate limits, siloed lockboxes, hooks CCV (single resolver for now; step 06
# extends to 2-of-2), POM blocked/delay selectors, and transfers pool/hook/verifier/resolver/
# lockbox ownership to the PoolOperationManager. Prereq: 1_Deploy ran on BOTH chains.
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
}

run_configure sepolia "${L1_RPC}"
run_configure "${L2_CHAIN}" "${L2_RPC}"



echo ""
echo "✓ step 05 done — pools configured, ownership transferred to POM."
