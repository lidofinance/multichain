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

[ -z "${HUB_MIGRATION_ONLY+x}" ] || { echo 'Obsolete HUB_MIGRATION_ONLY is forbidden' >&2; exit 1; }

# Canonical RPC endpoints — sourced from the environment only (forks tray app / .env), never a
# committed URL. Required; exported so child tools (state-mate, hardhat) inherit them.
#
# Hub (L1) chain selection — everything L1-specific derives from L1_CHAIN the way the L2 side
# derives from L2_CHAIN: the RPC env var NAME is RPC_<UPPERCASED SLUG> (forks-tray convention),
# the chain record is config/chains/<slug>.json. The default stays `sepolia` (scratch targets);
# workspace.py exports L1_CHAIN=ethereum for the mainnet migration target.
export L1_CHAIN="${L1_CHAIN:-sepolia}"
L1_RPC_VAR="RPC_$(printf '%s' "${L1_CHAIN}" | tr '[:lower:]' '[:upper:]')"
[ -n "${!L1_RPC_VAR:-}" ] || { echo "✗ ${L1_RPC_VAR} unset — export it via the forks tray app or .env"; exit 1; }
export "${L1_RPC_VAR}"
# Exported: the state-mate wiring resolves this env NAME for the l1 section's rpcUrl, and step 08
# and the forge scenarios read it, so they stay hub-agnostic.
export L1_RPC="${!L1_RPC_VAR}"
L1_CFG_CANON="config/chains/${L1_CHAIN}.json"
[ -f "${ROOT}/${L1_CFG_CANON}" ] || { echo "✗ unknown L1_CHAIN '${L1_CHAIN}' (no ${L1_CFG_CANON})"; exit 1; }
L1_CHAIN_ID="$(jq -r '.chain.chain_id' "${ROOT}/${L1_CFG_CANON}")"
# Operation of the selected target, exported by workspace.py from run.json: `scratch-deployment`
# (steps 01–03 create core, governance and the L2 token) or `in-place-upgrade` (the contracts
# exist; step 01m records them, step 06 upgrades them). Old runs without the field stay scratch.
export WSTETH_OPERATION="${WSTETH_OPERATION:-scratch-deployment}"

# Bootstrap output supplies addresses; the immutable target still owns the intended parameters.
migration_target_json() {
    if [ "${WSTETH_BOOTSTRAP:-}" = sepolia-migration ]; then
        [ -f "${ROOT}/state/migration-target.json" ] || { echo 'Run bootstrap-legacy first' >&2; return 1; }
        printf '%s\n' "${ROOT}/state/migration-target.json"
    else
        printf '%s\n' "${WSTETH_TARGET_DIR:?}/target.json"
    fi
}

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

# record_token <chain record>: the token the pool bridges. A token deployed by the component's
# 1_Deploy (scratch spokes: addresses.token stays address(0), token_deployment names it) is recorded
# under .deployed.token; an existing token (hub, in-place targets) is the addresses.token input.
record_token() {
    jq -r '.deployed.token // .addresses.token' "$1"
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
    # Fail loudly: a missing record would otherwise read as "spoke" and quietly configure the hub
    # timelock with the spoke selector config.
    [ -f "${cfg}" ] || { echo "✗ is_l1_chain: no ${cfg}"; exit 1; }
    # Assert the field too, not just the file: an absent .chain.pool_type (or a jq read of a record
    # mid-rewrite) yields "null", which a bare string compare reports as "spoke". Fail instead of
    # guessing.
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

# with_fork_account <rpc> <account> <command...>: impersonate only for this command.
# A subshell keeps cleanup traps local, including nested scopes for multi-sender forge scripts.
# Fresh Anvil nodes need this explicitly; no global auto-impersonation setting is required.
with_fork_account() (
    # Subshell variables survive EXIT even when Bash unwinds a failed function.
    _fork_scope_rpc="$1"; _fork_scope_account="$2"; shift 2
    is_anvil "${_fork_scope_rpc}" || { echo "✗ impersonation requires an Anvil fork" >&2; exit 1; }
    cast rpc anvil_impersonateAccount "${_fork_scope_account}" --rpc-url "${_fork_scope_rpc}" >/dev/null || exit $?
    trap '
        _fork_scope_status=$?
        trap - EXIT
        if ! cast rpc anvil_stopImpersonatingAccount "${_fork_scope_account}" --rpc-url "${_fork_scope_rpc}" >/dev/null; then
            echo "✗ could not stop impersonating ${_fork_scope_account}" >&2
            [ "${_fork_scope_status}" != 0 ] || _fork_scope_status=1
        fi
        exit "${_fork_scope_status}"
    ' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    "$@" || {
        _fork_scope_status=$?
        echo "✗ fork command failed for ${_fork_scope_account} (exit ${_fork_scope_status})" >&2
        exit "${_fork_scope_status}"
    }
)

# assert_chain_id <rpc> <expected> <label>: abort unless the fork reports <expected>.
assert_chain_id() {
    local cid; cid="$(cast chain-id --rpc-url "$1")"
    [ "${cid}" = "$2" ] || { echo "✗ chain id ${cid} != $2 ($3)"; exit 1; }
}

# Run an upstream deployment script against this run's chain records, exactly as the component
# documents it: from the component's own project root, with its release compiler profile
# (FOUNDRY_PROFILE=ccip-compile, so the deployed bytecode is CCIP's release build), its own
# default_config.json (or the explicit controlled-testnet override) and its own fs_permissions. Those permissions
# cover only contracts/lido-hvmv/config, so the run's records are copied into a staging directory
# there, named after the run, for the duration of the call and moved back afterwards: the record the
# script rewrites is this run's record, and nothing stays in the component tree. Only the
# broadcast receipts are redirected into the run (FOUNDRY_BROADCAST), where record-deployment.cjs
# reads the CREATE records from.
#
# The records come back however the call ends — script exit status, Ctrl-C, SIGTERM (EXIT/INT/TERM
# traps) — because 1_Deploy writes the record only after its broadcast, and a deployment the stage
# alone knows about must not be lost. A stage still present at the start of a call is therefore the
# trace of a call that died without unwinding (SIGKILL, power loss): it is reported, never deleted.
CCIP_RUN_STAGE_PARENT_REL="contracts/lido-hvmv/config/chains"
CCIP_RUN_STAGE_PREFIX=".wsteth-run."
# ccip_stage_unwind <stage>: move every record back into the run and remove the stage.
ccip_stage_unwind() {
    local f
    for f in "$1"/*.json; do
        [ -e "${f}" ] && cp "${f}" "${CFG_DIR}/"
    done
    rm -rf "$1"
}
run_ccip_script() {
    local name="$1" rpc="$2" target="$3"
    python3 "${ROOT}/script/ccip_build.py" verify || return $?
    local run_dir; run_dir="$(cd "${ROOT}/.active-run" && pwd -P)"
    python3 "${ROOT}/script/ccip_build.py" archive "${run_dir}/state/ccip-build" || return $?
    local parent="${CCIP_EVM}/${CCIP_RUN_STAGE_PARENT_REL}"
    local leftover
    for leftover in "${parent}/${CCIP_RUN_STAGE_PREFIX}"*; do
        [ -e "${leftover}" ] || continue
        echo "✗ ${leftover} is left from a call that did not finish; it may hold a record the run never received."
        echo "  Compare its records with ${CFG_DIR}, keep the newer deployment there, then remove the directory."
        return 1
    done
    local stage_rel="${CCIP_RUN_STAGE_PARENT_REL}/${CCIP_RUN_STAGE_PREFIX}$(basename "${run_dir}")"
    local stage="${CCIP_EVM}/${stage_rel}"
    mkdir -p "${stage}"
    # Every chain record of the run: 2_Configure resolves remote lanes by file name next to CHAIN_CONFIG.
    local f
    for f in "${CFG_DIR}"/*.json; do
        [ "$(basename "${f}")" = chain.schema.json ] && continue
        cp "${f}" "${stage}/"
    done
    trap "ccip_stage_unwind '${stage}'" EXIT
    trap "ccip_stage_unwind '${stage}'; trap - EXIT INT TERM; exit 130" INT TERM
    local profile_config=""
    if [ -n "${WSTETH_ACCESS_PROFILE:-}" ]; then
        mkdir -p "${stage}/profile"
        node "${ROOT}/script/testnet/prepare.cjs" ccip-config \
            "${CCIP_EVM}/contracts/lido-hvmv/config/default_config.json" "${stage}/profile/default_config.json"
        cp "${stage}/profile/default_config.json" "${run_dir}/state/ccip-default-config.json"
        profile_config="./${stage_rel}/profile/default_config.json"
    fi
    local rc=0
    ( cd "${CCIP_EVM}" &&
      if [ -n "${profile_config}" ]; then export DEFAULT_CONFIG="${profile_config}"; fi
      CHAIN_CONFIG="./${stage_rel}/${name}.json" \
      DEPLOYER_PRIVATE_KEY="${DEPLOYER_PRIVATE_KEY}" \
      FOUNDRY_PROFILE=ccip-compile FOUNDRY_BROADCAST="${run_dir}/broadcast/ccip" \
      forge script "contracts/lido-hvmv/script/deployment/${target}" \
        --rpc-url "${rpc}" --broadcast --skip "*.t.sol" -vv ) || rc=$?
    # Move the records back whether or not the script succeeded: a failed broadcast may already
    # have written partial outputs that --resume or the next run must see.
    ccip_stage_unwind "${stage}"
    trap - EXIT INT TERM
    return "${rc}"
}

# Owned scripts run in our project, with records and artifacts explicitly bound by the runner.
run_hub_script() {
    python3 "${ROOT}/script/hub_runner.py" "$1" "${L1_CHAIN}" "${L1_RPC}"
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

# timelock_propose_and_execute <rpc> <timelock> <proposer> <executor> <executor key> <name> <calls> <predecessor> <salt>
#   The life cycle of one proposal on a Chainlink RBACTimelock (or the LidoTimelock built on it) on an
#   anvil fork: scheduleBatch as the impersonated <proposer> with the timelock's minimum delay, the
#   delay waited by warping the fork clock, executeBatch through <executor> (the timelock's CallProxy,
#   which forwards anyone's call) signed by <executor key>. <calls> is the cast tuple array
#   "[(target,value,data),...]". Progress goes to stderr, a JSON record to stdout; any failed stage
#   exits. Fork-only: the caller has checked is_anvil.
timelock_propose_and_execute() {
    local rpc="$1" timelock="$2" proposer="$3" executor="$4" key="$5" name="$6" calls="$7" pred="$8" salt="$9"
    local sig='(address,uint256,bytes)[]' id sched executed delay sblk eblk
    delay="$(cast call "${timelock}" 'getMinDelay()(uint256)' --rpc-url "${rpc}" | awk '{print $1}')"
    id="$(cast call "${timelock}" "hashOperationBatch(${sig},bytes32,bytes32)(bytes32)" "${calls}" "${pred}" "${salt}" --rpc-url "${rpc}")"
    [ "$(cast call "${timelock}" 'isOperation(bytes32)(bool)' "${id}" --rpc-url "${rpc}")" = false ] \
        || { echo "✗ ${name}: operation ${id} already exists on the timelock ${timelock}" >&2; exit 1; }
    fund "${proposer}" "${rpc}"
    sched="$(with_fork_account "${rpc}" "${proposer}" cast send "${timelock}" "scheduleBatch(${sig},bytes32,bytes32,uint256)" "${calls}" "${pred}" "${salt}" "${delay}" \
        --from "${proposer}" --unlocked --gas-limit 2500000 --rpc-url "${rpc}" --json)"
    [ "$(jq -r '.status' <<<"${sched}")" = "0x1" ] \
        || { echo "✗ ${name}: scheduleBatch reverted (tx $(jq -r '.transactionHash' <<<"${sched}"))" >&2; exit 1; }
    sblk="$(jq -r '.blockNumber' <<<"${sched}")"
    [ "$(cast call "${timelock}" 'isOperationPending(bytes32)(bool)' "${id}" --rpc-url "${rpc}")" = true ] \
        || { echo "✗ ${name}: not pending after scheduleBatch" >&2; exit 1; }
    echo "  ${name}: scheduled ${id} (tx $(jq -r '.transactionHash' <<<"${sched}")), delay ${delay}s; warping the fork clock" >&2
    cast rpc evm_increaseTime "$((delay + 1))" --rpc-url "${rpc}" >/dev/null
    cast rpc evm_mine --rpc-url "${rpc}" >/dev/null
    [ "$(cast call "${timelock}" 'isOperationReady(bytes32)(bool)' "${id}" --rpc-url "${rpc}")" = true ] \
        || { echo "✗ ${name}: not ready after the delay" >&2; exit 1; }
    executed="$(cast send "${executor}" "$(cast calldata "executeBatch(${sig},bytes32,bytes32)" "${calls}" "${pred}" "${salt}")" \
        --private-key "${key}" --gas-limit 6000000 --rpc-url "${rpc}" --json)"
    eblk="$(jq -r '.blockNumber' <<<"${executed}")"
    [ "$(jq -r '.status' <<<"${executed}")" = "0x1" ] \
        || { echo "✗ ${name}: executeBatch reverted (tx $(jq -r '.transactionHash' <<<"${executed}"))" >&2; exit 1; }
    [ "$(cast call "${timelock}" 'isOperationDone(bytes32)(bool)' "${id}" --rpc-url "${rpc}")" = true ] \
        || { echo "✗ ${name}: not done after executeBatch" >&2; exit 1; }
    echo "  ${name}: executed through ${executor} (tx $(jq -r '.transactionHash' <<<"${executed}"))" >&2
    jq -n --arg name "${name}" --arg id "${id}" --arg pred "${pred}" --arg salt "${salt}" --argjson delay "${delay}" \
        --arg timelock "${timelock}" --arg proposer "${proposer}" --arg executor "${executor}" \
        --arg by "$(cast wallet address --private-key "${key}")" \
        --arg stx "$(jq -r '.transactionHash' <<<"${sched}")" --argjson sblk "$(cast to-dec "${sblk}")" \
        --arg etx "$(jq -r '.transactionHash' <<<"${executed}")" --argjson eblk "$(cast to-dec "${eblk}")" \
        '{name: $name, id: $id, timelock: $timelock, predecessor: $pred, salt: $salt, delay: $delay, proposer: $proposer,
          scheduledTx: $stx, scheduledAtBlock: $sblk, executor: $executor, executedBy: $by, executedTx: $etx, executedAtBlock: $eblk}'
}
