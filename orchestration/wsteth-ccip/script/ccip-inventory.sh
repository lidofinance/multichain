#!/usr/bin/env bash
# ccip-inventory.sh — inventory of the CCIP *system* contracts live on one chain, each with the
# version it reports about itself on-chain.
#
# Why not just read the Chainlink registry API? Because it is only a starting point:
#   * /chains publishes five addresses per chain (router, rmn, registryModule, tokenAdminRegistry,
#     tokenPoolFactory) and NO version for any of them;
#   * /lanes adds a version, but only for onRamp / offRamp;
#   * everything else that makes a lane work — RMNRemote, FeeQuoter, NonceManager, the wrapped
#     native and LINK fee tokens, and in 1.7/2.0 the CCV stack (VersionedVerifierResolver, Proxy,
#     CommitteeVerifier, Executor) — is not in the API at all.
# So the API supplies the entry points and this script CRAWLS outward from them over the RPC:
# it follows the address fields of each contract's config getters and asks everything it reaches
# for its own typeAndVersion(). The result is what the chain says, and it is diffed against what
# the API says at the end.
#
# Note on the /lanes shape: in a lane keyed "A_to_B" BOTH ramps live on A — onRamp is A's outbound
# ramp for that lane, offRamp is A's inbound ramp for the reverse direction. (Verified on-chain:
# 11155111_to_5003's offRamp has code on Sepolia, not on Mantle Sepolia.)
#
# Usage:
#   script/ccip-inventory.sh <rpc-url|chain-slug> [options]
#
#     <chain-slug>          resolved as $RPC_<UPPERCASED_SLUG> (forks-tray convention), e.g.
#                           `sepolia` -> $RPC_SEPOLIA, `mantle_sepolia_remote` -> $RPC_MANTLE_SEPOLIA_REMOTE
#   --peer <id|slug|name>   keep only the ramps serving lanes with this counterparty, and print
#                           the lane table for the pair
#   --legacy                also include the pre-1.6 per-lane ramps (Sepolia has ~35 of them)
#   --deep                  also walk authorized-caller sets and keep token pools (slow, noisy)
#   --owners                add an OWNER column (owner(), where implemented)
#   --env testnet|mainnet   registry environment (default: auto-detect from the chain id)
#   --chain-id <id>         skip `cast chain-id` (for a fork that reports a custom id)
#   --json                  emit JSON instead of the table
#   --refresh               bypass the API response cache (~/$TMPDIR, 60 min)
#   --jobs <n>              RPC concurrency (default 8)
#   -h | --help
#
# Requires cast (foundry), curl, jq. Read-only: eth_chainId, eth_getCode, eth_call only.
set -euo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
API="https://docs.chain.link/api/ccip/v1"
CACHE_DIR="${TMPDIR:-/tmp}/ccip-inventory-cache"
CACHE_TTL_MIN="${CCIP_CACHE_TTL_MIN:-60}"
TAB="$(printf '\t')"

# ── re-entrant workers (one process per RPC call, driven by xargs -P) ──────────────────────────
case "${1:-}" in
  __probe)   # __probe <rpc> <addr> -> "<addr>\t<yes|no>\t<typeAndVersion|ERC20:SYM|->"
    _code="$(cast code "$3" --rpc-url "$2" 2>/dev/null || echo 0x)"
    if [ -z "${_code}" ] || [ "${_code}" = "0x" ]; then printf '%s\tno\t-\n' "$3"; exit 0; fi
    _tv="$(cast call "$3" 'typeAndVersion()(string)' --rpc-url "$2" 2>/dev/null | tr -d '"' || true)"
    if [ -z "${_tv}" ]; then
        _sym="$(cast call "$3" 'symbol()(string)' --rpc-url "$2" 2>/dev/null | tr -d '"' || true)"
        [ -n "${_sym}" ] && _tv="ERC20:${_sym}"
    fi
    printf '%s\tyes\t%s\n' "$3" "${_tv:--}"; exit 0 ;;
  __call)    # __call <rpc> "<addr>|<sig>|<label>" -> "<addr-word>\t<label>" per address found
    _rpc="$2"; IFS='|' read -r _a _sig _label <<EOF2
$3
EOF2
    _out="$(cast call "${_a}" "${_sig}" --rpc-url "${_rpc}" 2>/dev/null || true)"
    [ -n "${_out}" ] || exit 0
    # A getter declared with a return type (`foo()(address)`) comes back from cast already
    # decoded — a checksummed address, not 32-byte words.
    if [ "${#_out}" = 42 ]; then
        printf '%s\t%s\n' "$(printf '%s' "${_out}" | tr 'A-F' 'a-f')" "${_label}"; exit 0
    fi
    printf '%s' "${_out}" | tr -d '\n' | sed 's/^0x//' | fold -w64 \
      | grep -E '^0{24}[0-9a-f]{40}$' | grep -Ev '^0{48}' | sed 's/^0\{24\}/0x/' | sort -u \
      | sed "s|\$|${TAB}${_label}|"
    exit 0 ;;
  __owner)   cast call "$3" 'owner()(address)' --rpc-url "$2" 2>/dev/null | head -1 || true; exit 0 ;;
esac

usage() { sed -n '2,/^set -euo/p' "${SELF}" | sed 's/^# \{0,1\}//; $d'; }
die() { echo "✗ $*" >&2; exit 1; }
lc() { printf '%s' "$1" | tr 'A-F' 'a-f'; }

# ── args ──────────────────────────────────────────────────────────────────────────────────────
RPC_ARG=""; PEER=""; LEGACY=0; DEEP=0; OWNERS=0; ENVIRON="auto"; CHAIN_ID=""; AS_JSON=0; REFRESH=0; JOBS=8
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help)  usage; exit 0 ;;
        --peer)     PEER="$2"; shift 2 ;;
        --legacy)   LEGACY=1; shift ;;
        --deep)     DEEP=1; shift ;;
        --owners)   OWNERS=1; shift ;;
        --env)      ENVIRON="$2"; shift 2 ;;
        --chain-id) CHAIN_ID="$2"; shift 2 ;;
        --json)     AS_JSON=1; shift ;;
        --refresh)  REFRESH=1; shift ;;
        --jobs)     JOBS="$2"; shift 2 ;;
        --rpc)      RPC_ARG="$2"; shift 2 ;;
        -*)         die "unknown option $1 (see --help)" ;;
        *)          [ -z "${RPC_ARG}" ] || die "unexpected argument $1"; RPC_ARG="$1"; shift ;;
    esac
done
[ -n "${RPC_ARG}" ] || { usage; exit 1; }
for t in cast curl jq; do command -v "${t}" >/dev/null || die "${t} not found in PATH"; done

case "${RPC_ARG}" in
    http://*|https://*|ws://*|wss://*) RPC="${RPC_ARG}" ;;
    *)  RPC_VAR="RPC_$(printf '%s' "${RPC_ARG}" | tr '[:lower:]-' '[:upper:]_')"
        RPC="${!RPC_VAR:-}"
        [ -n "${RPC}" ] || die "'${RPC_ARG}' is not a URL and \$${RPC_VAR} is unset — pass an RPC URL or export ${RPC_VAR}" ;;
esac

WORK="$(mktemp -d)"; trap 'rm -rf "${WORK}"' EXIT

# ── registry API (cached) ─────────────────────────────────────────────────────────────────────
mkdir -p "${CACHE_DIR}"
api_get() { # <cache-name> <url> -> path
    local f="${CACHE_DIR}/$1.json"
    if [ "${REFRESH}" = 1 ] || [ ! -s "${f}" ] || [ -n "$(find "${f}" -mmin "+${CACHE_TTL_MIN}" 2>/dev/null)" ]; then
        curl -fsS "$2" -o "${f}.tmp" || die "registry API fetch failed: $2"
        mv "${f}.tmp" "${f}"
    fi
    printf '%s' "${f}"
}

[ -n "${CHAIN_ID}" ] || CHAIN_ID="$(cast chain-id --rpc-url "${RPC}" 2>/dev/null)" || die "cannot reach RPC ${RPC}"
[ -n "${CHAIN_ID}" ] || die "cannot read chain id from ${RPC}"

if [ "${ENVIRON}" = "auto" ]; then ENV_TRY="testnet mainnet"; else ENV_TRY="${ENVIRON}"; fi
CHAINS_JSON=""
for e in ${ENV_TRY}; do
    f="$(api_get "chains-${e}" "${API}/chains?environment=${e}&outputKey=chainId")"
    if [ "$(jq -r --arg c "${CHAIN_ID}" '.data.evm[$c] // empty' "${f}")" != "" ]; then
        CHAINS_JSON="${f}"; ENVIRON="${e}"; break
    fi
done
[ -n "${CHAINS_JSON}" ] || die "chain id ${CHAIN_ID} is not a CCIP chain in the registry (${ENV_TRY// / / })"
LANES_JSON="$(api_get "lanes-${ENVIRON}" "${API}/lanes?environment=${ENVIRON}&outputKey=chainId")"

CHAIN_ENTRY="$(jq -c --arg c "${CHAIN_ID}" '.data.evm[$c]' "${CHAINS_JSON}")"
ce() { printf '%s' "${CHAIN_ENTRY}" | jq -r "$1"; }
CHAIN_NAME="$(ce .displayName)"; CHAIN_SELECTOR="$(ce .selector)"; CHAIN_SLUG="$(ce .internalId)"

PEER_ID=""
if [ -n "${PEER}" ]; then
    # Resolve --peer to exactly one chain, or refuse. "sepolia" alone matches 25 testnets by
    # substring, so anything short of an unambiguous hit has to be reported, not guessed.
    # The `ethereum-testnet-<q>` / `ethereum-mainnet-<q>` alias makes the bare L1 name work.
    PEER_CANDIDATES="$(jq -r --arg p "${PEER}" '
        ($p|ascii_downcase) as $q | ($q|gsub("[_ ]";"-")) as $qd | ($q|gsub("[_-]";" ")) as $qs
        | .data.evm | to_entries
        | map(. + {score:
            (if   .key == $p or .value.selector == $p                    then 0
             elif (.value.internalId|ascii_downcase)  == $qd             then 1
             elif (.value.internalId|ascii_downcase)  == "ethereum-testnet-" + $qd then 1
             elif (.value.internalId|ascii_downcase)  == "ethereum-mainnet-" + $qd then 1
             elif (.value.displayName|ascii_downcase) == $qs             then 1
             elif (.value.internalId|ascii_downcase)  | test($qd)        then 2
             elif (.value.displayName|ascii_downcase) | test($qs)        then 2
             else 9999 end)})
        | map(select(.score < 9999)) | sort_by(.score)
        | .[] | "\(.score)\t\(.key)\t\(.value.displayName)\t\(.value.internalId)"' "${CHAINS_JSON}")"
    [ -n "${PEER_CANDIDATES}" ] || die "--peer '${PEER}' matches no ${ENVIRON} chain in the registry"
    PEER_BEST="$(printf '%s\n' "${PEER_CANDIDATES}" | head -1 | cut -f1)"
    PEER_HITS="$(printf '%s\n' "${PEER_CANDIDATES}" | awk -F'\t' -v b="${PEER_BEST}" '$1==b')"
    if [ "$(printf '%s\n' "${PEER_HITS}" | wc -l | tr -d ' ')" -gt 1 ]; then
        printf '✗ --peer %s is ambiguous — pass a chain id, a selector or the exact name:\n' "${PEER}" >&2
        printf '%s\n' "${PEER_HITS}" | awk -F'\t' '{printf "    %-10s %-38s %s\n", $2, $4, $3}' >&2
        exit 1
    fi
    PEER_ID="$(printf '%s' "${PEER_HITS}" | cut -f2)"
    PEER_NAME="$(printf '%s' "${PEER_HITS}" | cut -f3)"
fi

# ── seeds ─────────────────────────────────────────────────────────────────────────────────────
FOUND="${WORK}/found.tsv"; QUEUE="${WORK}/queue"; SEEN="${WORK}/seen"; : >"${FOUND}"; : >"${QUEUE}"; : >"${SEEN}"
API_SEEDED="${WORK}/api_seeded"; : >"${API_SEEDED}"
add() { # <addr> <source> [hint] — hint labels a contract that has no typeAndVersion()
    local a; a="$(lc "${1:-}")"
    case "${a}" in ""|0x0000000000000000000000000000000000000000) return 0 ;; esac
    printf '%s\t%s\t%s\n' "${a}" "$2" "${3:--}" >>"${FOUND}"
    printf '%s\n' "${a}" >>"${QUEUE}"
}

add "$(ce .router)"             "registry:router"
add "$(ce .rmn)"                "registry:rmn"
add "$(ce .registryModule)"     "registry:registryModule"     "RegistryModuleOwnerCustom"
add "$(ce .tokenAdminRegistry)" "registry:tokenAdminRegistry"
add "$(ce .tokenPoolFactory)"   "registry:tokenPoolFactory"

# Lane ramps. Both ramps of a "<this chain>_to_<peer>" entry live on this chain (see header note).
LANE_TSV="${WORK}/lanes.tsv"
jq -r --arg c "${CHAIN_ID}" '
    .data | to_entries[] | .value as $l
    | select(($l.sourceChain.chainId|tostring) == $c)
    | ($l.destinationChain.chainId|tostring) as $peer
    | ($l.destinationChain.displayName) as $pname
    | ( ["onRamp",  $l.onRamp.address  // "", $l.onRamp.version  // "", $peer, $pname],
        ["offRamp", $l.offRamp.address // "", $l.offRamp.version // "", $peer, $pname] )
    | select(.[1] != "") | @tsv' "${LANES_JSON}" | sort -u >"${LANE_TSV}"

lane_kept() { # <version> — pre-1.6 means a per-lane ramp from the legacy topology
    case "$1" in 1.[0-5].*|1.[0-5]) [ "${LEGACY}" = 1 ] ;; *) return 0 ;; esac
}
while IFS="${TAB}" read -r kind addr ver peer pname; do
    lane_kept "${ver}" || continue
    [ -z "${PEER_ID}" ] || [ "${peer}" = "${PEER_ID}" ] || continue
    add "${addr}" "lanes:${kind}"
done <"${LANE_TSV}"
awk -F'\t' '{print $1}' "${FOUND}" | sort -u >"${API_SEEDED}"

# ── crawl ─────────────────────────────────────────────────────────────────────────────────────
# Each contract is asked for typeAndVersion(); the answer picks the config getters worth calling.
# Return data is scanned RAW for 32-byte words shaped like an address, so struct layouts can differ
# across 1.5 / 1.6 / 2.0 without breaking anything.
CONTRACTS="${WORK}/contracts.tsv"; NOCODE="${WORK}/nocode"; : >"${CONTRACTS}"; : >"${NOCODE}"

probes_for() { # <type>
    local extra=""
    [ "${DEEP}" = 1 ] && extra="getAllAuthorizedCallers()"
    case "$1" in
        Router*)                    echo "getArmProxy()(address) getWrappedNative()(address)" ;;
        ARMProxy*|RMNProxy*)        echo "getARM()(address)" ;;
        OnRamp*|EVM2EVMOnRamp*)     echo "getStaticConfig() getDynamicConfig() getAllDestChainConfigs()" ;;
        OffRamp*|EVM2EVMOffRamp*|CCVAggregator*) echo "getStaticConfig() getDynamicConfig() getAllSourceChainConfigs()" ;;
        FeeQuoter*|PriceRegistry*)  echo "getStaticConfig() ${extra}" ;;
        NonceManager*)              echo "${extra}" ;;
        VersionedVerifierResolver*) echo "getAllInboundImplementations() getAllOutboundImplementations() getFeeAggregator()(address)" ;;
        Proxy*)                     echo "getTarget()(address) getFeeAggregator()(address)" ;;
        Executor*)                  echo "getAllowedCCVs() getDestChains() getDynamicConfig()" ;;
        *Verifier*|*Validator*)     echo "getDynamicConfig() getStaticConfig()" ;;
        TokenAdminRegistry*|TokenPoolFactory*|RegistryModuleOwnerCustom*|CommitStore*|ERC20*|unknown) echo "" ;;
        *)                          echo "getStaticConfig() getDynamicConfig() getTarget()(address)" ;;
    esac
}

# Token pools are per-token, not system infrastructure; they are also the shape a *remote* chain's
# ramp address takes when it happens to collide with a local deployment (1.6 lane configs store the
# peer ramp as a 32-byte-padded address, indistinguishable from a local one).
is_system_type() {
    case "$1" in
        TokenPoolFactory*) return 0 ;;
        *TokenPool*|*Pool)  [ "${DEEP}" = 1 ] ;;
        *)                  return 0 ;;
    esac
}

MAX_CONTRACTS=400; round=0
while [ -s "${QUEUE}" ] && [ "${round}" -lt 8 ]; do
    round=$((round+1)); BATCH="${WORK}/batch.${round}"
    if [ -s "${SEEN}" ]; then sort -u "${QUEUE}" | grep -vxF -f "${SEEN}" >"${BATCH}" || true
    else sort -u "${QUEUE}" >"${BATCH}"; fi
    : >"${QUEUE}"
    [ -s "${BATCH}" ] || break
    cat "${BATCH}" >>"${SEEN}"; sort -u -o "${SEEN}" "${SEEN}"

    xargs -P "${JOBS}" -I{} "${SELF}" __probe "${RPC}" {} <"${BATCH}" >"${WORK}/ident.${round}"

    CALLS="${WORK}/calls.${round}"; : >"${CALLS}"
    while IFS="${TAB}" read -r a has_code tv; do
        if [ "${has_code}" != "yes" ]; then printf '%s\n' "${a}" >>"${NOCODE}"; continue; fi
        case "${tv}" in
            -)          type="unknown"; ver="-" ;;
            ERC20:*)    type="ERC20 ${tv#ERC20:}"; ver="-" ;;
            *\ [0-9]*)  type="${tv% *}"; ver="${tv##* }" ;;
            *)          type="${tv}"; ver="-" ;;
        esac
        printf '%s\t%s\t%s\n' "${a}" "${type}" "${ver}" >>"${CONTRACTS}"
        is_system_type "${type}" || continue
        [ "$(wc -l <"${CONTRACTS}")" -lt "${MAX_CONTRACTS}" ] || continue
        for sig in $(probes_for "${type}"); do
            printf '%s|%s|onchain:%s%s.%s\n' "${a}" "${sig}" "${type}" \
                   "$([ "${ver}" = "-" ] || printf ' %s' "${ver}")" "${sig%%(*}" >>"${CALLS}"
        done
    done <"${WORK}/ident.${round}"

    [ -s "${CALLS}" ] || continue
    xargs -P "${JOBS}" -I{} "${SELF}" __call "${RPC}" {} <"${CALLS}" >"${WORK}/hits.${round}" || true
    while IFS="${TAB}" read -r w label; do add "${w}" "${label}"; done <"${WORK}/hits.${round}"
done

# ── rows ──────────────────────────────────────────────────────────────────────────────────────
rank() {
    case "$1" in
        Router*) echo 10 ;; ARMProxy*|RMNProxy*) echo 20 ;; RMNRemote*) echo 21 ;; RMN*) echo 22 ;;
        FeeQuoter*|PriceRegistry*) echo 30 ;; WrappedNative*) echo 31 ;; FeeToken*|LinkToken*) echo 32 ;; NonceManager*) echo 35 ;;
        TokenAdminRegistry*) echo 40 ;; RegistryModuleOwnerCustom*) echo 41 ;; TokenPoolFactory*) echo 42 ;;
        OnRamp*|EVM2EVMOnRamp*) echo 50 ;; OffRamp*|EVM2EVMOffRamp*|CCVAggregator*) echo 51 ;; CommitStore*) echo 52 ;;
        VersionedVerifierResolver*) echo 60 ;; Proxy*) echo 61 ;; *Verifier*|*Validator*) echo 62 ;; Executor*) echo 63 ;;
        *TokenPool*|*Pool) echo 75 ;; ERC20*) echo 80 ;; unknown) echo 90 ;; *) echo 70 ;;
    esac
}

ROWS="${WORK}/rows.tsv"; SKIPPED=0; : >"${ROWS}"
while IFS="${TAB}" read -r a type ver; do
    src="$(awk -F'\t' -v a="${a}" '$1==a{print $2}' "${FOUND}" | sort -u | paste -sd, -)"
    hint="$(awk -F'\t' -v a="${a}" '$1==a && $3!="-"{print $3; exit}' "${FOUND}")"
    [ "${type}" = "unknown" ] && [ -n "${hint}" ] && type="${hint}?"
    # Name the wrapped native, and drop stray ERC20s — a peer chain's token address read out of a
    # lane config can collide with a real local token; only the API or Router vouching for it counts.
    case "${type}" in
      ERC20\ *)
        if   printf '%s' "${src}" | grep -q 'getWrappedNative'; then type="WrappedNative (${type#ERC20 })"
        elif printf '%s' "${src}" | grep -q 'FeeQuoter.*getStaticConfig\|PriceRegistry.*getStaticConfig'; then type="FeeToken (${type#ERC20 })"
        elif ! grep -qxF "${a}" "${API_SEEDED}"; then SKIPPED=$((SKIPPED+1)); continue; fi ;;
    esac
    # An address the crawl reached but that names no type is not evidence of anything — most are
    # a peer chain's ramp read out of a lane config. Keep it only if the API vouched for it.
    if [ "${type}" = "unknown" ] && ! grep -qxF "${a}" "${API_SEEDED}"; then SKIPPED=$((SKIPPED+1)); continue; fi
    is_system_type "${type}" || { SKIPPED=$((SKIPPED+1)); continue; }
    lanes="-"
    case "${type}" in
        OnRamp*|EVM2EVMOnRamp*) lanes="$(awk -F'\t' -v a="${a}" 'tolower($2)==a && $1=="onRamp"'  "${LANE_TSV}" | wc -l | tr -d ' ') out" ;;
        OffRamp*|EVM2EVMOffRamp*|CCVAggregator*) lanes="$(awk -F'\t' -v a="${a}" 'tolower($2)==a && $1=="offRamp"' "${LANE_TSV}" | wc -l | tr -d ' ') in" ;;
    esac
    owner="-"
    [ "${OWNERS}" = 1 ] && owner="$("${SELF}" __owner "${RPC}" "${a}")"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(rank "${type}")" "${type}" "${ver}" \
           "$(cast to-check-sum-address "${a}" 2>/dev/null || printf '%s' "${a}")" "${lanes}" "${src}" "${owner:--}" >>"${ROWS}"
done < <(sort -u "${CONTRACTS}")
sort -t"${TAB}" -k1,1n -k3,3r -k2,2 "${ROWS}" -o "${ROWS}"

# ── output ────────────────────────────────────────────────────────────────────────────────────
if [ "${AS_JSON}" = 1 ]; then
    jq -Rn --arg chain "${CHAIN_NAME}" --arg id "${CHAIN_ID}" --arg sel "${CHAIN_SELECTOR}" \
           --arg slug "${CHAIN_SLUG}" --arg env "${ENVIRON}" --arg rpc "${RPC}" '
      def dash: if . == "-" then null else . end;
      { chain: {displayName:$chain, chainId:($id|tonumber), selector:$sel, internalId:$slug,
                environment:$env, rpc:$rpc},
        contracts: [ inputs | split("\t")
                     | {type:.[1], version:(.[2]|dash), address:.[3], lanes:(.[4]|dash),
                        discoveredVia:(.[5]|split(",")), owner:(.[6]|dash)} ] }' <"${ROWS}"
    exit 0
fi

if [ -t 1 ]; then B="$(printf '\033[1m')"; N="$(printf '\033[0m')"; else B=""; N=""; fi
printf '\n%s%s%s  ·  chain id %s  ·  selector %s  ·  %s\n' "${B}" "${CHAIN_NAME}" "${N}" "${CHAIN_ID}" "${CHAIN_SELECTOR}" "${ENVIRON}"
printf 'rpc %s\n' "${RPC}"
printf 'fee tokens (registry): %s\n' "$(ce '.feeTokens | join(", ")')"
printf 'lanes: %s outbound, %s inbound%s\n\n' \
  "$(awk -F'\t' '$1=="onRamp"'  "${LANE_TSV}" | wc -l | tr -d ' ')" \
  "$(awk -F'\t' '$1=="offRamp"' "${LANE_TSV}" | wc -l | tr -d ' ')" \
  "$([ -n "${PEER_ID}" ] && printf ' (ramps filtered to the --peer lanes)' || true)"

{
    if [ "${OWNERS}" = 1 ]; then printf 'CONTRACT\tVERSION\tADDRESS\tLANES\tOWNER\tDISCOVERED VIA\n'
    else printf 'CONTRACT\tVERSION\tADDRESS\tLANES\tDISCOVERED VIA\n'; fi
    while IFS="${TAB}" read -r r type ver addr lanes src owner; do
        if [ "${OWNERS}" = 1 ]; then printf '%s\t%s\t%s\t%s\t%s\t%s\n' "${type}" "${ver}" "${addr}" "${lanes}" "${owner}" "${src}"
        else printf '%s\t%s\t%s\t%s\t%s\n' "${type}" "${ver}" "${addr}" "${lanes}" "${src}"; fi
    done <"${ROWS}"
} | column -t -s "${TAB}"

# ── diff: what the API claims vs what the chain reports ───────────────────────────────────────
printf '\n%sregistry API ↔ on-chain%s\n' "${B}" "${N}"
onchain_ver() { awk -F'\t' -v a="$(lc "$1")" 'tolower($4)==a{print $2" "$3; exit}' "${ROWS}"; }
armp="$(cast call "$(ce .router)" 'getArmProxy()(address)' --rpc-url "${RPC}" 2>/dev/null || echo '?')"
if [ "$(lc "${armp}")" = "$(lc "$(ce .rmn)")" ]; then printf '  ✓ router.getArmProxy() == registry.rmn\n'
else printf '  ⚠ router.getArmProxy() = %s but registry.rmn = %s\n' "${armp}" "$(ce .rmn)"; fi
for a in $(awk -F'\t' '$2 ~ /^registry:/ {print $1}' "${FOUND}" | sort -u); do
    grep -qxF "${a}" "${NOCODE}" 2>/dev/null && printf '  ⚠ registry address %s has NO CODE on this rpc\n' "${a}"
done
awk -F'\t' '{print tolower($2)"\t"$3"\t"$1}' "${LANE_TSV}" | sort -u | while IFS="${TAB}" read -r addr apiver kind; do
    lane_kept "${apiver}" || continue
    [ -z "${PEER_ID}" ] || grep -qi "${addr}" <(awk -F'\t' -v p="${PEER_ID}" '$4==p{print tolower($2)}' "${LANE_TSV}") || continue
    got="$(onchain_ver "${addr}")"
    if [ -z "${got}" ]; then printf '  ⚠ lanes API %-7s %s: not found on this chain\n' "${kind}" "${addr}"
    elif [ "${got##* }" != "${apiver}" ]; then printf '  ⚠ lanes API %-7s %s: API says %s, chain says %s\n' "${kind}" "${addr}" "${apiver}" "${got}"
    else printf '  ✓ lanes API %-7s %s == %s\n' "${kind}" "${addr}" "${got}"; fi
done
[ "${SKIPPED}" = 0 ] || printf '  · %s reached address(es) hidden (token pools / untyped — peer-chain ramps read out of lane configs); --deep to show\n' "${SKIPPED}"
nc="$(sort -u "${NOCODE}" 2>/dev/null | wc -l | tr -d ' ')"
[ "${nc}" = 0 ] || printf '  · %s referenced address(es) have no code (fee aggregators, admins, remote-chain addresses)\n' "${nc}"

# ── the requested pair ────────────────────────────────────────────────────────────────────────
if [ -n "${PEER_ID}" ]; then
    printf '\n%slanes with %s (chain id %s)%s\n' "${B}" "${PEER_NAME}" "${PEER_ID}" "${N}"
    { printf 'DIR\tRAMP\tAPI VER\tON-CHAIN\tADDRESS\tSUPPORTED TOKENS\n'
      jq -r --arg c "${CHAIN_ID}" --arg p "${PEER_ID}" '
        .data | to_entries[] | .value as $l
        | ($l.sourceChain.chainId|tostring) as $s | ($l.destinationChain.chainId|tostring) as $d
        | select($s == $c and $d == $p)
        | ( ["out (send)",    "onRamp",  $l.onRamp.version,  $l.onRamp.address,  ($l.supportedTokens|join(","))],
            ["in  (receive)", "offRamp", $l.offRamp.version, $l.offRamp.address, ($l.supportedTokens|join(","))] )
        | @tsv' "${LANES_JSON}" \
      | while IFS="${TAB}" read -r dir kind apiver addr toks; do
            printf '%s\t%s\t%s\t%s\t%s\t%s\n' "${dir}" "${kind}" "${apiver}" "$(onchain_ver "${addr}" || echo '-')" "${addr}" "${toks}"
        done
    } | column -t -s "${TAB}"
fi
echo
