# The migration adapter supplies a mutable run workspace, separate from target intent.
python3 "${ROOT}/workspace.py" require-active >/dev/null || return 1

# Shared setup + helpers for the wstETH 2.0 deploy scripts.
# Source after setting ROOT, e.g.:
#   HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   ROOT="$(cd "${HERE}/.." && pwd)"
#   . "${HERE}/_common.sh"

# Load .env if present (RPC_* normally already exported by the forks tray app) WITHOUT overriding
# variables already in the environment — an explicit per-invocation override
# (e.g. `DEPLOYER_PRIVATE_KEY=… bash script/07_…`) must beat the .env value, matching just's
# non-overriding dotenv-load so the same command behaves identically via just and via bash.
if [ -f "${ROOT}/.env" ]; then
    _pre_env="$(export -p)"
    set -a; . "${ROOT}/.env"; set +a
    eval "${_pre_env}"
    unset _pre_env
fi

# Canonical RPC endpoints — sourced from the environment only (forks tray app / .env), never a
# committed URL. Required; exported so child tools (state-mate, hardhat) inherit them.
: "${RPC_SEPOLIA:?set RPC_SEPOLIA (exported by the forks tray app, or in .env)}"
export RPC_SEPOLIA
L1_RPC="${RPC_SEPOLIA}"

# L2 chain selection — everything L2-specific (RPC env var name, chain id, config path, archive
# dir) derives from L2_CHAIN. The RPC env var NAME
# is RPC_<UPPERCASED SLUG> (forks-tray convention), e.g. RPC_MANTLE_SEPOLIA.
export L2_CHAIN="${L2_CHAIN:-mantle_sepolia}"
export L2_STATE_FILE="${L2_STATE_FILE:-state/l2.json}"
L2_RPC_VAR="RPC_$(printf '%s' "${L2_CHAIN}" | tr '[:lower:]' '[:upper:]')"
[ -n "${!L2_RPC_VAR:-}" ] || { echo "✗ ${L2_RPC_VAR} unset — export it via the forks tray app or .env"; exit 1; }
export "${L2_RPC_VAR}"
# Exported: the state-mate wiring (config/state-mate/wsteth.yaml) resolves this env NAME for the
# l2 section's rpcUrl, so it stays chain-agnostic.
export L2_RPC="${!L2_RPC_VAR}"

# Canonical L2 deploy record + its chain id (the scripts' chain-id asserts read the record, not a
# literal, so a new L2 only needs a config/chains/<slug>.json).
L2_CFG_CANON="config/chains/${L2_CHAIN}.json"
[ -f "${ROOT}/${L2_CFG_CANON}" ] || { echo "✗ unknown L2_CHAIN '${L2_CHAIN}' (no ${L2_CFG_CANON})"; exit 1; }
L2_CHAIN_ID="$(jq -r '.chain.chain_id' "${ROOT}/${L2_CFG_CANON}")"

# DEPLOYER_ADDRESS is resolved further down, once lc/eq exist — it is DERIVED from the signing
# key rather than defaulted past it. See the block after eq().

# Deploy record location consumed by the TEST/VERIFY path — step 08 (bash) and the forge
# scenarios (which read $RECORD_DIR via vm.envOr). Default = the canonical record the deploy
# writes. Override RECORD_DIR to point state + integration testing at a DIFFERENT record — e.g. a
# live-network deployment kept in config/chains.live-mantle — so a live-fork run and a persistent-anvil
# run can coexist without clobbering. The deploy scripts (01–07) always write the canonical
# config/chains; alternate records are supplied out-of-band and selected here for testing only.
# Exported so child tools (state-mate, forge) and just recipes inherit it.
export RECORD_DIR="${RECORD_DIR:-config/chains}"

# Vendored core (step 01 hardhat scratch deploy, step 10 verify) + ccip (steps 04/05/07) paths.
CORE_DIR="${CORE_DIR:-${ROOT}/../../components/core}"
CCIP_EVM="${ROOT}/../../components/ccip/chains/evm"
CFG_DIR="$(cd "${ROOT}/config/chains" && pwd -P)"

# Address helpers (case-insensitive compare): lc lowercases, eq compares two addresses.
lc() { printf '%s' "$1" | tr 'A-F' 'a-f'; }
eq() { [ "$(lc "$1")" = "$(lc "$2")" ]; }

# DEPLOYER_ADDRESS: DERIVED from DEPLOYER_PRIVATE_KEY whenever a key is present, and cross-checked
# against any value already in the environment. Reason: a stale or missing DEPLOYER_ADDRESS beside
# a real key would let the pipeline ADDRESS one account while SIGNING as another — and `just all`
# does not run step 00, so preflight's key<->address guard is not on the deploy path. The literal
# below is only reached when neither a key nor an address is set (read-only/inspection use).
if [ -n "${DEPLOYER_PRIVATE_KEY:-}" ]; then
    _dep_derived="$(cast wallet address --private-key "${DEPLOYER_PRIVATE_KEY}" 2>/dev/null || true)"
    if [ -n "${_dep_derived}" ]; then
        if [ -n "${DEPLOYER_ADDRESS:-}" ] && ! eq "${DEPLOYER_ADDRESS}" "${_dep_derived}"; then
            echo "✗ DEPLOYER_ADDRESS=${DEPLOYER_ADDRESS} but DEPLOYER_PRIVATE_KEY derives ${_dep_derived}"
            echo "  fix .env — the pipeline would address one account and sign as another"
            exit 1
        fi
        DEPLOYER_ADDRESS="${_dep_derived}"
    fi
    unset _dep_derived
fi
# Fallback only when there is no key at all: anvil dev account 0.
: "${DEPLOYER_ADDRESS:=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266}"

# has_code <addr> <rpc>: succeed iff <addr> has bytecode on <rpc> (RPC failure counts as no code).
has_code() {
    local code; code="$(cast code "$1" --rpc-url "$2" 2>/dev/null || echo 0x)"
    [ -n "${code}" ] && [ "${code}" != "0x" ]
}

# assert_code <addr> <rpc> <label>: fail clearly if <addr> has no bytecode on <rpc>. Makes a
# "test/verify run before deploy" or an RPC↔record mismatch (easy when switching live↔anvil)
# obvious instead of surfacing as a deep low-level revert. Substrate-agnostic (live fork or anvil).
assert_code() {
    has_code "$1" "$2" || {
        echo "✗ no contract at $1 on $2 ($3) — run the deploy first, or RPC/record ($RECORD_DIR) mismatch"; exit 1; }
}

# jq_inplace <file> <jq args...>: rewrite <file> through jq atomically (no truncation on jq failure).
jq_inplace() {
    local f="$1"; shift
    local tmp; tmp="$(mktemp)"
    jq "$@" "${f}" > "${tmp}" && mv "${tmp}" "${f}"
}

# fund <addr> <rpc>: top a fork account up to ~10000 ETH (best-effort; anvil usually pre-funds).
fund() {
    cast rpc anvil_setBalance "$1" 0x21e19e0c9bab2400000 --rpc-url "$2" >/dev/null 2>&1 || true
}

# is_l1_chain <chain_name>: succeed iff <chain_name> is the L1 HUB rather than a spoke.
# Discriminated by pool type, not by slug: the hub is the SiloedLockRelease chain (Ethereum, or
# sepolia standing in for it) and every spoke is BurnMint — chain.schema.json admits only those
# two. Name-based would silently mis-classify `ethereum`, `holesky` or any new hub slug.
is_l1_chain() {
    local cfg="${ROOT}/config/chains/$1.json"
    # Fail loudly: a missing record would otherwise read as "spoke" and quietly hand the L1 POM
    # the spoke selector config (unpauseCrossChainTransfers() left unblocked on the hub).
    [ -f "${cfg}" ] || { echo "✗ is_l1_chain: no ${cfg}"; exit 1; }
    # Assert the field too, not just the file: an absent .chain.pool_type (or a jq read of a record
    # mid-rewrite) yields "null", which a bare string compare reports as "spoke" — silently
    # deploying the HUB POM with unpauseCrossChainTransfers() (0xa6cc6ef9) left unblocked. Fail instead of guessing.
    local pt; pt="$(jq -r '.chain.pool_type // "null"' "${cfg}")"
    case "${pt}" in
        SiloedLockRelease|BurnMint) ;;
        *) echo "✗ is_l1_chain: ${cfg} has .chain.pool_type='${pt}' (expected SiloedLockRelease or BurnMint)"; exit 1 ;;
    esac
    [ "${pt}" = "SiloedLockRelease" ]
}

# Proxy-admin classification and assertion (transparent vs legacy OssifiableProxy): script/_proxy.sh.
. "$(dirname "${BASH_SOURCE[0]}")/_proxy.sh"

# is_anvil <rpc>: succeed iff the endpoint is an anvil node (responds to an anvil_* cheat method).
# Used to gate fork-only operations (account impersonation, setBalance) so they fail loudly against
# a live RPC instead of silently no-op'ing and leaving the deploy in a half-configured state.
is_anvil() { cast rpc anvil_nodeInfo --rpc-url "$1" >/dev/null 2>&1; }

# assert_chain_id <rpc> <expected> <label>: abort unless the fork reports <expected>.
assert_chain_id() {
    local cid; cid="$(cast chain-id --rpc-url "$1")"
    [ "${cid}" = "$2" ] || { echo "✗ chain id ${cid} != $2 ($3)"; exit 1; }
}

# Run upstream code against this run's records. A generated Foundry profile grants
# access only to the selected run's config, and keeps broadcasts/cache in that run.
run_ccip_script() {
    local name="$1" rpc="$2" target="$3"
    local default_cfg_src="${ROOT}/config/default_config.non_l1.json"
    if is_l1_chain "${name}"; then default_cfg_src="${ROOT}/config/default_config.json"; fi
    local run_dir; run_dir="$(cd "${ROOT}/.active-run" && pwd -P)"
    local forge_config
    forge_config="$(python3 "${ROOT}/script/ccip-run-config.py" "${CCIP_EVM}" "${run_dir}")"
    echo "  · DEFAULT_CONFIG = $(basename "${default_cfg_src}") for ${name}"
    ( cd "${CCIP_EVM}" && \
      CHAIN_CONFIG="${CFG_DIR}/${name}.json" \
      DEFAULT_CONFIG="${run_dir}/config/$(basename "${default_cfg_src}")" \
      DEPLOYER_PRIVATE_KEY="${DEPLOYER_PRIVATE_KEY}" FOUNDRY_PROFILE=wsteth_run \
      forge script "contracts/lido-hvmv/script/deployment/${target}" \
        --root "${CCIP_EVM}" --config-path "${forge_config}" \
        --rpc-url "${rpc}" --broadcast --skip "*.t.sol" -vv )
}

# assert_l2_state_chain: ${L2_STATE_FILE} (written by step 02) must belong to the active L2_CHAIN —
# catches switching L2_CHAIN over leftover state from another pair (files predating the .l2Chain
# field are assumed to belong to the default pair).
assert_l2_state_chain() {
    [ -f "${L2_STATE_FILE}" ] || return 0
    local rec; rec="$(jq -r '.l2Chain // "mantle_sepolia"' "${L2_STATE_FILE}")"
    [ "${rec}" = "${L2_CHAIN}" ] || {
        echo "✗ ${L2_STATE_FILE} belongs to '${rec}' but L2_CHAIN=${L2_CHAIN} — prepare a new run first"; exit 1; }
}
