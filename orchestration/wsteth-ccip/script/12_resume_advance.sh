#!/usr/bin/env bash
# Step 12b — drive the resume vote through Voting -> DG -> Timelock -> Agent -> Lido.resume().
# Emits one line per stage (and on any failure) so it can be watched. See 12_resume_lido.sh.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
set -a; . ./.env; set +a
# NOTE: deliberately does NOT read RPC_SEPOLIA. The forks tray app exports that pointing at a local
# anvil fork (http://localhost:28002), which silently hijacked an earlier run: every cast call
# errored to empty and the wait loops span out. Override with RESUME_L1_RPC if needed.
L1_RPC="${RESUME_L1_RPC:-http://127.0.0.1:8546}"

# Addresses FROM THE RECORD, same discipline as 12_resume_lido.sh — these four used to be live
# deploy #2's, so a parallel v2 pair would have been driven against the OLD protocol with every
# call succeeding. RECORD_DIR selects the deployment; its sibling state/ holds core's output.
RECORD_DIR="${RECORD_DIR:-config/chains}"
case "${RECORD_DIR}" in
    config/chains) SDIR="state" ;;
    *)             SDIR="${RECORD_DIR}/state" ;;
esac
L1J="${SDIR}/l1.json"; L1D="${SDIR}/l1.deployed.json"
for f in "${L1J}" "${L1D}" "${SDIR}/resume-vote-id"; do
    [ -f "${f}" ] || { echo "FAILED: ${f} missing — run 12_resume_lido.sh submit first"; exit 1; }
done
rec() { local v; v="$(jq -r "$1 // empty" "$2")"
        [ -n "${v}" ] && [ "${v}" != "null" ] || { echo "FAILED: $3 not in $2 ($1)"; exit 1; }; printf '%s' "${v}"; }
VOTING="$(rec '."app:aragon-voting".address // ."app:aragon-voting".proxy.address' "${L1D}" 'Aragon Voting')"
LIDO="$(rec '."app:lido".address // ."app:lido".proxy.address' "${L1D}" 'Lido')"
DG="$(rec '.dg.dualGovernance' "${L1J}" 'DualGovernance')"
TIMELOCK="$(rec '.dg.timelock' "${L1J}" 'EmergencyProtectedTimelock')"
VOTE=$(cat "${SDIR}/resume-vote-id")

# Fail fast on a wrong/dead endpoint rather than timing out in a wait loop.
CHAIN=$(cast chain-id --rpc-url "$L1_RPC" 2>/dev/null || true)
[ "$CHAIN" = "11155111" ] || { echo "FAILED: $L1_RPC is not live Sepolia (chain-id='$CHAIN')"; exit 1; }
VOTES=$(cast call "$VOTING" 'votesLength()(uint256)' --rpc-url "$L1_RPC" 2>/dev/null || true)
[ -n "$VOTES" ] && [ "$VOTES" -gt "$VOTE" ] || { echo "FAILED: vote #$VOTE not present on $L1_RPC (votesLength='$VOTES')"; exit 1; }

call() { cast call "$@" --rpc-url "$L1_RPC" 2>/dev/null | head -1; }
send() { cast send "$@" --rpc-url "$L1_RPC" --private-key "$DEPLOYER_PRIVATE_KEY" >/dev/null 2>&1; }
# poll <fn-desc> <max-iters> <command…> — waits for the command to print "true"
waitfor() { local d="$1" n="$2"; shift 2
    for ((i=0;i<n;i++)); do [ "$("$@")" = "true" ] && return 0; sleep 15; done
    echo "FAILED: timed out waiting for $d"; return 1; }

waitfor "vote #$VOTE to become executable" 60 call "$VOTING" 'canExecute(uint256)(bool)' "$VOTE" || exit 1
echo "STAGE 1/3 · vote #$VOTE decided — executing"
send "$VOTING" 'executeVote(uint256)' "$VOTE" || { echo "FAILED: executeVote reverted"; exit 1; }
PID=$(call "$TIMELOCK" 'getProposalsCount()(uint256)')
[ -n "$PID" ] && [ "$PID" != "0" ] || { echo "FAILED: no DG proposal was submitted"; exit 1; }
echo "STAGE 1/3 ✓ · DG proposal #$PID submitted (afterSubmitDelay 900s)"

waitfor "proposal #$PID to become schedulable" 80 call "$DG" 'canScheduleProposal(uint256)(bool)' "$PID" || exit 1
echo "STAGE 2/3 · scheduling proposal #$PID"
send "$DG" 'scheduleProposal(uint256)' "$PID" || { echo "FAILED: scheduleProposal reverted"; exit 1; }
echo "STAGE 2/3 ✓ · scheduled (afterScheduleDelay 900s)"

waitfor "proposal #$PID to become executable" 80 call "$TIMELOCK" 'canExecute(uint256)(bool)' "$PID" || exit 1
echo "STAGE 3/3 · executing proposal #$PID"
send "$TIMELOCK" 'execute(uint256)' "$PID" || { echo "FAILED: timelock execute reverted"; exit 1; }

STOPPED=$(call "$LIDO" 'isStopped()(bool)'); PAUSED=$(call "$LIDO" 'isStakingPaused()(bool)')
echo "STAGE 3/3 ✓ · isStopped=$STOPPED isStakingPaused=$PAUSED"
if [ "$STOPPED" = "false" ] && [ "$PAUSED" = "false" ]; then echo "SUCCESS · Lido resumed"; exit 0; fi
echo "FAILED: Lido still not resumed"; exit 1
