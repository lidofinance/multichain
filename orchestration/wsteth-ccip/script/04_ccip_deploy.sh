#!/usr/bin/env bash
# Step 04 — deploy the CCIP 2.0 stack on each chain with the component's own 1_Deploy.s.sol
# (components/ccip, run as its README documents: from its project root, release compiler profile,
# its default_config.json). L1 = SiloedLockRelease hub with one lockbox per lane, L2 = BurnMint
# spoke. CCIP infra addresses are hydrated from the Chainlink API (FFI) into the chain records.
#
# What this step contributes is the environment, not deployment logic:
#   • the scratch principals the component takes as parameters — the hub token and the L1 Agent
#     (step 01), the L2 governance executor (step 02) — are written into the run's chain records;
#   • on a scratch spoke the record keeps addresses.token = address(0) and carries token_deployment,
#     so 1_Deploy deploys the Lido wstETH token (ERC20BridgedPermit behind a TransparentUpgradeableProxy
#     whose ProxyAdmin the executor owns) and records it under .deployed.token*;
#   • the deployment identities step 08 verifies against are pinned from the broadcast CREATE
#     records (script/record-deployment.cjs).
# A chain whose record already carries this run's deployment is skipped, so a re-run after a failed
# spoke leaves the finished hub alone; a deployment this run did not broadcast is refused.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
cd "${ROOT}"
. "${HERE}/_common.sh"
: "${DEPLOYER_PRIVATE_KEY:?set DEPLOYER_PRIVATE_KEY}"

# Apply the remaining local submodule patches (currently core only, idempotent). Keeping this gate
# here makes a standalone step 04 fail if the scratch stack would be built from an inconsistent
# vendor tree. The ccip component is pristine upstream; check_ccip_base_shape guards its shape.
bash "${HERE}/00_patch_submodules.sh"
# The component compiles the Lido token from its npm package, pinned by commit in its package.json.
# Until the token under review is released, keep that package equal to the working tree.
bash "${HERE}/sync-ccip-packages.sh"

for f in state/l1.json "${L2_STATE_FILE}"; do [ -f "$f" ] || { echo "✗ missing $f (run earlier steps)"; exit 1; }; done
assert_l2_state_chain

scope="${WSTETH_DEPLOY_SCOPE:-both}"
case "$scope" in both|hub|spoke) ;; *) echo "Invalid WSTETH_DEPLOY_SCOPE"; exit 1;; esac
ZERO_ADDRESS="0x0000000000000000000000000000000000000000"

# seed_cfg <chain> <state file>: the environment's principals become the record's parameters.
# Which side supplies the token follows from the record's shape, never from what the state file
# happens to hold: a record with token_deployment is a scratch spoke whose token 1_Deploy deploys,
# so it keeps addresses.token = address(0) and a token already named in the state (an earlier
# deployment's, copied into this run) is an error, not an input; any other record bridges the token
# the environment supplies (the hub token from the scratch core, both tokens of an in-place target).
seed_cfg() {
    local name="$1" state="$2" cfg="${CFG_DIR}/$1.json"
    local dao token
    dao="$(jq -er 'if .agent then .agent else .opExec end' "${state}")"
    jq_inplace "${cfg}" --arg a "${dao}" '.governance_addresses.lido_dao_agent=$a'
    token="$(jq -r '.wstETH // empty' "${state}")"
    if jq -e '.token_deployment' "${cfg}" >/dev/null; then
        [ -z "${token}" ] || {
            echo "✗ ${name}: ${state} already names token ${token}, but the record deploys its token (token_deployment)."
            echo "  That is an earlier deployment's state; prepare a new run instead of pointing a new pool at it."
            exit 1; }
        [ "$(jq -r '.addresses.token' "${cfg}")" = "${ZERO_ADDRESS}" ] || {
            echo "✗ ${name}: the record carries token_deployment and a non-zero addresses.token — fix the target"; exit 1; }
    else
        [ -n "${token}" ] || {
            echo "✗ ${name}: no token in ${state} and no token_deployment in the record — nothing for 1_Deploy to bridge"; exit 1; }
        jq_inplace "${cfg}" --arg t "${token}" '.addresses.token=$t'
    fi
}

# deployed_in_this_run <chain>: the record carries a deployment AND this run's broadcast holds its
# receipts. 1_Deploy refuses a record that already carries a deployment, so a chain in this state is
# finished and skipped — which lets a re-run after a failed spoke leave the finished hub alone. A
# record that carries a deployment without receipts in this run (an imported record) is refused:
# this step deploys, it does not adopt.
deployed_in_this_run() {
    local name="$1" cfg="${CFG_DIR}/$1.json" pool receipts
    pool="$(jq -r '.deployed.token_pool // empty' "${cfg}")"
    [ -n "${pool}" ] && [ "${pool}" != "${ZERO_ADDRESS}" ] || return 1
    receipts="broadcast/ccip/1_Deploy.s.sol/$(jq -r '.chain.chain_id' "${cfg}")/run-latest.json"
    [ -f "${receipts}" ] || {
        echo "✗ ${name}: the record already carries a deployment (pool ${pool}) that this run did not broadcast."
        echo "  Prepare a new run to deploy; to verify an existing deployment, import its record instead."
        exit 1; }
    return 0
}

# deploy_chain <chain> <state file> <rpc>: seed the record, then 1_Deploy.
deploy_chain() {
    local name="$1" state="$2" rpc="$3"
    if deployed_in_this_run "${name}"; then
        echo "▸ ${name}: 1_Deploy already done in this run (pool $(jq -r '.deployed.token_pool' "${CFG_DIR}/${name}.json")); skip."
        return
    fi
    seed_cfg "${name}" "${state}"
    echo "▸ 1_Deploy on ${name} (${rpc})"
    run_ccip_script "${name}" "${rpc}" "1_Deploy.s.sol:DeployScript"
}

if [ "${WSTETH_SKIP_L1:-0}" != 1 ] && [ "$scope" != spoke ]; then
    deploy_chain "${L1_CHAIN}" state/l1.json "${L1_RPC}"
fi
if [ "$scope" != hub ]; then deploy_chain "${L2_CHAIN}" "${L2_STATE_FILE}" "${L2_RPC}"; fi

echo ""
node "${HERE}/record-deployment.cjs"
echo "✓ step 04 done."
echo "L1 pool:      $(jq -r '.deployed.token_pool' "${L1_CFG_CANON}")  (lockboxes: $(jq -r '.deployed.lock_boxes|length' "${L1_CFG_CANON}"))"
echo "L1 timelock:  $(jq -r '.deployed.timelock' "${L1_CFG_CANON}")  (CallProxy $(jq -r '.deployed.call_proxy' "${L1_CFG_CANON}"))"
[ "$scope" != hub ] || exit 0
echo "L2 token:     $(record_token "${L2_CFG_CANON}")"
echo "L2 pool:      $(jq -r '.deployed.token_pool' "${L2_CFG_CANON}")"
echo "L2 timelock:  $(jq -r '.deployed.timelock' "${L2_CFG_CANON}")  (CallProxy $(jq -r '.deployed.call_proxy' "${L2_CFG_CANON}"))"
