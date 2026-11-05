#!/usr/bin/env bash
# Materialize the npm packages the vendored ccip branch (lido-2.0-expiry) imports but pnpm has not
# installed in this checkout, as REAL directories under components/ccip/chains/evm/node_modules:
#
#   @lido/wsteth-token                 ← components/wsteth-token/contracts (the token under review;
#                                        the branch pins this repository at f10eb8a, the rehearsal
#                                        must compile the working tree)
#   @openzeppelin/contracts-upgradeable-5.0.2 ← components/openzeppelin-contracts-upgradeable-5.0.2/contracts
#   @openzeppelin/contracts-4.9.2      ← a shallow clone of OpenZeppelin v4.9.2, verified against the
#                                        pinned commit (RBACTimelock's base)
#   @chainlink/ccip-owner-contracts    ← a clone of smartcontractkit/ccip-owner-contracts at the
#                                        commit the branch's package.json pins
#
# Copies, not symlinks: Foundry resolves a file to its canonical path before applying the package's
# context remappings (node_modules/@lido/wsteth-token/:@openzeppelin/contracts/=…), so a symlinked
# package compiles against the wrong OpenZeppelin edition. Idempotent; a later `pnpm install` in the
# ccip project replaces all four, after which this script restores the token sync.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
EVM="$(cd "${ROOT}/../../components/ccip/chains/evm" && pwd -P)"
NM="${EVM}/node_modules"
COMPONENTS="$(cd "${ROOT}/../../components" && pwd -P)"

materialize() {  # <package dir> <source dir>: replace a symlink or stale copy with a synced copy
    local pkg="$1" src="$2"
    [ -d "${src}" ] || { echo "✗ missing source ${src}"; exit 1; }
    if [ -L "${pkg}" ]; then rm "${pkg}"; fi
    mkdir -p "${pkg}"
    rsync -a --delete --exclude 'package.json' "${src}/" "${pkg}/"
}

OWNER_REV="$(jq -r '.dependencies["@chainlink/ccip-owner-contracts"] // .devDependencies["@chainlink/ccip-owner-contracts"]' "${EVM}/package.json" | sed -E 's/.*#//')"
[ -n "${OWNER_REV}" ] && [ "${OWNER_REV}" != "null" ] || { echo "✗ ccip package.json does not pin @chainlink/ccip-owner-contracts"; exit 1; }
OWNER="${NM}/@chainlink/ccip-owner-contracts"
if [ ! -f "${OWNER}/src/RBACTimelock.sol" ] || [ "$(git -C "${OWNER}" rev-parse HEAD 2>/dev/null || true)" != "${OWNER_REV}" ]; then
    rm -rf "${OWNER}"
    git clone --quiet https://github.com/smartcontractkit/ccip-owner-contracts "${OWNER}"
    git -C "${OWNER}" checkout --quiet "${OWNER_REV}"
fi
git -C "${OWNER}" diff --quiet HEAD -- src || { echo 'Modified ccip-owner-contracts sources'; exit 1; }
[ -z "$(git -C "${OWNER}" ls-files --others -- src)" ] || { echo 'Unrecorded ccip-owner-contracts sources'; exit 1; }
echo "  ✔ @chainlink/ccip-owner-contracts @ $(git -C "${OWNER}" rev-parse --short HEAD)"

# The commit the v4.9.2 tag named when it was pinned here (2026-10-25); RBACTimelock, and so the
# deployed LidoTimelock bytecode, compile against it. A tag can move, a commit cannot: the checkout
# is verified against the commit, and re-cloned when it is anything else.
OZ492_REV="e50c24f5839db17f46991478384bfda14acfb830"
OZ492="${NM}/.oz-4.9.2-src"
if [ ! -f "${OZ492}/contracts/access/AccessControl.sol" ] || [ "$(git -C "${OZ492}" rev-parse HEAD 2>/dev/null || true)" != "${OZ492_REV}" ]; then
    rm -rf "${OZ492}"
    git clone --quiet --depth 1 --branch v4.9.2 https://github.com/OpenZeppelin/openzeppelin-contracts "${OZ492}"
    [ "$(git -C "${OZ492}" rev-parse HEAD)" = "${OZ492_REV}" ] \
        || { echo "✗ the OpenZeppelin v4.9.2 tag resolves to $(git -C "${OZ492}" rev-parse HEAD), not the pinned ${OZ492_REV}"; exit 1; }
fi
git -C "${OZ492}" diff --quiet HEAD -- contracts || { echo 'Modified OpenZeppelin 4.9.2 sources'; exit 1; }
[ -z "$(git -C "${OZ492}" ls-files --others -- contracts)" ] || { echo 'Unrecorded OpenZeppelin 4.9.2 sources'; exit 1; }
materialize "${NM}/@openzeppelin/contracts-4.9.2" "${OZ492}/contracts"
printf '{"name":"@openzeppelin/contracts","version":"4.9.2"}\n' > "${NM}/@openzeppelin/contracts-4.9.2/package.json"
echo "  ✔ @openzeppelin/contracts-4.9.2 @ ${OZ492_REV:0:7} (tag v4.9.2)"

materialize "${NM}/@openzeppelin/contracts-upgradeable-5.0.2" "${COMPONENTS}/openzeppelin-contracts-upgradeable-5.0.2/contracts"
printf '{"name":"@openzeppelin/contracts-upgradeable","version":"5.0.2"}\n' > "${NM}/@openzeppelin/contracts-upgradeable-5.0.2/package.json"
echo "  ✔ @openzeppelin/contracts-upgradeable-5.0.2 (copy of components/openzeppelin-contracts-upgradeable-5.0.2)"

mkdir -p "${NM}/@lido"
# The package itself may be a symlink to the component (an earlier manual setup): replace it, or
# rsync would write through the link into the component's own tree.
if [ -L "${NM}/@lido/wsteth-token" ]; then rm "${NM}/@lido/wsteth-token"; fi
mkdir -p "${NM}/@lido/wsteth-token"
materialize "${NM}/@lido/wsteth-token/contracts" "${COMPONENTS}/wsteth-token/contracts"
cp "${COMPONENTS}/wsteth-token/package.json" "${NM}/@lido/wsteth-token/package.json"
cp "${COMPONENTS}/wsteth-token/LICENSE" "${NM}/@lido/wsteth-token/LICENSE"
if ! diff -rq "${COMPONENTS}/wsteth-token/contracts" "${NM}/@lido/wsteth-token/contracts" >/dev/null; then
    echo "✗ @lido/wsteth-token differs from components/wsteth-token/contracts after sync"; exit 1
fi
echo "  ✔ @lido/wsteth-token = components/wsteth-token/contracts (synced copy)"
