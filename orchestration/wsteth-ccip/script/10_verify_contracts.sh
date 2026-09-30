#!/usr/bin/env bash
# Step 10 — source-verify the deployed contracts on the chains' explorers (L1 Sepolia via
# Etherscan; the L2 selected by L2_CHAIN via Etherscan, or a chain-specific Blockscout for any L2
# Etherscan v2 does not cover).
# Post-hoc and idempotent: reads the deploy record (config/chains + state/*.json), skips
# addresses Etherscan already shows as verified, and submits the rest with
# `forge verify-contract --guess-constructor-args` FROM THE PROJECT THAT DEPLOYED them (so
# compiler settings match the deploy artifacts):
#   • root project          — OpExec, L2 wstETH impl + OssifiableProxy
#                             ([profile.token]: OZ 4.x / solc 0.8.10)
#   • ../../components/ccip/chains/evm   — pools, hooks, lockboxes, POM (ERC1967Proxy + impl), CCV contracts
#   • ../../components/core (hardhat)    — Lido core via its own `verify:deployed` task (deployed-local.json);
#                             entries without a `contract` field (the dg:* ones) are skipped by it
#   • dual-governance       — via ITS OWN DeployConfigurable script in --resume --verify mode
#                             (replays the broadcast log; covers the whole DG family incl. the
#                             contract-created Escrow master copy)
# Live-only: chains whose RPC is an anvil fork are skipped (no explorer for a fork).
# On live chains, RPC_SEPOLIA_REMOTE / RPC_<L2 SLUG>_REMOTE (keyed/paid endpoints) are
# preferred over the pipeline RPCs for this step's on-chain reads when set.
# Requires ETHERSCAN_API_KEY when a live chain verifies via Etherscan (Blockscout needs no key).
# Best-effort: individual failures are reported and counted, not fatal mid-run.
# Ends with a POST-CHECK that asserts EVERY contract the pipeline deployed (full core family,
# DG family incl. the Escrow master copy, OpExec, L2 token, CCIP stacks) shows verified source
# on Etherscan — the step fails if any is missing, even if all submissions "succeeded".
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
cd "${ROOT}"
. "${HERE}/_common.sh"

# Self-gating so `just all` can include this step on a fork run without failing. Gate on the
# PIPELINE RPCs (they encode the deploy substrate), not the remote endpoints below.
L1_ANVIL=0; is_anvil "${L1_RPC}" && L1_ANVIL=1
L2_ANVIL=0; is_anvil "${L2_RPC}" && L2_ANVIL=1
if [ "${L1_ANVIL}" = "1" ] && [ "${L2_ANVIL}" = "1" ]; then
    echo "▸ both RPCs are anvil forks — nothing to verify on an explorer; skipping."
    exit 0
fi

# Per-chain verifier backend: L1 Sepolia is always Etherscan; so is mantle_sepolia (Etherscan v2
# multichain covers it). An L2 v2 does not cover would add a blockscout branch here.
case "${L2_CHAIN}" in
    *) L2_VERIFIER="etherscan"; L2_VERIFIER_URL="" ;;
esac
# backend_for <chainid>: which verifier serves this chain id.
backend_for() { [ "$1" = "11155111" ] && echo etherscan || echo "${L2_VERIFIER}"; }

# The Etherscan key is needed only when a live chain actually verifies via Etherscan.
if [ "${L1_ANVIL}" = "0" ] || { [ "${L2_ANVIL}" = "0" ] && [ "${L2_VERIFIER}" = "etherscan" ]; }; then
    : "${ETHERSCAN_API_KEY:?set ETHERSCAN_API_KEY (one Etherscan v2 key serves all Etherscan chains)}"
fi

# Live chain → prefer the keyed (paid, higher-quality) remote endpoints for this step's
# on-chain reads (impl slots, constructor-arg guessing from creation txs) when available.
_l2_remote_var="${L2_RPC_VAR}_REMOTE"
[ "${L1_ANVIL}" = "0" ] && L1_RPC="${RPC_SEPOLIA_REMOTE:-${L1_RPC}}"
[ "${L2_ANVIL}" = "0" ] && L2_RPC="${!_l2_remote_var:-${L2_RPC}}"

FAILED=0
SUBMITTED=0
SKIPPED=0

# is_verified <chainid> <addr>: succeed iff the chain's explorer already has source for <addr>.
# Blockscout's API is Etherscan-shape-compatible (getabi: .status == "1" when verified, no key).
# A throttled response ("rate limit") is NOT an "unverified" answer — retry it, so a transient
# 429 can't trigger a pointless resubmission (or a false post-check failure).
is_verified() {
    local res attempt url
    if [ "$(backend_for "$1")" = "blockscout" ]; then
        url="${L2_VERIFIER_URL}?module=contract&action=getabi&address=$2"
    else
        url="https://api.etherscan.io/v2/api?chainid=$1&module=contract&action=getabi&address=$2&apikey=${ETHERSCAN_API_KEY:-}"
    fi
    for attempt in 1 2 3; do
        res="$(curl -s "${url}")"
        sleep 0.25 # free-tier rate limit headroom
        [ "$(printf '%s' "${res}" | jq -r '.status')" = "1" ] && return 0
        printf '%s' "${res}" | grep -qi 'rate limit' || return 1
        sleep 1
    done
    return 1
}

# vc <chainid> <rpc> <project_dir> <profile|-> <addr> <path:Contract> <label> [ctor_args_hex]
# Constructor args are guessed from the creation tx by default; pass them explicitly (8th arg)
# for contracts CREATED BY CONTRACTS (e.g. Escrow via DualGovernance's constructor), where
# Etherscan exposes no creation tx for forge to guess from.
vc() {
    local cid="$1" rpc="$2" dir="$3" profile="$4" addr="$5" fqn="$6" label="$7" ctor="${8:-}"
    [ -n "${addr}" ] && [ "${addr}" != "null" ] || { echo "  – ${label}: no address in record; skipping"; return 0; }
    if is_verified "${cid}" "${addr}"; then
        echo "  ✔ ${label}: ${addr} already verified"; SKIPPED=$((SKIPPED + 1)); return 0
    fi
    echo "  ▸ ${label}: verifying ${addr} (${fqn##*:})"
    # macOS bash 3.2: expanding an empty array trips `set -u`, so pass a concrete profile always.
    local prof="default"
    [ "${profile}" != "-" ] && prof="${profile}"
    local argmode="--guess-constructor-args"
    [ -n "${ctor}" ] && argmode="--constructor-args=${ctor}"
    # Verifier backend flags per chain (arrays are non-empty in both branches; bash 3.2 + set -u).
    local backend_args
    if [ "$(backend_for "${cid}")" = "blockscout" ]; then
        backend_args=(--verifier blockscout --verifier-url "${L2_VERIFIER_URL}")
    else
        backend_args=(--etherscan-api-key "${ETHERSCAN_API_KEY:-}")
    fi
    if ( cd "${dir}" && FOUNDRY_PROFILE="${prof}" forge verify-contract "${addr}" "${fqn}" \
            --chain "${cid}" --rpc-url "${rpc}" "${argmode}" \
            "${backend_args[@]}" --watch ); then
        SUBMITTED=$((SUBMITTED + 1))
    else
        echo "  ✗ ${label}: verification failed (continuing)"; FAILED=$((FAILED + 1))
    fi
}

# impl_of <proxy> <rpc>: read the EIP-1967 implementation slot.
impl_of() {
    cast storage "$1" 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc --rpc-url "$2" \
        | sed 's/^0x000000000000000000000000/0x/'
}

CCIP_PROJ="${CCIP_EVM}"
# Real source paths inside the ccip project (per its remappings.txt; pnpm layout).
CL="node_modules/@chainlink/contracts-ccip/chains/evm/contracts"
OZ53="node_modules/@openzeppelin/contracts-5.3.0"

# verify_ccip_stack <chainid> <rpc> <cfg> <pool_fqn>
verify_ccip_stack() {
    local cid="$1" rpc="$2" cfg="$3" pool_fqn="$4"
    local pool hooks pom resolver verifier
    pool="$(jq -r '.deployed.token_pool // empty' "${cfg}")"
    hooks="$(jq -r '.deployed.advanced_pool_hooks // empty' "${cfg}")"
    pom="$(jq -r '.deployed.pool_operation_manager // empty' "${cfg}")"
    resolver="$(jq -r '.ccv.verifier_resolver // empty' "${cfg}")"
    verifier="$(jq -r '.ccv.message_id_verifier // empty' "${cfg}")"

    vc "${cid}" "${rpc}" "${CCIP_PROJ}" - "${pool}"  "${pool_fqn}" "token pool"
    vc "${cid}" "${rpc}" "${CCIP_PROJ}" - "${hooks}" "contracts/lido-hvmv/PausableAdvancedPoolHooks.sol:PausableAdvancedPoolHooks" "pool hooks"
    if [ -n "${pom}" ] && [ "${pom}" != "null" ]; then
        local pom_impl; pom_impl="$(impl_of "${pom}" "${rpc}")"
        vc "${cid}" "${rpc}" "${CCIP_PROJ}" - "${pom_impl}" "contracts/lido-hvmv/PoolOperationManager.sol:PoolOperationManager" "POM impl"
        vc "${cid}" "${rpc}" "${CCIP_PROJ}" - "${pom}" "${OZ53}/proxy/ERC1967/ERC1967Proxy.sol:ERC1967Proxy" "POM proxy"
    fi
    vc "${cid}" "${rpc}" "${CCIP_PROJ}" - "${resolver}" "${CL}/ccvs/VersionedVerifierResolver.sol:VersionedVerifierResolver" "CCV resolver"
    vc "${cid}" "${rpc}" "${CCIP_PROJ}" - "${verifier}" "contracts/lido-hvmv/ccvs/DummyMessageIdVerifier.sol:DummyMessageIdVerifier" "CCV msg-id verifier"
    # Lockboxes (L1 siloed hub only; empty array on L2).
    local lb
    for lb in $(jq -r '.deployed.lock_boxes[]?.lock_box' "${cfg}"); do
        vc "${cid}" "${rpc}" "${CCIP_PROJ}" - "${lb}" "${CL}/pools/ERC20LockBox.sol:ERC20LockBox" "lockbox"
    done
}

# ── L1 (Sepolia) ───────────────────────────────────────────────────────────
if [ "${L1_ANVIL}" = "1" ]; then
    echo "▸ L1 RPC is an anvil fork — skipping L1 verification."
else
    echo "── L1 Sepolia ────────────────────────────────────────────────────────"
    # Lido core (incl. wstETH) — core's own hardhat verify task, driven by deployed-local.json.
    # Entries without a `contract` field (dg:*) are skipped by the task; DG is handled below.
    if [ -f "${CORE_DIR}/deployed-local.json" ]; then
        echo "  ▸ Lido core: hardhat verify:deployed (../../components/core, deployed-local.json)"
        ( cd "${CORE_DIR}" && RPC_URL="${L1_RPC}" SEPOLIA_RPC_URL="${L1_RPC}" \
            ETHERSCAN_API_KEY="${ETHERSCAN_API_KEY}" \
            yarn hardhat verify:deployed --network sepolia --file deployed-local.json ) \
            || { echo "  ✗ core verify:deployed reported errors (continuing)"; FAILED=$((FAILED + 1)); }
    else
        echo "  – Lido core: ${CORE_DIR}/deployed-local.json missing; skipping core verification"
    fi

    # Dual Governance — deployed by the dual-governance submodule inside step 01. Use ITS OWN
    # deploy script in --resume mode: forge replays the broadcast log (no transactions are sent)
    # and --verify submits every contract recorded there — the full family (DualGovernance,
    # Timelock, Executor, ResealManager, ConfigProvider, TimelockedGovernance, tiebreaker
    # committees) INCLUDING the Escrow master copy, which is created by DualGovernance's
    # constructor (an additionalContracts entry) and therefore can't be arg-guessed per-address.
    # Manual fallback for Escrow alone: the DG repo's scripts/deploy/Readme.md documents the
    # forge verify-contract + cast abi-encode incantation.
    DG_PROJ="${CORE_DIR}/foundry/lib/dual-governance"
    DG_ADDR="$(jq -r '.dg.dualGovernance // empty' state/l1.json 2>/dev/null || true)"
    if [ -n "${DG_ADDR}" ] && is_verified 11155111 "${DG_ADDR}"; then
        echo "  ✔ Dual Governance: ${DG_ADDR} already verified; skipping the DG family pass"
        SKIPPED=$((SKIPPED + 1))
    elif [ -d "${DG_PROJ}/broadcast/DeployConfigurable.s.sol/11155111" ]; then
        # Current Forge requires --broadcast with --resume even for verification. Admit
        # that mode only when this deployment's entire broadcast is already confirmed.
        DG_BROADCAST="${DG_PROJ}/broadcast/DeployConfigurable.s.sol/11155111/run-latest.json"
        jq -e --arg dg "${DG_ADDR}" '
          (.transactions | length) > 0 and
          (.transactions | length) == (.receipts | length) and
          ((.pending // []) | length) == 0 and
          all(.receipts[]; .status == "0x1") and
          any(.transactions[]; ((.contractAddress // "") | ascii_downcase) == ($dg | ascii_downcase)) and
          ([.transactions[].hash] | sort) == ([.receipts[].transactionHash] | sort)
        ' "${DG_BROADCAST}" >/dev/null || {
            echo "✗ DG verification requires a complete successful broadcast matching this deployment; refusing resume"
            exit 1
        }
        echo "  ▸ Dual Governance: verify its fully confirmed broadcast (no pending transactions)"
        ( cd "${DG_PROJ}" && DEPLOY_CONFIG_FILE_NAME=deploy-config-scratch.toml \
            forge script scripts/deploy/DeployConfigurable.s.sol:DeployConfigurable \
            --rpc-url "${L1_RPC}" --resume --broadcast --verify \
            --etherscan-api-key "${ETHERSCAN_API_KEY}" --skip test ) \
            && SUBMITTED=$((SUBMITTED + 1)) \
            || { echo "  ✗ DG --resume --verify failed (continuing)"; FAILED=$((FAILED + 1)); }
    else
        echo "  – Dual Governance: no broadcast log in ${DG_PROJ}; skipping"
    fi

    # CCIP stack (siloed hub).
    verify_ccip_stack 11155111 "${L1_RPC}" "${RECORD_DIR}/sepolia.json" \
        "${CL}/pools/SiloedLockReleaseTokenPool.sol:SiloedLockReleaseTokenPool"
fi

# ── L2 (${L2_CHAIN}) ───────────────────────────────────────────────────────
if [ "${L2_ANVIL}" = "1" ]; then
    echo "▸ L2 RPC is an anvil fork — skipping L2 verification."
else
    echo "── L2 ${L2_CHAIN} ────────────────────────────────────────────────────"
    if [ -f state/l2.json ]; then
        vc "${L2_CHAIN_ID}" "${L2_RPC}" "${ROOT}" token "$(jq -r '.opExec // empty' state/l2.json)" \
            "../../components/governance-crosschain-bridges/contracts/bridges/OptimismBridgeExecutor.sol:OptimismBridgeExecutor" "OpExec"
        vc "${L2_CHAIN_ID}" "${L2_RPC}" "${ROOT}" token "$(jq -r '.wstETHImpl // empty' state/l2.json)" \
            "../../components/wsteth-token/contracts/token/ERC20BridgedPermit.sol:ERC20BridgedPermit" "wstETH impl"
        vc "${L2_CHAIN_ID}" "${L2_RPC}" "${ROOT}" token "$(jq -r '.wstETH // empty' state/l2.json)" \
            "../../components/wsteth-token/contracts/proxy/OssifiableProxy.sol:OssifiableProxy" "wstETH proxy"
    fi

    # CCIP stack (burn/mint spoke).
    verify_ccip_stack "${L2_CHAIN_ID}" "${L2_RPC}" "${RECORD_DIR}/${L2_CHAIN}.json" \
        "${CL}/pools/BurnMintTokenPool.sol:BurnMintTokenPool"
fi

# ── Post-check: assert EVERY deployed contract shows verified source on Etherscan ──
# Independent of the submission flow above (which is per-project and best-effort): enumerate
# everything the pipeline deployed and ask Etherscan directly, so a contract silently missed by
# a sub-verifier (e.g. core's verify:deployed) can't pass the step unverified.
CHECKED=0
NOT_VERIFIED=0

# audit <chainid> <addr> <label>
audit() {
    [ -n "$2" ] && [ "$2" != "null" ] || return 0
    CHECKED=$((CHECKED + 1))
    if is_verified "$1" "$2"; then
        echo "  ✔ $3: $2"
    else
        echo "  ✗ $3: $2 NOT verified"; NOT_VERIFIED=$((NOT_VERIFIED + 1))
    fi
}

# audit_ccip_stack <chainid> <rpc> <cfg>
audit_ccip_stack() {
    local cid="$1" rpc="$2" cfg="$3"
    audit "${cid}" "$(jq -r '.deployed.token_pool // empty' "${cfg}")" "token pool"
    audit "${cid}" "$(jq -r '.deployed.advanced_pool_hooks // empty' "${cfg}")" "pool hooks"
    local pom; pom="$(jq -r '.deployed.pool_operation_manager // empty' "${cfg}")"
    if [ -n "${pom}" ]; then
        audit "${cid}" "${pom}" "POM proxy"
        audit "${cid}" "$(impl_of "${pom}" "${rpc}")" "POM impl"
    fi
    audit "${cid}" "$(jq -r '.ccv.verifier_resolver // empty' "${cfg}")" "CCV resolver"
    audit "${cid}" "$(jq -r '.ccv.message_id_verifier // empty' "${cfg}")" "CCV msg-id verifier"
    local lb
    for lb in $(jq -r '.deployed.lock_boxes[]?.lock_box' "${cfg}"); do
        audit "${cid}" "${lb}" "lockbox"
    done
}

if [ "${L1_ANVIL}" = "0" ]; then
    echo "── post-check L1 Sepolia: every deployed contract verified? ──────────"
    # Full Lido core family: every record entry carrying a contract+address pair (the set
    # core's verify:deployed covers — proxies and implementations alike).
    if [ -f "${CORE_DIR}/deployed-local.json" ]; then
        while read -r addr name; do
            audit 11155111 "${addr}" "core ${name##*/}"
        done < <(jq -r '.. | objects | select(has("contract") and has("address")) | "\(.address) \(.contract)"' \
                 "${CORE_DIR}/deployed-local.json")
    fi
    # DG family from the deploy record.
    for key in dualGovernance adminExecutor timelock resealManager; do
        audit 11155111 "$(jq -r ".dg.${key} // empty" state/l1.json 2>/dev/null || true)" "DG ${key}"
    done
    # Escrow master copy is CREATED BY DualGovernance's constructor (no record entry); resolve it
    # on-chain via the signalling-escrow proxy. Best-effort: skipped if the calls don't resolve.
    DG_ADDR="$(jq -r '.dg.dualGovernance // empty' state/l1.json 2>/dev/null || true)"
    if [ -n "${DG_ADDR}" ]; then
        ESCROW="$(cast call "${DG_ADDR}" 'getVetoSignallingEscrow()(address)' --rpc-url "${L1_RPC}" 2>/dev/null || true)"
        MASTER="$([ -n "${ESCROW}" ] && cast call "${ESCROW}" 'ESCROW_MASTER_COPY()(address)' --rpc-url "${L1_RPC}" 2>/dev/null || true)"
        audit 11155111 "${MASTER}" "DG Escrow master copy"
    fi
    audit_ccip_stack 11155111 "${L1_RPC}" "${RECORD_DIR}/sepolia.json"
fi

if [ "${L2_ANVIL}" = "0" ]; then
    echo "── post-check L2 ${L2_CHAIN}: every deployed contract verified? ──────"
    if [ -f state/l2.json ]; then
        audit "${L2_CHAIN_ID}" "$(jq -r '.opExec // empty' state/l2.json)" "OpExec"
        audit "${L2_CHAIN_ID}" "$(jq -r '.wstETH // empty' state/l2.json)" "wstETH proxy"
        audit "${L2_CHAIN_ID}" "$(jq -r '.wstETHImpl // empty' state/l2.json)" "wstETH impl"
    fi
    audit_ccip_stack "${L2_CHAIN_ID}" "${L2_RPC}" "${RECORD_DIR}/${L2_CHAIN}.json"
fi

echo "──────────────────────────────────────────────────────────────────────────"
echo "verification: ${SUBMITTED} submitted, ${SKIPPED} already verified, ${FAILED} failed"
echo "post-check:   ${CHECKED} contracts checked, ${NOT_VERIFIED} NOT verified"
[ "${FAILED}" = "0" ] || { echo "✗ step 10 finished with submission failures — re-run after fixing (idempotent)."; exit 1; }
[ "${NOT_VERIFIED}" = "0" ] || { echo "✗ step 10: ${NOT_VERIFIED} contract(s) lack verified source on their explorer (see ✗ above)."; exit 1; }
echo "✓ step 10 done — every deployed contract has verified source on its explorer."
