#!/usr/bin/env bash
# Complete the independent Chainlink migration without a DAO/deployer bypass.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
cd "${ROOT}"
. "${HERE}/_common.sh"
is_anvil "$L1_RPC" || { echo 'Hub admin acceptance is fork-only'; exit 1; }
[ -f state/hub-migration.json ] || { echo 'Run hub-cutover first'; exit 1; }
timelock="$(jq -er '.deployed.timelock' "$L1_CFG_CANON")"
token="$(record_token "$L1_CFG_CANON")"
tar="$(jq -er '.ccip.token_admin_registry' "$L1_CFG_CANON")"
proposer="$(jq -er '.governance_addresses.chainlink_mcms' "$L1_CFG_CANON")"
executor="$(jq -er '.deployed.call_proxy' "$L1_CFG_CANON")"
deployer="$(cast wallet address --private-key "$DEPLOYER_PRIVATE_KEY")"
admin="$(cast call "$timelock" 'ADMIN_ROLE()(bytes32)' --rpc-url "$L1_RPC")"
[ "$(cast call "$timelock" 'hasRole(bytes32,address)(bool)' "$admin" "$deployer" --rpc-url "$L1_RPC")" = false ] \
    || { echo 'Deployer must relinquish Ethereum ADMIN_ROLE before cutover acceptance'; exit 1; }
data="$(cast calldata 'acceptAdminRole(address)' "$token")"
calls="[($tar,0,$data)]"
zero32="0x$(printf '%064d' 0)"
proposal="$(timelock_propose_and_execute "$L1_RPC" "$timelock" "$proposer" "$executor" "$DEPLOYER_PRIVATE_KEY" \
    'accept-hub-admin' "$calls" "$zero32" "$(cast keccak 'lido-hub:accept-admin')")"
read -r actual pending pool <<<"$(cast call "$tar" 'getTokenConfig(address)((address,address,address))' "$token" --rpc-url "$L1_RPC" | tr -d '()' | tr ',' ' ')"
eq "$actual" "$timelock" && eq "$pending" 0x0000000000000000000000000000000000000000
eq "$pool" "$(jq -er '.deployed.token_pool' "$L1_CFG_CANON")"
jq -n --argjson p "$proposal" --arg tar "$tar" --arg data "$data" --arg hub "$pool" --arg admin "$actual" \
    '{hub:$hub, administrator:$admin, proposal:($p + {calls:[{target:$tar,value:"0",data:$data}]})}' > state/hub-admin-accept.json
echo 'Hub registry administration accepted through Chainlink MCMS proposal.'
