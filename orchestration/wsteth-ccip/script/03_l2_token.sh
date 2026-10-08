#!/usr/bin/env bash
# Step 03 — deploy L2 wstETH (ERC20BridgedPermit) behind an OZ 5.3.0 TransparentUpgradeableProxy on the L2 fork.
# The proxy constructor creates the ProxyAdmin and gives it to the OptimismBridgeExecutor (step 02).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
cd "${ROOT}"
. "${HERE}/_common.sh"
: "${DEPLOYER_PRIVATE_KEY:?set DEPLOYER_PRIVATE_KEY}"

# The locally maintained token authorizes mint/burn exclusively through revocable roles.
# Validate that property before deployment, independently of source provenance.
#
# Assert the COMPILED ABI rather than the source text. It is the property that actually matters and
# it is spelling-independent: an authority reintroduced as storage (`address public bridge;` set in
# an initializer) instead of as an immutable, or gated by a differently named modifier, still
# surfaces here as a bridge* selector — whereas a source grep only ever catches the one spelling it
# was written for. Same artifacts `forge script` is about to broadcast, so this costs one cached
# compile. The check remains valid as the local implementation evolves.
L2_TOKEN_BASE="${ROOT}/../../components/wsteth-token/contracts/token/ERC20Bridged.sol"
[ -f "${L2_TOKEN_BASE}" ] || {
    echo "✗ ${L2_TOKEN_BASE} missing — ../../components/wsteth-token sources are missing."
    echo "  Restore the locally maintained components/wsteth-token sources."
    exit 1
}
TOKEN_METHODS="$(FOUNDRY_PROFILE=token forge inspect \
    ../../components/wsteth-token/contracts/token/ERC20BridgedPermit.sol:ERC20BridgedPermit methods 2>/dev/null || true)"
[ -n "${TOKEN_METHODS}" ] || {
    echo "✗ could not compile ../../components/wsteth-token/contracts/token/ERC20BridgedPermit.sol under FOUNDRY_PROFILE=token."
    echo "  The deploy below needs the same build, so fix this first — usually a missing"
    echo "  'just init-thirdparty' (the token profile resolves OZ 5.0.2 / 5.3.0 from the public"
    echo "  components/openzeppelin-contracts-* submodules), or a local token source/build configuration error."
    exit 1
}
# Method rows are '| name(args) | selector |', so anchor on the name column.
if printf '%s\n' "${TOKEN_METHODS}" | grep -qiE '^\|[[:space:]]*bridge'; then
    echo "✗ the L2 token about to be deployed exposes a legacy bridge authority:"
    printf '%s\n' "${TOKEN_METHODS}" | grep -iE '^\|[[:space:]]*bridge' | sed 's/^/    /'
    echo "  The local token must authorize mint/burn exclusively through its roles."
    echo "  Correct components/wsteth-token before deploying."
    exit 1
fi

[ -f "${L2_STATE_FILE}" ] || { echo "✗ run step 02 first (${L2_STATE_FILE} missing)"; exit 1; }

assert_chain_id "${L2_RPC}" "${L2_CHAIN_ID}" "L2 ${L2_CHAIN}"
assert_l2_state_chain
fund "${DEPLOYER_ADDRESS}" "${L2_RPC}"

# assert_token_shape <proxy>: check that what actually landed on-chain is the token we intended.
# Same discipline as step 01's getCCIPAdmin check — verify a patch where it creates its effect,
# on-chain, rather than trusting that the working tree happened to be patched at compile time.
# Run on both paths (fresh deploy AND the idempotent skip), so a token left over from an unpatched
# build is caught on re-run instead of being waved through by the skip.
assert_token_shape() {
    local proxy="$1" bridge ver dar

    # 1) A legacy bridge principal is outside the token's role authorization model.
    if bridge="$(cast call "${proxy}" "bridge()(address)" --rpc-url "${L2_RPC}" 2>/dev/null)"; then
        echo "✗ L2 wstETH ${proxy} still exposes bridge() = ${bridge}"
        echo "  the deployed token does not match the maintained token design; it must not"
        echo "  expose a second mint/burn principal outside the role system."
        echo "  Fix the token sources, then prepare a new run and redeploy."
        exit 1
    fi

    # 2) The permit base is in, and initialize() went through _initialize_v2 rather than the base's
    #    bare 3-arg initializer — which would have left the token with no DEFAULT_ADMIN_ROLE holder.
    ver="$(cast call "${proxy}" "getContractVersion()(uint256)" --rpc-url "${L2_RPC}" 2>/dev/null || true)"
    ver="${ver%% *}"
    if [ "${ver}" != "2" ]; then
        echo "✗ L2 wstETH getContractVersion() = '${ver:-<absent>}', expected 2."
        echo "  Either the permit base is missing from this build, or initialize() did not run"
        echo "  through _initialize_v2."
        exit 1
    fi

    assert_eip712_domain "${proxy}"
    assert_proxy_admin "${proxy}"

    # 4) The registration principal step 07 B relies on (registerAccessControlDefaultAdmin).
    #    Skipped once part D has handed DEFAULT_ADMIN_ROLE to the OpExec — that is the end state,
    #    not a failure.
    dar="$(cast call "${proxy}" "DEFAULT_ADMIN_ROLE()(bytes32)" --rpc-url "${L2_RPC}")"
    if [ "$(cast call "${proxy}" "hasRole(bytes32,address)(bool)" "${dar}" "${DEPLOYER_ADDRESS}" --rpc-url "${L2_RPC}")" = "true" ]; then
        echo "✓ L2 wstETH: no bridge(), contract version 2, EIP-712 domain coherent, deployer holds DEFAULT_ADMIN_ROLE"
    else
        echo "✓ L2 wstETH: no bridge(), contract version 2, EIP-712 domain coherent"
        echo "  (deployer no longer holds DEFAULT_ADMIN_ROLE — step 07 D has already handed it over)"
    fi
}

# 5) The proxy admin (script/_proxy.sh verifies the record-selected kind and EIP-1967 admin slot):
#    - transparent: a fresh deploy. The OZ 5.3.0 TransparentUpgradeableProxy keeps a ProxyAdmin in the
#      slot, and that ProxyAdmin must be owned by the OptimismBridgeExecutor from the first block
#      (initialOwner in the proxy constructor), so no EOA ever holds the upgrade right.
#    - legacy: a token from a run before 2026-10-08 (OssifiableProxy, admin acts directly). Accepted on
#      the idempotent skip path with the admin at OpExec, or still at the deployer while step 07 D is
#      pending (it hands the admin over). Such a proxy cannot be upgraded onto this implementation.
assert_proxy_admin() {
    local proxy="$1" opexec pinned info
    opexec="$(jq -r '.opExec // empty' "${L2_STATE_FILE}")"
    pinned="$(jq -r '.wstETHProxyAdmin // empty' "${L2_STATE_FILE}")"
    info="$(proxy_admin_kind "${proxy}" "${L2_RPC}" "${pinned}")" || return 1
    if legacy_pending_handover "${info}" "${pinned}" "${DEPLOYER_ADDRESS}"; then
        echo "⚠ L2 wstETH: legacy OssifiableProxy still administered by deployer; step 07 D hands it to OpExec."
    else
        assert_proxy_admin_owner "${proxy}" "${L2_RPC}" "${opexec}" "L2 wstETH" "${pinned}" "${info}"
    fi
}

# 3) EIP-712 domain coherence — the one place this proxy and its implementation can silently
#    disagree. `PermitExtension` bakes the hashed name/version into the IMPLEMENTATION's immutables
#    from its CONSTRUCTOR arguments, and that is what `permit` validates against; `eip712Domain()`
#    reports what the INITIALIZER wrote into PROXY storage. Nothing in the code makes the two agree
#    — DeployL2Token.s.sol simply passes the same constants to both. If that ever drifts, wallets
#    sign the advertised domain, `permit` checks the baked one, and every signature is rejected with
#    no state anywhere to inspect. So recompute the separator from the ADVERTISED fields and require
#    it to equal the one the token actually uses.
assert_eip712_domain() {
    local proxy="$1" dom dname dver dcid dvc th exp got
    dom="$(cast call "${proxy}" 'eip712Domain()(bytes1,string,string,uint256,address,bytes32,uint256[])' \
        --rpc-url "${L2_RPC}")"
    dname="$(printf '%s\n' "${dom}" | sed -n '2p' | sed -e 's/^"//' -e 's/"$//')"
    dver="$(printf '%s\n' "${dom}" | sed -n '3p' | sed -e 's/^"//' -e 's/"$//')"
    dcid="$(printf '%s\n' "${dom}" | sed -n '4p' | awk '{print $1}')"
    dvc="$(printf '%s\n' "${dom}" | sed -n '5p' | awk '{print $1}')"

    if ! eq "${dvc}" "${proxy}"; then
        echo "✗ L2 wstETH eip712Domain().verifyingContract = ${dvc}, expected the proxy ${proxy}."
        echo "  Signatures would be bound to the wrong contract."
        exit 1
    fi
    th="$(cast keccak 'EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)')"
    exp="$(cast keccak "$(cast abi-encode 'f(bytes32,bytes32,bytes32,uint256,address)' \
        "${th}" "$(cast keccak "${dname}")" "$(cast keccak "${dver}")" "${dcid}" "${dvc}")")"
    got="$(cast call "${proxy}" 'DOMAIN_SEPARATOR()(bytes32)' --rpc-url "${L2_RPC}")"
    if ! eq "${exp}" "${got}"; then
        echo "✗ L2 wstETH EIP-712 domain mismatch:"
        echo "    DOMAIN_SEPARATOR()             = ${got}"
        echo "      (built from the implementation's constructor immutables — what permit checks)"
        echo "    recomputed from eip712Domain() = ${exp}"
        echo "      (name='${dname}' version='${dver}' chainId=${dcid} — what wallets are told to sign)"
        echo "  DeployL2Token.s.sol must pass the SAME name/version to the constructor and to initData."
        exit 1
    fi
}

# Idempotency: skip if token already deployed with code.
EXISTING="$(jq -r '.wstETH // empty' "${L2_STATE_FILE}")"
if [ -n "${EXISTING}" ] && has_code "${EXISTING}" "${L2_RPC}"; then
    echo "▸ L2 wstETH already at ${EXISTING}; skipping deploy."
    assert_token_shape "${EXISTING}"
    exit 0
fi

echo "▸ deploying L2 wstETH (ERC20BridgedPermit behind an OZ 5.3.0 TransparentUpgradeableProxy)"
TOKEN_OUT="${ROOT}/state/l2.token.addr"
L2_OPEXEC="$(jq -er '.opExec' "${L2_STATE_FILE}")"
FOUNDRY_PROFILE=token forge build ../../components/wsteth-token/contracts/token/ERC20BridgedPermit.sol
# The OZ 5.3.0 proxy + ProxyAdmin: compiled from the token project's root, whose lib/ holds the
# submodule, so the deployed metadata names `lib/openzeppelin-contracts-5.3.0/contracts/...` sources
# and not this checkout's path (see components/wsteth-token/foundry.toml).
forge build --root ../../components/wsteth-token \
    lib/openzeppelin-contracts-5.3.0/contracts/proxy/transparent/TransparentUpgradeableProxy.sol \
    lib/openzeppelin-contracts-5.3.0/contracts/proxy/transparent/ProxyAdmin.sol
TOKEN_OUT="${TOKEN_OUT}" L2_OPEXEC="${L2_OPEXEC}" \
    forge script script/DeployL2Token.s.sol:DeployL2Token \
    --rpc-url "${L2_RPC}" --broadcast -vvv

# vm.writeFile emits no trailing newline, so `read` would hit EOF and (under set -e) abort.
PROXY="$(awk '{print $1}' "${TOKEN_OUT}")"
IMPL="$(awk '{print $2}' "${TOKEN_OUT}")"
PROXY_ADMIN="$(awk '{print $3}' "${TOKEN_OUT}")"
rm -f "${TOKEN_OUT}"

# Record CREATE outputs before checking them against the chain, including the new admin pin.
jq_inplace "${L2_STATE_FILE}" --arg p "${PROXY}" --arg i "${IMPL}" --arg a "${PROXY_ADMIN}" '.wstETH = $p | .wstETHImpl = $i | .wstETHProxyAdmin = $a'

assert_token_shape "${PROXY}"

# Seed the CCIP L2 chain config token address (used by step 04's 1_Deploy).
jq_inplace "${L2_CFG_CANON}" --arg p "${PROXY}" '.addresses.token = $p'

echo "✓ step 03 done. L2 wstETH proxy = ${PROXY} (impl ${IMPL}, ProxyAdmin ${PROXY_ADMIN} owned by OpExec)"
jq '.' "${L2_STATE_FILE}"
