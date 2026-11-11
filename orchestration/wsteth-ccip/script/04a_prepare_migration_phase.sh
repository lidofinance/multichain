#!/usr/bin/env bash
# Separate preparation boundaries from Explainer 1.1 and 1.2. Fork rehearsal only.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
cd "${ROOT}"
. "${HERE}/_common.sh"
phase="${1:?hub or base}"
jq -e '.migration.hub' "${WSTETH_TARGET_DIR:?}/target.json" >/dev/null
is_anvil "${L1_RPC}" && is_anvil "${L2_RPC}" || { echo 'Migration preparation is fork-only'; exit 1; }
deployer="$(cast wallet address --private-key "${DEPLOYER_PRIVATE_KEY}")"
fund "$deployer" "$L1_RPC"
fund "$deployer" "$L2_RPC"
zero32="0x$(printf '%064d' 0)"

if [ "$phase" = hub ]; then
    run_hub_script deploy
    WSTETH_DEPLOY_SCOPE=hub WSTETH_HUB_DEPLOY_SCRIPT=DeployHubForMigration.s.sol node "${HERE}/record-deployment.cjs"
    run_hub_script configure
    timelock="$(jq -er '.deployed.timelock' "${L1_CFG_CANON}")"
    dao="$(jq -er '.governance_addresses.lido_dao_agent' "${L1_CFG_CANON}")"
    admin="$(cast call "$timelock" 'ADMIN_ROLE()(bytes32)' --rpc-url "$L1_RPC")"
    cast send "$timelock" 'grantRole(bytes32,address)' "$admin" "$dao" --private-key "$DEPLOYER_PRIVATE_KEY" --rpc-url "$L1_RPC" >/dev/null
    cast send "$timelock" 'renounceRole(bytes32,address)' "$admin" "$deployer" --private-key "$DEPLOYER_PRIVATE_KEY" --rpc-url "$L1_RPC" >/dev/null
    [ "$(cast call "$timelock" 'hasRole(bytes32,address)(bool)' "$admin" "$deployer" --rpc-url "$L1_RPC")" = false ]
    echo 'Hub preparation complete: imported lanes only; deployer admin revoked before cutover.'
elif [ "$phase" = base ]; then
    # This executable checkpoint must pass before any Base preparation transaction.
    bash "${HERE}/05b_verify_hub.sh"
    WSTETH_DEPLOY_SCOPE=spoke bash "${HERE}/04_ccip_deploy.sh"
    LANE="${L2_CHAIN}" run_hub_script prepare-lane
    mkdir -p state/base-preparation
    mv "${CFG_DIR}/lane-preparation.json" state/base-preparation/ownership-calls.json
    timelock="$(jq -er '.deployed.timelock' "${L1_CFG_CANON}")"
    proposer="$(jq -er '.governance_addresses.chainlink_mcms' "${L1_CFG_CANON}")"
    executor="$(jq -er '.deployed.call_proxy' "${L1_CFG_CANON}")"
    calls="$(jq -r '"[" + (.calls | map("(\(.target),\(.value),\(.data))") | join(",")) + "]"' state/base-preparation/ownership-calls.json)"
    proposal="$(timelock_propose_and_execute "$L1_RPC" "$timelock" "$proposer" "$executor" "$DEPLOYER_PRIVATE_KEY" \
        'accept-base-contracts' "$calls" "$zero32" "$(cast keccak 'lido-hub:accept-base-contracts')")"
    jq --argjson p "$proposal" '. + {proposal: $p}' state/base-preparation/ownership-calls.json > state/base-preparation.json
    for target in $(jq -r '.calls[].target' state/base-preparation.json); do
        eq "$(cast call "$target" 'owner()(address)' --rpc-url "$L1_RPC")" "$timelock"
    done
    WSTETH_DEPLOY_SCOPE=spoke bash "${HERE}/05_ccip_configure.sh"
    WSTETH_SKIP_L1=1 bash "${HERE}/07_set_pool_gov.sh"
    bash "${HERE}/06a_migration_deploy.sh"
    echo 'Base preparation complete: new Ethereum contracts accepted by MCMS proposal; Base admin handed over.'
else
    echo 'Expected hub or base'; exit 1
fi
