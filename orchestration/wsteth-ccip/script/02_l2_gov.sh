#!/usr/bin/env bash
# Step 02 — deploy OptimismBridgeExecutor on the L2 fork (any OP-stack L2 — the messenger is the
# same predeploy on every OP chain; chain selected via L2_CHAIN, default mantle_sepolia).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
cd "${ROOT}"
. "${HERE}/_common.sh"
: "${DEPLOYER_PRIVATE_KEY:?set DEPLOYER_PRIVATE_KEY}"

[ -f state/l1.json ] || { echo "✗ run step 01 first (state/l1.json missing)"; exit 1; }
AGENT="$(jq -r '.agent' state/l1.json)"
[ "${AGENT}" != "null" ] && [ -n "${AGENT}" ] || { echo "✗ no agent in state/l1.json"; exit 1; }

assert_chain_id "${L2_RPC}" "${L2_CHAIN_ID}" "L2 ${L2_CHAIN}"
assert_l2_state_chain
fund "${DEPLOYER_ADDRESS}" "${L2_RPC}"

# Idempotency: skip only if opExec already deployed AND still pinned to the current Agent.
# Code alone isn't enough (cf. step 04's getToken probe): after an L1-only reset, step 01 mints a
# NEW Agent while the old opExec survives on L2 — skipping then would wire steps 03–07 to an
# executor whose ethereumGovernanceExecutor is the dead Agent, breaking L1→L2 governance.
if [ -f "${L2_STATE_FILE}" ]; then
    EXISTING="$(jq -r '.opExec // empty' "${L2_STATE_FILE}")"
    if [ -n "${EXISTING}" ] && has_code "${EXISTING}" "${L2_RPC}"; then
        GOT="$(cast call "${EXISTING}" 'getEthereumGovernanceExecutor()(address)' --rpc-url "${L2_RPC}" 2>/dev/null || echo 0x0)"
        if eq "${GOT}" "${AGENT}"; then
            echo "▸ opExec already deployed at ${EXISTING} (executor = current Agent); skipping."
            exit 0
        fi
        echo "▸ opExec at ${EXISTING} is pinned to stale executor ${GOT} (current Agent ${AGENT}); redeploying."
    fi
fi

echo "▸ deploying OptimismBridgeExecutor (ethereumGovernanceExecutor = Agent ${AGENT})"
FOUNDRY_PROFILE=govexec forge build --force ../../components/governance-crosschain-bridges/contracts/bridges/OptimismBridgeExecutor.sol
OPEXEC_OUT="${ROOT}/state/l2.opexec.addr"
L1_AGENT="${AGENT}" OPEXEC_OUT="${OPEXEC_OUT}" \
    forge script script/DeployL2Gov.s.sol:DeployL2Gov \
    --rpc-url "${L2_RPC}" --broadcast -vvv

OPEXEC="$(cat "${OPEXEC_OUT}")"
# Merge into an existing ${L2_STATE_FILE} (preserving keys like wstETH/wstETHImpl that step 03 adds —
# overwriting the file fresh would drop them on a re-run after a fork reset).
[ -f "${L2_STATE_FILE}" ] || echo '{}' > "${L2_STATE_FILE}"
jq_inplace "${L2_STATE_FILE}" --arg op "${OPEXEC}" --arg agent "${AGENT}" \
    --argjson cid "${L2_CHAIN_ID}" --arg l2 "${L2_CHAIN}" \
    '.chainId = $cid | .l2Chain = $l2 | .opExec = $op | .ethereumGovernanceExecutor = $agent'
rm -f "${OPEXEC_OUT}"

echo "✓ step 02 done. opExec = ${OPEXEC}"
jq '.' "${L2_STATE_FILE}"
