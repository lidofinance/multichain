# Resolve state carried by the selected record, never by an unrelated active run.
# Sets STATE_DIR, L2_STATE_NAME and L2_STATE; caller verifies deployment identities.
is_active_record() {
    [ -d "${ROOT}/config/chains" ] &&
        [ "$(cd "${RECORD_PATH}" && pwd -P)" = "$(cd "${ROOT}/config/chains" && pwd -P)" ]
}

resolve_record_policy() {
    if is_active_record; then
        POLICY="${ROOT}/config/ccv-policy.json"
    else
        POLICY="${RECORD_PATH}/ccv-policy.json"
    fi
}

resolve_record_state() {
    local candidate
    local candidates=("${RECORD_PATH}/state")
    if is_active_record; then
        candidates+=("${ROOT}/state")
    elif [ "$(basename "${RECORD_PATH}")" = chains ]; then
        # Step-08 archives put chains/ and state/ beside each other.
        candidates+=("${RECORD_PATH}/../state")
    fi
    for candidate in "${candidates[@]}"; do
        L2_STATE_NAME="$(basename "${L2_STATE_FILE}")"
        if [ ! -f "${candidate}/${L2_STATE_NAME}" ] && [ -f "${candidate}/l2.json" ]; then
            # Old records without l2Chain predate selectable spokes and belong to Mantle.
            [ "$(jq -r '.l2Chain // "mantle_sepolia"' "${candidate}/l2.json")" = "${L2_CHAIN}" ] || continue
            L2_STATE_NAME=l2.json
        fi
        if [ -f "${candidate}/${L2_STATE_NAME}" ]; then
            STATE_DIR="${candidate}"
            L2_STATE="${STATE_DIR}/${L2_STATE_NAME}"
            return 0
        fi
    done
    echo "✗ Missing ${L2_CHAIN} state carried by ${RECORD_PATH}" >&2
    return 1
}
