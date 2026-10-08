#!/usr/bin/env bash
# Step 08 — Claim A (E-STATE-01): diff the post-deploy on-chain state against the expected
# ownership/role matrix (PLAN §4) using state-mate (lidofinance tool, vendored at ../../libs/state-mate,
# branch feat/separate-deployed). Verifies pool/hook/lockbox ownership = POM, POM admin =
# Agent/OpExec (deployer revoked), TAR administrator = POM + pool binding, lane support, L2 token
# minter/burner + proxy/admin/implementation handover, OpExec pinned to the L1 Agent.
#
# Substrate-agnostic & record-sourced. state-mate's `--deployed` feature splits the config in two:
#   • config/state-mate/wsteth.yaml          — committed WIRING (relationships), no addresses
#   • config/state-mate/wsteth.deployed.yaml — the ADDRESS BOOK, GENERATED here from the deploy
#                                              record ($RECORD_DIR, default config/chains/*.json)
# so the just-deployed addresses are swapped in per run, on whichever network RPC_SEPOLIA /
# the L2 RPC (RPC_<L2_CHAIN>, exported as L2_RPC) point at (a live-testnet fork OR the
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
L1_CFG="${RECORD_PATH}/sepolia.json"
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
L1_WSTETH=$(jq_addr '.addresses.token'                     "${L1_CFG}")
L1_POOL=$(jq_addr   '.deployed.token_pool'                 "${L1_CFG}")
L1_HOOKS=$(jq_addr  '.deployed.advanced_pool_hooks'        "${L1_CFG}")
L1_POM=$(jq_addr    '.deployed.pool_operation_manager'     "${L1_CFG}")
L1_TAR=$(jq_addr    '.ccip.token_admin_registry'          "${L1_CFG}")
L1_LOCKBOX=$(jq -er --arg lane "${L2_CHAIN}" '[.deployed.lock_boxes[] | select(.remote_chain_name == $lane)] | if length == 1 then .[0].lock_box else error("missing or duplicate lockbox") end' "${L1_CFG}")
L1_ROUTER=$(jq_addr '.ccip.router'                         "${L1_CFG}")
L1_RESOLVER=$(jq_addr '.ccv.verifier_resolver'             "${L1_CFG}")
L1_VERIFIER=$(jq_addr '.ccv.message_id_verifier'           "${L1_CFG}")
L1_AGENT=$(jq_addr  '.governance_addresses.lido_dao_agent' "${L1_CFG}")

L2_WSTETH=$(jq_addr '.addresses.token'                     "${L2_CFG}")
L2_POOL=$(jq_addr   '.deployed.token_pool'                 "${L2_CFG}")
L2_HOOKS=$(jq_addr  '.deployed.advanced_pool_hooks'        "${L2_CFG}")
L2_POM=$(jq_addr    '.deployed.pool_operation_manager'     "${L2_CFG}")
L2_TAR=$(jq_addr    '.ccip.token_admin_registry'          "${L2_CFG}")
L2_ROUTER=$(jq_addr '.ccip.router'                         "${L2_CFG}")
L2_RESOLVER=$(jq_addr '.ccv.verifier_resolver'             "${L2_CFG}")
L2_VERIFIER=$(jq_addr '.ccv.message_id_verifier'           "${L2_CFG}")
L2_OPEXEC=$(jq_addr '.governance_addresses.lido_dao_agent' "${L2_CFG}")

# The L2 wstETH IMPLEMENTATION behind the proxy. It is the one deployed address the CCIP chain
# record does not carry: step 03 writes it to state/l2.json (.wstETHImpl) and step 10 reads it from
# there, so step 08 follows the same route rather than inventing a second source. The state dir
# travels WITH the record — the live one for the canonical record, the archived copy next to an
# archived record — so re-verifying an old archive reads that archive's own state/l2.json and not
# whatever the latest run happens to have left in ./state.
# State travels with the record (`just snapshot-record` copies it to $RECORD_DIR/state).
# The in-progress deploy uses ./state next to the default templates.
. "${HERE}/_record.sh"
resolve_record_state
L2_WSTETH_IMPL=$(jq_addr '.wstETHImpl' "${L2_STATE}")
# What the token proxy's EIP-1967 admin slot must hold (the wiring's `proxyAdmin:` anchor):
#   - a record from 2026-10-08 on carries .wstETHProxyAdmin — the ProxyAdmin contract the OZ 5.3.0
#     TransparentUpgradeableProxy constructor created in step 03 (owned by OpExec);
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
# Implementation identities are pinned by step 04 from its CREATE transaction records.
for state_file in "${STATE_DIR}/l1.json" "${L2_STATE}"; do
    if [ ! -f "${state_file}" ] || ! jq -e '[.poolOperationManager, .poolOperationManagerImplementation] | all(.[]; type == "string" and test("^0x[0-9a-fA-F]{40}$") and test("^0x0{40}$") == false)' "${state_file}" >/dev/null 2>&1; then
        echo "✗ missing or invalid POM deployment identity in ${state_file}"
        echo "  Restore poolOperationManager and poolOperationManagerImplementation from this deployment's trusted CREATE records (step 04), or select a RECORD_DIR with complete state/."
        echo "  Legacy records need these pins before verification; the current on-chain slot is not an independent expected value."
        exit 1
    fi
done
L1_POM_IMPL=$(jq_addr '.poolOperationManagerImplementation' "${STATE_DIR}/l1.json")
L2_POM_IMPL=$(jq_addr '.poolOperationManagerImplementation' "${L2_STATE}")
eq "$(jq_addr '.poolOperationManager' "${STATE_DIR}/l1.json")" "${L1_POM}" \
    || { echo "✗ L1 POM implementation record belongs to a different proxy"; exit 1; }
eq "$(jq_addr '.poolOperationManager' "${L2_STATE}")" "${L2_POM}" \
    || { echo "✗ L2 POM implementation record belongs to a different proxy"; exit 1; }
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
# wsteth.inputs.yaml is the check-side copy of the POM role-holders (config:) and
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
# The legacy .guardian field is not consumed by current PoolOperationManager deployment code.
for cfg in "${L1_CFG}" "${L2_CFG}"; do
    assert_input "emergencyBrakes" "${IN_BRAKES}"   "$(jq_addr '.governance_addresses.emergency_brakes' "${cfg}")"
    assert_input "chainlinkMcms"   "${IN_MCMS}"     "$(jq_addr '.governance_addresses.chainlink_mcms'   "${cfg}")"
done
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
# Same treatment for the expected PROPOSAL_QUEUE_HALT_ROLE / CROSS_CHAIN_TRANSFERS_PAUSE_ROLE member count: 1_Deploy grants PROPOSAL_QUEUE_HALT_ROLE / CROSS_CHAIN_TRANSFERS_PAUSE_ROLE to exactly
# {emergency_brakes, chainlink_mcms}, so the expected count is how many DISTINCT addresses those
# two are — 1 while collapsed, 2 once rotated apart. Derived here so the member-count assert (the
# only check that can see an EXTRA halter) can never be satisfied by a stale hand-typed number.
HALTERS_EXPECTED=$(eq "${IN_BRAKES}" "${IN_MCMS}" && echo 1 || echo 2)
IN_HALTERS=$(yqa haltRoleMemberCount)
[ "${IN_HALTERS}" = "${HALTERS_EXPECTED}" ] || { echo "✗ inputs drift: haltRoleMemberCount=${IN_HALTERS}, but the record's emergency_brakes/chainlink_mcms are $([ "${HALTERS_EXPECTED}" = 1 ] && echo collapsed || echo distinct) — expected ${HALTERS_EXPECTED}; update wsteth.inputs.yaml"; exit 1; }
echo "▸ guard: wsteth.inputs.yaml matches the deploy record (role-holders + CCIP infra + selectors + RMN + halter count)"

# ── 2. Preflight: the record's contracts must actually exist on the target RPCs. ──────────────
echo "▸ preflight: assert deployment present on L1 ${RPC_SEPOLIA} / L2 ${L2_RPC}"
assert_code "${L1_POOL}"   "${RPC_SEPOLIA}" "l1 pool"
assert_code "${L1_HOOKS}"  "${RPC_SEPOLIA}" "l1 hooks"
assert_code "${L1_POM}"    "${RPC_SEPOLIA}" "l1 POM"
assert_code "${L1_TAR}"    "${RPC_SEPOLIA}" "l1 TAR"
assert_code "${L1_WSTETH}" "${RPC_SEPOLIA}" "l1 wstETH"
assert_code "${L2_POOL}"   "${L2_RPC}"      "l2 pool"
assert_code "${L2_HOOKS}"  "${L2_RPC}"      "l2 hooks"
assert_code "${L2_POM}"    "${L2_RPC}"      "l2 POM"
assert_code "${L2_TAR}"    "${L2_RPC}"      "l2 TAR"
assert_code "${L2_WSTETH}" "${L2_RPC}"      "l2 wstETH"

# ── 3. Emit the address-book that the wiring config aliases resolve against. ───────────────────
# One &label per address; labels must match the *aliases in wsteth.yaml (state-mate enforces
# that every label is referenced and the wiring has no deployed section of its own).
# The book holds ONLY this repo's own deployments (steps 01-04: Lido core + DG, opExec, L2 token,
# pool stack, CCV stack). The Chainlink-owned CCIP infra (router, TAR) is not ours to deploy, so
# it is an authored externals fact in wsteth.inputs*.yaml, guarded against the record in 1b.
cat > "${DEPLOYED}" <<EOF
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
    - &l1PoolOperationManager "${L1_POM}"
    - &l1PoolOperationManagerImpl "${L1_POM_IMPL}"
    - &l1LockBox "${L1_LOCKBOX}"
    - &l1VerifierResolver "${L1_RESOLVER}"
    - &l1MessageIdVerifier "${L1_VERIFIER}"
    - &l1LidoDAOAgent "${L1_AGENT}"
    # The one non-contract entry: the EOA that signed this run, stamped into the record by step 04.
    # It is per-run record-derived (a committed inputs entry would break every run signed with a
    # different key) and state-mate's deployed schema admits no section besides l1/l2, so it
    # rides along here rather than in wsteth.inputs*.yaml.
    - &deployer "${DEPLOYER}"
  l2:
    - &l2WstETH "${L2_WSTETH}"
    - &l2TokenPool "${L2_POOL}"
    - &l2AdvancedPoolHooks "${L2_HOOKS}"
    - &l2PoolOperationManager "${L2_POM}"
    - &l2PoolOperationManagerImpl "${L2_POM_IMPL}"
    - &l2VerifierResolver "${L2_RESOLVER}"
    - &l2MessageIdVerifier "${L2_VERIFIER}"
    - &l2OptimismBridgeExecutor "${L2_OPEXEC}"
    # The implementation the L2 token proxy currently points at, from state/l2.json (see above).
    - &l2WstETHImpl "${L2_WSTETH_IMPL}"
    # What the token proxy's EIP-1967 admin slot holds (see above): the ProxyAdmin from state/l2.json
    # for a transparent proxy (${L2_WSTETH_PROXY_KIND} here), OpExec itself for a legacy OssifiableProxy.
    - &l2WstETHProxyAdmin "${L2_WSTETH_PROXY_ADMIN}"
EOF

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
echo "▸ state-mate diff against L1 ${RPC_SEPOLIA} / L2 ${L2_RPC} (record: ${RECORD_DIR})"
{
    echo "# state-mate run — $(date +%Y-%m-%dT%H:%M:%S%z)"
    echo "# git:        $(git -C "${ROOT}" rev-parse --short HEAD 2>/dev/null || echo unknown)"
    echo "# record:     ${RECORD_DIR}"
    echo "# L2_CHAIN:   ${L2_CHAIN}"
    echo "# L1 RPC:     ${RPC_SEPOLIA}"
    echo "# L2 RPC:     ${L2_RPC}"
    echo "# config:     $(basename "${CONFIG}") + $(basename "${DEPLOYED}") + $(basename "${INPUTS}")"
    echo
} > "${RUN_LOG}"
STATE_MATE_DIR="${SM_DIR}" node "${HERE}/verify-state-tables.cjs" \
    "${CONFIG}.tables.json" "${RPC_SEPOLIA}" "${L2_RPC}" 2>&1 | tee -a "${RUN_LOG}"
STATE_MATE_DIR="${SM_DIR}" node "${HERE}/build-state-mate-abis.cjs" "${CONFIG}" "${DEPLOYED}" "${INPUTS}" | tee -a "${RUN_LOG}"
( cd "${SM_DIR}" && corepack yarn start "${CONFIG}" --deployed "${DEPLOYED}" --inputs "${INPUTS}" ) \
    2>&1 | tee -a "${RUN_LOG}"

# ── 4b. POM UUPS surface and active implementation. ──────────────────────────────
# State-mate checks the proxy-facing interface and selector policy. This independent read also
# resolves the EIP-1967 slot, proves the implementation has code, and asks that implementation for
# the canonical slot UUID. Carrier presence alone is not treated as proof that an upgrade works;
# test/scenario/RealPomUpgrade.t.sol supplies the state-preserving fork rehearsal.
EIP1967_IMPLEMENTATION_SLOT=0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc
assert_uups_pom() {
    local tag="$1" pom="$2" rpc="$3"
    local raw impl uuid version mode
    raw=$(cast storage "${pom}" "${EIP1967_IMPLEMENTATION_SLOT}" --rpc-url "${rpc}")
    impl="0x${raw:26:40}"
    assert_code "${impl}" "${rpc}" "${tag} implementation"
    uuid=$(cast call "${impl}" 'proxiableUUID()(bytes32)' --rpc-url "${rpc}")
    [ "$(lc "${uuid}")" = "$(lc "${EIP1967_IMPLEMENTATION_SLOT}")" ] \
        || { echo "✗ ${tag}: proxiableUUID ${uuid} != implementation slot"; exit 1; }
    version=$(cast call "${pom}" 'UPGRADE_INTERFACE_VERSION()(string)' --rpc-url "${rpc}")
    [ "${version//\"/}" = "5.0.0" ] \
        || { echo "✗ ${tag}: UPGRADE_INTERFACE_VERSION=${version}, expected 5.0.0"; exit 1; }
    mode=$(cast call "${pom}" 'isSelectorBlocked(bytes4)(bool)' 0x4f1ef286 --rpc-url "${rpc}")
    [ "${mode}" = "true" ] \
        || { echo "✗ ${tag}: upgradeToAndCall selector blocked=${mode}, expected true"; exit 1; }
    echo "  ✓ ${tag}: UUPS 5.0.0, implementation ${impl}, proposal selector Blocked" | tee -a "${RUN_LOG}"
}
echo "" >> "${RUN_LOG}"
echo "# POM UUPS implementation evidence — see step 08 §4b and RealPomUpgrade" >> "${RUN_LOG}"
echo "▸ POM UUPS implementation and selector policy"
assert_uups_pom "L1-POM" "${L1_POM}" "${RPC_SEPOLIA}"
assert_uups_pom "L2-POM" "${L2_POM}" "${L2_RPC}"

# The L1 token's separate CCIP authority is checked in the state-mate matrix
# (l1/l1WstETH/getCCIPAdmin), with its contract-level diagnostic and archived result.

echo "✓ step 08 done — on-chain state matches the expected §4 matrix."

# ── 5. Archive the verified artifacts to deployments/<type>/<pair>/<date-time>/. ──────────────
DEPLOY_TYPE="${WSTETH_RUN_ENVIRONMENT:?run via just wsteth so the run environment is explicit}"
ARCHIVE="${ROOT}/deployments/${DEPLOY_TYPE}/sepolia-${L2_CHAIN}/$(date +%Y-%m-%d_%H-%M-%S)"
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
cp "${RECORD_PATH}/"*.json "${ARCHIVE}/chains/"
cp "${POLICY}" "${ARCHIVE}/chains/ccv-policy.json"
# The selector/governance config the deploy actually ran with. Without it the record cannot say
# WHICH custom_delay_selectors produced the POM state it archives — the same label-vs-binding gap
# this file's override exists to close, recurring one level up. See config/README.md.
# Both variants: the L1 hub runs with default_config.json, every spoke with the non_l1 one
# (0xa6cc6ef9 not Blocked there). Archiving only the first would misdescribe the L2 POM.
cp "${ROOT}/config/default_config.json" "${ROOT}/config/default_config.non_l1.json" "${ARCHIVE}/"
STATE_FILES=(l1.json l1.deployed.json)
for chain in ${WSTETH_L2_CHAINS:-${L2_CHAIN}}; do STATE_FILES+=("${chain}.json"); done
# Legacy archives can still carry a single l2.json.
STATE_FILES+=("${L2_STATE_NAME}")
for f in "${STATE_FILES[@]}"; do
    [ -f "${STATE_DIR}/${f}" ] && cp "${STATE_DIR}/${f}" "${ARCHIVE}/state/" || true
done
# State has one authoritative copy: RECORD_DIR=<archive>/chains and --record imports
# resolve the sibling ../state directory.
cp "${ROOT}/.active-run/run.json" "${ARCHIVE}/migration-run.json"
# Non-secret deploy parameters only — never copy .env (holds DEPLOYER_PRIVATE_KEY).
cat > "${ARCHIVE}/parameters.env" <<EOF
ARCHIVED_AT=$(date +%Y-%m-%dT%H:%M)
GIT_COMMIT=$(git -C "${ROOT}" rev-parse --short HEAD 2>/dev/null || echo unknown)
RECORD_DIR=${RECORD_DIR}
DEPLOYER_ADDRESS=${DEPLOYER_ADDRESS}
RPC_SEPOLIA=${RPC_SEPOLIA}
L2_CHAIN=${L2_CHAIN}
${L2_RPC_VAR}=${L2_RPC}
STATE_MATE_RESULT=$(grep -Eo '[0-9]+ checks( passed|,)' "${RUN_LOG}" | tail -1 || echo unknown)
EOF
echo "✓ artifacts archived to ${ARCHIVE#${ROOT}/}"
