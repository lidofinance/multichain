#!/usr/bin/env bash
# Step 11 — self-execute the delivery leg of a CCIP 2.0 message on a lane whose required CCV set is
# our own (the deployed VersionedVerifierResolver -> DummyMessageIdVerifier).
#
# WHY THIS EXISTS. Chainlink's executor cannot deliver our messages: the pool's hooks declare OUR
# CCV as the required set (2_Configure.s.sol:200-218), and that verifier's storageLocations is the
# placeholder "dummy://message-id-verifier" (1_Deploy.s.sol:128-130) — nothing off-chain publishes
# its attestations. But `OffRamp.execute` is permissionless (OffRamp.sol:188-224: no executor check,
# no exclusivity window) and DummyMessageIdVerifier.verifyMessage checks only
# `VERSION_TAG(0xdecafbad) ++ messageId` (DummyMessageIdVerifier.sol:52-71) — no signature, no
# external proof. So anyone can build the proof and anyone can execute. See
# live-dust-roundtrip-plan.md §2/§6 (Route A).
#
# Usage:  script/11_self_execute.sh <l1-to-l2|l2-to-l1> <ccipSend tx hash>
# Env:    RECORD_DIR (default config/chains), L2_CHAIN, RPC_SEPOLIA, RPC_<L2 SLUG>,
#         DEPLOYER_PRIVATE_KEY (+ DEPLOYER_ADDRESS). DRY_RUN=1 simulates and stops.
#         OFFRAMP=0x… skips OffRamp 2.0.0 resolution.
set -euo pipefail

DIRECTION="${1:?usage: $0 <l1-to-l2|l2-to-l1> <tx hash>}"
TX="${2:?usage: $0 <l1-to-l2|l2-to-l1> <tx hash>}"

RECORD_DIR="${RECORD_DIR:-config/chains}"
L2_CHAIN="${L2_CHAIN:-mantle_sepolia}"
L2_RPC_VAR="RPC_$(echo "${L2_CHAIN}" | tr '[:lower:]' '[:upper:]')"
L1_RPC="${RPC_SEPOLIA:?set RPC_SEPOLIA}"
L2_RPC="${!L2_RPC_VAR:?set ${L2_RPC_VAR}}"

# topic-0 of OnRamp 2.0's CCIPMessageSent. Coupled to the event shape exactly as
# test/scenario/BridgeScenarioBase.sol:172 is — if a CCIP bump changes the event, both break here.
SIG="$(cast keccak 'CCIPMessageSent(uint64,address,bytes32,address,uint256,bytes,(address,uint32,uint32,uint256,bytes)[],bytes[])')"
VERSION_TAG="decafbad"   # DummyMessageIdVerifier.VERSION_TAG

case "${DIRECTION}" in
  l1-to-l2) SRC_CFG="${RECORD_DIR}/sepolia.json";      DST_CFG="${RECORD_DIR}/${L2_CHAIN}.json"; SRC_RPC="${L1_RPC}"; DST_RPC="${L2_RPC}" ;;
  l2-to-l1) SRC_CFG="${RECORD_DIR}/${L2_CHAIN}.json";  DST_CFG="${RECORD_DIR}/sepolia.json";     SRC_RPC="${L2_RPC}"; DST_RPC="${L1_RPC}" ;;
  *) echo "✗ direction must be l1-to-l2 or l2-to-l1"; exit 1 ;;
esac

SRC_ROUTER=$(jq -r '.ccip.router'          "${SRC_CFG}")
SRC_SELECTOR=$(jq -r '.ccip.chain_selector' "${SRC_CFG}")
DST_ROUTER=$(jq -r '.ccip.router'          "${DST_CFG}")
DST_SELECTOR=$(jq -r '.ccip.chain_selector' "${DST_CFG}")
DST_CCV=$(jq -r '.ccv.verifier_resolver'   "${DST_CFG}")
[ -n "${DST_CCV}" ] && [ "${DST_CCV}" != "null" ] || { echo "✗ no .ccv.verifier_resolver in ${DST_CFG}"; exit 1; }

tv() { cast call "$1" 'typeAndVersion()(string)' --rpc-url "$2" 2>/dev/null | tr -d '"' || true; }

# ── 1. Resolve the ramps ──────────────────────────────────────────────────────
ON_RAMP=$(cast call "${SRC_ROUTER}" 'getOnRamp(uint64)(address)' "${DST_SELECTOR}" --rpc-url "${SRC_RPC}")
ON_TV="$(tv "${ON_RAMP}" "${SRC_RPC}")"
echo "▸ source OnRamp  ${ON_RAMP}  (${ON_TV})"
[ "${ON_TV}" = "OnRamp 2.0.0" ] || { echo "✗ active OnRamp is not 2.0.0 — this lane cannot carry a self-executed 2.0 delivery"; exit 1; }

OFF_RAMP="${OFFRAMP:-}"
if [ -z "${OFF_RAMP}" ]; then
    # getOffRamps() returns [(sourceChainSelector, offRamp), …]; split on '(' and keep our lane's.
    for cand in $(cast call "${DST_ROUTER}" 'getOffRamps()((uint64,address)[])' --rpc-url "${DST_RPC}" \
                  | tr '(' '\n' | grep "^${SRC_SELECTOR} " | grep -o '0x[0-9a-fA-F]\{40\}' | sort -u); do
        if [ "$(tv "${cand}" "${DST_RPC}")" = "OffRamp 2.0.0" ]; then OFF_RAMP="${cand}"; break; fi
    done
fi
[ -n "${OFF_RAMP}" ] || { echo "✗ no OffRamp 2.0.0 registered on the destination for source selector ${SRC_SELECTOR}"; exit 1; }
echo "▸ dest OffRamp   ${OFF_RAMP}  ($(tv "${OFF_RAMP}" "${DST_RPC}"))"
echo "▸ dest CCV       ${DST_CCV}   ($(tv "${DST_CCV}" "${DST_RPC}"))"

# ── 2. Scrape CCIPMessageSent ─────────────────────────────────────────────────
RECEIPT="$(cast receipt "${TX}" --rpc-url "${SRC_RPC}" --json)"
LOG="$(echo "${RECEIPT}" | jq -c --arg a "$(echo "${ON_RAMP}" | tr '[:upper:]' '[:lower:]')" --arg s "${SIG}" \
        '.logs[] | select((.address|ascii_downcase) == $a) | select(.topics[0] == $s)' | head -1)"
[ -n "${LOG}" ] || { echo "✗ no CCIPMessageSent from ${ON_RAMP} in ${TX}"; exit 1; }

MESSAGE_ID="$(echo "${LOG}" | jq -r '.topics[3]')"   # messageId is the 3rd indexed arg
DATA="$(echo "${LOG}" | jq -r '.data')"
# Non-indexed args are (address,uint256,bytes,Receipt[],bytes[]). Decoding only the first three is
# safe and far easier to parse: head slot 3 holds the absolute offset to `encodedMessage`, so the
# trailing head slots we ignore do not shift anything.
ENCODED="$(cast abi-decode 'f()(address,uint256,bytes)' "${DATA}" | sed -n '3p' | tr -d '[:space:]')"
[ -n "${ENCODED}" ] || { echo "✗ could not decode encodedMessage"; exit 1; }

# The OffRamp derives the id as keccak256(encodedMessage) (OffRamp.sol:228). If this disagrees with
# the event's indexed messageId, the decode is wrong and the proof would be rejected.
DERIVED="$(cast keccak "${ENCODED}")"
[ "${DERIVED}" = "${MESSAGE_ID}" ] || { echo "✗ keccak256(encodedMessage)=${DERIVED} != event messageId=${MESSAGE_ID}"; exit 1; }

PROOF="0x${VERSION_TAG}${MESSAGE_ID#0x}"
echo "▸ messageId      ${MESSAGE_ID}  (keccak matches)"
echo "▸ encodedMessage ${#ENCODED} hex chars"
echo "▸ proof          ${PROOF}"

STATE_BEFORE="$(cast call "${OFF_RAMP}" 'getExecutionState(bytes32)(uint8)' "${MESSAGE_ID}" --rpc-url "${DST_RPC}")"
echo "▸ exec state     ${STATE_BEFORE}  (0=UNTOUCHED 1=IN_PROGRESS 2=SUCCESS 3=FAILURE)"

# The OffRamp exposes the authoritative required-CCV set for a message. Use it rather than
# reasoning about token-only-ness: the destination's _isTokenOnlyTransfer (OffRamp.sol:421-428) is
# true when the receiver is an EOA, INDEPENDENT of the message's gas limit — so an EOA-recipient
# token transfer needs only the pool's CCVs even though the source-side OnRamp saw a non-zero
# legacy gas limit and put the lane defaults in the message.
REQUIRED="$(cast call "${OFF_RAMP}" 'getCCVsForMessage(bytes)(address[],address[],uint8)' "${ENCODED}" --rpc-url "${DST_RPC}" 2>/dev/null | head -1)"
echo "▸ required CCVs  ${REQUIRED}"
if ! echo "${REQUIRED}" | grep -qi "${DST_CCV#0x}"; then
    echo "✗ our CCV ${DST_CCV} is not in the required set — aborting"; exit 1
fi
EXTRA="$(echo "${REQUIRED}" | grep -o '0x[0-9a-fA-F]\{40\}' | grep -iv "${DST_CCV#0x}" || true)"
if [ -n "${EXTRA}" ]; then
    echo "✗ the required set also contains CCVs we cannot attest:"; echo "${EXTRA}" | sed 's/^/    /'
    echo "  This message is deliverable by nobody. See live-dust-roundtrip-plan.md §7.2."
    exit 1
fi

# ── 3. Simulate, then send ────────────────────────────────────────────────────
FROM="${DEPLOYER_ADDRESS:-0x0000000000000000000000000000000000000001}"
# CAUTION: a clean simulation does NOT mean the message will be delivered. `execute` catches a
# reverting releaseOrMint and records FAILURE instead of reverting itself, so the outer call
# succeeds either way. This only rules out the outer-level checks (RMN, onramp, quorum, ABI).
# The real verdict is getExecutionState() after the send.
echo "▸ simulating execute(…) as ${FROM} — outer-level checks only …"
if ! cast call "${OFF_RAMP}" 'execute(bytes,address[],bytes[],uint32)' \
        "${ENCODED}" "[${DST_CCV}]" "[${PROOF}]" 0 \
        --rpc-url "${DST_RPC}" --from "${FROM}"; then
    echo "✗ simulation reverted — NOT sending. Most likely causes:"
    echo "   • the message is not a token-only transfer (non-zero ccipReceiveGasLimit or non-empty"
    echo "     data), so the required CCV set also contains the lane defaults we cannot attest;"
    echo "   • a finality condition the pool enforces in _validateReleaseOrMint is not yet met;"
    echo "   • rate limit, pause, or RMN curse."
    exit 1
fi
echo "✓ simulation clean"

if [ "${DRY_RUN:-0}" = "1" ]; then
    echo "▸ DRY_RUN=1 — stopping before the send. To execute:"
    echo "  cast send ${OFF_RAMP} 'execute(bytes,address[],bytes[],uint32)' \\"
    echo "    ${ENCODED} '[${DST_CCV}]' '[${PROOF}]' 0 --rpc-url <dst> --private-key \$DEPLOYER_PRIVATE_KEY"
    exit 0
fi

: "${DEPLOYER_PRIVATE_KEY:?set DEPLOYER_PRIVATE_KEY}"
# gasLimitOverride=0 means "no override" (OffRamp.sol:220-224); correct for a token-only transfer.
# NOTE the deployed 2.0.0 takes uint32 here, unlike the vendored revision's uint256.
# An explicit gas limit is REQUIRED. eth_estimateGas runs the same catch-and-record path, so when
# the message has not yet succeeded the estimate covers only the FAILING branch and under-provisions
# the real one — the sub-call then OOGs and the catch sees zero-length error data. That is exactly
# how the first live delivery failed (2026-08-19); the retry with an explicit limit used 260455 gas.
TXHASH="$(cast send "${OFF_RAMP}" 'execute(bytes,address[],bytes[],uint32)' \
    "${ENCODED}" "[${DST_CCV}]" "[${PROOF}]" 0 \
    --gas-limit "${EXEC_GAS_LIMIT:-3000000}" \
    --rpc-url "${DST_RPC}" --private-key "${DEPLOYER_PRIVATE_KEY}" --json 2>/dev/null | jq -r '.transactionHash')"
echo "▸ execute tx     ${TXHASH}"

STATE_AFTER="$(cast call "${OFF_RAMP}" 'getExecutionState(bytes32)(uint8)' "${MESSAGE_ID}" --rpc-url "${DST_RPC}")"
echo "▸ exec state now ${STATE_AFTER}  (expect 2 = SUCCESS)"
if [ "${STATE_AFTER}" != "2" ]; then
    echo "✗ not SUCCESS — decoding the failure from ExecutionStateChanged:"
    # event ExecutionStateChanged(uint64 indexed src, uint64 indexed msgNum, bytes32 indexed id,
    #                             uint8 state, bytes returnData)
    RET="$(cast receipt "${TXHASH}" --rpc-url "${DST_RPC}" --json 2>/dev/null \
           | jq -r --arg a "$(echo "${OFF_RAMP}" | tr '[:upper:]' '[:lower:]')" \
                  '.logs[] | select((.address|ascii_downcase)==$a) | .data' | head -1)"
    echo "    raw: ${RET}"
    echo "    (selector 0x9fe2f95a = TokenHandlingError(address,bytes); an EMPTY inner err means"
    echo "     the sub-call ran out of gas — retry with a higher EXEC_GAS_LIMIT)"
    exit 1
fi
echo "✓ delivered"
