#!/usr/bin/env bash
# Step 00 — preflight: verify the initial conditions are suitable to START a deployment.
# Read-only (no transactions, no state writes). Checks, per chain (L1 Sepolia / the L2_CHAIN L2):
#   • RPC health — reachable, expected chain id, latest block + freshness, substrate (anvil|live)
#   • deployer — key↔address consistency, nonce, balance vs spend thresholds
#   • on-chain dependencies from config/chains/*.json — the EXTERNAL contracts the pipeline
#     drives (router, TAR, RMN proxy, registry module, CCV resolver/verifier): bytecode present
#     + typeAndVersion where exposed; cross-chain lane support (router.isChainSupported);
#     RMN curse status (best-effort)
#   • record state — warn if config/chains already carries a .deployed section / token address
#     (a previous deployment would be overwritten)
#   • tooling — cast/forge/jq present, required submodules initialized, their patches applied
# Hard failures (exit 1): unreachable RPC, wrong chain id, missing dependency bytecode,
# balance below the minimum, key↔address mismatch, missing submodule patches. Everything else is
# a warning.
#
# Thresholds (override via env): MIN_DEPLOYER_L1_ETH (default 2, the live run spent ~1.4),
# MIN_DEPLOYER_L2_ETH (default 0.05, the live run spent ~0.04). Skipped on anvil (pre-funded/fundable).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
cd "${ROOT}"
. "${HERE}/_common.sh"

MIN_DEPLOYER_L1_ETH="${MIN_DEPLOYER_L1_ETH:-2}"
MIN_DEPLOYER_L2_ETH="${MIN_DEPLOYER_L2_ETH:-0.05}"

FAIL=0
WARN=0
ok()   { echo "  ✔ $*"; }
warn() { echo "  ⚠ $*"; WARN=$((WARN + 1)); }
fail() { echo "  ✗ $*"; FAIL=1; }

# typever <addr> <rpc> <label>: report typeAndVersion() when the contract exposes it.
typever() {
    local tv
    tv="$(cast call "$1" 'typeAndVersion()(string)' --rpc-url "$2" 2>/dev/null || true)"
    [ -n "${tv}" ] && ok "$3: ${tv//\"/} at $1" || ok "$3: at $1 (no typeAndVersion)"
}

# dep <addr> <rpc> <label>: external dependency must exist (bytecode) — then report its version.
dep() {
    if has_code "$1" "$2"; then typever "$1" "$2" "$3"; else fail "$3: NO CODE at $1"; fi
}

# dep_soft: like dep, but only warns — for record entries that are OUTPUTS of a prior deploy
# (e.g. the self-deployed CCV layer), where missing code means record↔RPC mismatch, not a blocker.
dep_soft() {
    if has_code "$1" "$2"; then typever "$1" "$2" "$3"
    else warn "$3: no code at $1 (record entry from another deploy/substrate — redeployed by the CCV step)"; fi
}

# ether <wei>: render a wei amount as ether for messages.
ether() { cast from-wei "$1" 2>/dev/null || echo "?"; }

# ge_eth <wei> <eth>: succeed iff <wei> >= <eth> ether (integer wei math via cast).
ge_eth() { [ "$(echo "$1 >= $(cast to-wei "$2" ether)" | bc)" = "1" ]; }

echo "── tooling ───────────────────────────────────────────────────────────────"
for tool in cast forge jq bc; do
    command -v "${tool}" >/dev/null 2>&1 && ok "${tool}: $(command -v "${tool}")" || fail "${tool} not found in PATH"
done
for sub in ../../components/core ../../components/ccip ../../libs/state-mate ../../components/governance-crosschain-bridges; do
    if [ -e "${sub}/.git" ]; then
        sha="$(git -C "${sub}" rev-parse --short HEAD 2>/dev/null || echo '?')"
        dirty=""
        git -C "${sub}" diff --quiet 2>/dev/null || dirty=" (dirty)"
        ok "submodule ${sub} @ ${sha}${dirty}"
    else
        warn "submodule ${sub} not initialized (just init / init-thirdparty)"
    fi
done
# ../../components/core is pinned upstream + patched locally (patches/) — hence "(dirty)" above.
# core/0001 changes DEPLOYED wstETH bytecode (without it step 01 makes a token that cannot
# self-register into the TAR). ../../components/ccip is pristine upstream; its former guardian patch is retired.
if [ -e ../../components/core/.git ]; then
    if bash "${HERE}/00_patch_submodules.sh" --check >/dev/null 2>&1; then
        ok "submodule patches: all applied (patches/*/*.patch)"
    else
        fail "submodule patches NOT applied — run 'just patch-submodules' (details: 'just patch-submodules-check')"
    fi
fi

# Cheap pre-build check of the local token's authorization boundary. The retained
# IERC20Bridged interface is not an implemented mint/burn path. Step 03 checks
# the compiled ABI and deployed token as well.
L2_TOKEN_SRC="../../components/wsteth-token/contracts/token"
if [ -f "${L2_TOKEN_SRC}/ERC20Bridged.sol" ]; then
    if grep -qE '^[[:space:]]*address public (immutable )?bridge;|onlyBridge|^[[:space:]]*contract ERC20Bridged is[^{]*IERC20Bridged' \
            "${L2_TOKEN_SRC}/ERC20Bridged.sol" "${L2_TOKEN_SRC}/ERC20BridgedPermit.sol"; then
        fail "L2 token base still carries the legacy \`bridge\` mint/burn authority (${L2_TOKEN_SRC}/ERC20Bridged.sol) — local token source violates the authority model; step 03 would deploy a token with a second mint principal outside the role system"
    else
        ok "L2 token base carries no legacy \`bridge\` authority (locally maintained)"
    fi
else
    fail "Local components/wsteth-token sources are missing"
fi

echo "── deployer key ──────────────────────────────────────────────────────────"
if [ -n "${DEPLOYER_PRIVATE_KEY:-}" ]; then
    KEY_ADDR="$(cast wallet address --private-key "${DEPLOYER_PRIVATE_KEY}" 2>/dev/null || true)"
    if [ -z "${KEY_ADDR}" ]; then
        fail "DEPLOYER_PRIVATE_KEY is set but not a valid key"
    elif eq "${KEY_ADDR}" "${DEPLOYER_ADDRESS}"; then
        ok "DEPLOYER_PRIVATE_KEY matches DEPLOYER_ADDRESS (${DEPLOYER_ADDRESS})"
    else
        fail "DEPLOYER_PRIVATE_KEY derives ${KEY_ADDR}, but DEPLOYER_ADDRESS=${DEPLOYER_ADDRESS}"
    fi
else
    warn "DEPLOYER_PRIVATE_KEY not set (required by steps 01–07; preflight continues address-only)"
fi

# check_chain <tag> <rpc> <expected_chain_id> <cfg_json> <min_eth> <remote_selector>
check_chain() {
    local tag="$1" rpc="$2" want_cid="$3" cfg="$4" min_eth="$5" remote_sel="$6"

    echo "── ${tag} — RPC health (${rpc}) ──────────────────────────────────────"
    local cid
    cid="$(cast chain-id --rpc-url "${rpc}" 2>/dev/null || true)"
    if [ -z "${cid}" ]; then fail "RPC unreachable"; return; fi
    [ "${cid}" = "${want_cid}" ] && ok "chain id ${cid}" || { fail "chain id ${cid} != ${want_cid}"; return; }

    local substrate="live"
    is_anvil "${rpc}" && substrate="anvil fork"
    ok "substrate: ${substrate}"

    local blk ts now age
    blk="$(cast block-number --rpc-url "${rpc}")"
    ts="$(cast block latest --field timestamp --rpc-url "${rpc}")"
    now="$(date +%s)"
    age=$((now - ts))
    if [ "${substrate}" = "live" ] && [ "${age}" -gt 120 ]; then
        warn "latest block ${blk} is ${age}s old (stale/lagging endpoint?)"
    else
        ok "latest block ${blk} (${age}s old)"
    fi
    ok "gas price: $(ether "$(cast gas-price --rpc-url "${rpc}")") ETH/gas"

    echo "── ${tag} — deployer ${DEPLOYER_ADDRESS} ─────────────────────────────"
    local bal nonce
    bal="$(cast balance "${DEPLOYER_ADDRESS}" --rpc-url "${rpc}")"
    nonce="$(cast nonce "${DEPLOYER_ADDRESS}" --rpc-url "${rpc}")"
    if [ "${substrate}" = "anvil fork" ]; then
        ok "balance $(ether "${bal}") ETH (anvil — fundable, threshold skipped), nonce ${nonce}"
    elif ge_eth "${bal}" "${min_eth}"; then
        ok "balance $(ether "${bal}") ETH (>= ${min_eth}), nonce ${nonce}"
    else
        fail "balance $(ether "${bal}") ETH < ${min_eth} ETH minimum (override MIN_*_ETH if intentional)"
    fi

    echo "── ${tag} — on-chain dependencies (${cfg}) ───────────────────────────"
    local router tar rmn regmod resolver verifier
    router="$(jq -r '.ccip.router' "${cfg}")"
    tar="$(jq -r '.ccip.token_admin_registry' "${cfg}")"
    rmn="$(jq -r '.ccip.rmn_proxy' "${cfg}")"
    regmod="$(jq -r '.ccip.registry_module_owner' "${cfg}")"
    resolver="$(jq -r '.ccv.verifier_resolver // empty' "${cfg}")"
    verifier="$(jq -r '.ccv.message_id_verifier // empty' "${cfg}")"
    dep "${router}" "${rpc}" "CCIP Router"
    dep "${tar}"    "${rpc}" "TokenAdminRegistry"
    dep "${rmn}"    "${rpc}" "RMN proxy"
    dep "${regmod}" "${rpc}" "RegistryModuleOwner"
    [ -n "${resolver}" ] && dep_soft "${resolver}" "${rpc}" "CCV verifier resolver"
    [ -n "${verifier}" ] && dep_soft "${verifier}" "${rpc}" "CCV message-id verifier"

    # The lane to the remote chain must exist on the router (DON-side prerequisite).
    local supported
    supported="$(cast call "${router}" 'isChainSupported(uint64)(bool)' "${remote_sel}" --rpc-url "${rpc}" 2>/dev/null || true)"
    case "${supported}" in
        true)  ok "router supports remote lane (selector ${remote_sel})" ;;
        false) fail "router does NOT support remote selector ${remote_sel} — no lane to deploy against" ;;
        *)     warn "router lane support check failed (isChainSupported reverted?)" ;;
    esac

    # RMN curse status — ABI differs across RMN versions, so best-effort only.
    local cursed
    cursed="$(cast call "${rmn}" 'isCursed()(bool)' --rpc-url "${rpc}" 2>/dev/null || true)"
    case "${cursed}" in
        false) ok "RMN: not cursed" ;;
        true)  fail "RMN reports CURSED — CCIP halted on this chain" ;;
        *)     warn "RMN curse status unavailable (isCursed() not exposed by this version)" ;;
    esac

    echo "── ${tag} — record state (${cfg}) ────────────────────────────────────"
    local token deployed
    token="$(jq -r '.addresses.token // empty' "${cfg}")"
    deployed="$(jq -r '.deployed.token_pool // empty' "${cfg}")"
    if [ -n "${token}" ] || [ -n "${deployed}" ]; then
        warn "record already carries deployment output (token=${token:-—}, pool=${deployed:-—}) — a fresh deploy overwrites it (prepare a new run for a fresh deployment)"
    else
        ok "record pristine (no deployment output)"
    fi
    # .guardian is a legacy record field and is unused by current 1_Deploy: GUARDIAN_ROLE no
    # longer exists on PoolOperationManager. Do not treat guardian == emergency_brakes as a
    # POM-role collapse.
}

L1_SEL="$(jq -r '.ccip.chain_selector' config/chains/sepolia.json)"
L2_SEL="$(jq -r '.ccip.chain_selector' "${L2_CFG_CANON}")"

check_chain "L1 Sepolia"     "${L1_RPC}" 11155111        config/chains/sepolia.json "${MIN_DEPLOYER_L1_ETH}" "${L2_SEL}"
check_chain "L2 ${L2_CHAIN}" "${L2_RPC}" "${L2_CHAIN_ID}" "${L2_CFG_CANON}"          "${MIN_DEPLOYER_L2_ETH}" "${L1_SEL}"

# Pair consistency: an L1 record that already carries deploy output for a DIFFERENT L2 means the
# Sepolia fork/record belongs to another pair — step 04's skip logic would then never create this
# pair's lockbox.
echo "── pair consistency (config/chains/sepolia.json vs L2_CHAIN=${L2_CHAIN}) ──"
L1_LANE="$(jq -r '.remote_lanes[0].remote_chain_name // empty' config/chains/sepolia.json)"
L1_DEPLOYED="$(jq -r '.deployed.token_pool // empty' config/chains/sepolia.json)"
if [ -n "${L1_DEPLOYED}" ] && [ "${L1_LANE}" != "${L2_CHAIN}" ]; then
    warn "L1 record carries a deployment for the sepolia-${L1_LANE:-?} pair (lane != ${L2_CHAIN}) — prepare a new run on a fresh fork before deploying this pair"
else
    ok "L1 record consistent with the sepolia-${L2_CHAIN} pair"
fi

echo "──────────────────────────────────────────────────────────────────────────"
if [ "${FAIL}" = "1" ]; then
    echo "✗ preflight FAILED — fix the ✗ items above before deploying."
    exit 1
fi
if [ "${WARN}" -gt 0 ]; then
    echo "✓ preflight passed with ${WARN} warning(s) — review the ⚠ items, then deploy."
else
    echo "✓ preflight clean — initial conditions suitable to start the deployment."
fi
