#!/usr/bin/ksh
# =============================================================================
# lib/utils.ksh - Shared Utility Functions
# Logging, JSON parsing, API polling helpers
# Compatible with AIX ksh and IBM i PASE ksh
# =============================================================================

LOG_FILE="${LOG_DIR:-/tmp}/powervs_$(date +%Y%m%d_%H%M%S).log"

# -----------------------------------------------------------------------------
# log_info / log_warn / log_error
# Timestamped logging to stdout and log file
# -----------------------------------------------------------------------------
log_info() {
    MSG="[$(date '+%Y-%m-%d %H:%M:%S')] [INFO]  $*"
    print "$MSG"
    print "$MSG" >> "$LOG_FILE"
}

log_warn() {
    MSG="[$(date '+%Y-%m-%d %H:%M:%S')] [WARN]  $*"
    print "$MSG"
    print "$MSG" >> "$LOG_FILE"
}

log_error() {
    MSG="[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $*"
    print "$MSG" >&2
    print "$MSG" >> "$LOG_FILE"
}

# -----------------------------------------------------------------------------
# json_value KEY JSON_STRING
# Extracts a string value from flat JSON using awk. No jq dependency.
# Example: json_value "status" '{"status":"active","id":"abc"}'
# -----------------------------------------------------------------------------
json_value() {
    KEY="$1"
    JSON="$2"
    print "$JSON" | awk -F"\"${KEY}\":\"" '{print $2}' | awk -F'"' '{print $1}'
}

# -----------------------------------------------------------------------------
# json_value_num KEY JSON_STRING
# Extracts a numeric value from flat JSON using awk.
# -----------------------------------------------------------------------------
json_value_num() {
    KEY="$1"
    JSON="$2"
    print "$JSON" | awk -F"\"${KEY}\":" '{print $2}' | awk -F'[,}]' '{print $1}' | tr -d ' '
}

# -----------------------------------------------------------------------------
# api_call METHOD URL [DATA]
# Makes an authenticated cURL call to the PowerVS API.
# Sets global API_RESPONSE and API_HTTP_STATUS.
# Returns 0 on HTTP 2xx, 1 otherwise.
# -----------------------------------------------------------------------------
api_call() {
    METHOD="$1"
    URL="$2"
    DATA="${3:-}"

    ensure_valid_token
    if [ $? -ne 0 ]; then
        log_error "Cannot proceed without a valid IAM token."
        return 1
    fi

    if [ -n "$DATA" ]; then
        RESPONSE=$(curl -s -w "\n%{http_code}" -X "$METHOD" "$URL" \
            -H "Authorization: Bearer ${IAM_TOKEN}" \
            -H "CRN: ${POWER_CRN}" \
            -H "Content-Type: application/json" \
            -d "$DATA")
    else
        RESPONSE=$(curl -s -w "\n%{http_code}" -X "$METHOD" "$URL" \
            -H "Authorization: Bearer ${IAM_TOKEN}" \
            -H "CRN: ${POWER_CRN}" \
            -H "Content-Type: application/json")
    fi

    API_HTTP_STATUS=$(print "$RESPONSE" | tail -1)
    API_RESPONSE=$(print "$RESPONSE" | head -n -1)

    case "$API_HTTP_STATUS" in
        200|201|202|204) return 0 ;;
        *)
            log_error "API call failed. Method: $METHOD URL: $URL Status: $API_HTTP_STATUS"
            log_error "Response: $API_RESPONSE"
            return 1
            ;;
    esac
}

# -----------------------------------------------------------------------------
# wait_for_status POLL_URL EXPECTED_STATUS MAX_WAIT_SECS POLL_INTERVAL
# Polls a URL until the returned JSON "status" field matches EXPECTED_STATUS.
# Times out after MAX_WAIT_SECS.
# -----------------------------------------------------------------------------
wait_for_status() {
    POLL_URL="$1"
    EXPECTED_STATUS="$2"
    MAX_WAIT="${3:-600}"
    INTERVAL="${4:-15}"
    ELAPSED=0

    log_info "Waiting for status '${EXPECTED_STATUS}' (max ${MAX_WAIT}s, polling every ${INTERVAL}s)..."

    while [ "$ELAPSED" -lt "$MAX_WAIT" ]; do
        sleep "$INTERVAL"
        ELAPSED=$(expr $ELAPSED + $INTERVAL)

        api_call "GET" "$POLL_URL"
        if [ $? -ne 0 ]; then
            log_warn "Poll attempt failed at ${ELAPSED}s. Retrying..."
            continue
        fi

        CURRENT_STATUS=$(json_value "status" "$API_RESPONSE")
        log_info "  Status at ${ELAPSED}s: ${CURRENT_STATUS}"

        if [ "$CURRENT_STATUS" = "$EXPECTED_STATUS" ]; then
            log_info "Desired status '${EXPECTED_STATUS}' reached after ${ELAPSED}s."
            return 0
        fi

        # Abort early on known failure states
        case "$CURRENT_STATUS" in
            error|failed|ERROR|FAILED)
                log_error "Operation entered failure state: $CURRENT_STATUS"
                return 2
                ;;
        esac
    done

    log_error "Timed out after ${MAX_WAIT}s waiting for status '${EXPECTED_STATUS}'."
    return 1
}

# -----------------------------------------------------------------------------
# require_vars VAR1 VAR2 ...
# Checks that all named environment variables are set and non-empty.
# -----------------------------------------------------------------------------
require_vars() {
    MISSING=0
    for VAR in "$@"; do
        eval VAL=\$$VAR
        if [ -z "$VAL" ]; then
            log_error "Required variable '$VAR' is not set. Check config/powervs.conf."
            MISSING=1
        fi
    done
    return $MISSING
}
