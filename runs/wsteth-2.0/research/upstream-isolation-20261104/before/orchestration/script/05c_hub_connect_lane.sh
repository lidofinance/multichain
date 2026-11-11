#!/usr/bin/env bash
# Step 05c — FORK-ONLY, in-place targets with `.migration.hub`: Chainlink connects the pair lane
# (L2_CHAIN, the target's spoke) to the new hub AFTER the cutover. The hub belongs to the LidoTimelock
# by then, so the lane is a proposal of the timelock: scheduled by its proposer (Chainlink MCMS,
# impersonated here), the minimum delay waited by warping the fork clock, executed by the deployer
# key through the timelock's CallProxy (which forwards anyone's call).
#
# The batch is exactly what 2_Configure applies for a lane it configures and did not apply for this
# one (the hub record lists it under `deferred_lanes`, written by step 01h): it is built by the
# component's own 4_ConnectLane from the same records, so the rehearsal connects the lane with the
# same configuration the scratch deploy would have used.
#   1. TokenPool.applyChainUpdates([], [lane])                       selector, spoke pool and token, limits
#   2. TokenPool.applyTokenTransferFeeConfigUpdates([lane], [])
#   3. SiloedLockReleaseTokenPool.configureLockBoxes([lane → lockbox])  the lockbox 1_Deploy built for it
#   4. AdvancedPoolHooks.applyCCVConfigUpdates([lane])                the local resolver, both directions
#   5. DummyMessageIdVerifier.applyRemoteChainConfigUpdates([lane])
#   6. VersionedVerifierResolver.applyOutboundImplementationUpdates([lane])
#
# Before: the registry binds the new hub (step 05h) and the hub serves the old pool's lanes only; the
# spoke pool is deployed and configured (steps 04, 05) and names the hub chain as its lane. After: the
# pair lane is supported with the record's spoke pool and token and the component's default limits,
# its lockbox bound, its hooks entry and verifier/resolver entries set; every other lane, every
# lockbox balance and the registry entry unchanged. Recorded in state/hub-lane-connect.json
# (the batch, hashes, tx hashes, snapshots, checks, what stayed unverified) and state/l1.json
# (hubLaneConnect). Runs after 05h and before 07; a target without `.migration.hub` has nothing to do.
#
# Not rehearsed here: MCMS signing (the proposer is impersonated); nothing changes on the spoke in
# this step. Known window: between this connection and the spoke's action set (step 06) a hub → spoke
# send locks wstETH in the lane's lockbox until the spoke can mint.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
cd "${ROOT}"
. "${HERE}/_common.sh"
[ "${WSTETH_OPERATION}" = "in-place-upgrade" ] \
    || { echo "✗ step 05c is for in-place-upgrade targets (WSTETH_OPERATION=${WSTETH_OPERATION})"; exit 1; }
TARGET_JSON="${WSTETH_TARGET_DIR:?run via just wsteth so the target directory is explicit}/target.json"
if ! jq -e '.migration.hub' "${TARGET_JSON}" >/dev/null 2>&1; then
    echo "▸ ${TARGET_JSON} declares no .migration.hub: no deferred hub lane in this target."; exit 0
fi
if [ "${WSTETH_SKIP_L1:-0}" = 1 ]; then echo "▸ hub-only step (WSTETH_SKIP_L1=1); skip."; exit 0; fi
: "${DEPLOYER_PRIVATE_KEY:?set DEPLOYER_PRIVATE_KEY}"
DEPLOYER="$(cast wallet address --private-key "${DEPLOYER_PRIVATE_KEY}")"
is_anvil "${L1_RPC}" || { echo "✗ step 05c impersonates the LidoTimelock proposer and warps the clock; ${L1_RPC} is not anvil"; exit 1; }
L1_CFG="${CFG_DIR}/${L1_CHAIN}.json"; L2_CFG="${CFG_DIR}/${L2_CHAIN}.json"
jq -e '.deployed.token_pool and .deployed.timelock and .deployed.call_proxy and .ccv.verifier_resolver and .ccv.message_id_verifier' "${L1_CFG}" >/dev/null \
    || { echo "✗ ${L1_CFG} carries no configured hub deployment (run steps 04–05)"; exit 1; }
jq -e '.deployed.token_pool and .ccip.chain_selector' "${L2_CFG}" >/dev/null \
    || { echo "✗ ${L2_CFG} carries no configured spoke deployment (run steps 04–05)"; exit 1; }
[ -f state/hub-migration.json ] || { echo "✗ missing state/hub-migration.json: the cutover (step 05h) comes first — the lane is connected to the hub the registry binds"; exit 1; }
jq -e --arg l "${L2_CHAIN}" '.deferred_lanes // [] | index($l)' "${L1_CFG}" >/dev/null \
    || { echo "✗ ${L1_CFG} does not list ${L2_CHAIN} under deferred_lanes (step 01h writes it); 2_Configure then configured the lane itself and there is nothing to connect"; exit 1; }
RUN_ID="$(basename "$(cd "${ROOT}/.active-run" && pwd -P)")"
OUT="${ROOT}/state/hub-lane-connect.json"

callv() { cast call --rpc-url "${L1_RPC}" "$@"; }
num() { awk '{print $1}'; }
# limiter2 <two tuples, one per line>: "outEnabled outCapacity outRate inEnabled inCapacity inRate"
limiter2() { printf '%s' "$1" | sed -E 's/ \[[^]]*\]//g; s/[()]//g' | tr -d ' ' | awk -F, 'NR==1{o=$3" "$4" "$5} NR==2{print o, $3, $4, $5}'; }
decode_address_words() {
    local w
    for w in $(printf '%s' "$1" | grep -oE '0x[0-9a-fA-F]+'); do cast abi-decode 'x()(address)' "${w}"; done
}
addresses_of() { printf '%s' "$1" | grep -oE '0x[0-9a-fA-F]{40}' | tr 'A-F' 'a-f' | sort | paste -sd, -; }
balance() { callv "${TOKEN}" 'balanceOf(address)(uint256)' "$1" | num; }

TOKEN="$(record_token "${L1_CFG}")"; TAR="$(jq -er '.ccip.token_admin_registry' "${L1_CFG}")"; ROUTER="$(jq -er '.ccip.router' "${L1_CFG}")"
HUB="$(jq -er '.deployed.token_pool' "${L1_CFG}")"; HOOKS="$(jq -er '.deployed.advanced_pool_hooks' "${L1_CFG}")"
VERIFIER="$(jq -er '.ccv.message_id_verifier' "${L1_CFG}")"; RESOLVER="$(jq -er '.ccv.verifier_resolver' "${L1_CFG}")"
LIDO_TIMELOCK="$(jq -er '.deployed.timelock' "${L1_CFG}")"; CALL_PROXY="$(jq -er '.deployed.call_proxy' "${L1_CFG}")"
MCMS="${HUB_LANE_PROPOSER:-$(jq -er '.governance_addresses.chainlink_mcms' "${L1_CFG}")}"
L1_SELECTOR="$(jq -er '.ccip.chain_selector' "${L1_CFG}")"
PAIR_SELECTOR="$(jq -er '.ccip.chain_selector' "${L2_CFG}")"
SPOKE_POOL="$(jq -er '.deployed.token_pool' "${L2_CFG}")"; SPOKE_TOKEN="$(record_token "${L2_CFG}")"
PAIR_LOCKBOX="$(jq -er --arg lane "${L2_CHAIN}" '[.deployed.lock_boxes[] | select(.remote_chain_name == $lane)] | if length == 1 then .[0].lock_box else error("missing or duplicate lockbox of the pair") end' "${L1_CFG}")"
ALL_LOCKBOXES="$(jq -r '[.deployed.lock_boxes[].lock_box] | unique | .[]' "${L1_CFG}")"
CUTOVER_LANES="$(jq -r '.laneCount' state/hub-migration.json)"

if [ -f "${OUT}" ] || [ "$(callv "${HUB}" 'isSupportedChain(uint64)(bool)' "${PAIR_SELECTOR}")" = true ]; then
    echo "▸ the hub ${HUB} already serves ${L2_CHAIN} (selector ${PAIR_SELECTOR}) or ${OUT#${ROOT}/} exists: lane connected in this run; skip."
    exit 0
fi

# ── 0. preflight: the hub is the registry's and the LidoTimelock's; the proposal path is open ──
echo "▸ 0) preflight on ${L1_CHAIN} (${L1_RPC}): connect ${L2_CHAIN} (selector ${PAIR_SELECTOR}) to the hub ${HUB}"
FAIL=0; bad() { echo "  ✗ $*"; FAIL=1; }; ok() { echo "  ✔ $*"; }
read -r TAR_ADMIN TAR_PENDING TAR_POOL <<<"$(callv "${TAR}" 'getTokenConfig(address)((address,address,address))' "${TOKEN}" | tr -d '()' | tr ',' ' ')"
eq "${TAR_POOL}" "${HUB}" && ok "registry binds ${TOKEN} to the hub (administrator ${TAR_ADMIN}, pending ${TAR_PENDING})" \
    || bad "registry pool is ${TAR_POOL}, not the hub: run the cutover (step 05h) first"
for c in "${HUB}:hub" "${HOOKS}:hooks" "${VERIFIER}:verifier" "${RESOLVER}:resolver" "${PAIR_LOCKBOX}:${L2_CHAIN} lockbox"; do
    addr="${c%%:*}"; label="${c#*:}"
    eq "$(callv "${addr}" 'owner()(address)')" "${LIDO_TIMELOCK}" && ok "${label} ${addr} owned by the LidoTimelock" || bad "${label} ${addr} is not owned by the LidoTimelock ${LIDO_TIMELOCK}"
done
callv "${PAIR_LOCKBOX}" 'getAllAuthorizedCallers()(address[])' | tr 'A-F' 'a-f' | grep -q "$(lc "${HUB}")" \
    && ok "${L2_CHAIN} lockbox authorizes the hub" || bad "${L2_CHAIN} lockbox ${PAIR_LOCKBOX} does not authorize the hub"
PROPOSER_ROLE="$(callv "${LIDO_TIMELOCK}" 'PROPOSER_ROLE()(bytes32)')"; EXECUTOR_ROLE="$(callv "${LIDO_TIMELOCK}" 'EXECUTOR_ROLE()(bytes32)')"
[ "$(callv "${LIDO_TIMELOCK}" 'hasRole(bytes32,address)(bool)' "${PROPOSER_ROLE}" "${MCMS}")" = true ] \
    && ok "proposer to impersonate: ${MCMS} (governance_addresses.chainlink_mcms)" || bad "${MCMS} holds no PROPOSER_ROLE on the LidoTimelock"
[ "$(callv "${LIDO_TIMELOCK}" 'hasRole(bytes32,address)(bool)' "${EXECUTOR_ROLE}" "${CALL_PROXY}")" = true ] && has_code "${CALL_PROXY}" "${L1_RPC}" \
    && ok "executor: CallProxy ${CALL_PROXY} (called by the deployer ${DEPLOYER})" || bad "${CALL_PROXY} is not the timelock's executor"
[ "$(callv "${LIDO_TIMELOCK}" 'isProposalQueueHalted()(bool)')" = false ] && ok "proposal queue open" || bad "the LidoTimelock's proposal queue is halted"
MIN_DELAY="$(callv "${LIDO_TIMELOCK}" 'getMinDelay()(uint256)' | num)"; EXPIRY="$(callv "${LIDO_TIMELOCK}" 'getExpiryPeriod()(uint120)' | num)"
[ "${EXPIRY}" -gt "${MIN_DELAY}" ] && ok "min delay ${MIN_DELAY}s, expiry ${EXPIRY}s" || bad "expiry ${EXPIRY}s does not exceed the min delay ${MIN_DELAY}s"
SUPPORTED_BEFORE="$(callv "${HUB}" 'getSupportedChains()(uint64[])' | grep -oE '[0-9]{15,}' | sort)"
[ "$(printf '%s\n' "${SUPPORTED_BEFORE}" | grep -c .)" = "${CUTOVER_LANES}" ] \
    && ok "hub serves the ${CUTOVER_LANES} lanes of the cutover and no other" \
    || bad "hub serves $(printf '%s\n' "${SUPPORTED_BEFORE}" | grep -c .) lanes, the cutover record ${CUTOVER_LANES}"
callv "${HUB}" 'getLockBox(uint64)(address)' "${PAIR_SELECTOR}" >/dev/null 2>&1 && bad "a lockbox is already bound to selector ${PAIR_SELECTOR}" || ok "no lockbox bound to ${PAIR_SELECTOR} yet"
has_code "${SPOKE_POOL}" "${L2_RPC}" && ok "spoke pool ${SPOKE_POOL} deployed on ${L2_CHAIN}" || bad "no code at the spoke pool ${SPOKE_POOL} on ${L2_RPC}"
[ "$(cast call "${SPOKE_POOL}" 'isSupportedChain(uint64)(bool)' "${L1_SELECTOR}" --rpc-url "${L2_RPC}")" = true ] \
    && ok "spoke pool names ${L1_CHAIN} (selector ${L1_SELECTOR}) as its lane" || bad "spoke pool does not support ${L1_CHAIN}: run step 05 on ${L2_CHAIN}"
[ "${FAIL}" = 0 ] || { echo "✗ preflight failed; nothing scheduled."; exit 1; }

snapshot() {
    local boxes='{}' b
    for b in ${ALL_LOCKBOXES}; do boxes="$(jq -c --arg b "${b}" --arg v "$(balance "${b}")" '. + {($b): $v}' <<<"${boxes}")"; done
    read -r a p pl <<<"$(callv "${TAR}" 'getTokenConfig(address)((address,address,address))' "${TOKEN}" | tr -d '()' | tr ',' ' ')"
    jq -n --argjson blk "$(cast block-number --rpc-url "${L1_RPC}")" --argjson ts "$(cast block latest -f timestamp --rpc-url "${L1_RPC}")" \
        --argjson boxes "${boxes}" --arg hub "$(balance "${HUB}")" --arg a "${a}" --arg p "${p}" --arg pl "${pl}" \
        --argjson supported "$(callv "${HUB}" 'getSupportedChains()(uint64[])' | grep -oE '[0-9]{15,}' | sort | jq -R . | jq -sc .)" '
        {block: $blk, timestamp: $ts, lockBoxes: $boxes, hubBalance: $hub, supportedChains: $supported,
         registry: {administrator: $a, pendingAdministrator: $p, pool: $pl}}'
}
BEFORE="$(snapshot)"

# ── 1. the batch, built by the component from the records ────────────────────────────────────
echo ""
echo "▸ 1) 4_ConnectLane (components/ccip): the owner-only calls that connect ${L2_CHAIN}"
PROPOSAL_REL="contracts/lido-hvmv/config/.wsteth-run.${RUN_ID}.${L1_CHAIN}.lane-${L2_CHAIN}.json"
rm -f "${CCIP_EVM}/${PROPOSAL_REL}"
export LANE="${L2_CHAIN}" PROPOSAL_OUT="./${PROPOSAL_REL}"
run_ccip_script "${L1_CHAIN}" "${L1_RPC}" "4_ConnectLane.s.sol:ConnectLaneScript"
unset LANE PROPOSAL_OUT
[ -f "${CCIP_EVM}/${PROPOSAL_REL}" ] || { echo "✗ 4_ConnectLane wrote no ${PROPOSAL_REL}"; exit 1; }
mkdir -p state/hub-lane-connect
PROPOSAL_FILE="${ROOT}/state/hub-lane-connect/proposal-${L2_CHAIN}.json"
mv "${CCIP_EVM}/${PROPOSAL_REL}" "${PROPOSAL_FILE}"
jq . "${PROPOSAL_FILE}" >/dev/null || { echo "✗ ${PROPOSAL_FILE#${ROOT}/} is not JSON"; exit 1; }
p() { jq -er "$1" "${PROPOSAL_FILE}"; }
FAIL=0
[ "$(p '.lane')" = "${L2_CHAIN}" ] && [ "$(p '.remoteChainSelector')" = "${PAIR_SELECTOR}" ] || bad "the proposal file describes another lane ($(p '.lane') / $(p '.remoteChainSelector'))"
eq "$(p '.timelock')" "${LIDO_TIMELOCK}" && eq "$(p '.callProxy')" "${CALL_PROXY}" || bad "the proposal file names another timelock/CallProxy"
eq "$(p '.proposer')" "${MCMS}" || [ -n "${HUB_LANE_PROPOSER:-}" ] || bad "the proposal file names another proposer ($(p '.proposer'))"
jq -e --arg s "$(lc "${SPOKE_POOL}")" '[.expected.remotePools[] | ascii_downcase] | index($s)' "${PROPOSAL_FILE}" >/dev/null || bad "expected remote pools do not include the spoke pool ${SPOKE_POOL}"
eq "$(p '.expected.remoteToken')" "${SPOKE_TOKEN}" || bad "expected remote token $(p '.expected.remoteToken') is not the spoke token ${SPOKE_TOKEN}"
eq "$(p '.expected.lockBox')" "${PAIR_LOCKBOX}" || bad "expected lockbox $(p '.expected.lockBox') is not the record's ${PAIR_LOCKBOX}"
while read -r target; do
    case "$(lc "${target}")" in
        "$(lc "${HUB}")"|"$(lc "${HOOKS}")"|"$(lc "${VERIFIER}")"|"$(lc "${RESOLVER}")") ;;
        *) bad "call target ${target} is none of hub, hooks, verifier, resolver" ;;
    esac
done < <(jq -r '.calls[].target' "${PROPOSAL_FILE}")
# The LidoTimelock refuses blocked selectors at scheduling; check before, so a blocked call is named.
BLOCKED=""
n="$(callv "${LIDO_TIMELOCK}" 'getBlockedFunctionSelectorCount()(uint256)' | num)"
for ((i = 0; i < n; i++)); do BLOCKED="${BLOCKED} $(lc "$(callv "${LIDO_TIMELOCK}" 'getBlockedFunctionSelectorAt(uint256)(bytes4)' "${i}")")"; done
while read -r data; do
    sel="$(lc "${data:0:10}")"
    case " ${BLOCKED} " in *" ${sel} "*) bad "call selector ${sel} is blocked on the LidoTimelock" ;; esac
done < <(jq -r '.calls[].data' "${PROPOSAL_FILE}")
[ "${FAIL}" = 0 ] || { echo "✗ the batch does not describe this lane; nothing scheduled."; exit 1; }
CALLS_TEXT="[$(jq -r '.calls | map("(\(.target),\(.value),\(.data))") | join(",")' "${PROPOSAL_FILE}")]"
echo "  $(jq '.calls | length' "${PROPOSAL_FILE}") calls:"; jq -r '.calls[] | "    - " + .description' "${PROPOSAL_FILE}"
echo "  expected after: remote pools $(jq -c '.expected.remotePools' "${PROPOSAL_FILE}"), token $(p '.expected.remoteToken'), lockbox $(p '.expected.lockBox'), outbound $(jq -c '.expected.outbound' "${PROPOSAL_FILE}"), inbound $(jq -c '.expected.inbound' "${PROPOSAL_FILE}")"

# ── 2. the proposal through the LidoTimelock ─────────────────────────────────────────────────
echo ""
echo "▸ 2) LidoTimelock proposal by ${MCMS} (impersonated), executed through the CallProxy"
fund "${DEPLOYER}" "${L1_RPC}"
ZERO32="0x0000000000000000000000000000000000000000000000000000000000000000"
PROPOSAL="$(timelock_propose_and_execute "${L1_RPC}" "${LIDO_TIMELOCK}" "${MCMS}" "${CALL_PROXY}" "${DEPLOYER_PRIVATE_KEY}" \
    "connect-${L2_CHAIN}" "${CALLS_TEXT}" "${ZERO32}" "$(cast keccak "lido-hub-migration:connect-${L2_CHAIN}:${RUN_ID}")")"
PROPOSAL="$(jq --argjson c "$(jq -c '.calls' "${PROPOSAL_FILE}")" '. + {calls: $c}' <<<"${PROPOSAL}")"

# ── 3. post-conditions ───────────────────────────────────────────────────────────────────────
echo ""
echo "▸ 3) the lane on the hub"
AFTER="$(snapshot)"
FAIL=0
expect_eq() { [ "$2" = "$3" ] && ok "$1: $2" || bad "$1: $2, expected $3"; }
expect_eq "isSupportedChain(${PAIR_SELECTOR})" "$(callv "${HUB}" 'isSupportedChain(uint64)(bool)' "${PAIR_SELECTOR}")" "true"
expect_eq "remote pools" "$(decode_address_words "$(callv "${HUB}" 'getRemotePools(uint64)(bytes[])' "${PAIR_SELECTOR}")" | tr 'A-F' 'a-f' | sort | paste -sd, -)" \
    "$(jq -r '.expected.remotePools | map(ascii_downcase) | sort | join(",")' "${PROPOSAL_FILE}")"
expect_eq "remote token" "$(lc "$(decode_address_words "$(callv "${HUB}" 'getRemoteToken(uint64)(bytes)' "${PAIR_SELECTOR}")")")" "$(lc "${SPOKE_TOKEN}")"
expect_eq "lockbox" "$(lc "$(callv "${HUB}" 'getLockBox(uint64)(address)' "${PAIR_SELECTOR}")")" "$(lc "${PAIR_LOCKBOX}")"
read -r out_en out_cap out_rate in_en in_cap in_rate <<<"$(limiter2 "$(callv "${HUB}" 'getCurrentRateLimiterState(uint64,bool)((uint128,uint32,bool,uint128,uint128),(uint128,uint32,bool,uint128,uint128))' "${PAIR_SELECTOR}" false)")"
expect_eq "outbound limiter" "${out_en} ${out_cap} ${out_rate}" "$(jq -r '"\(.expected.outbound.enabled) \(.expected.outbound.capacity) \(.expected.outbound.rate)"' "${PROPOSAL_FILE}")"
expect_eq "inbound limiter" "${in_en} ${in_cap} ${in_rate}" "$(jq -r '"\(.expected.inbound.enabled) \(.expected.inbound.capacity) \(.expected.inbound.rate)"' "${PROPOSAL_FILE}")"
# TokenPool 2.0.0: getTokenTransferFeeConfig(localToken, destChainSelector, finality, tokenArgs); cast annotates large numbers ("150000 [1.5e5]")
FEE="$(callv "${HUB}" 'getTokenTransferFeeConfig(address,uint64,bytes4,bytes)((uint32,uint32,uint32,uint32,uint16,uint16,bool))' "${TOKEN}" "${PAIR_SELECTOR}" 0x00000000 0x | sed -E 's/ \[[^]]*\]//g' | tr -d '() ')"
expect_eq "fee config (destGasOverhead, enabled)" "$(cut -d, -f1 <<<"${FEE}") $(cut -d, -f7 <<<"${FEE}")" "$(p '.expected.destGasOverhead') true"
expect_eq "hooks: required outbound CCVs" "$(addresses_of "$(callv "${HOOKS}" 'getRequiredCCVs(address,uint64,uint256,bytes4,bytes,uint8)(address[])' "${TOKEN}" "${PAIR_SELECTOR}" 1000000000000000000 0x00000000 0x 0)")" "$(lc "${RESOLVER}")"
expect_eq "hooks: required inbound CCVs" "$(addresses_of "$(callv "${HOOKS}" 'getRequiredCCVs(address,uint64,uint256,bytes4,bytes,uint8)(address[])' "${TOKEN}" "${PAIR_SELECTOR}" 1000000000000000000 0x00000000 0x 1)")" "$(lc "${RESOLVER}")"
expect_eq "resolver: outbound implementation" "$(lc "$(callv "${RESOLVER}" 'getOutboundImplementation(uint64,bytes)(address)' "${PAIR_SELECTOR}" 0x)")" "$(lc "${VERIFIER}")"
expect_eq "verifier: remote chain router" "$(lc "$(callv "${VERIFIER}" 'getRemoteChainConfig(uint64)((address,uint64,bool,uint16,uint32,uint16),address[])' "${PAIR_SELECTOR}" | grep -oE '0x[0-9a-fA-F]{40}' | head -1)")" "$(lc "${ROUTER}")"
expect_eq "supported chains" "$(jq -c '.supportedChains' <<<"${AFTER}")" "$(printf '%s\n%s\n' "${SUPPORTED_BEFORE}" "${PAIR_SELECTOR}" | grep . | sort | jq -R . | jq -sc .)"
for b in ${ALL_LOCKBOXES}; do
    expect_eq "lockbox ${b} balance unchanged" "$(jq -r --arg b "${b}" '.lockBoxes[$b]' <<<"${AFTER}")" "$(jq -r --arg b "${b}" '.lockBoxes[$b]' <<<"${BEFORE}")"
done
expect_eq "hub balance unchanged" "$(jq -r '.hubBalance' <<<"${AFTER}")" "$(jq -r '.hubBalance' <<<"${BEFORE}")"
expect_eq "registry entry unchanged" "$(jq -c '.registry' <<<"${AFTER}")" "$(jq -c '.registry' <<<"${BEFORE}")"
[ "${FAIL}" = 0 ] || { echo "✗ the lane did not read back as expected after the batch; see above (the batch did execute — inspect the fork, prepare a new run)"; exit 1; }

# ── record ───────────────────────────────────────────────────────────────────────────────────
jq -n --arg run "${RUN_ID}" --arg l1 "${L1_CHAIN}" --arg lane "${L2_CHAIN}" --arg sel "${PAIR_SELECTOR}" --arg token "${TOKEN}" --arg hub "${HUB}" \
    --arg hooks "${HOOKS}" --arg verifier "${VERIFIER}" --arg resolver "${RESOLVER}" --arg lido "${LIDO_TIMELOCK}" --arg proxy "${CALL_PROXY}" \
    --arg box "${PAIR_LOCKBOX}" --arg spool "${SPOKE_POOL}" --arg stoken "${SPOKE_TOKEN}" --argjson proposal "${PROPOSAL}" \
    --argjson expected "$(jq -c '.expected' "${PROPOSAL_FILE}")" --argjson before "${BEFORE}" --argjson after "${AFTER}" --argjson cutover "${CUTOVER_LANES}" '
    {schemaVersion: 1, run: $run, chain: $l1, lane: $lane, selector: $sel, token: $token,
     hub: $hub, hooks: $hooks, verifier: $verifier, resolver: $resolver, lidoTimelock: $lido, callProxy: $proxy,
     lockBox: $box, spokePool: $spool, spokeToken: $stoken, lanesBefore: $cutover,
     proposal: $proposal, expected: $expected,
     snapshots: {before: $before, after: $after},
     impersonated: ["LidoTimelock proposer " + $proposal.proposer + " (scheduleBatch; on mainnet a Chainlink MCMS proposal)"],
     unverified: ["MCMS signing of the proposal; the CallProxy was called by the deployer key",
                  "the spoke side is untouched by this step: its lane to the hub was configured by the deployer (2_Configure) before the hand-over",
                  "the window between this connection and the spoke action set (step 06): a hub -> spoke send locks wstETH in the lane lockbox until the spoke can mint"]}' > "${OUT}"
jq_inplace state/l1.json --arg lane "${L2_CHAIN}" --arg id "$(jq -r '.id' <<<"${PROPOSAL}")" '.hubLaneConnect = {lane: $lane, proposal: $id}'
echo ""
echo "✓ step 05c done — the hub ${HUB} serves ${L2_CHAIN} (selector ${PAIR_SELECTOR}) from the lockbox ${PAIR_LOCKBOX}; $((CUTOVER_LANES + 1)) lanes now."
echo "  proposal $(jq -r '.id' <<<"${PROPOSAL}") on the LidoTimelock ${LIDO_TIMELOCK} (executed tx $(jq -r '.executedTx' <<<"${PROPOSAL}"))"
echo "  record: ${OUT#${ROOT}/}; batch: ${PROPOSAL_FILE#${ROOT}/}"
