#!/usr/bin/env bash
# Run pool/custody/governance fork checks while Base contracts are absent.
# These checks do not prove DON delivery or remote spoke governance.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
cd "${ROOT}"
. "${HERE}/_common.sh"
[ -f state/hub-admin-accept.json ] || { echo 'Run hub-accept-admin before checking the hub'; exit 1; }
HUB_CHECKPOINT=true FOUNDRY_TEST="${WSTETH_TEST_DIR:?}" forge test \
    --match-contract RealHubMigrationTest --match-path "${WSTETH_TEST_DIR}/scenario/RealHubMigration.t.sol" -vv 2>&1 | tee state/forge-hub-checkpoint.log
python3 "${HERE}/rehearsal_checks.py" state/forge-hub-checkpoint.log
jq -n --arg block "$(cast block-number --rpc-url "$L1_RPC")" --arg hub "$(jq -er '.deployed.token_pool' "$L1_CFG_CANON")" \
    '{status:"passed", hub:$hub, block:$block, scope:"Ethereum pool boundary, custody and governance before Base deployment; no spoke forks or DON"}' > state/hub-checkpoint.json
