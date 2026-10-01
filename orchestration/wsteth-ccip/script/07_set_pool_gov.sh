#!/usr/bin/env bash
# Step 07 — set pool in TAR + governance handover (final ownership/role end-state).
#
#   A) L2 only: grant the BurnMint pool MINTER_ROLE + BURNER_ROLE on the L2 wstETH token
#      (deployer holds the token DEFAULT_ADMIN_ROLE from step 03).
#   B) Both chains: register the token in the CCIP TokenAdminRegistry via RegistryModuleOwnerCustom
#      (.ccip.registry_module_owner). Prefer the permissionless entrypoints — these work
#      identically on a live network: registerAccessControlDefaultAdmin (L2 token holds the
#      deployer as DEFAULT_ADMIN_ROLE), or registerAdminViaGetCCIPAdmin/registerAdminViaOwner.
#      Fork-only fallback for tokens exposing none of the above (the canonical L1 wstETH):
#      impersonate the module owner and call TAR.proposeAdministrator directly; aborts loudly
#      on a live RPC (see LIVE_DEPLOY_CONCERNS.md §1-§2). See propose_tar_admin below.
#   C) L1: transfer the fresh token CCIP admin to the DAO Agent after TAR registration.
#      Both chains: drive the vendored 3_SetPoolAndTransferOwnership.s.sol — accepts the TAR
#      admin role, setPool(token,pool), transfers TAR admin -> POM (POM.directCall accepts),
#      then grants POM DEFAULT_ADMIN_ROLE -> Lido DAO (Agent on L1 / OpExec on L2) and revokes
#      the deployer.
#   D) L2 only: complete the token end-state (PLAN §4) — grant token DEFAULT_ADMIN_ROLE ->
#      OpExec, hand the OssifiableProxy admin -> OpExec, revoke the deployer's token admin.
#
# Idempotent: each part checks current on-chain state and skips work already done.
# Prereq: steps 01–05 ran on both chains (pools deployed + configured, ownership -> POM).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
cd "${ROOT}"
. "${HERE}/_common.sh"
: "${DEPLOYER_PRIVATE_KEY:?set DEPLOYER_PRIVATE_KEY}"
DEPLOYER="$(cast wallet address --private-key "${DEPLOYER_PRIVATE_KEY}")"

ZERO="0x0000000000000000000000000000000000000000"
# lc (lowercase) + eq (case-insensitive address compare) come from _common.sh.

# grant_role <token> <role> <grantee> <label> <rpc>: grant if the grantee lacks it (idempotent).
grant_role() {
    local token="$1" role="$2" grantee="$3" label="$4" rpc="$5"
    if [ "$(cast call "${token}" "hasRole(bytes32,address)(bool)" "${role}" "${grantee}" --rpc-url "${rpc}")" = "true" ]; then
        echo "  ${label} already granted; skip."
    else
        cast send "${token}" "grantRole(bytes32,address)" "${role}" "${grantee}" \
            --private-key "${DEPLOYER_PRIVATE_KEY}" --rpc-url "${rpc}" >/dev/null
        echo "  ${label} granted."
    fi
}

# revoke_role <token> <role> <holder> <label> <rpc>: revoke if the holder still has it (idempotent).
revoke_role() {
    local token="$1" role="$2" holder="$3" label="$4" rpc="$5"
    if [ "$(cast call "${token}" "hasRole(bytes32,address)(bool)" "${role}" "${holder}" --rpc-url "${rpc}")" = "true" ]; then
        cast send "${token}" "revokeRole(bytes32,address)" "${role}" "${holder}" \
            --private-key "${DEPLOYER_PRIVATE_KEY}" --rpc-url "${rpc}" >/dev/null
        echo "  ${label} revoked."
    else
        echo "  ${label} already absent; skip."
    fi
}

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
for f in config/chains/sepolia.json "${L2_CFG}"; do
    [ -f "$f" ] || { echo "✗ missing $f (run steps 04–05)"; exit 1; }
done
L1_AGENT=$(jq -er '.governance_addresses.lido_dao_agent' "${CFG_DIR}/sepolia.json")
L1_TOKEN=$(jq -r '.addresses.token'              config/chains/sepolia.json)
L1_TAR=$(jq -r '.ccip.token_admin_registry'      config/chains/sepolia.json)
L1_RMO=$(jq -r '.ccip.registry_module_owner'     config/chains/sepolia.json)

L2_TOKEN=$(jq -r '.addresses.token'              "${L2_CFG}")
L2_POOL=$(jq -r '.deployed.token_pool'           "${L2_CFG}")
L2_TAR=$(jq -r '.ccip.token_admin_registry'      "${L2_CFG}")
L2_RMO=$(jq -r '.ccip.registry_module_owner'     "${L2_CFG}")
L2_OPEXEC=$(jq -r '.governance_addresses.lido_dao_agent' "${L2_CFG}")

echo "deployer = ${DEPLOYER}"

# ═══════════════════════════════════════════════════════════════════════════
# A) L2: grant the pool MINTER_ROLE + BURNER_ROLE on the L2 wstETH token
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "▸ A) grant MINTER/BURNER to L2 pool ${L2_POOL} on L2 token ${L2_TOKEN}"
MINTER=$(cast call "${L2_TOKEN}" "MINTER_ROLE()(bytes32)" --rpc-url "${L2_RPC}")
BURNER=$(cast call "${L2_TOKEN}" "BURNER_ROLE()(bytes32)" --rpc-url "${L2_RPC}")
grant_role "${L2_TOKEN}" "${MINTER}" "${L2_POOL}" "MINTER_ROLE" "${L2_RPC}"
grant_role "${L2_TOKEN}" "${BURNER}" "${L2_POOL}" "BURNER_ROLE" "${L2_RPC}"

# ═══════════════════════════════════════════════════════════════════════════
# B) TAR: propose deployer as admin on each chain (L2 requires token ACL)
# ═══════════════════════════════════════════════════════════════════════════
# Seat the deployer as pending TAR admin. Prefer CCIP's permissionless RegistryModuleOwnerCustom
# entrypoints — these work IDENTICALLY on a live network (no impersonation):
#   1. registerAccessControlDefaultAdmin(token): caller must hold the token's DEFAULT_ADMIN_ROLE.
#      Our L2 ERC20BridgedPermit is AccessControl and the deployer holds it until part D hands it
#      to the DAO — so this is the path on L2.
#   2. registerAdminViaGetCCIPAdmin(token) / registerAdminViaOwner(token): when the token exposes
#      getCCIPAdmin()==deployer or owner()==deployer.
# Fork-only fallback: impersonate the registry module owner and call proposeAdministrator directly —
# needed for tokens that expose NONE of the above. The canonical L1 wstETH from core is neither
# AccessControl, Ownable, nor getCCIPAdmin, so on the fork L1 takes this path. On a LIVE RPC such a
# token cannot self-register and we abort loudly (see LIVE_DEPLOY_CONCERNS.md §1-§2) rather than
# silently no-op the anvil cheats.
# (The live registry modules — Sepolia 0xa3c7…31b0, Mantle Sepolia 0xf76c…05F6 — were verified to
#  carry registerAccessControlDefaultAdmin, so the L2 path needs no impersonation on live.)
register_via_module() {  # <name> <rmo> <fn(address)> <token> <rpc>
    local name="$1" rmo="$2" fn="$3" token="$4" rpc="$5"
    echo "  ${name}: ${fn%%(*}(token) via registry module ${rmo} (permissionless)"
    cast send "${rmo}" "${fn}" "${token}" \
        --private-key "${DEPLOYER_PRIVATE_KEY}" --rpc-url "${rpc}" >/dev/null
    echo "  ${name}: deployer is now pending TAR admin."
}
propose_tar_admin() {
    local name="$1" tar="$2" rmo="$3" token="$4" rpc="$5" acl_required="${6:-false}"
    read_tar_config "${tar}" "${token}" "${rpc}"
    if ! eq "${TAR_ADMIN}" "${ZERO}"; then
        echo "  ${name}: TAR administrator already set (${TAR_ADMIN}); skip propose."
        return
    fi
    if eq "${TAR_PENDING}" "${DEPLOYER}"; then
        echo "  ${name}: deployer already pending TAR admin; skip propose."
        return
    fi

    # 1) AccessControl DEFAULT_ADMIN_ROLE held by the deployer.
    local dar
    if dar=$(cast call "${token}" "DEFAULT_ADMIN_ROLE()(bytes32)" --rpc-url "${rpc}" 2>/dev/null) \
       && [ "$(cast call "${token}" "hasRole(bytes32,address)(bool)" "${dar}" "${DEPLOYER}" --rpc-url "${rpc}" 2>/dev/null)" = "true" ]; then
        register_via_module "${name}" "${rmo}" "registerAccessControlDefaultAdmin(address)" "${token}" "${rpc}"
        return
    fi

    # The locally maintained L2 token must register through its OZ ACL. A missing
    # role is a deployment error, including on forks; never mask it with another
    # token authority or registry-owner impersonation.
    if [ "${acl_required}" = "true" ]; then
        echo "  ✗ ${name}: ACL registration requires deployer to hold token DEFAULT_ADMIN_ROLE."
        exit 1
    fi

    # 2) getCCIPAdmin() or owner() == deployer (L1 only).
    local probe val
    for probe in "getCCIPAdmin()(address):registerAdminViaGetCCIPAdmin(address)" \
                 "owner()(address):registerAdminViaOwner(address)"; do
        val=$(cast call "${token}" "${probe%%:*}" --rpc-url "${rpc}" 2>/dev/null) || continue
        if eq "${val}" "${DEPLOYER}"; then
            register_via_module "${name}" "${rmo}" "${probe##*:}" "${token}" "${rpc}"
            return
        fi
    done

    # 3) Fork-only fallback: impersonate the registry module owner.
    if ! is_anvil "${rpc}"; then
        echo "  ✗ ${name}: token ${token} exposes no permissionless TAR-registration interface"
        echo "    (no AccessControl DEFAULT_ADMIN_ROLE / getCCIPAdmin() / owner() == deployer), and"
        echo "    ${rpc} is a live RPC — the registry module owner cannot be impersonated there."
        echo "    See LIVE_DEPLOY_CONCERNS.md §1-§2 (this is the canonical-wstETH-on-L1 case)."
        exit 1
    fi
    echo "  ${name}: [fork] impersonate registry module ${rmo} -> proposeAdministrator(token, deployer)"
    cast rpc anvil_impersonateAccount "${rmo}" --rpc-url "${rpc}" >/dev/null
    cast rpc anvil_setBalance "${rmo}" 0xde0b6b3a7640000 --rpc-url "${rpc}" >/dev/null   # 1 ETH
    # Always stop impersonating, even if the send reverts: under `set -e` a bare failure here would
    # abort the script and leave the registry module owner impersonated + funded on the fork.
    if ! cast send "${tar}" "proposeAdministrator(address,address)" "${token}" "${DEPLOYER}" \
        --from "${rmo}" --unlocked --rpc-url "${rpc}" >/dev/null; then
        cast rpc anvil_stopImpersonatingAccount "${rmo}" --rpc-url "${rpc}" >/dev/null 2>&1 || true
        echo "  ✗ ${name}: proposeAdministrator failed"; exit 1
    fi
    cast rpc anvil_stopImpersonatingAccount "${rmo}" --rpc-url "${rpc}" >/dev/null
    echo "  ${name}: deployer is now pending TAR admin."
}
echo ""
echo "▸ B) seat deployer as pending TAR admin (both chains)"
propose_tar_admin sepolia       "${L1_TAR}" "${L1_RMO}" "${L1_TOKEN}" "${L1_RPC}"
propose_tar_admin "${L2_CHAIN}" "${L2_TAR}" "${L2_RMO}" "${L2_TOKEN}" "${L2_RPC}" true

# The fresh L1 token uses the testnet core patch's current-CCIP-admin setter,
# rather than AccessControl.DEFAULT_ADMIN_ROLE. Complete that explicit integration
# independently of whether TAR was already proposed, registered or handed over.
echo ""
echo "▸ transfer fresh L1 token CCIP administration to the DAO Agent"
if ! L1_CCIP_ADMIN=$(cast call "${L1_TOKEN}" 'getCCIPAdmin()(address)' --rpc-url "${L1_RPC}"); then
    echo "✗ cannot read fresh L1 token CCIP admin; check the core patch and RPC"
    exit 1
fi
if eq "${L1_CCIP_ADMIN}" "${L1_AGENT}"; then
    echo "  L1 token CCIP admin already DAO Agent; skip."
elif eq "${L1_CCIP_ADMIN}" "${DEPLOYER}"; then
    cast send "${L1_TOKEN}" 'setCCIPAdmin(address)' "${L1_AGENT}" \
        --private-key "${DEPLOYER_PRIVATE_KEY}" --rpc-url "${L1_RPC}" >/dev/null
    L1_CCIP_ADMIN=$(cast call "${L1_TOKEN}" 'getCCIPAdmin()(address)' --rpc-url "${L1_RPC}")
    eq "${L1_CCIP_ADMIN}" "${L1_AGENT}" \
        || { echo "✗ L1 token CCIP admin handover did not reach the DAO Agent"; exit 1; }
    echo "  L1 token CCIP admin -> DAO Agent."
else
    echo "✗ L1 token CCIP admin is neither deployer nor DAO Agent: ${L1_CCIP_ADMIN}"
    exit 1
fi

# ═══════════════════════════════════════════════════════════════════════════
# C) drive 3_SetPoolAndTransferOwnership on both chains (TAR setPool + POM admin -> DAO)
# ═══════════════════════════════════════════════════════════════════════════
# Upstream scripts consume the selected run's populated chain records.

run_set_pool() {
    local name="$1" rpc="$2"
    echo "▸ 3_SetPoolAndTransferOwnership on ${name} (${rpc})"
    run_ccip_script "${name}" "${rpc}" "3_SetPoolAndTransferOwnership.s.sol:SetPoolAndTransferOwnershipScript"
}
echo ""
echo "▸ C) set pool + transfer POM admin to DAO (both chains)"
run_set_pool sepolia       "${L1_RPC}"
run_set_pool "${L2_CHAIN}" "${L2_RPC}"

# ═══════════════════════════════════════════════════════════════════════════
# D) L2 token end-state (PLAN §4): DEFAULT_ADMIN_ROLE + proxy admin -> OpExec, revoke deployer
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "▸ D) hand L2 token admin + proxy admin to OpExec ${L2_OPEXEC}, revoke deployer"
DEFAULT_ADMIN_ROLE="0x0000000000000000000000000000000000000000000000000000000000000000"

# grant DEFAULT_ADMIN_ROLE -> OpExec (before revoking deployer, to avoid lock-out)
grant_role "${L2_TOKEN}" "${DEFAULT_ADMIN_ROLE}" "${L2_OPEXEC}" "token DEFAULT_ADMIN_ROLE -> OpExec" "${L2_RPC}"

# OssifiableProxy admin -> OpExec
CUR_PROXY_ADMIN=$(cast call "${L2_TOKEN}" "proxy__getAdmin()(address)" --rpc-url "${L2_RPC}")
if eq "${CUR_PROXY_ADMIN}" "${L2_OPEXEC}"; then
    echo "  proxy admin already OpExec; skip."
elif eq "${CUR_PROXY_ADMIN}" "${DEPLOYER}"; then
    cast send "${L2_TOKEN}" "proxy__changeAdmin(address)" "${L2_OPEXEC}" \
        --private-key "${DEPLOYER_PRIVATE_KEY}" --rpc-url "${L2_RPC}" >/dev/null
    echo "  proxy admin -> OpExec."
else
    echo "  ⚠ proxy admin is ${CUR_PROXY_ADMIN} (not deployer/OpExec); leaving as-is."
fi

# revoke deployer's token DEFAULT_ADMIN_ROLE (last)
revoke_role "${L2_TOKEN}" "${DEFAULT_ADMIN_ROLE}" "${DEPLOYER}" "deployer token DEFAULT_ADMIN_ROLE" "${L2_RPC}"



echo ""
echo "✓ step 07 done."
