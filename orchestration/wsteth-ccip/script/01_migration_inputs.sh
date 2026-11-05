#!/usr/bin/env bash
# Step 01m — in-place upgrade targets: record the EXISTING contracts the migration operates on.
# Replaces the scratch steps 01–03: nothing is deployed. Reads the target's `migration` block
# (inputs/target/target.json), cross-checks every address on the two forks (bytecode, proxy
# admins, bridge wiring, messenger pairing, executor principal) and writes state/l1.json and the
# L2 state file in the shape steps 04, 06, 07 and 08 consume, keeping whatever those steps recorded.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
cd "${ROOT}"
. "${HERE}/_common.sh"
[ "${WSTETH_OPERATION}" = "in-place-upgrade" ] \
    || { echo "✗ step 01m is for in-place-upgrade targets (WSTETH_OPERATION=${WSTETH_OPERATION})"; exit 1; }
TARGET_JSON="$(migration_target_json)"

FAIL=0
ok()   { echo "  ✔ $*"; }
bad()  { echo "  ✗ $*"; FAIL=1; }
# expect <label> <actual> <expected>
expect() { if eq "$2" "$3"; then ok "$1: $2"; else bad "$1: $2, expected $3"; fi; }

M="$(jq -c '.migration' "${TARGET_JSON}")"
[ "${M}" != "null" ] || { echo "✗ ${TARGET_JSON} has no .migration block"; exit 1; }
jm() { jq -er "$1" <<<"${M}"; }
L2M="$(jq -ec --arg s "${L2_CHAIN}" '.l2s[] | select(.slug == $s)' <<<"${M}")" \
    || { echo "✗ ${TARGET_JSON}: .migration.l2s has no entry for ${L2_CHAIN}"; exit 1; }
jl2() { jq -er "$1" <<<"${L2M}"; }

AGENT="$(jm '.l1.agent')"
L1_TOKEN="$(jm '.l1.token')"
L1_BRIDGE="$(jm '.l1.bridgeProxy')"
OPEXEC="$(jl2 '.executor')"
L2_TOKEN="$(jl2 '.token')"
L2_BRIDGE="$(jl2 '.bridgeProxy')"

echo "▸ chains"
assert_chain_id "${L1_RPC}" "${L1_CHAIN_ID}" "L1 ${L1_CHAIN}"
assert_chain_id "${L2_RPC}" "${L2_CHAIN_ID}" "L2 ${L2_CHAIN}"
ok "L1 ${L1_CHAIN} (${L1_CHAIN_ID}) at block $(cast block-number --rpc-url "${L1_RPC}"); L2 ${L2_CHAIN} (${L2_CHAIN_ID}) at block $(cast block-number --rpc-url "${L2_RPC}")"

echo "▸ chain records agree with the migration inputs"
expect "L1 record token"      "$(jq -r '.addresses.token' "${L1_CFG_CANON}")" "${L1_TOKEN}"
expect "L1 record DAO agent"  "$(jq -r '.governance_addresses.lido_dao_agent' "${L1_CFG_CANON}")" "${AGENT}"
expect "L2 record token"      "$(jq -r '.addresses.token' "${L2_CFG_CANON}")" "${L2_TOKEN}"
expect "L2 record executor"   "$(jq -r '.governance_addresses.lido_dao_agent' "${L2_CFG_CANON}")" "${OPEXEC}"

echo "▸ bytecode present"
for pair in "${L1_TOKEN}:L1 wstETH" "${L1_BRIDGE}:L1 bridge proxy" "${AGENT}:Aragon Agent"; do
    assert_code "${pair%%:*}" "${L1_RPC}" "${pair#*:}"; ok "${pair#*:} ${pair%%:*}"
done
for pair in "${L2_TOKEN}:L2 wstETH proxy" "${L2_BRIDGE}:L2 bridge proxy" "${OPEXEC}:bridge executor"; do
    assert_code "${pair%%:*}" "${L2_RPC}" "${pair#*:}"; ok "${pair#*:} ${pair%%:*}"
done

echo "▸ L1 bridge ${L1_BRIDGE}"
L1_MESSENGER="$(cast call "${L1_BRIDGE}" 'messenger()(address)' --rpc-url "${L1_RPC}")"
L1_BRIDGE_IMPL="$(cast call "${L1_BRIDGE}" 'proxy__getImplementation()(address)' --rpc-url "${L1_RPC}")"
expect "proxy admin"   "$(cast call "${L1_BRIDGE}" 'proxy__getAdmin()(address)' --rpc-url "${L1_RPC}")" "${AGENT}"
expect "l1Token"       "$(cast call "${L1_BRIDGE}" 'l1Token()(address)' --rpc-url "${L1_RPC}")" "${L1_TOKEN}"
expect "l2Token"       "$(cast call "${L1_BRIDGE}" 'l2Token()(address)' --rpc-url "${L1_RPC}")" "${L2_TOKEN}"
expect "l2TokenBridge" "$(cast call "${L1_BRIDGE}" 'l2TokenBridge()(address)' --rpc-url "${L1_RPC}")" "${L2_BRIDGE}"
EXPECTED_L1_MESSENGER="$(jq -r '.l1.messenger // empty' <<<"${M}")"
[ -z "${EXPECTED_L1_MESSENGER}" ] || expect "messenger" "${L1_MESSENGER}" "${EXPECTED_L1_MESSENGER}"
assert_code "${L1_MESSENGER}" "${L1_RPC}" "L1 cross-domain messenger"
ESCROW="$(cast call "${L1_TOKEN}" 'balanceOf(address)(uint256)' "${L1_BRIDGE}" --rpc-url "${L1_RPC}" | awk '{print $1}')"
ok "implementation ${L1_BRIDGE_IMPL}; messenger ${L1_MESSENGER}; escrow ${ESCROW} wei wstETH"

echo "▸ L2 bridge ${L2_BRIDGE}"
L2_MESSENGER="$(cast call "${L2_BRIDGE}" 'messenger()(address)' --rpc-url "${L2_RPC}")"
L2_BRIDGE_IMPL="$(cast call "${L2_BRIDGE}" 'proxy__getImplementation()(address)' --rpc-url "${L2_RPC}")"
expect "proxy admin"   "$(cast call "${L2_BRIDGE}" 'proxy__getAdmin()(address)' --rpc-url "${L2_RPC}")" "${OPEXEC}"
expect "l1Token"       "$(cast call "${L2_BRIDGE}" 'l1Token()(address)' --rpc-url "${L2_RPC}")" "${L1_TOKEN}"
expect "l2Token"       "$(cast call "${L2_BRIDGE}" 'l2Token()(address)' --rpc-url "${L2_RPC}")" "${L2_TOKEN}"
expect "l1TokenBridge" "$(cast call "${L2_BRIDGE}" 'l1TokenBridge()(address)' --rpc-url "${L2_RPC}")" "${L1_BRIDGE}"
EXPECTED_L2_MESSENGER="$(jq -r '.messenger // empty' <<<"${L2M}")"
[ -z "${EXPECTED_L2_MESSENGER}" ] || expect "messenger" "${L2_MESSENGER}" "${EXPECTED_L2_MESSENGER}"
expect "messenger pairs with L1" "$(cast call "${L2_MESSENGER}" 'OTHER_MESSENGER()(address)' --rpc-url "${L2_RPC}")" "${L1_MESSENGER}"
ok "implementation ${L2_BRIDGE_IMPL}"

echo "▸ L2 token ${L2_TOKEN}"
L2_TOKEN_IMPL="$(cast call "${L2_TOKEN}" 'proxy__getImplementation()(address)' --rpc-url "${L2_RPC}")"
expect "proxy admin" "$(cast call "${L2_TOKEN}" 'proxy__getAdmin()(address)' --rpc-url "${L2_RPC}")" "${OPEXEC}"
TOKEN_NAME="$(cast call "${L2_TOKEN}" 'name()(string)' --rpc-url "${L2_RPC}" | sed 's/^"//; s/"$//')"
TOKEN_SYMBOL="$(cast call "${L2_TOKEN}" 'symbol()(string)' --rpc-url "${L2_RPC}" | sed 's/^"//; s/"$//')"
TOKEN_DECIMALS="$(cast call "${L2_TOKEN}" 'decimals()(uint8)' --rpc-url "${L2_RPC}")"
TOKEN_SUPPLY="$(cast call "${L2_TOKEN}" 'totalSupply()(uint256)' --rpc-url "${L2_RPC}" | awk '{print $1}')"
ok "implementation ${L2_TOKEN_IMPL}; ${TOKEN_NAME} (${TOKEN_SYMBOL}, ${TOKEN_DECIMALS} decimals); total supply ${TOKEN_SUPPLY} wei"

echo "▸ bridge executor ${OPEXEC}"
expect "ethereum governance executor" "$(cast call "${OPEXEC}" 'getEthereumGovernanceExecutor()(address)' --rpc-url "${L2_RPC}")" "${AGENT}"
ok "delay $(cast call "${OPEXEC}" 'getDelay()(uint256)' --rpc-url "${L2_RPC}" | awk '{print $1}')s, grace period $(cast call "${OPEXEC}" 'getGracePeriod()(uint256)' --rpc-url "${L2_RPC}" | awk '{print $1}')s"

echo "▸ Emergency Brakes on the legacy bridges (veto of activate / close through the disabler roles)"
L1_EB="$(jm '.l1.emergencyBrakes')"
L2_EB="$(jl2 '.emergencyBrakes')"
DEPOSITS_DISABLER="$(cast keccak 'BridgingManager.DEPOSITS_DISABLER_ROLE')"
WITHDRAWALS_DISABLER="$(cast keccak 'BridgingManager.WITHDRAWALS_DISABLER_ROLE')"
DEPOSITS_ENABLER="$(cast keccak 'BridgingManager.DEPOSITS_ENABLER_ROLE')"
WITHDRAWALS_ENABLER="$(cast keccak 'BridgingManager.WITHDRAWALS_ENABLER_ROLE')"
expect "L1 Emergency Brakes hold DEPOSITS_DISABLER_ROLE" "$(cast call "${L1_BRIDGE}" 'hasRole(bytes32,address)(bool)' "${DEPOSITS_DISABLER}" "${L1_EB}" --rpc-url "${L1_RPC}")" true
expect "L1 Agent holds DEPOSITS_ENABLER_ROLE"            "$(cast call "${L1_BRIDGE}" 'hasRole(bytes32,address)(bool)' "${DEPOSITS_ENABLER}" "${AGENT}" --rpc-url "${L1_RPC}")" true
expect "L2 Emergency Brakes hold WITHDRAWALS_DISABLER_ROLE" "$(cast call "${L2_BRIDGE}" 'hasRole(bytes32,address)(bool)' "${WITHDRAWALS_DISABLER}" "${L2_EB}" --rpc-url "${L2_RPC}")" true
expect "L2 executor holds WITHDRAWALS_ENABLER_ROLE"        "$(cast call "${L2_BRIDGE}" 'hasRole(bytes32,address)(bool)' "${WITHDRAWALS_ENABLER}" "${OPEXEC}" --rpc-url "${L2_RPC}")" true

[ "${FAIL}" = 0 ] || { echo "✗ migration inputs do not match the chain state"; exit 1; }

mkdir -p state
# merge_state <file> <json>: the inputs overwrite their own keys and leave every other key — the
# timelock and CallProxy pins step 04 records, the implementations step 06 writes — in place, so a
# re-check of the inputs after those steps does not erase what they recorded.
merge_state() {
    local file="$1" json="$2"
    [ -f "${file}" ] || echo '{}' > "${file}"
    jq_inplace "${file}" --argjson inputs "${json}" '. + $inputs'
}
merge_state state/l1.json "$(jq -n --argjson cid "${L1_CHAIN_ID}" --arg t "${L1_TOKEN}" --arg a "${AGENT}" --arg b "${L1_BRIDGE}" \
      --arg bi "${L1_BRIDGE_IMPL}" --arg m "${L1_MESSENGER}" --arg e "${ESCROW}" --arg eb "${L1_EB}" \
    '{chainId: $cid, wstETH: $t, agent: $a, legacyBridge: $b, legacyBridgeImplementation: $bi, messenger: $m, escrowAtInput: $e, emergencyBrakes: $eb}')"
merge_state "${L2_STATE_FILE}" "$(jq -n --arg c "${L2_CHAIN}" --argjson cid "${L2_CHAIN_ID}" --arg t "${L2_TOKEN}" --arg ti "${L2_TOKEN_IMPL}" \
      --arg o "${OPEXEC}" --arg a "${AGENT}" --arg b "${L2_BRIDGE}" --arg bi "${L2_BRIDGE_IMPL}" --arg m "${L2_MESSENGER}" \
      --arg n "${TOKEN_NAME}" --arg s "${TOKEN_SYMBOL}" --arg sup "${TOKEN_SUPPLY}" --arg eb "${L2_EB}" \
    '{l2Chain: $c, chainId: $cid, wstETH: $t, wstETHImpl: $ti, opExec: $o, ethereumGovernanceExecutor: $a,
      legacyBridge: $b, legacyBridgeImplementation: $bi, messenger: $m, tokenName: $n, tokenSymbol: $s, totalSupplyAtInput: $sup, emergencyBrakes: $eb}')"
echo ""
echo "✓ step 01m done — existing contracts recorded in state/l1.json and ${L2_STATE_FILE}; nothing deployed."
