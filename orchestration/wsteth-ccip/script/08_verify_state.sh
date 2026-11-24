#!/usr/bin/env bash
# Step 08 — Claim A (E-STATE-01): diff the post-deploy on-chain state against the expected
# ownership/role matrix (PLAN §4) using state-mate (lidofinance tool, vendored at ../../libs/state-mate,
# branch feat/separate-deployed). Verifies pool/hook/lockbox ownership = LidoTimelock, timelock
# roles (ADMIN = Agent/OpExec with the deployer gone, PROPOSER = MCMS, EXECUTOR = CallProxy,
# CANCELLER/HALT = Emergency Brakes), TAR administrator = timelock + pool binding, lane support,
# L2 token minter/burner + proxy/admin/implementation handover, OpExec pinned to the L1 Agent, and
# on in-place targets the upgraded legacy bridges (implementation, admin, mode, flags, wiring).
#
# Substrate-agnostic & record-sourced. state-mate's `--deployed` feature splits the config in two:
#   • config/state-mate/wsteth.yaml          — committed WIRING (relationships), no addresses
#   • config/state-mate/wsteth.deployed.yaml — the ADDRESS BOOK, GENERATED here from the deploy
#                                              record ($RECORD_DIR, default config/chains/*.json)
# so the just-deployed addresses are swapped in per run, on whichever network the L1 RPC
# (RPC_<L1_CHAIN>, exported as L1_RPC) / the L2 RPC (RPC_<L2_CHAIN>, exported as L2_RPC) point at (a live-testnet fork OR the
# persistent anvil fork). ABIs are
# hand-provided, name-keyed (address-independent) in config/state-mate/abis.json.
#
# On success, the verified artifacts are archived to deployments/<live|forks>/<pair>/<date-time>/
# (state-mate trio + deploy records + state/ files + non-secret parameters) for later review.
#
# The RUN OUTPUT is archived too, as run/state-mate.log. That file — not a check count quoted in
# prose — is Claim A's A.10 evidence carrier: dated, bound to a commit via parameters.env, and
# recoverable. README.md §3 cites the path; nothing should hard-code the number.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
. "${HERE}/_common.sh"

SM_DIR="${STATE_MATE_DIR:-${ROOT}/../../libs/state-mate}"
# The policy the component deploys with (its scripts default DEFAULT_CONFIG to this file).
CCIP_DEFAULT_CONFIG="${CCIP_EVM}/contracts/lido-hvmv/config/default_config.json"
if [ -n "${WSTETH_ACCESS_PROFILE:-}" ]; then
    CCIP_DEFAULT_CONFIG="${ROOT}/state/ccip-default-config.json"
    [ -f "${CCIP_DEFAULT_CONFIG}" ] || { echo 'Missing recorded testnet CCIP configuration'; exit 1; }
fi
CONFIG="${ROOT}/config/state-mate/wsteth.yaml"           # committed wiring (no addresses)
DEPLOYED="${ROOT}/config/state-mate/wsteth.deployed.yaml" # generated address book (this file)
# Committed inputs (config:/externals:) — per-pair: the L2 externals (chain selector, Chainlink
# router + TAR) are authored check-side constants that differ per L2, so each L2 carries its own
# inputs file (the default chain keeps the original name).
if [ "${L2_CHAIN}" = "mantle_sepolia" ]; then
    INPUTS="${ROOT}/config/state-mate/wsteth.inputs.yaml"
else
    INPUTS="${ROOT}/config/state-mate/wsteth.inputs.${L2_CHAIN}.yaml"
fi
case "${RECORD_DIR}" in
    /*) RECORD_PATH="${RECORD_DIR}" ;;
    *) RECORD_PATH="${ROOT}/${RECORD_DIR}" ;;
esac
L1_CFG="${RECORD_PATH}/${L1_CHAIN}.json"
L2_CFG="${RECORD_PATH}/${L2_CHAIN}.json"

[ -d "${SM_DIR}/node_modules" ] || { echo "✗ state-mate deps not installed at ${SM_DIR} (run: just init-thirdparty)"; exit 1; }
[ -f "${CONFIG}" ] || { echo "✗ missing wiring config ${CONFIG}"; exit 1; }
[ -f "${INPUTS}" ] || { echo "✗ missing inputs config ${INPUTS}"; exit 1; }
command -v yq >/dev/null || { echo "✗ yq not found (the inputs guard needs it; install: brew install yq)"; exit 1; }
for f in "${L1_CFG}" "${L2_CFG}"; do
    [ -f "${f}" ] || { echo "✗ missing deploy record ${f} (run the deploy first, or set RECORD_DIR)"; exit 1; }
done

# ── 1. Pull the just-deployed addresses out of the record (the deploy output). ────────────────
jq_addr() { jq -er "$1" "$2"; }  # -e: fail if the field is missing/null (stale/partial record)
L1_WSTETH=$(record_token                                   "${L1_CFG}")
L1_POOL=$(jq_addr   '.deployed.token_pool'                 "${L1_CFG}")
L1_HOOKS=$(jq_addr  '.deployed.advanced_pool_hooks'        "${L1_CFG}")
L1_TIMELOCK=$(jq_addr '.deployed.timelock'                 "${L1_CFG}")
L1_CALL_PROXY=$(jq_addr '.deployed.call_proxy'             "${L1_CFG}")
L1_TAR=$(jq_addr    '.ccip.token_admin_registry'          "${L1_CFG}")
L1_LOCKBOX=$(jq -er --arg lane "${L2_CHAIN}" '[.deployed.lock_boxes[] | select(.remote_chain_name == $lane)] | if length == 1 then .[0].lock_box else error("missing or duplicate lockbox") end' "${L1_CFG}")
L1_ROUTER=$(jq_addr '.ccip.router'                         "${L1_CFG}")
L1_RESOLVER=$(jq_addr '.ccv.verifier_resolver'             "${L1_CFG}")
L1_VERIFIER=$(jq_addr '.ccv.message_id_verifier'           "${L1_CFG}")
L1_AGENT=$(jq_addr  '.governance_addresses.lido_dao_agent' "${L1_CFG}")

L2_WSTETH=$(record_token                                   "${L2_CFG}")
L2_POOL=$(jq_addr   '.deployed.token_pool'                 "${L2_CFG}")
L2_HOOKS=$(jq_addr  '.deployed.advanced_pool_hooks'        "${L2_CFG}")
L2_TIMELOCK=$(jq_addr '.deployed.timelock'                 "${L2_CFG}")
L2_CALL_PROXY=$(jq_addr '.deployed.call_proxy'             "${L2_CFG}")
L2_TAR=$(jq_addr    '.ccip.token_admin_registry'          "${L2_CFG}")
L2_ROUTER=$(jq_addr '.ccip.router'                         "${L2_CFG}")
L2_RESOLVER=$(jq_addr '.ccv.verifier_resolver'             "${L2_CFG}")
L2_VERIFIER=$(jq_addr '.ccv.message_id_verifier'           "${L2_CFG}")
L2_OPEXEC=$(jq_addr '.governance_addresses.lido_dao_agent' "${L2_CFG}")

# The L2 wstETH IMPLEMENTATION behind the proxy, from the chain state file: step 04 pins it there
# from the CREATE records of the component's 1_Deploy (scratch spokes), step 06 writes the migration
# implementation (in-place targets), and step 10 reads the same field. The state dir
# travels WITH the record — the live one for the canonical record, the archived copy next to an
# archived record — so re-verifying an old archive reads that archive's own state/l2.json and not
# whatever the latest run happens to have left in ./state.
# State travels with the record (`just snapshot-record` copies it to $RECORD_DIR/state).
# The in-progress deploy uses ./state next to the default templates.
. "${HERE}/_record.sh"
resolve_record_state
L2_WSTETH_IMPL=$(jq_addr '.wstETHImpl' "${L2_STATE}")
# What the token proxy's EIP-1967 admin slot must hold (the wiring's `proxyAdmin:` anchor):
#   - a scratch spoke record carries .wstETHProxyAdmin — the ProxyAdmin contract the OZ 5.3.0
#     TransparentUpgradeableProxy constructor created in the component's 1_Deploy (owned by OpExec);
#   - an earlier record (OssifiableProxy, e.g. the live Mantle Sepolia token) has no such field: that
#     proxy keeps its admin — OpExec itself after step 07 — directly in the slot.
# The renderer adds proxyAdminOwner for transparent records, so both ownership hops
# are checked by state-mate and retained in its archived log.
if jq -e '.wstETHProxyAdmin' "${L2_STATE}" >/dev/null 2>&1; then
    L2_WSTETH_PROXY_ADMIN=$(jq_addr '.wstETHProxyAdmin' "${L2_STATE}")
    L2_WSTETH_PROXY_KIND="transparent"
else
    L2_WSTETH_PROXY_ADMIN="${L2_OPEXEC}"
    L2_WSTETH_PROXY_KIND="legacy"
fi
# Timelock identities are pinned by step 04 from its CREATE transaction records (state files);
# the record alone could carry an address an unrelated contract landed on after a fork reset.
for state_file in "${STATE_DIR}/l1.json" "${L2_STATE}"; do
    jq -e '[.timelock, .callProxy] | all(.[]; type == "string" and test("^0x[0-9a-fA-F]{40}$") and test("^0x0{40}$") == false)' "${state_file}" >/dev/null 2>&1 \
        || { echo "✗ missing or invalid timelock identity in ${state_file} (step 04 records .timelock/.callProxy from the CREATE records)"; exit 1; }
done
eq "$(jq_addr '.timelock' "${STATE_DIR}/l1.json")" "${L1_TIMELOCK}" \
    || { echo "✗ L1 timelock in state/l1.json is not the record's .deployed.timelock"; exit 1; }
eq "$(jq_addr '.callProxy' "${STATE_DIR}/l1.json")" "${L1_CALL_PROXY}" \
    || { echo "✗ L1 CallProxy in state/l1.json is not the record's .deployed.call_proxy"; exit 1; }
eq "$(jq_addr '.timelock' "${L2_STATE}")" "${L2_TIMELOCK}" \
    || { echo "✗ L2 timelock in the L2 state file is not the record's .deployed.timelock"; exit 1; }
eq "$(jq_addr '.callProxy' "${L2_STATE}")" "${L2_CALL_PROXY}" \
    || { echo "✗ L2 CallProxy in the L2 state file is not the record's .deployed.call_proxy"; exit 1; }
# In-place targets: the legacy bridge proxies and the implementations step 06 put behind them.
IN_PLACE=0
if [ "${WSTETH_OPERATION}" = "in-place-upgrade" ]; then
    IN_PLACE=1
    L1_LEGACY_BRIDGE=$(jq_addr '.legacyBridge' "${STATE_DIR}/l1.json")
    L1_MIGRATION_IMPL=$(jq_addr '.migrationBridgeImplementation' "${STATE_DIR}/l1.json")
    L2_LEGACY_BRIDGE=$(jq_addr '.legacyBridge' "${L2_STATE}")
    L2_MIGRATION_IMPL=$(jq_addr '.migrationBridgeImplementation' "${L2_STATE}")
fi
# ...and prove the two files describe the SAME deployment before trusting the implementation from
# one against the proxy from the other. Without this, a stale ./state left over from a later run
# would have us assert an unrelated implementation as this record's.
eq "$(jq_addr '.wstETH' "${L2_STATE}")" "${L2_WSTETH}" \
    || { echo "✗ ${L2_STATE} describes a different deployment than ${L2_CFG} (wstETH proxy mismatch) — stale state/, or RECORD_DIR and state/ are out of step"; exit 1; }

# The deployer the revocation checks bind to comes from the RECORD (stamped by step 04 from the
# signing key), never from the environment — a DEPLOYER_ADDRESS default (anvil account 0) would
# make every "hasRole(…, *deployer) == false" check pass vacuously against a key that never
# deployed anything. It is an EOA rather than one of our deployments, so it is emitted under the
# address book, which is otherwise strictly this repo's own deployments.
DEPLOYER=$(jq_addr '.governance_addresses.deployer' "${L1_CFG}")
eq "${DEPLOYER}" "$(jq_addr '.governance_addresses.deployer' "${L2_CFG}")" \
    || { echo "✗ records disagree on governance_addresses.deployer"; exit 1; }

# ── 1b. Guard: the committed inputs (wsteth.inputs.yaml) must agree with the deploy record. ───
# wsteth.inputs.yaml is the check-side copy of the timelock role-holders (config:) and
# the external Chainlink facts — router, TAR, chain selectors (externals:); config/chains/*.json is
# the deploy-side source the CCIP scripts consume. The two are intentionally duplicated
# (checks-only adoption of state-mate's `.inputs`), so assert they match here and fail loudly on
# drift rather than silently verifying against stale inputs. For the CCIP infra this is the only
# pin we have: step 04 FFI-hydrates `.ccip` from the Chainlink API, so a published-infra move must
# stop the run, not silently redirect the checks at a different router/registry.
yqa() { yq -r "(.. | select(anchor == \"$1\")) // \"\"" "${INPUTS}"; }  # .inputs value by &anchor
assert_input() {  # <label> <inputs-value> <record-value>; eq (from _common.sh) is case-insensitive
    eq "$2" "$3" || { echo "✗ inputs drift: $1 — wsteth.inputs.yaml=$2 record=$3"; exit 1; }
}
# Read each committed input once (chain-independent), then diff against the per-chain records.
IN_BRAKES=$(yqa emergencyBrakes); IN_MCMS=$(yqa chainlinkMcms)
# Active role-holders (config:) — both chain records carry the same two; check each record.
# The legacy .guardian field is not consumed by the timelock deployment code. Each chain may name
# its own Emergency Brakes / MCMS (the L2 anchors fall back to the L1 ones when absent).
IN_L2_BRAKES=$(yqa l2EmergencyBrakes); IN_L2_MCMS=$(yqa l2ChainlinkMcms)
assert_input "emergencyBrakes"   "${IN_BRAKES}"                 "$(jq_addr '.governance_addresses.emergency_brakes' "${L1_CFG}")"
assert_input "chainlinkMcms"     "${IN_MCMS}"                   "$(jq_addr '.governance_addresses.chainlink_mcms'   "${L1_CFG}")"
assert_input "l2EmergencyBrakes" "${IN_L2_BRAKES:-${IN_BRAKES}}" "$(jq_addr '.governance_addresses.emergency_brakes' "${L2_CFG}")"
assert_input "l2ChainlinkMcms"   "${IN_L2_MCMS:-${IN_MCMS}}"     "$(jq_addr '.governance_addresses.chainlink_mcms'   "${L2_CFG}")"
# External Chainlink facts (externals:) — per chain: the CCIP infra we reference but never deploy.
assert_input "l1CCIPRouter"         "$(yqa l1CCIPRouter)"         "${L1_ROUTER}"
assert_input "l1TokenAdminRegistry" "$(yqa l1TokenAdminRegistry)" "${L1_TAR}"
assert_input "l2CCIPRouter"         "$(yqa l2CCIPRouter)"         "${L2_ROUTER}"
assert_input "l2TokenAdminRegistry" "$(yqa l2TokenAdminRegistry)" "${L2_TAR}"
assert_input "l1ChainId" "$(yqa l1ChainId)" "$(jq_addr '.chain.chain_id' "${L1_CFG}")"
assert_input "l2ChainId" "$(yqa l2ChainId)" "$(jq_addr '.chain.chain_id' "${L2_CFG}")"
assert_input "l1ChainSelector"      "$(yqa l1ChainSelector)"      "$(jq_addr '.ccip.chain_selector' "${L1_CFG}")"
assert_input "l2ChainSelector"      "$(yqa l2ChainSelector)"      "$(jq_addr '.ccip.chain_selector' "${L2_CFG}")"
assert_input "l1RmnProxy"           "$(yqa l1RmnProxy)"           "$(jq_addr '.ccip.rmn_proxy' "${L1_CFG}")"
assert_input "l2RmnProxy"           "$(yqa l2RmnProxy)"           "$(jq_addr '.ccip.rmn_proxy' "${L2_CFG}")"
# Same treatment for the timelock role cardinalities 1_Deploy produces: PROPOSAL_QUEUE_HALT_ROLE =
# {emergency_brakes} (always 1), CANCELLER_ROLE = {emergency_brakes, chainlink_mcms} (2, or 1 while
# the two are collapsed onto one key). Derived here, per chain — each timelock has its own pair —
# so the member-count asserts (the only checks that can see an EXTRA holder) can never be
# satisfied by a stale hand-typed number.
CANCELLERS_EXPECTED=$(eq "${IN_BRAKES}" "${IN_MCMS}" && echo 1 || echo 2)
L2_CANCELLERS_EXPECTED=$(eq "${IN_L2_BRAKES:-${IN_BRAKES}}" "${IN_L2_MCMS:-${IN_MCMS}}" && echo 1 || echo 2)
IN_HALTERS=$(yqa haltRoleMemberCount); IN_CANCELLERS=$(yqa cancellerRoleMemberCount); IN_L2_CANCELLERS=$(yqa l2CancellerRoleMemberCount)
[ "${IN_HALTERS}" = "1" ] || { echo "✗ inputs drift: haltRoleMemberCount=${IN_HALTERS}, expected 1 (only emergency_brakes may halt the queue)"; exit 1; }
[ "${IN_CANCELLERS}" = "${CANCELLERS_EXPECTED}" ] || { echo "✗ inputs drift: cancellerRoleMemberCount=${IN_CANCELLERS}, but the L1 record's emergency_brakes/chainlink_mcms are $([ "${CANCELLERS_EXPECTED}" = 1 ] && echo collapsed || echo distinct) — expected ${CANCELLERS_EXPECTED}"; exit 1; }
[ "${IN_L2_CANCELLERS}" = "${L2_CANCELLERS_EXPECTED}" ] || { echo "✗ inputs drift: l2CancellerRoleMemberCount=${IN_L2_CANCELLERS}, but the L2 record's emergency_brakes/chainlink_mcms are $([ "${L2_CANCELLERS_EXPECTED}" = 1 ] && echo collapsed || echo distinct) — expected ${L2_CANCELLERS_EXPECTED}"; exit 1; }
echo "▸ guard: wsteth.inputs matches the deploy record (role-holders + CCIP infra + selectors + RMN + role counts)"

# ── 2. Preflight: the record's contracts must actually exist on the target RPCs. ──────────────
echo "▸ preflight: assert deployment present on L1 ${L1_RPC} / L2 ${L2_RPC}"
assert_code "${L1_POOL}"       "${L1_RPC}" "l1 pool"
assert_code "${L1_HOOKS}"      "${L1_RPC}" "l1 hooks"
assert_code "${L1_TIMELOCK}"   "${L1_RPC}" "l1 timelock"
assert_code "${L1_CALL_PROXY}" "${L1_RPC}" "l1 CallProxy"
assert_code "${L1_TAR}"        "${L1_RPC}" "l1 TAR"
assert_code "${L1_WSTETH}"     "${L1_RPC}" "l1 wstETH"
assert_code "${L2_POOL}"       "${L2_RPC}" "l2 pool"
assert_code "${L2_HOOKS}"      "${L2_RPC}" "l2 hooks"
assert_code "${L2_TIMELOCK}"   "${L2_RPC}" "l2 timelock"
assert_code "${L2_CALL_PROXY}" "${L2_RPC}" "l2 CallProxy"
assert_code "${L2_TAR}"        "${L2_RPC}" "l2 TAR"
assert_code "${L2_WSTETH}"     "${L2_RPC}" "l2 wstETH"
if [ "${IN_PLACE}" = 1 ]; then
    assert_code "${L1_LEGACY_BRIDGE}"  "${L1_RPC}" "l1 legacy bridge"
    assert_code "${L1_MIGRATION_IMPL}" "${L1_RPC}" "l1 migration bridge implementation"
    assert_code "${L2_LEGACY_BRIDGE}"  "${L2_RPC}" "l2 legacy bridge"
    assert_code "${L2_MIGRATION_IMPL}" "${L2_RPC}" "l2 migration bridge implementation"
fi

# ── 3. Emit the address-book that the wiring config aliases resolve against. ───────────────────
# One &label per address; labels must match the *aliases in wsteth.yaml (state-mate enforces
# that every label is referenced and the wiring has no deployed section of its own).
# The book holds ONLY this repo's own deployments (steps 01-04: Lido core + DG, opExec, L2 token,
# pool stack, CCV stack). The Chainlink-owned CCIP infra (router, TAR) is not ours to deploy, so
# it is an authored externals fact in wsteth.inputs*.yaml, guarded against the record in 1b.
{
cat <<EOF
# GENERATED by script/08_verify_state.sh from the deploy record (${RECORD_DIR}). Do not edit.
# Address book for the wiring-only config/state-mate/wsteth.yaml (state-mate --deployed feature).
# Scope: ONLY what this repo deployed (steps 01-04), plus the run's signer EOA (see below).
# Addresses we merely reference -- the Chainlink-owned router/TokenAdminRegistry/RMN proxy -- are
# authored externals facts in wsteth.inputs*.yaml instead.
deployed:
  l1:
    - &l1WstETH "${L1_WSTETH}"
    - &l1TokenPool "${L1_POOL}"
    - &l1AdvancedPoolHooks "${L1_HOOKS}"
    - &l1LidoTimelock "${L1_TIMELOCK}"
    - &l1CallProxy "${L1_CALL_PROXY}"
    - &l1LockBox "${L1_LOCKBOX}"
    - &l1VerifierResolver "${L1_RESOLVER}"
    - &l1MessageIdVerifier "${L1_VERIFIER}"
    - &l1LidoDAOAgent "${L1_AGENT}"
    # The one non-contract entry: the EOA that signed this run, stamped into the record by step 04.
    # It is per-run record-derived (a committed inputs entry would break every run signed with a
    # different key) and state-mate's deployed schema admits no section besides l1/l2, so it
    # rides along here rather than in wsteth.inputs*.yaml.
    - &deployer "${DEPLOYER}"
EOF
if [ "${IN_PLACE}" = 1 ]; then
    cat <<EOF
    - &l1LegacyBridge "${L1_LEGACY_BRIDGE}"
    - &l1MigrationBridgeImpl "${L1_MIGRATION_IMPL}"
EOF
fi
cat <<EOF
  l2:
    - &l2WstETH "${L2_WSTETH}"
    - &l2TokenPool "${L2_POOL}"
    - &l2AdvancedPoolHooks "${L2_HOOKS}"
    - &l2LidoTimelock "${L2_TIMELOCK}"
    - &l2CallProxy "${L2_CALL_PROXY}"
    - &l2VerifierResolver "${L2_RESOLVER}"
    - &l2MessageIdVerifier "${L2_VERIFIER}"
    - &l2OptimismBridgeExecutor "${L2_OPEXEC}"
    # The implementation the L2 token proxy currently points at, from state/l2.json (see above).
    - &l2WstETHImpl "${L2_WSTETH_IMPL}"
    # What the token proxy's EIP-1967 admin slot holds (see above): the ProxyAdmin from state/l2.json
    # for a transparent proxy (${L2_WSTETH_PROXY_KIND} here), OpExec itself for a legacy OssifiableProxy.
    - &l2WstETHProxyAdmin "${L2_WSTETH_PROXY_ADMIN}"
EOF
if [ "${IN_PLACE}" = 1 ]; then
    cat <<EOF
    - &l2LegacyBridge "${L2_LEGACY_BRIDGE}"
    - &l2MigrationBridgeImpl "${L2_MIGRATION_IMPL}"
EOF
fi
} > "${DEPLOYED}"

# Generate whole-hub expectations plus this spoke's complete matrix from declared policy.
# Archives carry their own policy; never borrow today's intent for an old record.
resolve_record_policy
if [ ! -f "${POLICY}" ]; then
    POLICY="${ROOT}/config/state-mate/ccv-policy.legacy.${L2_CHAIN}.json"
    node "${HERE}/legacy-ccv-policy.cjs" "${RECORD_PATH}" "${L2_CHAIN}" "${L2_STATE}" "${POLICY}"
    echo "▸ Legacy record: asserting the historical single-lane dummy policy (not inferred from RPC)."
fi
GENERATED_CONFIG="${ROOT}/config/state-mate/wsteth.${L2_CHAIN}.yaml"
STATE_MATE_DIR="${SM_DIR}" node "${HERE}/render-multichain-state.cjs" \
    "${CONFIG}" "${RECORD_PATH}" "${POLICY}" "${L2_CHAIN}" "${GENERATED_CONFIG}" "${L2_STATE}"
CONFIG="${GENERATED_CONFIG}"

# ── 4. Run state-mate: wiring + generated address book + committed inputs. ────────────────────
# Output is tee'd to state/state-mate.log so the run itself (not a number retyped into a document)
# can be archived below. It lives under state/ (gitignored, overwritten per run) rather than in a
# temp file so that a FAILED run — which aborts before the archive step, since pipefail is set —
# still leaves its output for inspection.
mkdir -p "${ROOT}/state"
RUN_LOG="${ROOT}/state/state-mate.${L2_CHAIN}.log"
echo "▸ state-mate diff against L1 ${L1_RPC} / L2 ${L2_RPC} (record: ${RECORD_DIR})"
{
    echo "# state-mate run — $(date +%Y-%m-%dT%H:%M:%S%z)"
    echo "# git:        $(git -C "${ROOT}" rev-parse --short HEAD 2>/dev/null || echo unknown)"
    echo "# record:     ${RECORD_DIR}"
    echo "# L2_CHAIN:   ${L2_CHAIN}"
    echo "# L1 RPC:     ${L1_RPC}"
    echo "# L2 RPC:     ${L2_RPC}"
    echo "# config:     $(basename "${CONFIG}") + $(basename "${DEPLOYED}") + $(basename "${INPUTS}")"
    echo
} > "${RUN_LOG}"
STATE_MATE_DIR="${SM_DIR}" node "${HERE}/verify-state-tables.cjs" \
    "${CONFIG}.tables.json" "${L1_RPC}" "${L2_RPC}" 2>&1 | tee -a "${RUN_LOG}"
STATE_MATE_DIR="${SM_DIR}" node "${HERE}/build-state-mate-abis.cjs" "${CONFIG}" "${DEPLOYED}" "${INPUTS}" | tee -a "${RUN_LOG}"
( cd "${SM_DIR}" && corepack yarn start "${CONFIG}" --deployed "${DEPLOYED}" --inputs "${INPUTS}" ) \
    2>&1 | tee -a "${RUN_LOG}"

# ── 4b. Timelock surface, read independently of state-mate. ─────────────────────────────────
# The LidoTimelock is not upgradeable: its address is its identity (pinned above from the CREATE
# records). This read proves the queue is open, the minimum delay is the one in the component's
# default_config.json and the proposal-blocked selectors are exactly those of the same file, in
# insertion order.
assert_timelock() {
    local tag="$1" timelock="$2" rpc="$3"
    local halted delay count i sel
    halted=$(cast call "${timelock}" 'isProposalQueueHalted()(bool)' --rpc-url "${rpc}")
    [ "${halted}" = "false" ] || { echo "✗ ${tag}: proposal queue is halted"; exit 1; }
    delay=$(cast call "${timelock}" 'getMinDelay()(uint256)' --rpc-url "${rpc}" | awk '{print $1}')
    local expected_delay; expected_delay="$(jq -r '.governance.min_delay_seconds' "${CCIP_DEFAULT_CONFIG}")"
    [ "${delay}" = "${expected_delay}" ] \
        || { echo "✗ ${tag}: min delay ${delay}s != configured ${expected_delay}s"; exit 1; }
    count=$(cast call "${timelock}" 'getBlockedFunctionSelectorCount()(uint256)' --rpc-url "${rpc}" | awk '{print $1}')
    local expected; expected="$(jq -r '[.blocked_selectors[].selector] | join(",")' "${CCIP_DEFAULT_CONFIG}")"
    local got=""
    i=0
    while [ "${i}" -lt "${count}" ]; do
        sel=$(cast call "${timelock}" 'getBlockedFunctionSelectorAt(uint256)(bytes4)' "${i}" --rpc-url "${rpc}")
        got="${got:+${got},}${sel}"
        i=$((i + 1))
    done
    [ "$(lc "${got}")" = "$(lc "${expected}")" ] \
        || { echo "✗ ${tag}: blocked selectors ${got} != configured ${expected}"; exit 1; }
    echo "  ✓ ${tag}: queue open, min delay ${delay}s, blocked selectors ${got}" | tee -a "${RUN_LOG}"
}
echo "" >> "${RUN_LOG}"
echo "# LidoTimelock evidence — see step 08 §4b and the governance scenarios" >> "${RUN_LOG}"
echo "▸ LidoTimelock queue, delay and blocked selectors"
assert_timelock "L1 timelock" "${L1_TIMELOCK}" "${L1_RPC}"
assert_timelock "L2 timelock" "${L2_TIMELOCK}" "${L2_RPC}"

echo "✓ step 08 done — on-chain state matches the expected §4 matrix."

# ── 5. Archive the verified artifacts to deployments/<type>/<pair>/<date-time>/. ──────────────
DEPLOY_TYPE="${WSTETH_RUN_ENVIRONMENT:?run via just wsteth so the run environment is explicit}"
ARCHIVE="${ROOT}/deployments/${DEPLOY_TYPE}/${L1_CHAIN}-${L2_CHAIN}/$(date +%Y-%m-%d_%H-%M-%S)"
[ ! -e "${ARCHIVE}" ] || { echo "archive already exists: ${ARCHIVE}" >&2; exit 1; }
mkdir -p "${ARCHIVE}/state-mate" "${ARCHIVE}/chains" "${ARCHIVE}/state" "${ARCHIVE}/run"
cp "${CONFIG}" "${DEPLOYED}" "${INPUTS}" "${ROOT}/config/state-mate/abis.json" "${ROOT}/config/state-mate/abis.json.gz" "${ARCHIVE}/state-mate/"
cp "${CONFIG}.tables.json" "${ARCHIVE}/state-mate/"
# Claim A's evidence carrier (A.10): the run itself, not a figure quoted in a document.
cp "${RUN_LOG}" "${ARCHIVE}/run/state-mate.log"
# Claim B's carrier, when `just test-scenarios` has already run on this substrate. Inside
# `just all` runs test-scenarios immediately before verify-state, so this archives the current
# deployment's scenario carrier. Standalone verify-state may still pick up an older log; its own
# header carries the date and commit, so check those before relying on it.
[ -f "${ROOT}/state/forge-scenarios.${L2_CHAIN}.log" ] && cp "${ROOT}/state/forge-scenarios.${L2_CHAIN}.log" "${ARCHIVE}/run/" || true
[ ! -f "${ROOT}/state/forge-hub-checkpoint.log" ] || cp "${ROOT}/state/forge-hub-checkpoint.log" "${ARCHIVE}/run/"
cp "${RECORD_PATH}/"*.json "${ARCHIVE}/chains/"
cp "${POLICY}" "${ARCHIVE}/chains/ccv-policy.json"
# The selector/governance config the deploy actually ran with: the component's own
# default_config.json (the deploy sets no DEFAULT_CONFIG). Without it the record cannot say WHICH
# blocked selectors and delay produced the timelock state it archives.
cp "${CCIP_DEFAULT_CONFIG}" "${ARCHIVE}/default_config.json"
STATE_FILES=(l1.json l1.deployed.json)
for chain in ${WSTETH_L2_CHAINS:-${L2_CHAIN}}; do STATE_FILES+=("${chain}.json"); done
# Legacy archives can still carry a single l2.json.
STATE_FILES+=("${L2_STATE_NAME}")
# In-place targets: the vote's timers and, with a hub migration, Chainlink's cutover and lane-connection
# records (proposals, calldata, snapshots, what stayed unverified) belong to the evidence.
STATE_FILES+=(migration.json hub-migration.json hub-admin-accept.json hub-checkpoint.json base-preparation.json hub-lane-connect.json)
STATE_FILES+=(forks.json bootstrap-core.json bootstrap.json bootstrap-remotes.json migration-target.json forge-bootstrap.log existing-lane-tests.json)
STATE_FILES+=(hub-preserved-before.json hub-preserved-after.json)
for f in "${STATE_FILES[@]}"; do
    [ -f "${STATE_DIR}/${f}" ] && cp "${STATE_DIR}/${f}" "${ARCHIVE}/state/" || true
done
for d in hub-migration hub-lane-connect base-preparation migration hub-scripts ccip-build; do
    [ -d "${STATE_DIR}/${d}" ] && cp -R "${STATE_DIR}/${d}" "${ARCHIVE}/state/${d}" || true
done
# State has one authoritative copy: RECORD_DIR=<archive>/chains and --record imports
# resolve the sibling ../state directory.
cp "${ROOT}/.active-run/run.json" "${ARCHIVE}/migration-run.json"
cp -R "${ROOT}/.active-run/inputs" "${ARCHIVE}/inputs"
cp -R "${ROOT}/.active-run/broadcast" "${ARCHIVE}/broadcast"
# Non-secret deploy parameters only — never copy .env (holds DEPLOYER_PRIVATE_KEY).
cat > "${ARCHIVE}/parameters.env" <<EOF
ARCHIVED_AT=$(date +%Y-%m-%dT%H:%M)
GIT_COMMIT=$(git -C "${ROOT}" rev-parse --short HEAD 2>/dev/null || echo unknown)
RECORD_DIR=${RECORD_DIR}
DEPLOYER_ADDRESS=${DEPLOYER_ADDRESS}
L1_CHAIN=${L1_CHAIN}
L1_RPC=${L1_RPC}
L2_CHAIN=${L2_CHAIN}
${L2_RPC_VAR}=${L2_RPC}
STATE_MATE_RESULT=$(grep -Eo '[0-9]+ checks( passed|,)' "${RUN_LOG}" | tail -1 || echo unknown)
EOF
echo "✓ artifacts archived to ${ARCHIVE#${ROOT}/}"
