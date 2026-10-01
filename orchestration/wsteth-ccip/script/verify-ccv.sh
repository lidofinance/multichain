#!/usr/bin/env bash
# Standalone read-only inspection of the CCV configuration for the deployed wstETH lane
# sepolia <-> mantle_sepolia.
#
#   bash script/verify-ccv.sh
#
# Reads RECORD_DIR (defaults to the current public record), without loading .env.
# Read-only display; step 08 remains the authoritative pass/fail gate.
#
# Override an RPC from the environment if the public one is rate-limiting:
#   RPC_SEPOLIA=… RPC_MANTLE_SEPOLIA=… bash script/verify-ccv.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RECORD_DIR="${RECORD_DIR:-config/chains.live-mantle-2026-09-15}"
[[ "$RECORD_DIR" = /* ]] || RECORD_DIR="$ROOT/$RECORD_DIR"
command -v jq >/dev/null || { echo "jq is required"; exit 1; }
RPC_SEPOLIA="${RPC_SEPOLIA:-https://ethereum-sepolia-rpc.publicnode.com}"
RPC_MANTLE_SEPOLIA="${RPC_MANTLE_SEPOLIA:-https://rpc.sepolia.mantle.xyz}"
read_field() { jq -er "$2 | select(type == \"string\" and length > 0)" "$RECORD_DIR/$1.json"; }
L1_HOOKS="$(read_field sepolia .deployed.advanced_pool_hooks)"
L1_RESOLVER="$(read_field sepolia .ccv.verifier_resolver)"
L1_VERIFIER="$(read_field sepolia .ccv.message_id_verifier)"
L1_ROUTER="$(read_field sepolia .ccip.router)"
L1_POM="$(read_field sepolia .deployed.pool_operation_manager)"
L1_AGENT="$(read_field sepolia .governance_addresses.lido_dao_agent)"
L2_HOOKS="$(read_field mantle_sepolia .deployed.advanced_pool_hooks)"
L2_RESOLVER="$(read_field mantle_sepolia .ccv.verifier_resolver)"
L2_VERIFIER="$(read_field mantle_sepolia .ccv.message_id_verifier)"
L2_ROUTER="$(read_field mantle_sepolia .ccip.router)"
L2_POM="$(read_field mantle_sepolia .deployed.pool_operation_manager)"
L2_OPEXEC="$(read_field mantle_sepolia .governance_addresses.lido_dao_agent)"
SEPOLIA_SEL="$(read_field sepolia .ccip.chain_selector)"
MANTLE_SEPOLIA_SEL="$(read_field mantle_sepolia .ccip.chain_selector)"
DEPLOYER="$(read_field sepolia .governance_addresses.deployer)"

command -v cast >/dev/null || { echo "✗ cast not found (foundry: https://getfoundry.sh)"; exit 1; }

# side <label> <rpc> <hooks> <resolver> <verifier> <router> <remote selector>
side() {
    local label="$1" rpc="$2" hooks="$3" resolver="$4" verifier="$5" router="$6" remote_sel="$7"

    echo
    echo "══ ${label} — CCV config toward remote selector ${remote_sel}"
    echo

    echo "── PausableAdvancedPoolHooks ${hooks}"
    # Amount above which the threshold CCV sets apply; 0 = no amount-based escalation.
    echo -n "   getThresholdAmount   : "
    cast call "${hooks}" "getThresholdAmount()(uint256)" --rpc-url "${rpc}"
    echo "   getCCVConfig         : (outbound, thresholdOutbound, inbound, thresholdInbound)"
    cast call "${hooks}" "getCCVConfig(uint64)((address[],address[],address[],address[]))" \
        "${remote_sel}" --rpc-url "${rpc}" | sed 's/^/     /'

    echo "── VersionedVerifierResolver ${resolver}"
    echo -n "   owner                : "
    cast call "${resolver}" "owner()(address)" --rpc-url "${rpc}"
    echo -n "   getFeeAggregator     : "
    cast call "${resolver}" "getFeeAggregator()(address)" --rpc-url "${rpc}"

    echo "── DummyMessageIdVerifier ${verifier}"
    echo -n "   owner                : "
    cast call "${verifier}" "owner()(address)" --rpc-url "${rpc}"
    # allowlistAdmin can mutate per-lane sender allowlists (applyAllowlistUpdates is
    # owner-OR-allowlistAdmin) and is NOT rotated by the deploy pipeline — expect the deployer.
    echo -n "   getDynamicConfig     : "
    cast call "${verifier}" "getDynamicConfig()((address,address))" --rpc-url "${rpc}" \
        | tr -d '\n'
    echo "  (feeAggregator, allowlistAdmin)"

    # Whether that CCV quorum is enforced at all: only CCIP 2.0 ramps read it — the 2.0 OnRamp
    # the outbound set, the 2.0 OffRamp the inbound one. A lane can carry several ramp versions
    # side by side, so print every registered one with its version rather than assuming.
    echo "── Lane transport (router ${router})"
    local onramp
    onramp=$(cast call "${router}" "getOnRamp(uint64)(address)" "${remote_sel}" --rpc-url "${rpc}")
    echo "   onRamp   ${onramp}  $(cast call "${onramp}" "typeAndVersion()(string)" --rpc-url "${rpc}" 2>/dev/null || echo '(no typeAndVersion)')"
    # cast renders each pair as "(<selector> [sci], 0x<addr>)" — drop the sci-notation hint, then
    # keep the addresses registered for this lane's remote selector.
    cast call "${router}" "getOffRamps()((uint64,address)[])" --rpc-url "${rpc}" \
        | tr -d ' ' | sed 's/\[[0-9.e+]*\]//g' \
        | grep -oE '\([0-9]+,0x[0-9a-fA-F]{40}\)' | tr -d '()' \
        | awk -F, -v sel="${remote_sel}" '$1 == sel { print $2 }' \
        | while read -r off; do
              [ -n "${off}" ] || continue
              echo "   offRamp  ${off}  $(cast call "${off}" "typeAndVersion()(string)" --rpc-url "${rpc}" 2>/dev/null || echo '(no typeAndVersion)')"
          done
}

echo "lane: sepolia (${SEPOLIA_SEL}) <-> mantle_sepolia (${MANTLE_SEPOLIA_SEL})"
echo "record: ${RECORD_DIR}"

side "L1 sepolia" "${RPC_SEPOLIA}" \
     "${L1_HOOKS}" "${L1_RESOLVER}" "${L1_VERIFIER}" "${L1_ROUTER}" "${MANTLE_SEPOLIA_SEL}"

side "L2 mantle_sepolia" "${RPC_MANTLE_SEPOLIA}" \
     "${L2_HOOKS}" "${L2_RESOLVER}" "${L2_VERIFIER}" "${L2_ROUTER}" "${SEPOLIA_SEL}"

cat <<LEGEND

── Expected (per config/state-mate/wsteth.yaml; asserted by script/08_verify_state.sh)
   threshold 0, CCV set 1-of-1 = the resolver, both directions, threshold sets empty
   L1  CCV owner = POM ${L1_POM}   feeAggregator = Agent  ${L1_AGENT}
   L2  CCV owner = POM ${L2_POM}   feeAggregator = OpExec ${L2_OPEXEC}
   both  allowlistAdmin = deployer ${DEPLOYER}  (residual EOA power, not rotated by the pipeline)
LEGEND
