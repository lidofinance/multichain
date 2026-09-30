#!/usr/bin/env bash
# Step 00b — apply the local patches this pipeline needs on top of the vendored submodules.
#
# Each submodule is pinned to an upstream commit, but the deploy needs a few files changed on top
# of it. Those changes live as patch files here rather than as uncommitted edits inside the
# submodules, so the deploy is reproducible from a fresh clone, the diff is visible in THIS repo's
# review, and `git submodule update` / a branch switch cannot silently drop them.
# See patches/README.md. Layout: patches/<name>/*.patch is applied to lib/<name>.
#
#   patches/core/  → ../../components/core   0001 TESTNET-ONLY getCCIPAdmin()/setCCIPAdmin() on wstETH (changes
#                               DEPLOYED BYTECODE; what lets step 07 self-register into the real
#                               Chainlink TAR), 0002 hardhat local-devnet fixed gas limit.
#   ../../components/ccip                  NO patches. Its former guardian-unseating patch was retired after
#                             lido-proposals removed GUARDIAN_ROLE from PoolOperationManager and
#                             its deployment inputs entirely.
#   components/wsteth-token is locally maintained and has no submodule patches.
#   Its ABI and on-chain authority checks live in step 03.
#
# Idempotent: a patch already present in the working tree is detected and skipped. apply/revert are
# all-or-nothing per submodule — every patch is classified before the tree is touched, so a patch
# gone stale against a moved submodule cannot leave the earlier ones applied behind it. Nothing is
# force-applied; a patch that neither applies nor is already applied aborts loudly, which is the
# signal that the submodule moved off the commit named in the patch's `Base:` header line.
#
# Usage:
#   bash script/00_patch_submodules.sh            apply (default; safe to re-run)
#   bash script/00_patch_submodules.sh --check    report only, no writes; exit 1 if any is missing
#   bash script/00_patch_submodules.sh --revert   reverse-apply, restoring pristine upstream
#
# Deliberately independent of _common.sh: this must run on a fresh clone, before any RPC is set.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
cd "${ROOT}"

PATCH_ROOT="${ROOT}/patches"

MODE="apply"
case "${1:-}" in
    "")        MODE="apply"  ;;
    --check)   MODE="check"  ;;
    --revert)  MODE="revert" ;;
    *) echo "✗ unknown argument '$1' (expected --check or --revert)"; exit 1 ;;
esac

[ -d "${PATCH_ROOT}" ] || { echo "✗ ${PATCH_ROOT} missing"; exit 1; }

FAIL=0
CHANGED=0
TOTAL=0

# applied <submodule_dir> <patch>: true when the patch is already present in that working tree.
# A patch that reverse-applies cleanly is, by definition, already there.
applied()   { git -C "$1" apply --check -R "$2" 2>/dev/null; }
# appliable <submodule_dir> <patch>: true when the patch applies cleanly to the current tree.
appliable() { git -C "$1" apply --check "$2" 2>/dev/null; }

# stuck <submodule_dir> <patch_dir> <name>: neither state — report the base-commit mismatch that
# almost always causes it.
stuck() {
    echo "    ✗ $3: neither applies nor is already applied"
    echo "        HEAD is:       $(git -C "$1" rev-parse --short HEAD)"
    echo "        patch was cut against: $(sed -n 's/^Base: [^@]*@ //p' "$2/$3" | head -1)"
    echo "        Likely a partially-applied patch, or the submodule moved off its pinned commit."
}

# patch_submodule <name>: run MODE over patches/<name>/*.patch against lib/<name>.
patch_submodule() {
    local name="$1"
    local sub="${ROOT}/../../components/${name}"
    local dir="${PATCH_ROOT}/${name}"

    if [ ! -e "${sub}/.git" ]; then
        echo "  ⚠ lib/${name} not initialized — skipping its patches (just init / init-thirdparty)"
        return
    fi

    shopt -s nullglob
    local patches=("${dir}"/*.patch)
    shopt -u nullglob
    [ "${#patches[@]}" -gt 0 ] || return 0
    TOTAL=$((TOTAL + ${#patches[@]}))

    echo "  lib/${name} @ $(git -C "${sub}" rev-parse --short HEAD) — ${#patches[@]} patch(es)"

    # Classify everything before touching the tree (apply/revert only).
    if [ "${MODE}" != "check" ]; then
        local blocked=0 p name_
        for p in "${patches[@]}"; do
            name_="$(basename "${p}")"
            if ! applied "${sub}" "${p}" && ! appliable "${sub}" "${p}"; then
                stuck "${sub}" "${dir}" "${name_}"; blocked=1; FAIL=1
            fi
        done
        if [ "${blocked}" = "1" ]; then
            echo "    → lib/${name} left untouched; re-cut the patches above and update their Base: lines"
            return
        fi
    fi

    local p n
    for p in "${patches[@]}"; do
        n="$(basename "${p}")"
        case "${MODE}" in
            apply)
                if applied "${sub}" "${p}"; then echo "    ✔ ${n}: already applied"
                else git -C "${sub}" apply "${p}"; echo "    + ${n}: applied"; CHANGED=$((CHANGED + 1)); fi
                ;;
            check)
                if applied "${sub}" "${p}"; then echo "    ✔ ${n}: applied"
                elif appliable "${sub}" "${p}"; then
                    echo "    ✗ ${n}: NOT applied (run 'just patch-submodules')"; FAIL=1
                else stuck "${sub}" "${dir}" "${n}"; FAIL=1; fi
                ;;
            revert)
                if applied "${sub}" "${p}"; then
                    git -C "${sub}" apply -R "${p}"; echo "    - ${n}: reverted"; CHANGED=$((CHANGED + 1))
                else echo "    ✔ ${n}: not applied; nothing to revert"; fi
                ;;
        esac
    done
}

# The CCIP tree is intentionally patch-free, so the patch probes above cannot detect a stale
# checkout after the parent repo's gitlink moves. Check the deployment-critical source properties
# directly before any caller can compile and broadcast a POM from the wrong vendor revision.
check_ccip_base_shape() {
    local sub="${ROOT}/../../components/ccip"
    [ -e "${sub}/.git" ] || return 0

    local expected_rev
    # The index also covers a newly added or intentionally updated, uncommitted gitlink.
    expected_rev="$(git -C "${ROOT}/../.." ls-files --stage -- components/ccip | awk '$1 == "160000" && $3 == "0" {print $2}')"
    if [ -z "${expected_rev}" ]; then
        echo "  ✗ components/ccip: missing or conflicted gitlink in the parent index"
        FAIL=1
        return
    fi
    local actual_rev
    actual_rev="$(git -C "${sub}" rev-parse HEAD)"
    local pom="${sub}/chains/evm/contracts/lido-hvmv/PoolOperationManager.sol"
    local deploy="${sub}/chains/evm/contracts/lido-hvmv/script/deployment/1_Deploy.s.sol"
    local bad=0

    if [ "${actual_rev}" != "${expected_rev}" ]; then
        echo "  ✗ ../../components/ccip: ${actual_rev} checked out; expected pinned ${expected_rev}"
        bad=1
    fi
    if ! git -C "${sub}" diff --quiet -- "${pom#${sub}/}" "${deploy#${sub}/}" \
            || ! git -C "${sub}" diff --cached --quiet -- "${pom#${sub}/}" "${deploy#${sub}/}"; then
        echo "  ✗ ../../components/ccip: PoolOperationManager or its deployment script has local modifications"
        bad=1
    fi

    if [ ! -f "${pom}" ] || [ ! -f "${deploy}" ]; then
        echo "  ✗ ../../components/ccip: current checkout does not contain the POM deployment sources"
        FAIL=1
        return
    fi

    grep -q 'UUPSUpgradeable' "${pom}" \
        || { echo "  ✗ ../../components/ccip: PoolOperationManager is not UUPSUpgradeable"; bad=1; }
    grep -q '__UUPSUpgradeable_init();' "${pom}" \
        || { echo "  ✗ ../../components/ccip: PoolOperationManager does not initialize its UUPS base"; bad=1; }
    for role in PROPOSAL_QUEUE_HALT_ROLE CROSS_CHAIN_TRANSFERS_PAUSE_ROLE PROPOSAL_QUEUE_RESTART_ROLE CROSS_CHAIN_TRANSFERS_UNPAUSE_ROLE; do
        grep -q "bytes32 public constant ${role}" "${pom}" \
            || { echo "  ✗ ../../components/ccip: missing operational role ${role}"; bad=1; }
    done
    grep -q 'function isSelectorBlocked(' "${pom}" \
        || { echo "  ✗ ../../components/ccip: missing boolean selector-blocking API"; bad=1; }
    if grep -qE 'enum ProposalMode|function (veto|approve)\(' "${pom}"; then
        echo "  ✗ ../../components/ccip: retired proposal modes/veto/approve API is present"
        bad=1
    fi
    grep -qE 'internal view override onlyRole\(DEFAULT_ADMIN_ROLE\)' "${pom}" \
        || { echo "  ✗ ../../components/ccip: _authorizeUpgrade is not DEFAULT_ADMIN_ROLE-only"; bad=1; }
    if grep -qE '^[[:space:]]*bytes32 public constant GUARDIAN_ROLE|^[[:space:]]*address guardian;' "${pom}" \
            || grep -qE '^[[:space:]]*guardian:' "${deploy}"; then
        echo "  ✗ ../../components/ccip: legacy PoolOperationManager guardian authority is present"
        bad=1
    fi

    if [ "${bad}" = "1" ]; then
        echo "    update ../../components/ccip to the parent repo's pinned UUPS-capable revision before deploying"
        FAIL=1
    else
        echo "  ✔ ../../components/ccip base: UUPS admin gate present; legacy guardian authority absent"
    fi
}

echo "▸ patches: ${PATCH_ROOT}"
for d in "${PATCH_ROOT}"/*/; do
    patch_submodule "$(basename "${d}")"
done
check_ccip_base_shape

echo ""
if [ "${FAIL}" = "1" ]; then
    echo "✗ submodule patches: FAILED — resolve the ✗ items above before deploying."
    exit 1
fi
case "${MODE}" in
    apply)  echo "✓ submodule patches applied (${CHANGED} newly applied, $(( TOTAL - CHANGED )) already present)." ;;
    check)  echo "✓ submodule patches: all ${TOTAL} applied." ;;
    revert) echo "✓ submodule patches reverted (${CHANGED} undone) — submodules back to pristine upstream." ;;
esac
