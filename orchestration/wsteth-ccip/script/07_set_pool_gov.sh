#!/usr/bin/env bash
# Step 07 — register the pool in the TokenAdminRegistry and hand governance over, with the
# component's own 3_SetPoolAndTransferOwnership.s.sol (components/ccip) on both chains.
#
# The component covers every registration path a scratch deployment needs: a token whose
# getCCIPAdmin() is the deployer (the scratch hub wstETH, core patch 0001 — the script registers,
# accepts and moves the CCIP admin to the DAO Agent), a token whose DEFAULT_ADMIN_ROLE the deployer
# holds (the spoke token 1_Deploy deployed — registered through the registry module's
# AccessControl entrypoint, then its admin role goes to the DAO and the deployer renounces it),
# and an administration already pending for the deployer. It then binds the pool, hands the
# registry administration to the LidoTimelock (accepted through the bypass), grants the timelock
# ADMIN_ROLE to the Lido DAO (Agent on L1 / OpExec on L2) and renounces the deployer's.
#
# What stays here is the in-place upgrade case the component does not model:
#   D) FORK-ONLY, L1 of an in-place target WITHOUT `.migration.hub`: the token's current registry
#      administrator (impersonated) hands the administration to the LidoTimelock and E binds the
#      pool. A target that declares the hub migration gets the hand-over from Chainlink's cutover
#      batch (step 05h), which binds the hub itself and leaves the administration pending, so D
#      skips; D refuses to run on such a target when the cutover record is missing, because this
#      shortcut would bind a hub that does not carry the old pool's lanes and custody.
#   E) a registry administration already PENDING for the LidoTimelock is accepted through the
#      timelock's bypass while the deployer still holds its ADMIN_ROLE, and the pool is bound in the
#      same batch unless it already is (after step 05h it is). 3_SetPool then finds the timelock
#      administering and only moves the admin role. Binding the pool here is a cutover when the
#      registry already names one (an in-place target without the hub migration): the displaced pool
#      is announced and recorded in the chain state file (registryPoolBefore), never replaced
#      silently. On the L2 of an in-place target nothing is pending here: the vote's action set
#      (step 06) registers the token, binds the pool and hands the administration to the timelock,
#      accepting it through the bypass in the same set.
#   C) 3_SetPoolAndTransferOwnership on both chains, skipped for a chain whose timelock admin has
#      already been handed over (the component's preflight requires the deployer as sole admin, so a
#      re-run after an interrupted spoke must not replay a finished hub).
#
# Prereq: steps 01–05 ran on both chains (pools deployed + configured, ownership -> timelock); on a
# target that declares `.migration.hub` also 05h and 05c (05c is a proposal of the timelock and does
# not depend on the acceptance below).
# In-place targets run this step BEFORE step 06: the vote's batches use the timelocks' admin bypass,
# so the DAO must already be their admin.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
cd "${ROOT}"
. "${HERE}/_common.sh"
: "${DEPLOYER_PRIVATE_KEY:?set DEPLOYER_PRIVATE_KEY}"
DEPLOYER="$(cast wallet address --private-key "${DEPLOYER_PRIVATE_KEY}")"

# lc (lowercase) + eq (case-insensitive address compare) come from _common.sh.

# Read TAR token config (administrator, pendingAdministrator, tokenPool) into globals.
read_tar_config() {
    local tar="$1" token="$2" rpc="$3" fields count
    fields="$(cast call "${tar}" "getTokenConfig(address)((address,address,address))" "${token}" \
        --rpc-url "${rpc}" | grep -oE '0x[0-9a-fA-F]{40}')"
    # Guard against cast output-format drift: positional parsing only holds if we got exactly the
    # three expected 40-hex addresses. Abort loudly rather than silently misassign admin/pending/pool.
    count="$(printf '%s\n' "${fields}" | grep -c . || true)"
    [ "${count}" = "3" ] || { echo "✗ read_tar_config: expected 3 addresses, got ${count}"; exit 1; }
    TAR_ADMIN="$(printf '%s\n' "${fields}" | sed -n '1p')"
    TAR_PENDING="$(printf '%s\n' "${fields}" | sed -n '2p')"
    TAR_POOL="$(printf '%s\n' "${fields}" | sed -n '3p')"
}

# ── load addresses ──
assert_l2_state_chain
L2_CFG="${L2_CFG_CANON}"
L1_CFG="${L1_CFG_CANON}"
for f in "${L1_CFG}" "${L2_CFG}"; do
    [ -f "$f" ] || { echo "✗ missing $f (run steps 04–05)"; exit 1; }
done
L1_AGENT=$(jq -er '.governance_addresses.lido_dao_agent' "${L1_CFG}")
L1_TOKEN=$(record_token                           "${L1_CFG}")
L1_TAR=$(jq -r '.ccip.token_admin_registry'      "${L1_CFG}")
L1_POOL=$(jq -r '.deployed.token_pool'           "${L1_CFG}")
L1_TIMELOCK=$(jq -r '.deployed.timelock'         "${L1_CFG}")

L2_TOKEN=$(record_token                           "${L2_CFG}")
L2_POOL=$(jq -r '.deployed.token_pool'           "${L2_CFG}")
L2_TAR=$(jq -r '.ccip.token_admin_registry'      "${L2_CFG}")
L2_OPEXEC=$(jq -er '.governance_addresses.lido_dao_agent' "${L2_CFG}")
L2_TIMELOCK=$(jq -r '.deployed.timelock'         "${L2_CFG}")

echo "deployer = ${DEPLOYER}"

# ═══════════════════════════════════════════════════════════════════════════
# E) accept a registry administration pending for the LidoTimelock and bind the pool
# ═══════════════════════════════════════════════════════════════════════════
# 3_SetPoolAndTransferOwnership only knows the deployer-registered path (it accepts for the
# deployer, binds the pool, then hands the administration to the timelock). When the token's
# administration was handed to the timelock by ANOTHER administrator — Chainlink's on mainnet L1
# (its cutover batch, replayed by step 05h on a fork, or part D's impersonated hand-over on a target
# without the hub migration), or the Base executor's action set on L2 — the acceptance and the pool
# binding are timelock calls. The deployer still holds the timelock's ADMIN_ROLE
# until part C, so they go through the bypass; on mainnet the DAO does the same as admin.
# accept_pending_tar_admin <name> <tar> <token> <pool> <timelock> <rpc> <state file>
accept_pending_tar_admin() {
    local name="$1" tar="$2" token="$3" pool="$4" timelock="$5" rpc="$6" state="${7:-}"
    [ -n "${timelock}" ] && [ "${timelock}" != "null" ] || { echo "  ✗ ${name}: no timelock in the record (run step 04)"; exit 1; }
    read_tar_config "${tar}" "${token}" "${rpc}"
    local only_pool=0
    if eq "${TAR_ADMIN}" "${timelock}"; then
        if eq "${TAR_POOL}" "${pool}"; then
            echo "  ${name}: timelock already administers the token with the pool bound; skip."
            return
        fi
        only_pool=1
        echo "  ${name}: timelock administers the token; binding pool ${pool} through the bypass."
    elif ! eq "${TAR_PENDING}" "${timelock}"; then
        echo "  ${name}: no registry administration pending for the timelock (admin ${TAR_ADMIN}, pending ${TAR_PENDING}); nothing to accept."
        return
    fi
    local admin_role
    admin_role="$(cast call "${timelock}" 'ADMIN_ROLE()(bytes32)' --rpc-url "${rpc}")"
    [ "$(cast call "${timelock}" 'hasRole(bytes32,address)(bool)' "${admin_role}" "${DEPLOYER}" --rpc-url "${rpc}")" = "true" ] \
        || { echo "  ✗ ${name}: the deployer no longer holds the timelock ADMIN_ROLE; the pending administration must be accepted by the DAO as admin"; exit 1; }
    if [ "${TAR_POOL}" != "0x0000000000000000000000000000000000000000" ] && ! eq "${TAR_POOL}" "${pool}"; then
        echo "  ⚠ ${name}: the registry serves ${token} through pool ${TAR_POOL} today; binding ${pool} CUTS OVER every lane and the liquidity that pool holds."
        [ -z "${state}" ] || jq_inplace "${state}" --arg p "${TAR_POOL}" '.registryPoolBefore = $p'
    fi
    local accept setpool calls
    accept="$(cast calldata 'acceptAdminRole(address)' "${token}")"
    setpool="$(cast calldata 'setPool(address,address)' "${token}" "${pool}")"
    if [ "${only_pool}" = 1 ]; then calls="[(${tar},0,${setpool})]"
    elif eq "${TAR_POOL}" "${pool}"; then calls="[(${tar},0,${accept})]"
    else calls="[(${tar},0,${accept}),(${tar},0,${setpool})]"; fi
    cast send "${timelock}" 'bypasserExecuteBatch((address,uint256,bytes)[])' "${calls}" \
        --private-key "${DEPLOYER_PRIVATE_KEY}" --rpc-url "${rpc}" >/dev/null
    read_tar_config "${tar}" "${token}" "${rpc}"
    eq "${TAR_ADMIN}" "${timelock}" && eq "${TAR_POOL}" "${pool}" \
        || { echo "  ✗ ${name}: registry state after the bypass batch is admin ${TAR_ADMIN}, pool ${TAR_POOL}"; exit 1; }
    echo "  ${name}: timelock ${timelock} administers ${token}; pool ${pool} bound."
}
# ═══════════════════════════════════════════════════════════════════════════
# D) in-place L1: the current registry administrator hands the token to the LidoTimelock (fork-only)
# ═══════════════════════════════════════════════════════════════════════════
# A target that declares the hub migration (.migration.hub in target.json) gets this hand-over from
# step 05h instead: Chainlink's cutover batch binds the new hub and leaves the administration pending
# for the timelock, so D finds it pending and skips. Running D without that step would replay the
# old Base-only shortcut (administration first, pool bound by E) and leave the nine lanes unfunded.
if [ "${WSTETH_OPERATION:-scratch-deployment}" = "in-place-upgrade" ] && [ "${WSTETH_SKIP_L1:-0}" != 1 ]; then
    echo ""
    echo "▸ D) ${L1_CHAIN}: registry administrator hands the token administration to the timelock"
    if jq -e '.migration.hub' "${WSTETH_TARGET_DIR:-/nonexistent}/target.json" >/dev/null 2>&1 && [ ! -f state/hub-migration.json ]; then
        echo "  ✗ ${L1_CHAIN}: the target declares the hub migration (.migration.hub) but state/hub-migration.json is missing — run hub-cutover (step 05h) before set-pool-gov"
        exit 1
    fi
    read_tar_config "${L1_TAR}" "${L1_TOKEN}" "${L1_RPC}"
    if eq "${TAR_ADMIN}" "${L1_TIMELOCK}" || eq "${TAR_PENDING}" "${L1_TIMELOCK}"; then
        echo "  ${L1_CHAIN}: administration already with or pending for the timelock (admin ${TAR_ADMIN}, pending ${TAR_PENDING}); skip."
    else
        [ "${TAR_ADMIN}" != "0x0000000000000000000000000000000000000000" ] \
            || { echo "  ✗ ${L1_CHAIN}: the token has no registry administrator to hand over from"; exit 1; }
        is_anvil "${L1_RPC}" \
            || { echo "  ✗ ${L1_CHAIN}: the hand-over impersonates the registry administrator ${TAR_ADMIN} and is fork-only; ${L1_RPC} is not anvil"; exit 1; }
        fund "${TAR_ADMIN}" "${L1_RPC}"
        with_fork_account "${L1_RPC}" "${TAR_ADMIN}" cast send "${L1_TAR}" 'transferAdminRole(address,address)' "${L1_TOKEN}" "${L1_TIMELOCK}" \
            --from "${TAR_ADMIN}" --unlocked --rpc-url "${L1_RPC}" >/dev/null
        read_tar_config "${L1_TAR}" "${L1_TOKEN}" "${L1_RPC}"
        eq "${TAR_PENDING}" "${L1_TIMELOCK}" || { echo "  ✗ ${L1_CHAIN}: hand-over not pending for the timelock (pending ${TAR_PENDING})"; exit 1; }
        jq_inplace state/l1.json --arg a "${TAR_ADMIN}" '.registryAdministratorBefore = $a'
        echo "  ${L1_CHAIN}: administrator ${TAR_ADMIN} (impersonated) handed ${L1_TOKEN} to the timelock; pending."
    fi
fi

echo ""
echo "▸ E) accept registry administration pending for the timelock (both chains)"
if [ "${WSTETH_SKIP_L1:-0}" != 1 ]; then
    accept_pending_tar_admin "${L1_CHAIN}" "${L1_TAR}" "${L1_TOKEN}" "${L1_POOL}" "${L1_TIMELOCK}" "${L1_RPC}" state/l1.json
fi
accept_pending_tar_admin "${L2_CHAIN}" "${L2_TAR}" "${L2_TOKEN}" "${L2_POOL}" "${L2_TIMELOCK}" "${L2_RPC}" "${L2_STATE_FILE}"

# ═══════════════════════════════════════════════════════════════════════════
# C) drive 3_SetPoolAndTransferOwnership on both chains (TAR setPool + timelock admin -> DAO)
# ═══════════════════════════════════════════════════════════════════════════
# timelock_handed_over <timelock> <dao> <rpc>: the end state 3_SetPool produces — the DAO holds the
# timelock ADMIN_ROLE and the deployer does not. The component's preflight rejects that state (it
# requires the deployer as sole admin), so the chain is finished and must be skipped on a re-run.
timelock_handed_over() {
    local timelock="$1" dao="$2" rpc="$3" admin_role
    admin_role="$(cast call "${timelock}" 'ADMIN_ROLE()(bytes32)' --rpc-url "${rpc}")"
    [ "$(cast call "${timelock}" 'hasRole(bytes32,address)(bool)' "${admin_role}" "${dao}" --rpc-url "${rpc}")" = "true" ] \
        && [ "$(cast call "${timelock}" 'hasRole(bytes32,address)(bool)' "${admin_role}" "${DEPLOYER}" --rpc-url "${rpc}")" = "false" ]
}
run_set_pool() {
    local name="$1" rpc="$2" timelock="$3" dao="$4"
    if timelock_handed_over "${timelock}" "${dao}" "${rpc}"; then
        echo "▸ ${name}: timelock ${timelock} admin already handed to ${dao}; 3_SetPoolAndTransferOwnership done, skip."
        return
    fi
    echo "▸ 3_SetPoolAndTransferOwnership on ${name} (${rpc})"
    run_ccip_script "${name}" "${rpc}" "3_SetPoolAndTransferOwnership.s.sol:SetPoolAndTransferOwnershipScript"
}
echo ""
echo "▸ C) set pool + transfer timelock admin to DAO (both chains)"
if [ "${WSTETH_SKIP_L1:-0}" != 1 ]; then
    run_set_pool "${L1_CHAIN}" "${L1_RPC}" "${L1_TIMELOCK}" "${L1_AGENT}"
fi
run_set_pool "${L2_CHAIN}" "${L2_RPC}" "${L2_TIMELOCK}" "${L2_OPEXEC}"

echo ""
echo "✓ step 07 done."
