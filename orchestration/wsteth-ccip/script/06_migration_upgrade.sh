#!/usr/bin/env bash
# Step 06 — execute the one DAO vote using the three implementations prepared earlier.
# The Agent upgrades the L1 bridge, authorizes it on the Base lockbox, arms both timers,
# and sends the Base action set. The real Base messenger relays that action set to the
# executor, which upgrades token/bridge, assigns roles, binds the pool and arms timers.
# Legacy transfers started before the vote remain in flight for the scenario tests.
# FORK-ONLY: Agent and aliased L1 messenger are impersonated. On hub targets the order is
# hub-prepare -> hub-cutover -> hub-accept-admin -> base-prepare -> hub-connect-lane -> vote.
# Activation, sweep and close are exercised afterwards by the scenario tests.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
cd "${ROOT}"
. "${HERE}/_common.sh"
[ "${WSTETH_OPERATION}" = "in-place-upgrade" ] \
    || { echo "✗ step 06 is for in-place-upgrade targets (WSTETH_OPERATION=${WSTETH_OPERATION})"; exit 1; }
: "${DEPLOYER_PRIVATE_KEY:?set DEPLOYER_PRIVATE_KEY}"
DEPLOYER="$(cast wallet address --private-key "${DEPLOYER_PRIVATE_KEY}")"
export DEPLOYER_ADDRESS="${DEPLOYER}"
is_anvil "${L1_RPC}" && is_anvil "${L2_RPC}" \
    || { echo "✗ step 06 impersonates governance principals and is fork-only; ${L1_RPC} / ${L2_RPC} are not anvil"; exit 1; }

assert_l2_state_chain
for f in state/l1.json "${L2_STATE_FILE}"; do [ -f "$f" ] || { echo "✗ missing $f (run step 01m)"; exit 1; }; done
L1_CFG="${CFG_DIR}/${L1_CHAIN}.json"; L2_CFG="${CFG_DIR}/${L2_CHAIN}.json"
for f in "${L1_CFG}" "${L2_CFG}"; do
    jq -e '.deployed.token_pool and .deployed.timelock' "$f" >/dev/null \
        || { echo "✗ $f carries no lane deployment (run steps 04–05 first)"; exit 1; }
done
TARGET_JSON="${WSTETH_TARGET_DIR:?run via just wsteth so the target directory is explicit}/target.json"
TOKEN_VERSION="$(jq -r '.migration.tokenVersion // "2"' "${TARGET_JSON}")"
# The timelocks must already be administered by the DAO (step 07): the vote uses their admin bypass.
timelock_admin_is() {  # <timelock> <dao> <rpc>
    local role; role="$(cast call "$1" 'ADMIN_ROLE()(bytes32)' --rpc-url "$3")"
    [ "$(cast call "$1" 'hasRole(bytes32,address)(bool)' "${role}" "$2" --rpc-url "$3")" = "true" ]
}
timelock_admin_is "$(jq -er '.deployed.timelock' "${L1_CFG}")" "$(jq -er '.agent' state/l1.json)" "${L1_RPC}" \
    || { echo "✗ the Agent is not the ${L1_CHAIN} timelock admin (run step 07 before step 06)"; exit 1; }
timelock_admin_is "$(jq -er '.deployed.timelock' "${L2_CFG}")" "$(jq -er '.opExec' "${L2_STATE_FILE}")" "${L2_RPC}" \
    || { echo "✗ the executor is not the ${L2_CHAIN} timelock admin (run step 07 before step 06)"; exit 1; }

# ── timers of the vote ────────────────────────────────────────────────────────────────────────
L1_ACTIVATION_DELAY="$(jq -er '.migration.timers.l1ActivationDelay' "${TARGET_JSON}")"
L2_ACTIVATION_DELAY="$(jq -er '.migration.timers.l2ActivationDelay' "${TARGET_JSON}")"
CLOSE_DELAY="$(jq -er '.migration.timers.closeDelay' "${TARGET_JSON}")"
NOW="$(cast block latest -f timestamp --rpc-url "${L1_RPC}")"
export ACTIVATE_L1_AT=$((NOW + L1_ACTIVATION_DELAY))
export ACTIVATE_L2_AT=$((ACTIVATE_L1_AT + L2_ACTIVATION_DELAY))
export CLOSE_AT=$((ACTIVATE_L2_AT + CLOSE_DELAY))
echo "▸ timers: T₀ ${NOW}, T_L1 ${ACTIVATE_L1_AT}, T_${L2_CHAIN} ${ACTIVATE_L2_AT}, T_close ${CLOSE_AT}"

# ── artifacts: each component builds with its own foundry.toml ────────────────────────────────
BRIDGE_ROOT="$(cd "${ROOT}/../../components/l2-bridge-migration" && pwd -P)"
TOKEN_ROOT="$(cd "${ROOT}/../../components/wsteth-token" && pwd -P)"
echo "▸ building component artifacts"
forge build --root "${BRIDGE_ROOT}" --silent
forge build --root "${TOKEN_ROOT}" --silent contracts/token/ERC20BridgedPermit.sol
export TOKEN_ARTIFACT="${TOKEN_ROOT}/out/ERC20BridgedPermit.sol/ERC20BridgedPermit.json"
export L1_BRIDGE_ARTIFACT="${BRIDGE_ROOT}/out/L1MigrationBridge.sol/L1MigrationBridge.json"
export L2_BRIDGE_ARTIFACT="${BRIDGE_ROOT}/out/L2MigrationBridge.sol/L2MigrationBridge.json"
for f in "${TOKEN_ARTIFACT}" "${L1_BRIDGE_ARTIFACT}" "${L2_BRIDGE_ARTIFACT}"; do [ -f "$f" ] || { echo "✗ missing artifact $f"; exit 1; }; done

export L1_CFG L2_CFG TOKEN_VERSION
export L1_STATE="${ROOT}/state/l1.json" L2_STATE="${ROOT}/${L2_STATE_FILE}"
MIG_DIR="${ROOT}/state/migration"; mkdir -p "${MIG_DIR}"

# Implementations were prepared before connecting Base. Other in-place targets use this fallback.
if [ ! -f "${MIG_DIR}/l1-deploy.json" ] || [ ! -f "${MIG_DIR}/l2-deploy.json" ]; then
    if jq -e '.migration.hub' "$TARGET_JSON" >/dev/null; then
        echo 'Missing prepared implementations: run base-prepare before the lane proposal and vote'; exit 1
    fi
    bash "${HERE}/06a_migration_deploy.sh"
fi
export L1_DEPLOY_JSON="${MIG_DIR}/l1-deploy.json"
export L2_DEPLOY_JSON="${MIG_DIR}/l2-deploy.json"

# ── principals (read from the records, never literals) ────────────────────────────────────────
AGENT="$(jq -er '.agent' state/l1.json)"
L1_MESSENGER="$(jq -er '.messenger' state/l1.json)"
OPEXEC="$(jq -er '.opExec' "${L2_STATE_FILE}")"
L2_MESSENGER="$(jq -er '.messenger' "${L2_STATE_FILE}")"
L1_TOKEN="$(jq -er '.addresses.token' "${L1_CFG}")"
# AddressAliasHelper.applyL1ToL2Alias: the L2 messenger only accepts relays from the aliased L1 messenger.
ALIASED_L1_MESSENGER="$(uv run python3 -I -c 'import sys; print("0x%040x" % ((int(sys.argv[1],16) + 0x1111000000000000000000000000000000001111) % (1<<160)))' "${L1_MESSENGER}")"
echo "▸ principals: Agent ${AGENT}, executor ${OPEXEC}, aliased L1 messenger ${ALIASED_L1_MESSENGER}"
for a in "${AGENT}" "${DEPLOYER}"; do fund "${a}" "${L1_RPC}"; done
for a in "${ALIASED_L1_MESSENGER}" "${DEPLOYER}"; do fund "${a}" "${L2_RPC}"; done

run_migration_script() {  # <Contract file:name> <rpc> <out json> [extra forge args]
    local target="$1" rpc="$2" out="$3"; shift 3
    OUT_JSON="${out}" FOUNDRY_PROFILE=migration forge script "script/migration/${target}" \
        --rpc-url "${rpc}" --sender "${DEPLOYER}" --non-interactive -vv "$@"
}

# ── 0. Legacy transfers in flight across the upgrade ──────────────────────────────────────────
# The rehearsal must show that transfers started on the OLD implementations still finalize after
# the upgrade. A rehearsal user gets L1 wstETH (fork storage write), bridges D0 through the legacy
# path and D0 is relayed so the user also holds Base wstETH backed by the escrow; then D1 (L1
# deposit) and W1 (Base withdrawal) are started and left in flight for the scenario to relay after
# the upgrade. Messages are recorded exactly as the messengers emitted them (SentMessage).
USER="$(uv run python3 -I -c 'import hashlib; print("0x" + hashlib.sha3_256(b"base-migration-rehearsal-user").hexdigest()[-40:])')"
L2_TOKEN="$(jq -er '.addresses.token' "${L2_CFG}")"
L1_BRIDGE="$(jq -er '.legacyBridge' state/l1.json)"
L2_BRIDGE="$(jq -er '.legacyBridge' "${L2_STATE_FILE}")"
SEED_WEI=$(cast to-wei 40 ether)      # L1 wstETH the user starts with
D0_WEI=$(cast to-wei 10 ether)        # relayed before the upgrade: funds the user on Base
D1_WEI=$(cast to-wei 3 ether)         # L1 deposit left in flight
W1_WEI=$(cast to-wei 2 ether)         # Base withdrawal left in flight
fund "${USER}" "${L1_RPC}"; fund "${USER}" "${L2_RPC}"
# wstETH (OpenZeppelin ERC20, solidity 0.6.12) keeps _balances in slot 0.
if [ "${WSTETH_BOOTSTRAP:-}" = sepolia-migration ]; then
    with_fork_account "${L1_RPC}" "${DEPLOYER}" cast send "${L1_TOKEN}" 'transfer(address,uint256)' "${USER}" "${SEED_WEI}" \
        --from "${DEPLOYER}" --unlocked --rpc-url "${L1_RPC}" >/dev/null
else
    cast rpc anvil_setStorageAt "${L1_TOKEN}" "$(cast index address "${USER}" 0)" "$(cast to-uint256 "${SEED_WEI}")" --rpc-url "${L1_RPC}" >/dev/null
fi
[ "$(cast call "${L1_TOKEN}" 'balanceOf(address)(uint256)' "${USER}" --rpc-url "${L1_RPC}" | awk '{print $1}')" = "${SEED_WEI}" ] \
    || { echo "✗ could not seed the rehearsal user with L1 wstETH"; exit 1; }
with_fork_account "${L1_RPC}" "${USER}" cast send "${L1_TOKEN}" 'approve(address,uint256)' "${L1_BRIDGE}" "${SEED_WEI}" --from "${USER}" --unlocked --rpc-url "${L1_RPC}" >/dev/null
# sent_message <receipt json> <messenger>: prints "nonce gasLimit sender message" from the SentMessage event.
SENT_MESSAGE_TOPIC="$(cast keccak 'SentMessage(address,address,bytes,uint256,uint256)')"
sent_message() {
    local receipt="$1" messenger="$2" data
    data="$(jq -r --arg m "$(lc "${messenger}")" --arg t "${SENT_MESSAGE_TOPIC}" \
        '.logs[] | select((.address | ascii_downcase) == $m and .topics[0] == $t) | .data' <<<"${receipt}" | head -1)"
    [ -n "${data}" ] || { echo "✗ no SentMessage event from ${messenger}" >&2; return 1; }
    # cast prints one value per line and annotates integers (`200000 [2e5]`); strip the annotation.
    cast abi-decode 'x()(address,bytes,uint256,uint256)' "${data}" | sed -E 's/ \[[^]]*\]//' | tr '\n' ' ' | awk '{print $3, $4, $1, $2}'
}
# legacy_deposit <wei>: user deposits on L1 through the legacy path; prints the SentMessage fields.
legacy_deposit() {
    local receipt
    receipt="$(with_fork_account "${L1_RPC}" "${USER}" cast send "${L1_BRIDGE}" 'depositERC20(address,address,uint256,uint32,bytes)' "${L1_TOKEN}" "${L2_TOKEN}" "$1" 200000 0x \
        --from "${USER}" --unlocked --rpc-url "${L1_RPC}" --json)"
    sent_message "${receipt}" "${L1_MESSENGER}"
}
# relay_to_l2 "<nonce> <gas> <sender> <message>": relay an L1 SentMessage on Base from the aliased L1 messenger.
relay_to_l2() {
    local nonce gas sender message data hash
    read -r nonce gas sender message <<<"$1"
    data="$(cast calldata 'relayMessage(uint256,address,address,uint256,uint256,bytes)' "${nonce}" "${sender}" "${L2_BRIDGE}" 0 "${gas}" "${message}")"
    hash="$(cast keccak "${data}")"
    with_fork_account "${L2_RPC}" "${ALIASED_L1_MESSENGER}" cast send "${L2_MESSENGER}" "${data}" --from "${ALIASED_L1_MESSENGER}" --unlocked --gas-limit 3000000 --rpc-url "${L2_RPC}" >/dev/null
    [ "$(cast call "${L2_MESSENGER}" 'successfulMessages(bytes32)(bool)' "${hash}" --rpc-url "${L2_RPC}")" = "true" ] \
        || { echo "✗ relay of nonce ${nonce} to Base failed"; exit 1; }
}
echo ""
echo "▸ 0) legacy transfers: D0 (relayed), then D1 and W1 left in flight across the upgrade"
D0="$(legacy_deposit "${D0_WEI}")"; relay_to_l2 "${D0}"
[ "$(cast call "${L2_TOKEN}" 'balanceOf(address)(uint256)' "${USER}" --rpc-url "${L2_RPC}" | awk '{print $1}')" = "${D0_WEI}" ] \
    || { echo "✗ D0 did not mint ${D0_WEI} wei on Base"; exit 1; }
D1="$(legacy_deposit "${D1_WEI}")"
W1_RECEIPT="$(with_fork_account "${L2_RPC}" "${USER}" cast send "${L2_BRIDGE}" 'withdraw(address,uint256,uint32,bytes)' "${L2_TOKEN}" "${W1_WEI}" 200000 0x --from "${USER}" --unlocked --rpc-url "${L2_RPC}" --json)"
W1="$(sent_message "${W1_RECEIPT}" "${L2_MESSENGER}")"
read -r D1_NONCE D1_GAS D1_SENDER D1_MESSAGE <<<"${D1}"
read -r W1_NONCE W1_GAS W1_SENDER W1_MESSAGE <<<"${W1}"
jq -n --arg u "${USER}" --arg dn "${D1_NONCE}" --arg dg "${D1_GAS}" --arg ds "${D1_SENDER}" --arg dm "${D1_MESSAGE}" --arg dw "${D1_WEI}" \
      --arg wn "${W1_NONCE}" --arg wg "${W1_GAS}" --arg ws "${W1_SENDER}" --arg wm "${W1_MESSAGE}" --arg ww "${W1_WEI}" \
    '{user: $u,
      inFlightDeposit: {nonce: $dn, gasLimit: $dg, sender: $ds, message: $dm, amount: $dw},
      inFlightWithdrawal: {nonce: $wn, gasLimit: $wg, sender: $ws, message: $wm, amount: $ww}}' \
    > "${MIG_DIR}/in-flight.json"
echo "  user ${USER}: D0 ${D0_WEI} wei relayed; D1 ${D1_WEI} wei (nonce ${D1_NONCE}) and W1 ${W1_WEI} wei (nonce ${W1_NONCE}) in flight"

# ── 2. Ethereum: the vote as the Agent ────────────────────────────────────────────────────────
echo ""
echo "▸ 2) ${L1_CHAIN}: vote using prepared implementations (Agent, impersonated): upgrade, lockbox authorization, timers, governance message"
with_fork_account "${L1_RPC}" "${DEPLOYER}" with_fork_account "${L1_RPC}" "${AGENT}" run_migration_script MigrationL1Upgrade.s.sol:MigrationL1Upgrade "${L1_RPC}" "${MIG_DIR}/l1-upgrade.json" --broadcast --unlocked
export L1_UPGRADE_JSON="${MIG_DIR}/l1-upgrade.json"

# ── 3. Base: relay the governance message through the real messenger, execute, verify ─────────
echo ""
echo "▸ 3) ${L2_CHAIN}: relay the governance message (aliased L1 messenger, impersonated), execute the action set"
QUEUE_CALLDATA="$(jq -er '.queueCalldata' "${L1_UPGRADE_JSON}")"
NONCE="$(jq -er '.governanceMessageNonce' "${L1_UPGRADE_JSON}")"
GAS="$(jq -er '.governanceMessageGas' "${L1_UPGRADE_JSON}")"
COUNT_BEFORE="$(cast call "${OPEXEC}" 'getActionsSetCount()(uint256)' --rpc-url "${L2_RPC}" | awk '{print $1}')"
RELAY_DATA="$(cast calldata 'relayMessage(uint256,address,address,uint256,uint256,bytes)' "${NONCE}" "${AGENT}" "${OPEXEC}" 0 "${GAS}" "${QUEUE_CALLDATA}")"
RELAY_HASH="$(cast keccak "${RELAY_DATA}")"
with_fork_account "${L2_RPC}" "${ALIASED_L1_MESSENGER}" cast send "${L2_MESSENGER}" "${RELAY_DATA}" --from "${ALIASED_L1_MESSENGER}" --unlocked --gas-limit 6000000 --rpc-url "${L2_RPC}" >/dev/null
if [ "$(cast call "${L2_MESSENGER}" 'successfulMessages(bytes32)(bool)' "${RELAY_HASH}" --rpc-url "${L2_RPC}")" != "true" ]; then
    echo "✗ the governance message was relayed but its execution failed (failedMessages=$(cast call "${L2_MESSENGER}" 'failedMessages(bytes32)(bool)' "${RELAY_HASH}" --rpc-url "${L2_RPC}"))"
    exit 1
fi
COUNT_AFTER="$(cast call "${OPEXEC}" 'getActionsSetCount()(uint256)' --rpc-url "${L2_RPC}" | awk '{print $1}')"
[ "${COUNT_AFTER}" = "$((COUNT_BEFORE + 1))" ] || { echo "✗ executor action set count ${COUNT_BEFORE} -> ${COUNT_AFTER}, expected one new set"; exit 1; }
ACTIONS_SET_ID="${COUNT_BEFORE}"
[ "$(cast call "${OPEXEC}" 'getCurrentState(uint256)(uint8)' "${ACTIONS_SET_ID}" --rpc-url "${L2_RPC}")" = "0" ] \
    || { echo "✗ action set ${ACTIONS_SET_ID} is not Queued"; exit 1; }
echo "  action set ${ACTIONS_SET_ID} queued through the messenger relay; executing (delay $(cast call "${OPEXEC}" 'getDelay()(uint256)' --rpc-url "${L2_RPC}" | awk '{print $1}')s)"
cast send "${OPEXEC}" 'execute(uint256)' "${ACTIONS_SET_ID}" --private-key "${DEPLOYER_PRIVATE_KEY}" --gas-limit 8000000 --rpc-url "${L2_RPC}" >/dev/null
[ "$(cast call "${OPEXEC}" 'getCurrentState(uint256)(uint8)' "${ACTIONS_SET_ID}" --rpc-url "${L2_RPC}")" = "1" ] \
    || { echo "✗ action set ${ACTIONS_SET_ID} did not reach Executed"; exit 1; }
ACTIONS_SET_ID="${ACTIONS_SET_ID}" RELAYED_HASH="${RELAY_HASH}" \
    run_migration_script MigrationL2Verify.s.sol:MigrationL2Verify "${L2_RPC}" "${MIG_DIR}/l2-execute.json"

# ── 4. Record ─────────────────────────────────────────────────────────────────────────────────
jq -s 'add' "${MIG_DIR}/in-flight.json" "${MIG_DIR}/l2-deploy.json" "${MIG_DIR}/l1-upgrade.json" "${MIG_DIR}/l2-execute.json" > state/migration.json
L2_TOKEN_IMPL="$(jq -er '.l2TokenImplementation' state/migration.json)"
L2_BRIDGE_IMPL="$(jq -er '.l2BridgeImplementation' state/migration.json)"
L1_BRIDGE_IMPL="$(jq -er '.l1BridgeImplementation' state/migration.json)"
jq_inplace "${L2_STATE_FILE}" --arg t "${L2_TOKEN_IMPL}" --arg b "${L2_BRIDGE_IMPL}" \
    '.wstETHImpl = $t | .migrationBridgeImplementation = $b'
jq_inplace state/l1.json --arg b "${L1_BRIDGE_IMPL}" '.migrationBridgeImplementation = $b'
echo ""
echo "✓ step 06 done — the vote executed on both forks (T₀ ${NOW})."
echo "L1 bridge implementation:  ${L1_BRIDGE_IMPL}"
echo "L2 token implementation:   ${L2_TOKEN_IMPL}"
echo "L2 bridge implementation:  ${L2_BRIDGE_IMPL}"
echo "Base action set:           ${ACTIONS_SET_ID} (hash $(jq -r '.executedActionSetHash' state/migration.json))"
echo "Timers:                    activate L1 at ${ACTIVATE_L1_AT}, activate ${L2_CHAIN} at ${ACTIVATE_L2_AT}, close at ${CLOSE_AT}"
echo "Both bridges are on the new code in LEGACY; the scenario test drives activate / sweep / close."
