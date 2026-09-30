#!/usr/bin/env bash
# Step 04 — deploy the CCIP 2.0 pool stack on each chain by driving the vendored ccip
# submodule's 1_Deploy.s.sol. L1 = SiloedLockRelease (siloed hub), L2 = BurnMint (spoke).
# CCIP infra addresses are auto-hydrated from the Chainlink API (FFI) into the chain configs.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
cd "${ROOT}"
. "${HERE}/_common.sh"
: "${DEPLOYER_PRIVATE_KEY:?set DEPLOYER_PRIVATE_KEY}"

# Apply the remaining local submodule patches (currently core only, idempotent). Keeping this gate
# here makes a standalone step 04 fail if the scratch stack would be built from an inconsistent
# vendor tree. PoolOperationManager itself is pristine upstream: GUARDIAN_ROLE has been removed.
bash "${HERE}/00_patch_submodules.sh"

for f in state/l1.json state/l2.json; do [ -f "$f" ] || { echo "✗ missing $f (run earlier steps)"; exit 1; }; done
assert_l2_state_chain
L1_WSTETH=$(jq -r .wstETH state/l1.json); AGENT=$(jq -r .agent state/l1.json)
L2_WSTETH=$(jq -r .wstETH state/l2.json); OPEXEC=$(jq -r .opExec state/l2.json)

# Populate only this run's chain records; never import another run's cached CCIP data.
seed_cfg() {
    local name="$1" token="$2" agent="$3"
    jq_inplace "${CFG_DIR}/${name}.json" --arg t "${token}" --arg a "${agent}" \
        '.addresses.token=$t | .governance_addresses.lido_dao_agent=$a'
}
seed_cfg sepolia "$L1_WSTETH" "$AGENT"
# The L1 record's lane is per-pair: point it at the active L2 (siloed hub semantics preserved).
# Steps 05/07/08 read this same run record.
jq_inplace "${CFG_DIR}/sepolia.json" --arg l2 "${L2_CHAIN}" \
    '.remote_lanes = [{"is_siloed": true, "remote_chain_name": $l2}]'
seed_cfg "${L2_CHAIN}" "$L2_WSTETH" "$OPEXEC"

# Pair guard: if the L1 pool already exists on-chain but has no lockbox for THIS L2, the record
# belongs to another pair — run_deploy's skip logic would keep the stale pool and never create
# this pair's lockbox.
L1_POOL_EXISTING="$(jq -r '.deployed.token_pool // empty' "${CFG_DIR}/sepolia.json")"
if [ -n "${L1_POOL_EXISTING}" ] && has_code "${L1_POOL_EXISTING}" "${L1_RPC}"; then
    if ! jq -e --arg l2 "${L2_CHAIN}" '.deployed.lock_boxes[]? | select(.remote_chain_name == $l2)' \
            "${CFG_DIR}/sepolia.json" >/dev/null; then
        echo "✗ L1 pool ${L1_POOL_EXISTING} is deployed for a different pair (no ${L2_CHAIN} lockbox in the record)."
        echo "  Deploy this pair on a fresh L1 fork (prepare a new run first) or keep a separate L1 record per pair."
        exit 1
    fi
fi

SKIPPED_DEPLOY_CHAINS=()
run_deploy() {
    local name="$1" rpc="$2"
    local cfg="${CFG_DIR}/${name}.json"
    local existing; existing="$(jq -r '.deployed.token_pool // empty' "${cfg}")"
    # Gate on on-chain code (like steps 02/03), not just the config record, so a fresh/reset fork
    # isn't skipped just because the committed config still carries a stale .deployed block.
    if [ -n "${existing}" ] && has_code "${existing}" "${rpc}"; then
        # Code at the stale address isn't proof it's OUR pool: after a fork reset the deployer
        # nonce can shift and land an unrelated contract on this address. Confirm by calling the
        # pool's getToken() and matching the configured token before trusting the skip.
        local got
        got="$(cast call "${existing}" 'getToken()(address)' --rpc-url "${rpc}" 2>/dev/null || true)"
        if [ -n "${got}" ] && eq "${got}" "$(jq -r '.addresses.token' "${cfg}")"; then
            echo "▸ ${name}: token_pool ${existing} already deployed on-chain; skipping 1_Deploy."
            SKIPPED_DEPLOY_CHAINS+=("${name}")
            return
        fi
        echo "▸ ${name}: ${existing} has code but is not our pool (getToken mismatch); redeploying."
    fi
    # Redeploying (no real pool on-chain, e.g. a reset fork): the committed config may still carry
    # stale deploy OUTPUTS (.deployed/.ccv) which make 1_Deploy refuse ("token_pool exists in
    # config"). Drop them so it deploys fresh; keep .ccip (FFI-hydrated live infra, valid on the fork).
    if [ -n "${existing}" ]; then
        jq_inplace "${cfg}" 'del(.deployed) | del(.ccv)'
        echo "▸ ${name}: cleared stale .deployed/.ccv before redeploy."
    fi
    echo "▸ 1_Deploy on ${name} (${rpc})"
    run_ccip_script "${name}" "${rpc}" "1_Deploy.s.sol:DeployScript"
}

run_deploy sepolia "${L1_RPC}"
run_deploy "${L2_CHAIN}" "${L2_RPC}"

# Stamp the key that actually signed the deploy into the record, so step 08's deployer-revocation
# checks bind to the real deployer — not to whatever DEPLOYER_ADDRESS happens to be exported in the
# verifying environment (default: anvil account 0, which would pass vacuously).
DEPLOYER_FROM_KEY="$(cast wallet address --private-key "${DEPLOYER_PRIVATE_KEY}")"
for f in config/chains/sepolia.json "${L2_CFG_CANON}"; do
    jq_inplace "${f}" --arg d "${DEPLOYER_FROM_KEY}" '.governance_addresses.deployer = $d'
done

echo ""
node "${HERE}/record-pom-implementations.cjs" "${SKIPPED_DEPLOY_CHAINS[@]+${SKIPPED_DEPLOY_CHAINS[@]}}"
echo "✓ step 04 done."
echo "L1 pool:  $(jq -r '.deployed.token_pool' config/chains/sepolia.json)  (lockboxes: $(jq -r '.deployed.lock_boxes|length' config/chains/sepolia.json))"
echo "L1 POM:   $(jq -r '.deployed.pool_operation_manager' config/chains/sepolia.json)"
echo "L2 pool:  $(jq -r '.deployed.token_pool' "${L2_CFG_CANON}")"
echo "L2 POM:   $(jq -r '.deployed.pool_operation_manager' "${L2_CFG_CANON}")"
