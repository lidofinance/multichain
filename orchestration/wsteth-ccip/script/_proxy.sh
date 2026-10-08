# Proxy-admin helpers shared by steps 03, 07, 08 and 10.
# The deployment record selects the kind: a wstETHProxyAdmin pin means transparent;
# no pin means historical OssifiableProxy. RPC errors never select a fallback kind.
# Requires from _common.sh: eq.

# proxy_admin_kind <proxy> <rpc> <recordedProxyAdmin-or-empty>
# Prints "transparent <proxyAdmin> <owner>" | "legacy <admin>" | "none".
proxy_admin_kind() {
    local proxy="$1" rpc="$2" pinned="${3?recordedProxyAdmin argument required}" admin owner code
    admin="$(cast admin "${proxy}" --rpc-url "${rpc}")" || {
        echo "✗ Cannot read proxy admin for ${proxy}" >&2
        return 1
    }
    if [ -z "${admin}" ] || eq "${admin}" "0x0000000000000000000000000000000000000000"; then
        echo none
        return 0
    fi
    if [ -z "${pinned}" ]; then
        local legacy_admin
        legacy_admin="$(cast call "${proxy}" 'proxy__getAdmin()(address)' --rpc-url "${rpc}")" || {
            echo "✗ Cannot verify legacy proxy admin for ${proxy}; restore its recorded wstETHProxyAdmin if transparent" >&2
            return 1
        }
        eq "${legacy_admin}" "${admin}" || {
            echo "✗ Legacy proxy getter differs from its EIP-1967 admin slot" >&2; return 1;
        }
        echo "legacy ${admin}"
        return 0
    fi
    eq "${admin}" "${pinned}" || {
        echo "✗ ProxyAdmin ${admin} differs from recorded wstETHProxyAdmin ${pinned}." >&2
        return 1
    }
    code="$(cast code "${admin}" --rpc-url "${rpc}")" || {
        echo "✗ Cannot read proxy admin bytecode for ${admin}" >&2
        return 1
    }
    [ -n "${code}" ] && [ "${code}" != 0x ] || {
        echo "✗ No bytecode at recorded ProxyAdmin ${admin}" >&2; return 1;
    }
    owner="$(cast call "${admin}" "owner()(address)" --rpc-url "${rpc}")" || {
        echo "✗ Cannot read proxy admin owner for recorded ProxyAdmin ${admin}" >&2
        return 1
    }
    [ -n "${owner}" ] || { echo "✗ Empty proxy admin owner response" >&2; return 1; }
    echo "transparent ${admin} ${owner}"
}

legacy_pending_handover() {
    local info="$1" pinned="$2" deployer="$3" kind admin owner
    read -r kind admin owner <<<"${info}"
    [ "${kind}" = legacy ] && [ -z "${pinned}" ] && eq "${admin}" "${deployer}"
}

# assert_proxy_admin_owner <proxy> <rpc> <expected> <label> [recordedProxyAdmin] [info]: the upgrade right over <proxy> must rest
# with <expected> — ProxyAdmin.owner() for a transparent proxy, the admin itself for a legacy one.
# Prints the ✓ line on success; prints the ✗ diagnostic and returns 1 otherwise.
assert_proxy_admin_owner() {
    local proxy="$1" rpc="$2" expected="$3" label="$4" pinned="${5:-}" kind admin owner info
    info="${6:-}"
    if [ -z "${info}" ]; then info="$(proxy_admin_kind "${proxy}" "${rpc}" "${pinned}")" || return 1; fi
    read -r kind admin owner <<<"${info}"
    case "${kind}" in
        transparent)
            if [ -z "${pinned}" ] || ! eq "${admin}" "${pinned}"; then
                echo "✗ ${label}: ProxyAdmin ${admin} differs from recorded wstETHProxyAdmin ${pinned:-<missing>}."
                return 1
            fi
            eq "${owner}" "${expected}" || {
                echo "✗ ${label} ${proxy}: ProxyAdmin ${admin} is owned by ${owner}, expected ${expected}."
                return 1
            }
            echo "✓ ${label}: TransparentUpgradeableProxy, ProxyAdmin ${admin} owned by ${expected}" ;;
        legacy)
            if [ -n "${pinned}" ]; then
                echo "✗ ${label}: expected recorded ProxyAdmin ${pinned}, got a legacy or unreadable admin ${admin}."
                return 1
            fi
            eq "${admin}" "${expected}" || {
                echo "✗ ${label} ${proxy}: legacy OssifiableProxy admin is ${admin}, expected ${expected}."
                return 1
            }
            echo "✓ ${label}: legacy OssifiableProxy administered directly by ${expected}" ;;
        *)
            echo "✗ ${label} ${proxy}: the EIP-1967 admin slot is empty — not a proxy this pipeline recognises."
            return 1 ;;
    esac
}
