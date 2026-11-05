#!/usr/bin/env bash
# Step 01h — in-place upgrade targets whose target.json declares `.migration.hub`: inventory of the
# Ethereum pool the new hub takes over, read at one pinned block of the L1 RPC, and the run inputs
# derived from it. Read-only on chain; nothing is deployed or sent.
#
#   • reads the pool the TokenAdminRegistry binds to the token (must be `.migration.hub.pool`, a
#     SiloedLockReleaseTokenPool 1.6.0 owned by `.migration.hub.timelock`): owner, rebalancer, ERC20
#     balance, unsiloed accounting, and every supported lane — siloed flag, silo balance, silo
#     rebalancer, remote token, remote pools, outbound and inbound rate limits, the Router's on-ramp;
#     the registry entry; the Chainlink timelock's minimum delay and role holders;
#   • names each lane from the Chainlink registry API row of its selector (slug from the internalId)
#     and requires the lane set to equal `.migration.hub.expectedLanes`: a lane that appeared or
#     disappeared changes the manifest and the batch, so the run stops instead of guessing;
#   • writes state/hub-migration/inventory.json (what was read, at which block) and manifest.json
#     (what the cutover will do: lockbox group per lane — one shared lockbox for the unsiloed lanes,
#     one per siloed lane — the amount each lockbox receives, the silo rebalancer after the batch);
#   • writes a record per imported spoke (config/chains/<slug>.json with only what 2_Configure reads),
#     appends the lanes to the hub record's remote_lanes (is_siloed = the old pool's silo flag, so
#     DeployHubForMigration builds exactly that lockbox topology), writes the hub record's imported_lanes (remote
#     pools, limits, no required CCVs) and deferred_lanes (the target's own spokes: 2_Configure leaves
#     them to the hub's owner, so the cutover binds a hub that mirrors the old pool and step 05c
#     connects each spoke lane by a LidoTimelock proposal), and extends the run's
#     config/ccv-policy.json with the imported lanes (no required CCVs, no local outbound implementation).
#
# Runs after step 01m and before step 04 (1_Deploy reads remote_lanes). A hub record that already
# carries a deployment is left alone when it agrees with the inventory and refused otherwise.
# Without `.migration.hub` the step reports that and exits 0.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
cd "${ROOT}"
. "${HERE}/_common.sh"
[ "${WSTETH_OPERATION}" = "in-place-upgrade" ] \
    || { echo "✗ step 01h is for in-place-upgrade targets (WSTETH_OPERATION=${WSTETH_OPERATION})"; exit 1; }
TARGET_JSON="$(migration_target_json)"
HUB="$(jq -c '.migration.hub // empty' "${TARGET_JSON}")"
if [ -z "${HUB}" ]; then
    echo "▸ ${TARGET_JSON} declares no .migration.hub: the hub migration is not part of this target; nothing to inventory."
    exit 0
fi
if [ "${WSTETH_SKIP_L1:-0}" = 1 ]; then echo "▸ hub-only step (WSTETH_SKIP_L1=1); skip."; exit 0; fi
for t in curl bc; do command -v "${t}" >/dev/null || { echo "✗ ${t} not found in PATH"; exit 1; }; done
[ -f state/l1.json ] || { echo "✗ missing state/l1.json (run step 01m)"; exit 1; }

L1_CFG="${CFG_DIR}/${L1_CHAIN}.json"
TOKEN="$(jq -er '.addresses.token' "${L1_CFG}")"
TAR="$(jq -er '.ccip.token_admin_registry' "${L1_CFG}")"
ROUTER="$(jq -er '.ccip.router' "${L1_CFG}")"
HUB_POOL="$(jq -er '.pool' <<<"${HUB}")"
HUB_TIMELOCK="$(jq -er '.timelock' <<<"${HUB}")"
SILO_POLICY="$(jq -r '.siloRebalancerAfterCutover // "restore"' <<<"${HUB}")"
case "${SILO_POLICY}" in
    restore|timelock) ;;
    *) echo "✗ .migration.hub.siloRebalancerAfterCutover must be 'restore' (previous rebalancer) or 'timelock'"; exit 1 ;;
esac
EXPECTED_LANES="$(jq -c '[.expectedLanes[]] | sort' <<<"${HUB}")"
[ "$(jq 'length' <<<"${EXPECTED_LANES}")" -gt 0 ] || { echo "✗ .migration.hub.expectedLanes is empty"; exit 1; }
OUT_DIR="${ROOT}/state/hub-migration"; mkdir -p "${OUT_DIR}"

# One pinned block for every read: the amounts become the batch arguments of the cutover.
BLK="$(cast block-number --rpc-url "${L1_RPC}")"
BLOCK_HASH="$(cast block "${BLK}" -f hash --rpc-url "${L1_RPC}")"
BLOCK_TS="$(cast block "${BLK}" -f timestamp --rpc-url "${L1_RPC}")"
call() { cast call --rpc-url "${L1_RPC}" -b "${BLK}" "$@"; }
num() { awk '{print $1}'; }
# limiter <tuple text>: "(tokens [x], lastUpdated [x], isEnabled, capacity [x], rate [x])" -> "isEnabled capacity rate"
limiter() { printf '%s' "$1" | tr -d '\n' | sed -E 's/ \[[^]]*\]//g; s/[()]//g' | tr -d ' ' | awk -F, '{print $3, $4, $5}'; }
# decode_address_words <cast bytes[] output>: each 32-byte word -> checksummed address (EVM remotes only)
decode_address_words() {
    local w
    for w in $(printf '%s' "$1" | grep -oE '0x[0-9a-fA-F]+'); do
        [ "${#w}" = 66 ] || { echo "✗ remote address ${w} is not a 32-byte word (non-EVM encoding is not supported)" >&2; return 1; }
        cast abi-decode 'x()(address)' "${w}"
    done
}

echo "▸ ${L1_CHAIN} block ${BLK} (${BLOCK_HASH}, ${BLOCK_TS}); token ${TOKEN}; registry ${TAR}"
read -r TAR_ADMIN TAR_PENDING TAR_POOL <<<"$(call "${TAR}" 'getTokenConfig(address)((address,address,address))' "${TOKEN}" | tr -d '()' | tr ',' ' ')"
eq "${TAR_POOL}" "${HUB_POOL}" || { echo "✗ the registry binds ${TOKEN} to ${TAR_POOL}, target.json names ${HUB_POOL} (.migration.hub.pool)"; exit 1; }
eq "${TAR_ADMIN}" "${HUB_TIMELOCK}" || { echo "✗ registry administrator is ${TAR_ADMIN}, target.json names ${HUB_TIMELOCK} (.migration.hub.timelock)"; exit 1; }
OLD_POOL="${TAR_POOL}"
TYPE_VERSION="$(call "${OLD_POOL}" 'typeAndVersion()(string)' | tr -d '"')"
[ "${TYPE_VERSION}" = "SiloedLockReleaseTokenPool 1.6.0" ] \
    || { echo "✗ ${OLD_POOL} is '${TYPE_VERSION}'; the cutover batch is written for SiloedLockReleaseTokenPool 1.6.0"; exit 1; }
OWNER="$(call "${OLD_POOL}" 'owner()(address)')"
REBALANCER="$(call "${OLD_POOL}" 'getRebalancer()(address)')"
RATE_LIMIT_ADMIN="$(call "${OLD_POOL}" 'getRateLimitAdmin()(address)')"
UNSILOED="$(call "${OLD_POOL}" 'getUnsiloedLiquidity()(uint256)' | num)"
BALANCE="$(call "${TOKEN}" 'balanceOf(address)(uint256)' "${OLD_POOL}" | num)"
eq "${OWNER}" "${HUB_TIMELOCK}" || { echo "✗ old pool owner ${OWNER} is not the Chainlink timelock ${HUB_TIMELOCK}"; exit 1; }
eq "${REBALANCER}" "${HUB_TIMELOCK}" \
    || { echo "✗ unsiloed rebalancer is ${REBALANCER}; the batch withdraws the unsiloed bucket as the timelock"; exit 1; }
echo "  old pool ${OLD_POOL} (${TYPE_VERSION}): balance $(cast from-wei "${BALANCE}") wstETH, unsiloed $(cast from-wei "${UNSILOED}")"

echo "▸ Chainlink timelock ${HUB_TIMELOCK}"
MIN_DELAY="$(call "${HUB_TIMELOCK}" 'getMinDelay()(uint256)' | num)"
BLOCKED_COUNT="$(call "${HUB_TIMELOCK}" 'getBlockedFunctionSelectorCount()(uint256)' | num)"
ROLES_JSON='{}'
for r in ADMIN_ROLE PROPOSER_ROLE EXECUTOR_ROLE CANCELLER_ROLE BYPASSER_ROLE; do
    role="$(call "${HUB_TIMELOCK}" "${r}()(bytes32)")"
    n="$(call "${HUB_TIMELOCK}" 'getRoleMemberCount(bytes32)(uint256)' "${role}" | num)"
    members='[]'; i=0
    while [ "${i}" -lt "${n}" ]; do
        m="$(call "${HUB_TIMELOCK}" 'getRoleMember(bytes32,uint256)(address)' "${role}" "${i}")"
        members="$(jq -c --arg m "${m}" '. + [$m]' <<<"${members}")"; i=$((i + 1))
    done
    ROLES_JSON="$(jq -c --arg r "${r}" --arg h "${role}" --argjson m "${members}" '. + {($r): {hash: $h, members: $m}}' <<<"${ROLES_JSON}")"
    echo "  ${r}: $(jq -r 'join(", ")' <<<"${members}")"
done
echo "  min delay ${MIN_DELAY}s, blocked selectors ${BLOCKED_COUNT}"
[ "$(jq -r '.PROPOSER_ROLE.members | length' <<<"${ROLES_JSON}")" -gt 0 ] || { echo "✗ the timelock has no proposer to impersonate"; exit 1; }
[ "$(jq -r '.EXECUTOR_ROLE.members | length' <<<"${ROLES_JSON}")" -gt 0 ] || { echo "✗ the timelock has no executor"; exit 1; }

# Chainlink registry API: the chain each selector belongs to (and the spoke's CCIP infrastructure
# 2_Configure requires in a remote record). Cached in the run for reproducibility.
API_ENV="testnet"; [ "${L1_CHAIN_ID}" = 1 ] && API_ENV="mainnet"
API_JSON="${OUT_DIR}/chains-api.json"
curl -fsS "https://docs.chain.link/api/ccip/v1/chains?environment=${API_ENV}&outputKey=selector" -o "${API_JSON}.tmp" \
    || { echo "✗ Chainlink registry API unreachable"; exit 1; }
mv "${API_JSON}.tmp" "${API_JSON}"
# slug <internalId>: "ethereum-mainnet-ink-1" -> ink, "bitcoin-mainnet-bitlayer-1" -> bitlayer, "0g-mainnet" -> zerog
slug_of() {
    jq -rn --arg id "$1" '$id | ascii_downcase | sub("-(mainnet|testnet)"; "") | sub("^(ethereum|bitcoin)-"; "")
        | sub("-[0-9]+$"; "") | gsub("-"; "_") | if . == "0g" then "zerog" else . end'
}

echo "▸ lanes of the old pool"
LANES='[]'; SILOED_TOTAL=0
while read -r sel; do
    [ -n "${sel}" ] || continue
    row="$(jq -c --arg s "${sel}" '.data.evm[$s] // empty' "${API_JSON}")"
    [ -n "${row}" ] || { echo "✗ selector ${sel} is not a ${API_ENV} chain in the Chainlink registry"; exit 1; }
    slug="$(slug_of "$(jq -r '.internalId' <<<"${row}")")"
    [[ "${slug}" =~ ^[a-z][a-z0-9_]*$ ]] || { echo "✗ derived slug '${slug}' for selector ${sel} is not usable as a record name"; exit 1; }
    siloed="$(call "${OLD_POOL}" 'isSiloed(uint64)(bool)' "${sel}")"
    rebal="$(call "${OLD_POOL}" 'getChainRebalancer(uint64)(address)' "${sel}")"
    avail="$(call "${OLD_POOL}" 'getAvailableTokens(uint64)(uint256)' "${sel}" | num)"
    remote_token="$(decode_address_words "$(call "${OLD_POOL}" 'getRemoteToken(uint64)(bytes)' "${sel}")")"
    remote_pools="$(decode_address_words "$(call "${OLD_POOL}" 'getRemotePools(uint64)(bytes[])' "${sel}")" | jq -R . | jq -sc .)"
    [ "$(jq 'length' <<<"${remote_pools}")" -gt 0 ] || { echo "✗ lane ${slug} (${sel}) has no remote pool"; exit 1; }
    read -r out_en out_cap out_rate <<<"$(limiter "$(call "${OLD_POOL}" 'getCurrentOutboundRateLimiterState(uint64)((uint128,uint32,bool,uint128,uint128))' "${sel}")")"
    read -r in_en in_cap in_rate <<<"$(limiter "$(call "${OLD_POOL}" 'getCurrentInboundRateLimiterState(uint64)((uint128,uint32,bool,uint128,uint128))' "${sel}")")"
    onramp="$(call "${ROUTER}" 'getOnRamp(uint64)(address)' "${sel}")"
    group="shared"; [ "${siloed}" = "true" ] && group="${slug}"
    if [ "${siloed}" = "true" ]; then SILOED_TOTAL="$(echo "${SILOED_TOTAL} + ${avail}" | bc)"; fi
    LANES="$(jq -c --arg slug "${slug}" --arg sel "${sel}" --argjson row "${row}" --argjson siloed "${siloed}" --arg rebal "${rebal}" \
        --arg avail "${avail}" --arg token "${remote_token}" --argjson pools "${remote_pools}" --argjson out_en "${out_en}" --arg out_cap "${out_cap}" \
        --arg out_rate "${out_rate}" --argjson in_en "${in_en}" --arg in_cap "${in_cap}" --arg in_rate "${in_rate}" --arg onramp "${onramp}" --arg group "${group}" \
        '. + [{slug: $slug, selector: $sel, chainId: $row.chainId, internalId: $row.internalId, displayName: $row.displayName,
               siloed: $siloed, rebalancer: $rebal, siloBalance: (if $siloed then $avail else "0" end), availableTokens: $avail,
               remoteToken: $token, remotePools: $pools,
               outbound: {enabled: $out_en, capacity: $out_cap, rate: $out_rate}, inbound: {enabled: $in_en, capacity: $in_cap, rate: $in_rate},
               onRamp: $onramp, lockBoxGroup: $group,
               registry: {router: $row.router, rmn_proxy: $row.rmn, token_admin_registry: $row.tokenAdminRegistry, registry_module_owner: $row.registryModule}}]' <<<"${LANES}")"
    printf '  %-10s %-20s siloed=%-5s silo=%s wstETH rebalancer=%s remotePool=%s out=(%s,%s,%s) in=(%s,%s,%s)\n' \
        "${slug}" "${sel}" "${siloed}" "$( [ "${siloed}" = true ] && cast from-wei "${avail}" || echo '-')" "${rebal}" \
        "$(jq -r '.[0]' <<<"${remote_pools}")" "${out_en}" "${out_cap}" "${out_rate}" "${in_en}" "${in_cap}" "${in_rate}"
done < <(call "${OLD_POOL}" 'getSupportedChains()(uint64[])' | grep -oE '[0-9]{15,}')
LANES="$(jq -c 'sort_by(.slug)' <<<"${LANES}")"
FOUND_LANES="$(jq -c '[.[].slug] | sort' <<<"${LANES}")"
[ "${FOUND_LANES}" = "${EXPECTED_LANES}" ] || {
    echo "✗ the old pool serves ${FOUND_LANES}, target.json expects ${EXPECTED_LANES} (.migration.hub.expectedLanes)."
    echo "  Update the target (and the plan) if the lane set changed; the manifest is not guessed from a changed set."
    exit 1; }
for s in $(jq -r '.[].slug' <<<"${LANES}"); do
    [ "${s}" != "${L1_CHAIN}" ] && [ "${s}" != "${L2_CHAIN}" ] || { echo "✗ imported lane slug '${s}' collides with a chain of the pair"; exit 1; }
    if [ -f "${CFG_DIR}/${s}.json" ] && ! jq -e '.imported' "${CFG_DIR}/${s}.json" >/dev/null; then
        echo "✗ ${CFG_DIR}/${s}.json exists and is not an imported record; the slug collides with a spoke of the target"; exit 1
    fi
done
UNACCOUNTED="$(echo "${BALANCE} - ${UNSILOED} - ${SILOED_TOTAL}" | bc)"
echo "  accounting: balance ${BALANCE} = unsiloed ${UNSILOED} + silos ${SILOED_TOTAL} + unaccounted ${UNACCOUNTED}"
[ "${UNACCOUNTED}" = 0 ] || echo "  ⚠ ${UNACCOUNTED} wei in the old pool is outside its accounting (direct transfers or dust); the cutover refuses to run until this is explained (HUB_ALLOW_UNACCOUNTED=1 leaves it in the old pool)"

# lockBoxGroups: shared <- unsiloed bucket; each siloed lane <- its silo balance.
LB_GROUPS="$(jq -c --arg unsiloed "${UNSILOED}" '
    (map(select(.siloed | not)) | map(.slug)) as $shared
    | ({} | if ($shared | length) > 0 then . + {shared: {lanes: $shared, amount: $unsiloed}} else . end)
    + (map(select(.siloed)) | map({(.slug): {lanes: [.slug], amount: .siloBalance}}) | add // {})' <<<"${LANES}")"

INVENTORY="$(jq -n --argjson hub "${HUB}" --argjson cid "${L1_CHAIN_ID}" --argjson blk "${BLK}" --arg bh "${BLOCK_HASH}" --argjson ts "${BLOCK_TS}" \
    --arg rpc "${L1_RPC}" --arg env "${API_ENV}" --arg token "${TOKEN}" --arg tar "${TAR}" --arg admin "${TAR_ADMIN}" --arg pending "${TAR_PENDING}" \
    --arg pool "${OLD_POOL}" --arg tv "${TYPE_VERSION}" --arg owner "${OWNER}" --arg rebal "${REBALANCER}" --arg rla "${RATE_LIMIT_ADMIN}" \
    --arg bal "${BALANCE}" --arg uns "${UNSILOED}" --arg st "${SILOED_TOTAL}" --arg un "${UNACCOUNTED}" --arg tl "${HUB_TIMELOCK}" \
    --arg delay "${MIN_DELAY}" --arg blocked "${BLOCKED_COUNT}" --argjson roles "${ROLES_JSON}" --argjson lanes "${LANES}" --arg router "${ROUTER}" '
    {schemaVersion: 1,
     target: $hub,
     readAt: {chainId: $cid, block: $blk, blockHash: $bh, timestamp: $ts, rpc: $rpc, registryApiEnvironment: $env},
     token: $token, router: $router,
     registry: {address: $tar, administrator: $admin, pendingAdministrator: $pending, pool: $pool},
     oldPool: {address: $pool, typeAndVersion: $tv, owner: $owner, rebalancer: $rebal, rateLimitAdmin: $rla,
               balance: $bal, unsiloedLiquidity: $uns, siloedTotal: $st, unaccounted: $un},
     chainlinkTimelock: {address: $tl, minDelay: ($delay | tonumber), blockedSelectorCount: ($blocked | tonumber), roles: $roles},
     lanes: $lanes}')"
MANIFEST="$(jq --argjson groups "${LB_GROUPS}" --arg policy "${SILO_POLICY}" '. + {lockBoxGroups: $groups, siloRebalancerAfterCutover: $policy}' <<<"${INVENTORY}")"
printf '%s\n' "${INVENTORY}" | jq . > "${OUT_DIR}/inventory.json"
printf '%s\n' "${MANIFEST}" | jq . > "${OUT_DIR}/manifest.json"
echo "▸ wrote ${OUT_DIR#${ROOT}/}/inventory.json and manifest.json; lockbox groups: $(jq -r 'to_entries | map("\(.key)[\(.value.lanes | length)]=\(.value.amount)") | join(", ")' <<<"${LB_GROUPS}")"

# ── run inputs derived from the manifest ─────────────────────────────────────────────────────
# Remote lanes of the hub: the target's own spokes first, then the imported lanes (is_siloed = the
# old pool's silo flag: DeployHubForMigration gives every siloed lane its own lockbox and the others one shared).
# The target's own spokes are deferred lanes: their lockbox is prepared after the cutover;
# our ConfigureHubForMigration leaves their configuration to the hub's owner, so the hub the cutover binds (05h) mirrors the old
# pool exactly, and Chainlink connects each spoke lane afterwards by a LidoTimelock proposal (05c).
NEW_LANES="$(jq -c 'map({is_siloed: .siloed, remote_chain_name: .slug})' <<<"${LANES}")"
IMPORTED="$(jq -c 'map({(.slug): {remote_pools: .remotePools, rate_limits: {outbound: .outbound, inbound: .inbound}, required_ccvs: "none"}}) | add' <<<"${LANES}")"
SLUGS="$(jq -c 'map(.slug)' <<<"${LANES}")"
DESIRED_LANES="$(jq -c --argjson slugs "${SLUGS}" --argjson new "${NEW_LANES}" '[.remote_lanes[] | select(.remote_chain_name as $n | $slugs | index($n) | not)] + $new' "${L1_CFG}")"
DEFERRED="$(jq -c --argjson slugs "${SLUGS}" '[.remote_lanes[].remote_chain_name | select(. as $n | $slugs | index($n) | not)]' "${L1_CFG}")"
[ "$(jq 'length' <<<"${DEFERRED}")" -gt 0 ] || { echo "✗ ${L1_CFG#${ROOT}/} lists no lane of its own besides the imported ones; nothing for the hub to connect"; exit 1; }
if jq -e '.deployed.token_pool' "${L1_CFG}" >/dev/null 2>&1; then
    if [ "$(jq -cS '.remote_lanes' "${L1_CFG}")" = "$(jq -cS . <<<"${DESIRED_LANES}")" ] \
        && [ "$(jq -cS '.imported_lanes // {}' "${L1_CFG}")" = "$(jq -cS . <<<"${IMPORTED}")" ] \
        && [ "$(jq -cS '.deferred_lanes // []' "${L1_CFG}")" = "$(jq -cS . <<<"${DEFERRED}")" ]; then
        echo "▸ ${L1_CFG#${ROOT}/} already carries a deployment and agrees with this inventory; record left as is."
    else
        echo "✗ ${L1_CFG#${ROOT}/} already carries a deployment whose lanes differ from this inventory; prepare a new run."
        exit 1
    fi
else
    jq_inplace "${L1_CFG}" --argjson lanes "${DESIRED_LANES}" --argjson imported "${IMPORTED}" --argjson deferred "${DEFERRED}" \
        '.remote_lanes = $lanes | .imported_lanes = $imported | .deferred_lanes = $deferred'
    echo "▸ ${L1_CFG#${ROOT}/}: remote_lanes now $(jq -r '[.remote_lanes[] | .remote_chain_name + (if .is_siloed then "(siloed)" else "" end)] | join(", ")' "${L1_CFG}"); imported_lanes written; deferred_lanes $(jq -r 'join(", ")' <<<"${DEFERRED}") (connected by step 05c)"
fi
# One record per imported spoke: only the standard remote-record fields used by the migration scripts, plus the
# provenance. The spoke itself is not deployed, configured or verified by this run.
while read -r lane; do
    slug="$(jq -r '.slug' <<<"${lane}")"
    jq -n --argjson lane "${lane}" --arg l1 "${L1_CHAIN}" --arg old "${OLD_POOL}" --argjson blk "${BLK}" '
        {addresses: {token: $lane.remoteToken},
         ccip: {chain_selector: $lane.selector, router: $lane.registry.router, rmn_proxy: $lane.registry.rmn_proxy,
                token_admin_registry: $lane.registry.token_admin_registry, registry_module_owner: $lane.registry.registry_module_owner},
         chain: {chain_id: $lane.chainId, chain_name: $lane.slug},
         remote_lanes: [{is_siloed: false, remote_chain_name: $l1}],
         deployed: {token_pool: $lane.remotePools[0]},
         imported: {source_pool: $old, block: $blk, selector: $lane.selector, internal_id: $lane.internalId, display_name: $lane.displayName,
                    note: "spoke of a lane the hub takes over from the existing pool; not deployed by this run — only the standard remote-record fields used by the migration scripts"}}' \
        > "${CFG_DIR}/${slug}.json"
done < <(jq -c '.[]' <<<"${LANES}")
echo "▸ imported spoke records: $(jq -r 'map(.slug + ".json") | join(", ")' <<<"${LANES}")"
# The CCV policy covers exactly the hub's lanes: imported lanes require no CCVs and get no local
# outbound implementation.
POLICY="${ROOT}/config/ccv-policy.json"
if [ -f "${POLICY}" ]; then
    jq_inplace "${POLICY}" --arg l1 "${L1_CHAIN}" --argjson slugs "${SLUGS}" '
        reduce $slugs[] as $s (.; .chains[$l1].lanes[$s] = {outbound: [], inbound: []} | .chains[$l1].localResolver.outbound[$s] = "none")'
    echo "▸ ${POLICY#${ROOT}/}: ${L1_CHAIN} lanes $(jq -r --arg l1 "${L1_CHAIN}" '.chains[$l1].lanes | keys | join(", ")' "${POLICY}")"
else
    echo "  ⚠ no ${POLICY#${ROOT}/} in the run; verify-state will need one that covers the imported lanes"
fi
echo ""
echo "✓ step 01h done — inventory at ${L1_CHAIN} block ${BLK}; $(jq 'length' <<<"${LANES}") lanes, $(jq 'length' <<<"${LB_GROUPS}") lockbox groups for the imported lanes."
