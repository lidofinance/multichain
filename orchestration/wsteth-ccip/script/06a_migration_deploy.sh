#!/usr/bin/env bash
# Explainer 1.2: all three implementations exist before the Base lane proposal and DAO vote.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
cd "${ROOT}"
. "${HERE}/_common.sh"
is_anvil "$L1_RPC" && is_anvil "$L2_RPC" || { echo 'Migration deployment is fork-only'; exit 1; }
export L1_CFG="${CFG_DIR}/${L1_CHAIN}.json" L2_CFG="${CFG_DIR}/${L2_CHAIN}.json"
export L1_STATE="${ROOT}/state/l1.json" L2_STATE="${ROOT}/${L2_STATE_FILE}"
BRIDGE_ROOT="${ROOT}/../../components/l2-bridge-migration"
TOKEN_ROOT="${ROOT}/../../components/wsteth-token"
forge build --root "$BRIDGE_ROOT" --silent
forge build --root "$TOKEN_ROOT" --silent contracts/token/ERC20BridgedPermit.sol
export TOKEN_ARTIFACT="${TOKEN_ROOT}/out/ERC20BridgedPermit.sol/ERC20BridgedPermit.json"
export L1_BRIDGE_ARTIFACT="${BRIDGE_ROOT}/out/L1MigrationBridge.sol/L1MigrationBridge.json"
export L2_BRIDGE_ARTIFACT="${BRIDGE_ROOT}/out/L2MigrationBridge.sol/L2MigrationBridge.json"
export TOKEN_VERSION="$(jq -r '.migration.tokenVersion // "2"' "${WSTETH_TARGET_DIR:?}/target.json")"
export DEPLOYER_ADDRESS="$(cast wallet address --private-key "$DEPLOYER_PRIVATE_KEY")"
mkdir -p state/migration
for side in l1 l2; do
    if [ "$side" = l1 ]; then rpc="$L1_RPC"; contract=MigrationL1Deploy; else rpc="$L2_RPC"; contract=MigrationL2Deploy; fi
    out="${ROOT}/state/migration/${side}-deploy.json"
    [ ! -e "$out" ] || { echo "$out already exists; refusing to redeploy implementations"; exit 1; }
    fund "$DEPLOYER_ADDRESS" "$rpc"
    OUT_JSON="$out" FOUNDRY_PROFILE=migration with_fork_account "$rpc" "$DEPLOYER_ADDRESS" \
        forge script "script/migration/${contract}.s.sol:${contract}" --rpc-url "$rpc" \
        --sender "$DEPLOYER_ADDRESS" --non-interactive --broadcast --unlocked -vv
done
