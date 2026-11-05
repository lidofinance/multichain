#!/usr/bin/env bash
# Step 05h — FORK-ONLY, in-place targets with `.migration.hub`: the two proposals by which Chainlink
# moves the token's Ethereum pool from the existing SiloedLockReleaseTokenPool 1.6.0 to the new hub,
# replayed through the REAL Chainlink RBACTimelock on the L1 fork — a proposer impersonated,
# the minimum delay waited by warping the fork clock, execution through the timelock's executor
# (its CallProxy forwards anyone's call) by the deployer key.
#
#   A) outbound pause on the old pool, one call: setChainRateLimiterConfigs(lanes, outbound
#      {enabled, capacity 2 wei, rate 1 wei/s}, inbound unchanged) — the smallest limiter the pool accepts
#      prescribes. Then a ccipSend to every lane is simulated and must revert.
#   B) the cutover batch (predecessor = A, so the timelock itself enforces the order):
#        withdrawLiquidity(unsiloed)                          — the unsiloed bucket, to the timelock
#        per siloed lane: [setSiloRebalancer(lane, timelock)] withdrawSiloedLiquidity(lane, silo)
#                         [setSiloRebalancer(lane, previous)] — brackets when the silo's rebalancer
#                                                               is another address; the restore
#                                                               follows the manifest's policy
#        wstETH.transfer(lockbox, amount) per lockbox group   — plain transfers fund ERC20LockBox 2.0.0
#        TokenAdminRegistry.setPool(token, newHub)
#        TokenAdminRegistry.transferAdminRole(token, LidoTimelock)
#      Amounts are the manifest's (step 01h, pinned block); the step stops if the old pool no longer
#      holds exactly them. All calls are one batch: any revert leaves pool, registry and lockboxes as
#      they were.
#
# Before A the new hub must mirror the old pool: it serves every lane the manifest lists (lockbox
# map, imported remote pools and limits, lockboxes authorize the hub, LidoTimelock owns the stack)
# and no other — the pair lane (Base) is a deferred lane of the hub record, connected after the
# cutover by the owner's proposal (step 05c, hub-connect-lane), so this batch migrates what exists
# and nothing more. After B, outside the transaction: old pool empty; the Chainlink timelock's wstETH
# balance unchanged; each lockbox grew by its amount; Base contracts absent; legacy escrow
# untouched; registry pool = new hub with the administration pending for the LidoTimelock. Everything
# is recorded in state/hub-migration.json (calldata, hashes, tx hashes, snapshots, what stayed
# unverified) and state/l1.json (registryPoolBefore, registryAdministratorBefore). The separate
# hub-accept-admin step accepts through a Chainlink MCMS proposal in LidoTimelock.
#
# Not rehearsed here (no spoke forks in this target): the spokes' remote-pool additions and
# outbound pauses, the queue drain, DON delivery, MCMS signing — listed under `unverified`.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
cd "${ROOT}"
. "${HERE}/_common.sh"
[ "${WSTETH_OPERATION}" = "in-place-upgrade" ] \
    || { echo "✗ step 05h is for in-place-upgrade targets (WSTETH_OPERATION=${WSTETH_OPERATION})"; exit 1; }
TARGET_JSON="${WSTETH_TARGET_DIR:?run via just wsteth so the target directory is explicit}/target.json"
if ! jq -e '.migration.hub' "${TARGET_JSON}" >/dev/null 2>&1; then
    echo "▸ ${TARGET_JSON} declares no .migration.hub: no hub cutover in this target."; exit 0
fi
if [ "${WSTETH_SKIP_L1:-0}" = 1 ]; then echo "▸ hub-only step (WSTETH_SKIP_L1=1); skip."; exit 0; fi
: "${DEPLOYER_PRIVATE_KEY:?set DEPLOYER_PRIVATE_KEY}"
DEPLOYER="$(cast wallet address --private-key "${DEPLOYER_PRIVATE_KEY}")"
is_anvil "${L1_RPC}" || { echo "✗ step 05h impersonates Chainlink's proposer and warps the clock; ${L1_RPC} is not anvil"; exit 1; }
command -v bc >/dev/null || { echo "✗ bc not found in PATH"; exit 1; }
MANIFEST="${ROOT}/state/hub-migration/manifest.json"
[ -f "${MANIFEST}" ] || { echo "✗ missing ${MANIFEST#${ROOT}/} (run step 01h)"; exit 1; }
[ -f state/l1.json ] || { echo "✗ missing state/l1.json (run step 01m)"; exit 1; }
L1_CFG="${CFG_DIR}/${L1_CHAIN}.json"
jq -e '.deployed.token_pool and .deployed.timelock and .ccv.verifier_resolver' "${L1_CFG}" >/dev/null \
    || { echo "✗ ${L1_CFG} carries no configured hub deployment (run steps 04–05)"; exit 1; }
RUN_ID="$(basename "$(cd "${ROOT}/.active-run" && pwd -P)")"
OUT="${ROOT}/state/hub-migration.json"

m() { jq -er "$1" "${MANIFEST}"; }
num() { awk '{print $1}'; }
callv() { cast call --rpc-url "${L1_RPC}" "$@"; }
# limiter <one tuple>: "(tokens [x], lastUpdated [x], isEnabled, capacity [x], rate [x])" -> "isEnabled capacity rate"
limiter() { printf '%s' "$1" | tr -d '\n' | sed -E 's/ \[[^]]*\]//g; s/[()]//g' | tr -d ' ' | awk -F, '{print $3, $4, $5}'; }
# limiter2 <two tuples, one per line>: "outEnabled outCapacity outRate inEnabled inCapacity inRate"
limiter2() { printf '%s' "$1" | sed -E 's/ \[[^]]*\]//g; s/[()]//g' | tr -d ' ' | awk -F, 'NR==1{o=$3" "$4" "$5} NR==2{print o, $3, $4, $5}'; }
decode_address_words() {
    local w
    for w in $(printf '%s' "$1" | grep -oE '0x[0-9a-fA-F]+'); do cast abi-decode 'x()(address)' "${w}"; done
}
balance() { callv "${TOKEN}" 'balanceOf(address)(uint256)' "$1" | num; }

TOKEN="$(m '.token')"; TAR="$(m '.registry.address')"; ROUTER="$(m '.router')"
OLD_POOL="$(m '.oldPool.address')"; CL_TIMELOCK="$(m '.chainlinkTimelock.address')"
UNSILOED="$(m '.oldPool.unsiloedLiquidity')"; UNACCOUNTED="$(m '.oldPool.unaccounted')"
SILO_POLICY="$(m '.siloRebalancerAfterCutover')"
NEW_HUB="$(jq -er '.deployed.token_pool' "${L1_CFG}")"
LIDO_TIMELOCK="$(jq -er '.deployed.timelock' "${L1_CFG}")"
LEGACY_BRIDGE="$(jq -er '.legacyBridge' state/l1.json)"
BASE_LOCKBOX="0x0000000000000000000000000000000000000000"
jq -e --arg lane "${L2_CHAIN}" '[.deployed.lock_boxes[] | select(.remote_chain_name == $lane)] | length == 0' "${L1_CFG}" >/dev/null \
    || { echo 'Base lockbox must not be deployed before the hub migration'; exit 1; }
jq -e '(.deployed.token_pool // null) == null' "${CFG_DIR}/${L2_CHAIN}.json" >/dev/null \
    || { echo 'Base pool must not be deployed before the hub migration'; exit 1; }
admin_role="$(callv "${LIDO_TIMELOCK}" 'ADMIN_ROLE()(bytes32)')"
[ "$(callv "${LIDO_TIMELOCK}" 'hasRole(bytes32,address)(bool)' "${admin_role}" "${DEPLOYER}")" = false ] \
    || { echo 'Deployer must relinquish hub ADMIN_ROLE before cutover'; exit 1; }
LANES="$(jq -c '.lanes' "${MANIFEST}")"
LB_GROUPS="$(jq -c '.lockBoxGroups' "${MANIFEST}")"
eq "${TOKEN}" "$(jq -er '.addresses.token' "${L1_CFG}")" || { echo "✗ manifest token ${TOKEN} is not the record's token"; exit 1; }

if [ -f "${OUT}" ] || eq "$(callv "${TAR}" 'getTokenConfig(address)((address,address,address))' "${TOKEN}" | tr -d '()' | cut -d, -f3 | tr -d ' ')" "${NEW_HUB}"; then
    echo "▸ the registry already binds ${TOKEN} to the new hub ${NEW_HUB} (or ${OUT#${ROOT}/} exists): cutover done in this run; skip."
    exit 0
fi

# ── 0. preflight: the new hub serves every lane; the old pool still holds the manifest amounts ──
echo "▸ 0) preflight on ${L1_CHAIN} (${L1_RPC})"
FAIL=0; bad() { echo "  ✗ $*"; FAIL=1; }; ok() { echo "  ✔ $*"; }
# lockbox per group from the hub record: all lanes of a group share one address; groups are distinct.
BOXES='{}'
while read -r group; do
    addrs="$(jq -r --argjson lanes "$(jq -c --arg g "${group}" '.[$g].lanes' <<<"${LB_GROUPS}")" '[.deployed.lock_boxes[] | select(.remote_chain_name as $n | $lanes | index($n)) | .lock_box | ascii_downcase] | unique | .[]' "${L1_CFG}")"
    [ "$(printf '%s\n' "${addrs}" | grep -c .)" = 1 ] || { bad "lockbox group ${group} maps to several or no lockboxes: ${addrs//$'\n'/, }"; continue; }
    BOXES="$(jq -c --arg g "${group}" --arg a "$(cast to-check-sum-address "${addrs}")" '. + {($g): $a}' <<<"${BOXES}")"
done < <(jq -r 'keys[]' <<<"${LB_GROUPS}")
[ "$(jq -r '[.[] | ascii_downcase] | unique | length' <<<"${BOXES}")" = "$(jq 'length' <<<"${BOXES}")" ] || bad "lockbox groups share an address"
jq -e --arg b "$(lc "${BASE_LOCKBOX}")" '[.[] | ascii_downcase] | index($b) | not' <<<"${BOXES}" >/dev/null || bad "an imported lane shares the ${L2_CHAIN} lockbox"
ok "lockboxes: $(jq -r 'to_entries | map("\(.key)=\(.value)") | join(", ")' <<<"${BOXES}"); ${L2_CHAIN}=${BASE_LOCKBOX}"
eq "$(callv "${NEW_HUB}" 'owner()(address)')" "${LIDO_TIMELOCK}" && ok "new hub ${NEW_HUB} owned by LidoTimelock ${LIDO_TIMELOCK}" || bad "new hub owner is not the LidoTimelock"
SUPPORTED="$(callv "${NEW_HUB}" 'getSupportedChains()(uint64[])' | grep -oE '[0-9]{15,}' | sort)"
# The hub the registry is about to bind mirrors the old pool: it serves the manifest's lanes and no other.
# The pair lane (${L2_CHAIN}) is connected afterwards by the owner's proposal (step 05c), not by the cutover.
PAIR_SELECTOR="$(jq -er '.ccip.chain_selector' "${CFG_DIR}/${L2_CHAIN}.json")"
[ "$(printf '%s\n' "${SUPPORTED}" | grep -c .)" = "$(jq 'length' <<<"${LANES}")" ] \
    && ok "new hub serves exactly $(jq 'length' <<<"${LANES}") lanes" \
    || bad "new hub serves $(printf '%s\n' "${SUPPORTED}" | grep -c .) lanes, the manifest $(jq 'length' <<<"${LANES}"): the cutover must bind a hub that mirrors the old pool"
grep -qx "${PAIR_SELECTOR}" <<<"${SUPPORTED}" && bad "${L2_CHAIN} (selector ${PAIR_SELECTOR}) is already a lane of the new hub; it is connected by step 05c after the cutover (deferred_lanes in the hub record)" \
    || ok "${L2_CHAIN} lane not yet on the hub (connected by step 05c)"
callv "${NEW_HUB}" 'getLockBox(uint64)(address)' "${PAIR_SELECTOR}" >/dev/null 2>&1 \
    && bad "${L2_CHAIN} lockbox already bound on the new hub" || ok "${L2_CHAIN} lockbox not deployed or bound yet"
while read -r lane; do
    slug="$(jq -r '.slug' <<<"${lane}")"; sel="$(jq -r '.selector' <<<"${lane}")"; group="$(jq -r '.lockBoxGroup' <<<"${lane}")"
    box="$(jq -r --arg g "${group}" '.[$g]' <<<"${BOXES}")"
    grep -qx "${sel}" <<<"${SUPPORTED}" || bad "${slug}: selector ${sel} not supported by the new hub"
    eq "$(callv "${NEW_HUB}" 'getLockBox(uint64)(address)' "${sel}")" "${box}" || bad "${slug}: new hub lockbox for ${sel} is not ${box}"
    want_pools="$(jq -r '.remotePools | map(ascii_downcase) | sort | join(",")' <<<"${lane}")"
    have_pools="$(decode_address_words "$(callv "${NEW_HUB}" 'getRemotePools(uint64)(bytes[])' "${sel}")" | tr 'A-F' 'a-f' | sort | paste -sd, -)"
    [ "${want_pools}" = "${have_pools}" ] || bad "${slug}: new hub remote pools ${have_pools} != imported ${want_pools}"
    eq "$(decode_address_words "$(callv "${NEW_HUB}" 'getRemoteToken(uint64)(bytes)' "${sel}")")" "$(jq -r '.remoteToken' <<<"${lane}")" || bad "${slug}: new hub remote token differs"
    # TokenPool 2.0.0 reports both buckets at once: (outbound, inbound) for the default finality
    read -r out_en out_cap out_rate in_en in_cap in_rate <<<"$(limiter2 "$(callv "${NEW_HUB}" 'getCurrentRateLimiterState(uint64,bool)((uint128,uint32,bool,uint128,uint128),(uint128,uint32,bool,uint128,uint128))' "${sel}" false)")"
    [ "${out_en} ${out_cap} ${out_rate}" = "$(jq -r '"\(.outbound.enabled) \(.outbound.capacity) \(.outbound.rate)"' <<<"${lane}")" ] || bad "${slug}: new hub outbound limit (${out_en},${out_cap},${out_rate}) differs from the import"
    [ "${in_en} ${in_cap} ${in_rate}" = "$(jq -r '"\(.inbound.enabled) \(.inbound.capacity) \(.inbound.rate)"' <<<"${lane}")" ] || bad "${slug}: new hub inbound limit (${in_en},${in_cap},${in_rate}) differs from the import"
    # the old pool still holds what the manifest says
    if [ "$(jq -r '.siloed' <<<"${lane}")" = true ]; then
        have="$(callv "${OLD_POOL}" 'getAvailableTokens(uint64)(uint256)' "${sel}" | num)"
        [ "${have}" = "$(jq -r '.siloBalance' <<<"${lane}")" ] || bad "${slug}: silo now ${have}, manifest $(jq -r '.siloBalance' <<<"${lane}") — re-run step 01h on a frozen fork"
        eq "$(callv "${OLD_POOL}" 'getChainRebalancer(uint64)(address)' "${sel}")" "$(jq -r '.rebalancer' <<<"${lane}")" || bad "${slug}: silo rebalancer changed since the inventory"
    fi
done < <(jq -c '.[]' <<<"${LANES}")
while read -r box; do
    eq "$(callv "${box}" 'owner()(address)')" "${LIDO_TIMELOCK}" || bad "lockbox ${box} not owned by the LidoTimelock"
    callv "${box}" 'getAllAuthorizedCallers()(address[])' | tr 'A-F' 'a-f' | grep -q "$(lc "${NEW_HUB}")" || bad "lockbox ${box} does not authorize the new hub"
done < <(jq -r '.[]' <<<"${BOXES}")
[ "$(callv "${OLD_POOL}" 'getUnsiloedLiquidity()(uint256)' | num)" = "${UNSILOED}" ] || bad "old pool unsiloed liquidity changed since the inventory"
[ "$(balance "${OLD_POOL}")" = "$(m '.oldPool.balance')" ] || bad "old pool balance changed since the inventory"
if [ "${UNACCOUNTED}" != 0 ]; then
    if [ "${HUB_ALLOW_UNACCOUNTED:-0}" = 1 ]; then echo "  ⚠ ${UNACCOUNTED} wei outside the old pool's accounting stay in the old pool (HUB_ALLOW_UNACCOUNTED=1)"
    else bad "${UNACCOUNTED} wei in the old pool are outside its accounting; explain them (or HUB_ALLOW_UNACCOUNTED=1 to leave them behind)"; fi
fi
read -r TAR_ADMIN TAR_PENDING TAR_POOL <<<"$(callv "${TAR}" 'getTokenConfig(address)((address,address,address))' "${TOKEN}" | tr -d '()' | tr ',' ' ')"
eq "${TAR_ADMIN}" "${CL_TIMELOCK}" && eq "${TAR_POOL}" "${OLD_POOL}" && [ "${TAR_PENDING}" = "0x0000000000000000000000000000000000000000" ] \
    && ok "registry: administrator ${TAR_ADMIN}, pool ${TAR_POOL}, nothing pending" || bad "registry entry (admin ${TAR_ADMIN}, pending ${TAR_PENDING}, pool ${TAR_POOL}) is not the inventoried one"
MIN_DELAY="$(callv "${CL_TIMELOCK}" 'getMinDelay()(uint256)' | num)"
PROPOSER="${HUB_PROPOSER:-$(m '.chainlinkTimelock.roles.PROPOSER_ROLE.members[0]')}"
EXECUTOR="${HUB_EXECUTOR:-$(m '.chainlinkTimelock.roles.EXECUTOR_ROLE.members[0]')}"
[ "$(callv "${CL_TIMELOCK}" 'hasRole(bytes32,address)(bool)' "$(m '.chainlinkTimelock.roles.PROPOSER_ROLE.hash')" "${PROPOSER}")" = true ] && ok "proposer to impersonate: ${PROPOSER}" || bad "${PROPOSER} holds no PROPOSER_ROLE"
[ "$(callv "${CL_TIMELOCK}" 'hasRole(bytes32,address)(bool)' "$(m '.chainlinkTimelock.roles.EXECUTOR_ROLE.hash')" "${EXECUTOR}")" = true ] && has_code "${EXECUTOR}" "${L1_RPC}" \
    && ok "executor: ${EXECUTOR} (calls forwarded by the deployer ${DEPLOYER}); min delay ${MIN_DELAY}s" || bad "${EXECUTOR} is not an executor contract of the timelock"
[ "${FAIL}" = 0 ] || { echo "✗ preflight failed; nothing scheduled."; exit 1; }

snapshot() {  # -> JSON of every balance and registry field the invariants compare
    local boxes='{}' g
    for g in $(jq -r 'keys[]' <<<"${BOXES}"); do boxes="$(jq -c --arg g "${g}" --arg b "$(balance "$(jq -r --arg g "${g}" '.[$g]' <<<"${BOXES}")")" '. + {($g): $b}' <<<"${boxes}")"; done
    local silos='{}' lane sel slug
    while read -r lane; do
        [ "$(jq -r '.siloed' <<<"${lane}")" = true ] || continue
        sel="$(jq -r '.selector' <<<"${lane}")"; slug="$(jq -r '.slug' <<<"${lane}")"
        silos="$(jq -c --arg s "${slug}" --arg a "$(callv "${OLD_POOL}" 'getAvailableTokens(uint64)(uint256)' "${sel}" | num)" \
            --arg r "$(callv "${OLD_POOL}" 'getChainRebalancer(uint64)(address)' "${sel}")" '. + {($s): {balance: $a, rebalancer: $r}}' <<<"${silos}")"
    done < <(jq -c '.[]' <<<"${LANES}")
    read -r a p pl <<<"$(callv "${TAR}" 'getTokenConfig(address)((address,address,address))' "${TOKEN}" | tr -d '()' | tr ',' ' ')"
    jq -n --argjson blk "$(cast block-number --rpc-url "${L1_RPC}")" --argjson ts "$(cast block latest -f timestamp --rpc-url "${L1_RPC}")" \
        --arg old "$(balance "${OLD_POOL}")" --arg uns "$(callv "${OLD_POOL}" 'getUnsiloedLiquidity()(uint256)' | num)" --argjson silos "${silos}" \
        --arg tl "$(balance "${CL_TIMELOCK}")" --argjson boxes "${boxes}" --arg base "0" --arg escrow "$(balance "${LEGACY_BRIDGE}")" \
        --arg a "${a}" --arg p "${p}" --arg pl "${pl}" '
        {block: $blk, timestamp: $ts, oldPool: {balance: $old, unsiloedLiquidity: $uns, silos: $silos}, chainlinkTimelock: $tl,
         lockBoxes: $boxes, baseLockBox: $base, baseLockBoxDeployed: false, legacyEscrow: $escrow, registry: {administrator: $a, pendingAdministrator: $p, pool: $pl}}'
}
BEFORE="$(snapshot)"
echo "  before: old pool $(cast from-wei "$(jq -r '.oldPool.balance' <<<"${BEFORE}")") wstETH; lockboxes $(jq -c '.lockBoxes' <<<"${BEFORE}"); ${L2_CHAIN} lockbox $(jq -r '.baseLockBox' <<<"${BEFORE}"); escrow $(jq -r '.legacyEscrow' <<<"${BEFORE}")"

# ── proposal mechanics through the real RBACTimelock (timelock_propose_and_execute, _common.sh) ──
fund "${DEPLOYER}" "${L1_RPC}"
ZERO32="0x0000000000000000000000000000000000000000000000000000000000000000"
# propose_and_execute <name> <calls> <predecessor> <salt> -> JSON record on stdout (progress on stderr)
propose_and_execute() {
    timelock_propose_and_execute "${L1_RPC}" "${CL_TIMELOCK}" "${PROPOSER}" "${EXECUTOR}" "${DEPLOYER_PRIVATE_KEY}" "$1" "$2" "$3" "$4"
}
CALLS_JSON='[]'; CALLS_TEXT=''
add_call() {  # <target> <calldata> <description>
    CALLS_TEXT="${CALLS_TEXT:+${CALLS_TEXT},}(${1},0,${2})"
    CALLS_JSON="$(jq -c --arg t "$1" --arg d "$2" --arg x "$3" '. + [{target: $t, value: "0", data: $d, decoded: $x}]' <<<"${CALLS_JSON}")"
}
reset_calls() { CALLS_JSON='[]'; CALLS_TEXT=''; }

# ── A. outbound pause on the old pool ─────────────────────────────────────────────────────────
echo ""
echo "▸ A) outbound pause on the old pool: setChainRateLimiterConfigs for $(jq 'length' <<<"${LANES}") lanes (outbound enabled, capacity 2 wei, rate 1 wei/s; inbound unchanged)"
SELECTORS="[$(jq -r 'map(.selector) | join(",")' <<<"${LANES}")]"
OUT_PAUSED="[$(jq -r 'map("(true,2,1)") | join(",")' <<<"${LANES}")]"
IN_SAME="[$(jq -r 'map("(\(.inbound.enabled),\(.inbound.capacity),\(.inbound.rate))") | join(",")' <<<"${LANES}")]"
reset_calls
add_call "${OLD_POOL}" "$(cast calldata 'setChainRateLimiterConfigs(uint64[],(bool,uint128,uint128)[],(bool,uint128,uint128)[])' "${SELECTORS}" "${OUT_PAUSED}" "${IN_SAME}")" \
    "SiloedLockReleaseTokenPool.setChainRateLimiterConfigs(${SELECTORS}, outbound ${OUT_PAUSED}, inbound ${IN_SAME})"
PROPOSAL_A="$(propose_and_execute "pause" "[${CALLS_TEXT}]" "${ZERO32}" "$(cast keccak "lido-hub-migration:pause:${RUN_ID}")")"
PROPOSAL_A="$(jq --argjson c "${CALLS_JSON}" '. + {calls: $c}' <<<"${PROPOSAL_A}")"
while read -r lane; do
    sel="$(jq -r '.selector' <<<"${lane}")"
    read -r en cap rate <<<"$(limiter "$(callv "${OLD_POOL}" 'getCurrentOutboundRateLimiterState(uint64)((uint128,uint32,bool,uint128,uint128))' "${sel}")")"
    [ "${en} ${cap} ${rate}" = "true 2 1" ] || { echo "✗ $(jq -r '.slug' <<<"${lane}"): outbound limiter (${en},${cap},${rate}) is not the pause"; exit 1; }
done < <(jq -c '.[]' <<<"${LANES}")
echo "  outbound limiters of all lanes read back as (enabled, capacity 2 wei, rate 1 wei/s)"
# A ccipSend of 1 wstETH must return the exact capacity error on every lane.
# Balances and allowances exist only in eth_call overrides: no persistent token funding.
SENDER="0x$(cast keccak 'lido-hub-migration:sender' | cut -c27-66)"
PAUSE_CHECK="$(python3 "${HERE}/check_hub_pause.py" "${MANIFEST}")"
echo "  exact pause errors: ${PAUSE_CHECK}"

# ── B. the cutover batch ──────────────────────────────────────────────────────────────────────
echo ""
echo "▸ B) cutover batch (predecessor: the pause)"
reset_calls
if [ "${UNSILOED}" != 0 ]; then
    add_call "${OLD_POOL}" "$(cast calldata 'withdrawLiquidity(uint256)' "${UNSILOED}")" "SiloedLockReleaseTokenPool.withdrawLiquidity(${UNSILOED}) — unsiloed bucket to the timelock"
fi
EXPECTED_REBALANCERS='{}'
while read -r lane; do
    [ "$(jq -r '.siloed' <<<"${lane}")" = true ] || continue
    slug="$(jq -r '.slug' <<<"${lane}")"; sel="$(jq -r '.selector' <<<"${lane}")"; amt="$(jq -r '.siloBalance' <<<"${lane}")"; rebal="$(jq -r '.rebalancer' <<<"${lane}")"
    after="${rebal}"
    if ! eq "${rebal}" "${CL_TIMELOCK}"; then
        add_call "${OLD_POOL}" "$(cast calldata 'setSiloRebalancer(uint64,address)' "${sel}" "${CL_TIMELOCK}")" "setSiloRebalancer(${sel} ${slug}, timelock) — the silo's rebalancer is ${rebal}"
    fi
    if [ "${amt}" != 0 ]; then
        add_call "${OLD_POOL}" "$(cast calldata 'withdrawSiloedLiquidity(uint64,uint256)' "${sel}" "${amt}")" "withdrawSiloedLiquidity(${sel} ${slug}, ${amt}) — silo to the timelock"
    fi
    if ! eq "${rebal}" "${CL_TIMELOCK}"; then
        if [ "${SILO_POLICY}" = restore ]; then
            add_call "${OLD_POOL}" "$(cast calldata 'setSiloRebalancer(uint64,address)' "${sel}" "${rebal}")" "setSiloRebalancer(${sel} ${slug}, ${rebal}) — previous rebalancer restored (siloRebalancerAfterCutover=restore)"
        else after="${CL_TIMELOCK}"; fi
    fi
    EXPECTED_REBALANCERS="$(jq -c --arg s "${slug}" --arg a "${after}" '. + {($s): $a}' <<<"${EXPECTED_REBALANCERS}")"
done < <(jq -c '.[]' <<<"${LANES}")
while read -r group; do
    amt="$(jq -r --arg g "${group}" '.[$g].amount' <<<"${LB_GROUPS}")"; box="$(jq -r --arg g "${group}" '.[$g]' <<<"${BOXES}")"
    [ "${amt}" != 0 ] || continue
    add_call "${TOKEN}" "$(cast calldata 'transfer(address,uint256)' "${box}" "${amt}")" "wstETH.transfer(${box} = lockbox ${group} [$(jq -r --arg g "${group}" '.[$g].lanes | join(", ")' <<<"${LB_GROUPS}")], ${amt})"
done < <(jq -r 'keys[]' <<<"${LB_GROUPS}")
add_call "${TAR}" "$(cast calldata 'setPool(address,address)' "${TOKEN}" "${NEW_HUB}")" "TokenAdminRegistry.setPool(${TOKEN}, ${NEW_HUB}) — the new hub serves every lane from here"
add_call "${TAR}" "$(cast calldata 'transferAdminRole(address,address)' "${TOKEN}" "${LIDO_TIMELOCK}")" "TokenAdminRegistry.transferAdminRole(${TOKEN}, ${LIDO_TIMELOCK}) — pending for the LidoTimelock"
echo "  $(jq 'length' <<<"${CALLS_JSON}") calls:"; jq -r '.[] | "    - " + .decoded' <<<"${CALLS_JSON}"
PROPOSAL_B="$(propose_and_execute "cutover" "[${CALLS_TEXT}]" "$(jq -r '.id' <<<"${PROPOSAL_A}")" "$(cast keccak "lido-hub-migration:cutover:${RUN_ID}")")"
PROPOSAL_B="$(jq --argjson c "${CALLS_JSON}" '. + {calls: $c}' <<<"${PROPOSAL_B}")"

# ── post-conditions, outside the transaction ──────────────────────────────────────────────────
echo ""
echo "▸ invariants on the frozen checkpoint"
AFTER="$(snapshot)"
FAIL=0
delta() { echo "$(jq -r "$1" <<<"${AFTER}") - $(jq -r "$1" <<<"${BEFORE}")" | bc; }
expect_eq() { [ "$2" = "$3" ] && ok "$1: $2" || bad "$1: $2, expected $3"; }
WANT_OLD_LEFT="0"; [ "${HUB_ALLOW_UNACCOUNTED:-0}" = 1 ] && WANT_OLD_LEFT="${UNACCOUNTED}"
expect_eq "old pool balance" "$(jq -r '.oldPool.balance' <<<"${AFTER}")" "${WANT_OLD_LEFT}"
expect_eq "old pool unsiloed liquidity" "$(jq -r '.oldPool.unsiloedLiquidity' <<<"${AFTER}")" "0"
for s in $(jq -r '.oldPool.silos | keys[]' <<<"${AFTER}"); do
    expect_eq "old pool silo ${s}" "$(jq -r --arg s "${s}" '.oldPool.silos[$s].balance' <<<"${AFTER}")" "0"
    expect_eq "silo ${s} rebalancer after" "$(lc "$(jq -r --arg s "${s}" '.oldPool.silos[$s].rebalancer' <<<"${AFTER}")")" "$(lc "$(jq -r --arg s "${s}" '.[$s]' <<<"${EXPECTED_REBALANCERS}")")"
done
expect_eq "delta balance(chainlinkTimelock)" "$(delta '.chainlinkTimelock')" "0"
for g in $(jq -r 'keys[]' <<<"${LB_GROUPS}"); do
    expect_eq "delta lockbox ${g}" "$(delta ".lockBoxes[\"${g}\"]")" "$(jq -r --arg g "${g}" '.[$g].amount' <<<"${LB_GROUPS}")"
done
expect_eq "delta ${L2_CHAIN} lockbox" "$(delta '.baseLockBox')" "0"
expect_eq "delta legacy escrow" "$(delta '.legacyEscrow')" "0"
expect_eq "registry pool" "$(lc "$(jq -r '.registry.pool' <<<"${AFTER}")")" "$(lc "${NEW_HUB}")"
expect_eq "registry administrator" "$(lc "$(jq -r '.registry.administrator' <<<"${AFTER}")")" "$(lc "${CL_TIMELOCK}")"
expect_eq "registry pending administrator" "$(lc "$(jq -r '.registry.pendingAdministrator' <<<"${AFTER}")")" "$(lc "${LIDO_TIMELOCK}")"
# conservation in exact integers (jq would lose precision above 2^53): old pool + lockboxes before == after
sum() { jq -r '[.oldPool.balance, (.lockBoxes[])] | join(" + ")' <<<"$1" | bc; }
expect_eq "oldPool + Σ lockboxes (before = after)" "$(sum "${AFTER}")" "$(sum "${BEFORE}")"
[ "${FAIL}" = 0 ] || { echo "✗ invariants violated after the batch; see above (the batch did execute — inspect the fork, prepare a new run)"; exit 1; }

# ── record ────────────────────────────────────────────────────────────────────────────────────
# Lanes in a flat shape for the scenario test: the lockbox and amount each lane's custody moved to.
TEST_LANES="$(jq -c --argjson boxes "${BOXES}" --argjson groups "${LB_GROUPS}" 'map({slug, selector, siloed, lockBoxGroup, lockBox: $boxes[.lockBoxGroup],
    groupAmount: $groups[.lockBoxGroup].amount, remotePool: .remotePools[0], remoteToken, inboundCapacity: .inbound.capacity, outboundCapacity: .outbound.capacity, onRamp})' <<<"${LANES}")"
jq -n --arg run "${RUN_ID}" --arg l1 "${L1_CHAIN}" --arg token "${TOKEN}" --arg tar "${TAR}" --arg old "${OLD_POOL}" --arg hub "${NEW_HUB}" --arg lido "${LIDO_TIMELOCK}" \
    --arg cl "${CL_TIMELOCK}" --arg base "${BASE_LOCKBOX}" --arg escrow "${LEGACY_BRIDGE}" --argjson boxes "${BOXES}" --argjson groups "${LB_GROUPS}" \
    --argjson a "${PROPOSAL_A}" --argjson b "${PROPOSAL_B}" --argjson before "${BEFORE}" --argjson after "${AFTER}" --argjson pause "${PAUSE_CHECK}" \
    --argjson lanes "${TEST_LANES}" --argjson rebal "${EXPECTED_REBALANCERS}" --argjson manifest "$(cat "${MANIFEST}")" --arg sender "${SENDER}" \
    --argjson supported "$(printf '%s\n' "${SUPPORTED}" | grep . | jq -R . | jq -sc .)" --arg pair "${L2_CHAIN}" --arg pairsel "${PAIR_SELECTOR}" '
    {schemaVersion: 3, run: $run, chain: $l1, token: $token, registry: $tar, oldPool: $old, newHub: $hub, lidoTimelock: $lido, chainlinkTimelock: $cl,
     lockBoxes: $boxes, baseLockBox: $base, baseLockBoxDeployed: false, legacyEscrow: $escrow,
     lockBoxGroups: $groups, siloRebalancersAfter: $rebal,
     hubAtCutover: {supportedChains: $supported, deferredLane: $pair, deferredLaneSelector: $pairsel,
                    note: "the hub the batch bound served exactly the old pool lanes; the pair lane is connected by step 05c (hub-connect-lane)"},
     proposals: [$a, $b],
     snapshots: {before: $before, after: $after},
     pauseCheck: $pause, pauseCheckSender: $sender,
     laneCount: ($lanes | length), lanes: $lanes,
     impersonated: ["Chainlink timelock proposer " + $a.proposer + " (scheduleBatch; on mainnet an MCMS proposal)"],
     unverified: ["spoke pools: addition of the new hub as remote pool and the outbound pause on each spoke (no spoke forks in this target)",
                  "CCIP queue spoke -> Ethereum assumed empty: the fork is frozen; mainnet needs the drain window before the batch",
                  "DON delivery after the cutover (impersonated OffRamp in the scenario tests only)",
                  "MCMS signing of the two proposals; the executor was called by the deployer key through the CallProxy"],
     manifest: $manifest}' > "${OUT}"
jq_inplace state/l1.json --arg p "${OLD_POOL}" --arg a "${CL_TIMELOCK}" --arg ida "$(jq -r '.id' <<<"${PROPOSAL_A}")" --arg idb "$(jq -r '.id' <<<"${PROPOSAL_B}")" \
    '.registryPoolBefore = $p | .registryAdministratorBefore = $a | .hubCutover = {pauseProposal: $ida, cutoverProposal: $idb}'
echo ""
echo "✓ step 05h done — the registry binds ${TOKEN} to the new hub ${NEW_HUB} (the old pool's $(jq 'length' <<<"${LANES}") lanes); administration pending for the LidoTimelock ${LIDO_TIMELOCK} (hub-accept-admin accepts by MCMS proposal); the ${L2_CHAIN} lane is connected by step 05c."
echo "  pause proposal   $(jq -r '.id' <<<"${PROPOSAL_A}") (executed tx $(jq -r '.executedTx' <<<"${PROPOSAL_A}"))"
echo "  cutover proposal $(jq -r '.id' <<<"${PROPOSAL_B}") (executed tx $(jq -r '.executedTx' <<<"${PROPOSAL_B}"))"
echo "  record: ${OUT#${ROOT}/}"
