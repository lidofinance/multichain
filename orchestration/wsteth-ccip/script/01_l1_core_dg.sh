#!/usr/bin/env bash
# Step 01 — deploy Lido core + Dual Governance on the L1 Sepolia fork.
#
# Drives the vendored `core` submodule (lidofinance/core, feat/scratch-dg) hardhat scratch deploy as-is
# against $RPC_SEPOLIA, then copies the deployment record into our state/ and extracts the
# addresses downstream steps need. DG is enabled (Voting -> DG -> Timelock -> AdminExecutor ->
# Agent). We run core's deploy + mine, but NOT its integration suite (that's core's own test).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
. "${HERE}/_common.sh"

STATE_DIR="${ROOT}/state"
mkdir -p "${STATE_DIR}"
CORE_DIR="$(cd "${CORE_DIR}" && pwd)"  # default set in _common.sh

echo "▸ L1 RPC:    ${L1_RPC}"
echo "▸ core dir:  ${CORE_DIR}"

# Local patches on top of the pinned core (patches/core/*.patch, idempotent). 0001 adds the
# getCCIPAdmin() hook that lets step 07 self-register into the real Chainlink TAR, so it must be
# in place BEFORE this deploy compiles wstETH — a patched-vs-pristine core yields DIFFERENT
# bytecode at the same address. Applied here (not only in `just init`) so no path reaches the
# deploy unpatched.
CORE_DIR="${CORE_DIR}" bash "${HERE}/00_patch_submodules.sh"

# Preflight: right chain + deployer funded on the fork (anvil funds dev accounts, but be safe).
assert_chain_id "${L1_RPC}" 11155111 "Sepolia"
fund "${DEPLOYER_ADDRESS}" "${L1_RPC}"

# Idempotency: skip if a DG-enabled record already exists in our state.
if [ -f "${STATE_DIR}/l1.json" ] && [ "$(jq -r '.dg.adminExecutor // empty' "${STATE_DIR}/l1.json")" != "" ]; then
    echo "▸ state/l1.json already has DG addresses; skipping (rm it to redeploy)."
    exit 0
fi

# ── Run core's scratch deploy (DG enabled) against the L1 fork ──
# core's `local` network uses `accounts: "remote"`, so its signer is the fork node's account #0
# (anvil's first dev key) regardless of DEPLOYER — that mismatches the DEPLOYER we write into the
# state file and trips state-file.ts's deployer check. `local-devnet` is the local-node network
# that signs with a configured key (LOCAL_DEVNET_PK); point it at our deployer so core actually
# deploys from DEPLOYER_ADDRESS. (NETWORK only feeds hardhat's --network flag + logs here;
# migration logic keys off chainId, and we pin NETWORK_STATE_FILE explicitly below.)
pushd "${CORE_DIR}" >/dev/null
export NETWORK=local-devnet
export LOCAL_DEVNET_PK="${DEPLOYER_PRIVATE_KEY}"
# External staking modules OFF (opt-out flags, core lib/env-flags.ts:44-50). We bridge wstETH and
# need none of CSM / CMv2 — and step 0140-plug-staking-modules plugs them by sending txs AS the
# freshly deployed Agent, which no network here can sign for: `local-devnet` pins
# accounts:[LOCAL_DEVNET_PK] so hardhat's LocalAccountsProvider raises HH103 for any address it
# holds no key for, and `local` (accounts:"remote") makes the scratch steps take
# (await ethers.provider.getSigner()).address as the deployer — anvil dev account #0, which
# state-file.ts:325 then rejects against our $DEPLOYER. Both measured, not assumed. On a live
# chain the Agent cannot be impersonated at all, so these stay off there too.
# Turn BOTH off together: StakingRouter assigns module ids in plug order, so disabling only one
# shifts the other's id (and ConsolidationMigrator takes targetModuleId as an immutable ctor arg).
export CSM_DEPLOYMENT_ENABLED=false
export CMV2_DEPLOYMENT_ENABLED=false
# PROTOCOL_ACTIVATION_ENABLED is opt-in in core (lib/env-flags.ts:52-58, default OFF): when
# truthy, step 0155 calls Lido.resume() + setStakingLimit via LidoTemplate while the template
# still controls the Agent — before 0160 hands the Agent to Dual Governance. Without it, Lido
# ships isStopped=true / isStakingPaused=true and the first stake needs a full Voting→DG→
# Timelock round (~35 min on testnet delays). That blocked the 2026-08-19 dust round-trip and
# live deploy #3. This pipeline's purpose is a usable testnet stack, so default ON. Set
# PROTOCOL_ACTIVATION_ENABLED=0 to keep the historical paused bootstrap (then resume later
# with script/12_resume_lido.sh).
export PROTOCOL_ACTIVATION_ENABLED="${PROTOCOL_ACTIVATION_ENABLED:-1}"
echo "▸ PROTOCOL_ACTIVATION_ENABLED=${PROTOCOL_ACTIVATION_ENABLED} (core step 0155: Lido.resume before DG handoff)"
# core pins local-devnet's chainId to LOCAL_DEVNET_CHAIN_ID (default 32382) and hardhat aborts
# when it disagrees with the node — ours is a Sepolia fork, so say so.
export LOCAL_DEVNET_CHAIN_ID="${LOCAL_DEVNET_CHAIN_ID:-11155111}"
export RPC_URL="${L1_RPC}"
export GENESIS_TIME="${GENESIS_TIME:-1655733600}"          # Sepolia beacon genesis
export GENESIS_FORK_VERSION="${GENESIS_FORK_VERSION:-0x90000069}"
export DEPLOYER="${DEPLOYER_ADDRESS}"
export GAS_PRIORITY_FEE="${GAS_PRIORITY_FEE:-1}"
export GAS_MAX_FEE="${GAS_MAX_FEE:-100}"
export NETWORK_STATE_FILE="deployed-local.json"
# Scratch params: core's pristine file + the deployer vested 1M TLDO (~51.5% of supply), so the
# deployer alone meets Aragon's 50%-support/5%-quorum thresholds on a live network, where the
# default test holders can't be impersonated. Generated into state/ at run time (core reads
# SCRATCH_DEPLOY_CONFIG as a plain fs path, absolute ok) — no submodule edit to survive a fresh clone.
SCRATCH_PARAMS="${STATE_DIR}/deploy-params-testnet.toml"
awk -v l="\"${DEPLOYER_ADDRESS}\" = \"1000000000000000000000000\" # deployer (live voting majority)" \
    '{print} /^\[vesting\.holders\]/{print l}' \
    "${CORE_DIR}/scripts/scratch/deploy-params-testnet.toml" > "${SCRATCH_PARAMS}"
grep -q "${DEPLOYER_ADDRESS}" "${SCRATCH_PARAMS}" || { echo "✗ vesting.holders insert failed"; exit 1; }

# ── DG committees off the anvil keys ───────────────────────────────────────────────────────────
# core's pristine params seat every DG committee on an anvil dev account. Those private keys are
# public, so on a live chain they hand emergency control of Dual Governance to anyone; core's own
# assertNoDevCommitteesOnPublicChain (dg-checks.ts:56-83) refuses unless overridden. Substitute
# addresses derived from ACTORS_MNEMONIC so the guard passes on its own merits instead of being
# bypassed. Seven DISTINCT holders — the pristine file reuses anvil[1] for reseal AND proposer.
: "${ACTORS_MNEMONIC:?set ACTORS_MNEMONIC (.env) — DG committees must not use anvil dev keys}"
dg_addr() { cast wallet address --private-key \
    "$(cast wallet derive-private-key "${ACTORS_MNEMONIC}" "$1" | tr -d ' ' | grep -oE '0x[0-9a-fA-F]{64}' | tail -1)"; }
DG_RESEAL="$(dg_addr 4)"; DG_PROPOSER="$(dg_addr 5)"
DG_ACTIVATION="$(dg_addr 6)"; DG_EXECUTION="$(dg_addr 7)"
DG_TB1="$(dg_addr 8)"; DG_TB2="$(dg_addr 9)"; DG_TB3="$(dg_addr 10)"
sed -E -i.bak \
  -e "s|^(resealCommittee = )\"0x[0-9a-fA-F]{40}\".*|\1\"${DG_RESEAL}\" # ACTORS_MNEMONIC[4]|" \
  -e "s|^(emergencyGovernanceProposer = )\"0x[0-9a-fA-F]{40}\".*|\1\"${DG_PROPOSER}\" # ACTORS_MNEMONIC[5]|" \
  -e "s|^(emergencyActivationCommittee = )\"0x[0-9a-fA-F]{40}\".*|\1\"${DG_ACTIVATION}\" # ACTORS_MNEMONIC[6]|" \
  -e "s|^(emergencyExecutionCommittee = )\"0x[0-9a-fA-F]{40}\".*|\1\"${DG_EXECUTION}\" # ACTORS_MNEMONIC[7]|" \
  "${SCRATCH_PARAMS}"
# the three tiebreaker sub-committees are positional: one members=[…] line each, in file order
awk -v a="${DG_TB1}" -v b="${DG_TB2}" -v c="${DG_TB3}" '
  /^members = \[/ { n++; if (n==1) { print "members = [\"" a "\"] # ACTORS_MNEMONIC[8]"; next }
                          if (n==2) { print "members = [\"" b "\"] # ACTORS_MNEMONIC[9]"; next }
                          if (n==3) { print "members = [\"" c "\"] # ACTORS_MNEMONIC[10]"; next } }
  {print}' "${SCRATCH_PARAMS}" > "${SCRATCH_PARAMS}.tmp" && mv "${SCRATCH_PARAMS}.tmp" "${SCRATCH_PARAMS}"
rm -f "${SCRATCH_PARAMS}.bak"
# Fail loudly rather than deploying anvil committees: no anvil address may survive.
for a in 0x70997970C51812dc3A010C7d01b50e0d17dc79C8 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC \
         0x90F79bf6EB2c4f870365E785982E1f101E93b906 0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65 \
         0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc 0x976EA74026E726554dB657fA54763abd0C3a0aa9; do
    grep -qi "$a" "${SCRATCH_PARAMS}" && { echo "✗ anvil dev address $a survived the DG substitution"; exit 1; }
done
echo "▸ DG committees seated from ACTORS_MNEMONIC[4..10] (no anvil keys)"
export SCRATCH_DEPLOY_CONFIG="${SCRATCH_PARAMS}"
# Core's final state-mate check pins the LDO totalSupply to the DEFAULT params' holder sum
# (scripts/scratch/state-mate/scratch.yaml, the only quoted 19+-digit totalSupply). Recompute it
# from the params we actually deploy with, so the check stays meaningful instead of being skipped.
# (bc, not awk: the sum exceeds double precision.) Idempotent: re-patching writes the same value.
TOTAL_LDO=$( { awk -F'"' 'sec && /^\[/{sec=0} /^\[vesting\.holders\]/{sec=1;next} sec && $4 ~ /^[0-9]+$/{print $4}' "${SCRATCH_PARAMS}"; \
               sed -n 's/^unvestedTokensAmount = "\([0-9][0-9]*\)".*/\1/p' "${SCRATCH_PARAMS}"; } | paste -sd+ - | bc)
[ -n "${TOTAL_LDO}" ] || { echo "✗ failed to sum vesting holders"; exit 1; }
# temp+mv (not `sed -i ''`, which is BSD-only and breaks under GNU sed on a Linux CI runner).
# The edit lands in the SUBMODULE working tree, so keep a pristine copy and restore it below —
# otherwise every deploy leaves ../../components/core dirty outside patches/core/*.patch, which blocks
# `git merge` / `git submodule update` there ("local changes would be overwritten").
SM_YAML="scripts/scratch/state-mate/scratch.yaml"
SM_YAML_BACKUP="${STATE_DIR}/scratch.yaml.pristine"
cp "${SM_YAML}" "${SM_YAML_BACKUP}"
# Upstream step 0160 prunes older DG artifacts for the chain. Preserve pre-existing
# files, including untracked operator records, and restore them on success or failure.
DG_ARTIFACT_DIR="${CORE_DIR}/foundry/lib/dual-governance/deploy-artifacts"
DG_ARTIFACT_BACKUP="$(mktemp -d "${STATE_DIR}/dg-artifacts.XXXXXX")"
for artifact in "${DG_ARTIFACT_DIR}"/deploy-artifact-11155111-*.toml; do
    if [ -f "${artifact}" ]; then cp "${artifact}" "${DG_ARTIFACT_BACKUP}/"; fi
done
restore_sm_yaml() {
    if [ -f "${SM_YAML_BACKUP}" ]; then cp "${SM_YAML_BACKUP}" "${CORE_DIR}/${SM_YAML}" || return 1; fi
    for artifact in "${DG_ARTIFACT_BACKUP}"/*.toml; do
        if [ -f "${artifact}" ]; then cp "${artifact}" "${DG_ARTIFACT_DIR}/" || return 1; fi
    done
    rm -rf "${DG_ARTIFACT_BACKUP}"
    return 0
}
trap restore_sm_yaml EXIT
sed -E "s/(totalSupply: )\"[0-9]{19,}\"/\1\"${TOTAL_LDO}\"/" "${SM_YAML}" > "${SM_YAML}.tmp" \
    && mv "${SM_YAML}.tmp" "${SM_YAML}"
grep -q "totalSupply: \"${TOTAL_LDO}\"" "${SM_YAML}" \
    || { echo "✗ scratch.yaml totalSupply patch failed"; exit 1; }
# DG_ALLOW_DEV_COMMITTEES deliberately NOT set: the committees now come from ACTORS_MNEMONIC, so
# core's assertNoDevCommitteesOnPublicChain must pass on its own. If it ever fires again, the
# substitution above broke — do not paper over it with the override.
# DG_DEPLOYMENT_ENABLED unset == enabled.

# core's 0100-deploy-circuit-breaker step appends `--verify --etherscan-api-key` to its forge run
# whenever ETHERSCAN_API_KEY is set, with no fork check (steps/0100-deploy-circuit-breaker.ts:90).
# On a fork that submits a locally-deployed address to the real Etherscan and dies — rate limit or
# unknown address — aborting the migration AFTER a successful on-chain deploy. Fork contracts are
# not verifiable anyway; step 10 does the real Etherscan pass on live chains (and self-skips on
# anvil), so drop the key here.
if is_anvil "${L1_RPC}"; then
    unset ETHERSCAN_API_KEY
    echo "▸ fork substrate — ETHERSCAN_API_KEY unset for the core deploy (no fork verification)"
fi

# core's own post-deploy state-mate check (dao-deploy.sh:42) does not pass on core @ fe5aa4956:
# its scratch.yaml has drifted from the v3.1.0 ABIs (28 check errors across stakingRouter,
# oracleReportSanityChecker, validatorsExitBusOracle, accountingOracle, lido, …), and eight
# deployed contracts have no mapping in prepare-state-mate-check.ts (beaconChainDepositor,
# circuitBreaker, consolidationBus, consolidationGateway, consolidationMigrator,
# easyTrackEVMScriptExecutor, srLib, topUpGateway). Both are upstream content work — mapping the
# eight is not enough on its own, since state-mate rejects a .deployed anchor no config
# references, so each also needs a checks section. Default it off and flip it back with
# STATE_MATE_CHECK=on once core's scratch.yaml catches up. This is core's check of CORE; our own
# leaf verification (step 08, config/state-mate/wsteth.yaml) is unaffected and still gating.
export STATE_MATE_CHECK="${STATE_MATE_CHECK:-off}"
[ "${STATE_MATE_CHECK}" = "off" ] && echo "▸ core's own state-mate check disabled (broken upstream on this core revision)"

bash scripts/dao-deploy.sh
# mine.ts uses the anvil/hardhat-node `hardhat_mine` cheat to advance blocks — fork-only. On a live
# RPC that method doesn't exist (ProviderError) and would abort the script AFTER a successful deploy,
# before we extract addresses. Live chains mine on their own, so skip it there.
if is_anvil "${L1_RPC}"; then
    yarn hardhat --network "${NETWORK}" run --no-compile scripts/utils/mine.ts
else
    echo "▸ live RPC — skipping fork-only mine.ts (hardhat_mine unavailable)"
fi
popd >/dev/null

# ── Copy the deployment record + extract addresses we need ──
cp "${CORE_DIR}/deployed-local.json" "${STATE_DIR}/l1.deployed.json"
SRC="${STATE_DIR}/l1.deployed.json"

jq -n --slurpfile d "${SRC}" '
  ($d[0]) as $s | {
    chainId: 11155111,
    wstETH:       ($s.wstETH.address),
    stETH:        ($s["app:lido"].proxy.address // $s["app:lido"].proxy),
    lidoLocator:  ($s.lidoLocator.proxy.address // $s.lidoLocator.address),
    agent:        ($s["app:aragon-agent"].proxy.address // $s["app:aragon-agent"].proxy),
    voting:       ($s["app:aragon-voting"].proxy.address // $s["app:aragon-voting"].proxy),
    dg: {
      dualGovernance:  ($s.dualGovernance.address // $s["dg:dualGovernance"].address // $s["dg:dualGovernance"]),
      adminExecutor:   ($s["dg:adminExecutor"].address // $s["dg:adminExecutor"] // $s.adminExecutor.address),
      timelock:        ($s["dg:emergencyProtectedTimelock"].address // $s.emergencyProtectedTimelock.address // $s["dg:timelock"].address),
      resealManager:   ($s.resealManager.address // $s["dg:resealManager"].address // $s.resealManager)
    }
  }' > "${STATE_DIR}/l1.json"

echo ""
echo "▸ wrote ${STATE_DIR}/l1.json:"
jq '.' "${STATE_DIR}/l1.json"

# Sanity: every address downstream steps depend on must be present. If any extracted to null the
# core schema differs from our jq fallbacks — fail loudly (a single-field check would let e.g. a
# null wstETH/agent through and silently deploy pools against a non-existent token).
MISSING=""
for path in .wstETH .stETH .agent .voting \
            .dg.dualGovernance .dg.adminExecutor .dg.timelock; do
    [ "$(jq -r "${path} // empty" "${STATE_DIR}/l1.json")" != "" ] || MISSING="${MISSING} ${path}"
done
if [ -n "${MISSING}" ]; then
    echo ""
    echo "⚠ l1.json extraction produced null for:${MISSING}"
    echo "  relevant keys present in the core record:"
    jq -r 'keys[] | select(test("wsteth|steth|lido|agent|voting|dg|dual|admin|timelock|reseal|executor";"i"))' "${SRC}" || true
    exit 1
fi

# The deployed wstETH must carry the CCIP admin hook from patches/core/0001 and it must answer the
# deployer — that is the whole reason step 07 can self-register into the real Chainlink TAR via
# registerAdminViaGetCCIPAdmin instead of falling into its impersonation branch (which aborts on a
# live RPC). Assert it HERE, at the point the patch takes effect, so a lost or mis-applied 0001
# fails with an obvious message rather than five steps later inside the TAR registration.
L1_WSTETH="$(jq -r '.wstETH' "${STATE_DIR}/l1.json")"
CCIP_ADMIN="$(cast call "${L1_WSTETH}" "getCCIPAdmin()(address)" --rpc-url "${L1_RPC}" 2>/dev/null || true)"
if [ -z "${CCIP_ADMIN}" ]; then
    echo "✗ wstETH ${L1_WSTETH} has no getCCIPAdmin() — patches/core/0001 missing from this build."
    echo "  Run 'just patch-submodules', then redeploy (the hook is set in the constructor)."
    exit 1
fi
if ! eq "${CCIP_ADMIN}" "${DEPLOYER_ADDRESS}"; then
    echo "✗ wstETH getCCIPAdmin() = ${CCIP_ADMIN}, expected the deployer ${DEPLOYER_ADDRESS}."
    echo "  Step 07 registerAdminViaGetCCIPAdmin would revert CanOnlySelfRegister."
    exit 1
fi
echo "✓ wstETH getCCIPAdmin() = deployer (patch 0001 in effect)"

# When activation is on, fail here rather than discovering isStopped on the first stake.
# Core's isTruthyEnv accepts 1/true/yes/on (case-insensitive).
_act="$(printf '%s' "${PROTOCOL_ACTIVATION_ENABLED}" | tr '[:upper:]' '[:lower:]')"
case "${_act}" in
    1|true|yes|on)
        LIDO="$(jq -r '.stETH' "${STATE_DIR}/l1.json")"
        STOPPED="$(cast call "${LIDO}" 'isStopped()(bool)' --rpc-url "${L1_RPC}")"
        STAKING_PAUSED="$(cast call "${LIDO}" 'isStakingPaused()(bool)' --rpc-url "${L1_RPC}")"
        if [ "${STOPPED}" != "false" ] || [ "${STAKING_PAUSED}" != "false" ]; then
            echo "✗ PROTOCOL_ACTIVATION_ENABLED=${PROTOCOL_ACTIVATION_ENABLED} but Lido isStopped=${STOPPED} isStakingPaused=${STAKING_PAUSED}"
            echo "  core step 0155 did not leave the protocol operational."
            exit 1
        fi
        echo "✓ Lido isStopped=false isStakingPaused=false (protocol activation)"
        ;;
esac

echo "✓ step 01 done."
