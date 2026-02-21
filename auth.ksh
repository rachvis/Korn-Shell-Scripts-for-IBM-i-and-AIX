#!/usr/bin/ksh
# =============================================================================
# lib/auth.ksh - IBM Cloud Authentication Library
# Handles IAM token acquisition and refresh for PowerVS API calls
# Compatible with AIX ksh and IBM i PASE ksh
# =============================================================================

# Source config if not already loaded
if [ -z "$CONFIG_LOADED" ]; then
    SCRIPT_DIR=$(dirname "$0")
    . "${SCRIPT_DIR}/../config/powervs.conf"
fi

TOKEN_FILE="/tmp/.ibmcloud_token_$$"
TOKEN_EXPIRY_FILE="/tmp/.ibmcloud_token_expiry_$$"

# -----------------------------------------------------------------------------
# get_iam_token
# Authenticates with IBM Cloud IAM using an API key and caches the token.
# Sets the global IAM_TOKEN variable.
# -----------------------------------------------------------------------------
get_iam_token() {
    print "INFO: Acquiring IBM Cloud IAM token..."

    RESPONSE=$(curl -s -w "\n%{http_code}" -X POST \
        "https://iam.cloud.ibm.com/identity/token" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "grant_type=urn:ibm:params:oauth:grant-type:apikey&apikey=${IBMCLOUD_API_KEY}")

    HTTP_STATUS=$(print "$RESPONSE" | tail -1)
    BODY=$(print "$RESPONSE" | head -n -1)

    if [ "$HTTP_STATUS" != "200" ]; then
        print "ERROR: Failed to acquire IAM token. HTTP Status: $HTTP_STATUS"
        print "ERROR: Response: $BODY"
        return 1
    fi

    # Parse access_token from JSON response using awk (no jq required on AIX/IBM i)
    IAM_TOKEN=$(print "$BODY" | awk -F'"access_token":"' '{print $2}' | awk -F'"' '{print $1}')
    EXPIRY=$(print "$BODY" | awk -F'"expires_in":' '{print $2}' | awk -F',' '{print $1}' | tr -d ' ')

    if [ -z "$IAM_TOKEN" ]; then
        print "ERROR: Could not parse IAM token from response."
        return 1
    fi

    # Cache token and expiry timestamp
    print "$IAM_TOKEN" > "$TOKEN_FILE"
    EXPIRY_TS=$(expr $(date +%s) + $EXPIRY - 60)   # refresh 60s before actual expiry
    print "$EXPIRY_TS" > "$TOKEN_EXPIRY_FILE"

    print "INFO: IAM token acquired successfully. Expires in ${EXPIRY}s."
    export IAM_TOKEN
    return 0
}

# -----------------------------------------------------------------------------
# ensure_valid_token
# Checks whether the cached token is still valid; refreshes if needed.
# -----------------------------------------------------------------------------
ensure_valid_token() {
    NOW=$(date +%s)

    if [ -f "$TOKEN_FILE" ] && [ -f "$TOKEN_EXPIRY_FILE" ]; then
        EXPIRY_TS=$(cat "$TOKEN_EXPIRY_FILE")
        if [ "$NOW" -lt "$EXPIRY_TS" ]; then
            IAM_TOKEN=$(cat "$TOKEN_FILE")
            export IAM_TOKEN
            return 0
        fi
        print "INFO: Cached IAM token has expired. Refreshing..."
    fi

    get_iam_token
    return $?
}

# -----------------------------------------------------------------------------
# cleanup_token_cache
# Removes cached token files on exit.
# -----------------------------------------------------------------------------
cleanup_token_cache() {
    rm -f "$TOKEN_FILE" "$TOKEN_EXPIRY_FILE"
}
trap cleanup_token_cache EXIT INT TERM
