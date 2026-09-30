#!/usr/bin/env bash
# Step 12 — resume the scratch Lido on L1 through the full governance chain.
#
# WHY. Needed only when the scratch Lido shipped paused (PROTOCOL_ACTIVATION_ENABLED off —
# live deploy #2 and #3). New deploys default that flag ON in script/01_l1_core_dg.sh, so
# Lido.resume() already ran in core step 0155 before DG took the Agent. When the flag was
# off: isStopped=true, isStakingPaused=true, wstETH totalSupply=0, and RESUME_ROLE sits
# with the AGENT, reachable only via Dual Governance. Lido.resume()
# (../../components/core/contracts/0.4.24/Lido.sol:527-532) does both _resume() and _resumeStaking().
# See live-dust-roundtrip-plan.md §4.0.
#
# Encoding follows the canonical DG helpers:
#   CallsScriptBuilder            (dual-governance/scripts/utils/CallsScriptBuilder.sol)
#   ExternalCallsBuilder.addForwardCall (…/ExternalCallsBuilder.sol:38-48)
#
#   Aragon EVM script = 0x00000001 ++ [ target(20) ++ dataLen(4) ++ data ]*
#
# Chain:  TokenManager.forward( script[ Voting.newVote( script[ DG.submitProposal(
#             [ {target: Agent, payload: Agent.forward( script[ Lido.resume() ] )} ] ) ] ) ] )
#
# Usage: script/12_resume_lido.sh build|submit|status|advance
#   build   — print every intermediate encoding, simulate the forward, send nothing
#   submit  — create the vote (TokenManager.forward) and cast the deployer's YES
#   status  — where the vote / DG proposal currently stands
#   advance — do whatever the next ready step is (executeVote / schedule / execute)
set -euo pipefail

L1_RPC="${RPC_SEPOLIA:?set RPC_SEPOLIA}"
MODE="${1:-build}"

# Addresses come FROM THE RECORD, never hardcoded: this script used to carry live deploy #2's six
# addresses inline, so pointing it at any other deployment (a parallel v2 pair, a fork) would have
# resumed the WRONG protocol — silently, since every call would have succeeded against the old one.
# RECORD_DIR selects which deployment; its sibling state/ holds core's own deploy output.
#   RECORD_DIR=config/chains            -> state/                      (the working record)
#   RECORD_DIR=config/chains.live-X     -> config/chains.live-X/state/ (a snapshot)
RECORD_DIR="${RECORD_DIR:-config/chains}"
case "${RECORD_DIR}" in
    config/chains) SDIR="state" ;;
    *)             SDIR="${RECORD_DIR}/state" ;;
esac
L1J="${SDIR}/l1.json"; L1D="${SDIR}/l1.deployed.json"
for f in "${L1J}" "${L1D}"; do
    [ -f "${f}" ] || { echo "✗ ${f} missing — run step 01 first, or point RECORD_DIR at a snapshot"; exit 1; }
done

# Aragon apps live under core's "app:<name>" keys; Dual Governance under .dg in our extract.
rec() { # rec <jq filter> <file> <label>
    local v; v="$(jq -r "$1 // empty" "$2")"
    [ -n "${v}" ] && [ "${v}" != "null" ] || { echo "✗ ${3} not found in $2 ($1)"; exit 1; }
    printf '%s' "${v}"
}
LIDO="$(rec '."app:lido".address // ."app:lido".proxy.address' "${L1D}" 'Lido')"
AGENT="$(rec '."app:aragon-agent".address // ."app:aragon-agent".proxy.address' "${L1D}" 'Aragon Agent')"
VOTING="$(rec '."app:aragon-voting".address // ."app:aragon-voting".proxy.address' "${L1D}" 'Aragon Voting')"
TOKEN_MANAGER="$(rec '."app:aragon-token-manager".address // ."app:aragon-token-manager".proxy.address' "${L1D}" 'Aragon TokenManager')"
DG="$(rec '.dg.dualGovernance' "${L1J}" 'DualGovernance')"
TIMELOCK="$(rec '.dg.timelock' "${L1J}" 'EmergencyProtectedTimelock')"
echo "▸ record ${RECORD_DIR} — Lido ${LIDO} · Agent ${AGENT} · Voting ${VOTING}"
echo "  TokenManager ${TOKEN_MANAGER} · DG ${DG} · Timelock ${TIMELOCK}"
METADATA="Resume Lido (stopped since scratch deploy) so wstETH can be minted for the CCIP dust round-trip"

hex()   { echo "${1#0x}"; }
# Aragon callsScript: spec id 0x00000001 then one (target, len, data) entry.
script1() { # $1=target $2=data(0x…)
    local d; d="$(hex "$2")"
    printf '0x00000001%s%08x%s' "$(hex "$1" | tr 'A-Z' 'a-z')" $(( ${#d} / 2 )) "$d"
}

RESUME=$(cast calldata 'resume()')
AGENT_SCRIPT=$(script1 "$LIDO" "$RESUME")
AGENT_FWD=$(cast calldata 'forward(bytes)' "$AGENT_SCRIPT")
SUBMIT=$(cast calldata 'submitProposal((address,uint96,bytes)[],string)' "[($AGENT,0,$AGENT_FWD)]" "$METADATA")
DG_SCRIPT=$(script1 "$DG" "$SUBMIT")
NEW_VOTE=$(cast calldata 'newVote(bytes,string,bool,bool)' "$DG_SCRIPT" "$METADATA" false false)
TM_SCRIPT=$(script1 "$VOTING" "$NEW_VOTE")

case "$MODE" in
build)
    echo "1. Lido.resume()                 ${RESUME}"
    echo "2. callsScript[Lido.resume()]     ${AGENT_SCRIPT}"
    echo "3. Agent.forward(#2)              ${AGENT_FWD:0:74}…  (${#AGENT_FWD} chars)"
    echo "4. DG.submitProposal([{Agent,0,#3}], metadata)  (${#SUBMIT} chars)"
    echo "5. callsScript[DG.submitProposal] (${#DG_SCRIPT} chars)"
    echo "6. Voting.newVote(#5, metadata, false, false)   (${#NEW_VOTE} chars)"
    echo "7. callsScript[Voting.newVote]    (${#TM_SCRIPT} chars)"
    echo
    echo "▸ simulating TokenManager.forward(#7) as ${DEPLOYER_ADDRESS} …"
    cast call "$TOKEN_MANAGER" 'forward(bytes)' "$TM_SCRIPT" --from "$DEPLOYER_ADDRESS" --rpc-url "$L1_RPC"
    echo "✓ simulation clean — run '$0 submit' to create the vote"
    ;;
submit)
    : "${DEPLOYER_PRIVATE_KEY:?}"
    BEFORE=$(cast call "$VOTING" 'votesLength()(uint256)' --rpc-url "$L1_RPC")
    echo "▸ votesLength before: ${BEFORE}"
    cast send "$TOKEN_MANAGER" 'forward(bytes)' "$TM_SCRIPT" \
        --rpc-url "$L1_RPC" --private-key "$DEPLOYER_PRIVATE_KEY" >/dev/null
    VOTE_ID=$((BEFORE))
    echo "▸ created vote #${VOTE_ID}; casting YES"
    cast send "$VOTING" 'vote(uint256,bool,bool)' "$VOTE_ID" true false \
        --rpc-url "$L1_RPC" --private-key "$DEPLOYER_PRIVATE_KEY" >/dev/null
    echo "$VOTE_ID" > "${SDIR}/resume-vote-id"
    echo "✓ vote #${VOTE_ID} created and supported"
    ;;
status)
    VOTE_ID=$(cat "${SDIR}/resume-vote-id" 2>/dev/null || echo "")
    [ -n "$VOTE_ID" ] && {
        echo "vote #${VOTE_ID}:"
        cast call "$VOTING" 'getVote(uint256)(bool,bool,uint64,uint64,uint64,uint64,uint256,uint256,uint256,bytes)' \
            "$VOTE_ID" --rpc-url "$L1_RPC" | head -9 | \
            paste -d' ' <(printf 'open\nexecuted\nstartDate\nsnapshotBlock\nsupportRequired\nminAcceptQuorum\nyea\nnay\nvotingPower\n') -
    }
    echo "timelock proposals: $(cast call "$TIMELOCK" 'getProposalsCount()(uint256)' --rpc-url "$L1_RPC")"
    echo "lido isStopped=$(cast call "$LIDO" 'isStopped()(bool)' --rpc-url "$L1_RPC") isStakingPaused=$(cast call "$LIDO" 'isStakingPaused()(bool)' --rpc-url "$L1_RPC")"
    ;;
*)
    echo "usage: $0 build|submit|status"; exit 1 ;;
esac
