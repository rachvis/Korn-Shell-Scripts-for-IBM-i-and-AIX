#!/usr/bin/ksh
# =============================================================================
# scripts/clone.ksh - Clone a PowerVS VM Instance (Volume-level Clone)
#
# This script creates a clone of the storage volumes attached to a PowerVS VM.
# Cloning operates at the volume level via the IBM Cloud PowerVS API.
# The clone can then be attached to a new VM for test/dev environments or
# for migration purposes.
#
# Usage:
#   ./scripts/clone.ksh -n <clone-name> [-s <source-pvm-id>] [-r <replication-enabled>]
#
# Options:
#   -n  Name prefix for cloned volumes (required)
#   -s  Source PVM Instance ID (optional, defaults to PVM_INSTANCE_ID in config)
#   -r  Enable replication on cloned volumes: true|false (default: false)
#
# Examples:
#   ./scripts/clone.ksh -n "prod-clone-20250821"
#   ./scripts/clone.ksh -n "dr-clone" -s "abc-123-def" -r true
# =============================================================================

SCRIPT_DIR=$(dirname "$0")
. "${SCRIPT_DIR}/../config/powervs.conf"
. "${SCRIPT_DIR}/../lib/auth.ksh"
. "${SCRIPT_DIR}/../lib/utils.ksh"

# --- Argument Parsing --------------------------------------------------------
CLONE_NAME=""
SOURCE_PVM_ID=""
REPLICATION="false"

while getopts "n:s:r:" OPT; do
    case "$OPT" in
        n) CLONE_NAME="$OPTARG" ;;
        s) SOURCE_PVM_ID="$OPTARG" ;;
        r) REPLICATION="$OPTARG" ;;
        *) print "Usage: $0 -n <clone-name> [-s <pvm-id>] [-r true|false]"; exit 1 ;;
    esac
done

if [ -z "$CLONE_NAME" ]; then
    log_error "Clone name prefix is required. Use -n <name>."
    exit 1
fi

# Use config PVM_INSTANCE_ID if not overridden
[ -z "$SOURCE_PVM_ID" ] && SOURCE_PVM_ID="$PVM_INSTANCE_ID"

require_vars IBMCLOUD_API_KEY POWER_CRN CLOUD_INSTANCE_ID SOURCE_PVM_ID POWER_API_ENDPOINT
[ $? -ne 0 ] && exit 1

log_info "========================================================"
log_info "PowerVS Volume Clone Script Starting"
log_info "Clone Name    : $CLONE_NAME"
log_info "Source PVM ID : $SOURCE_PVM_ID"
log_info "Replication   : $REPLICATION"
log_info "========================================================"

# --- Step 1: Retrieve Volume IDs Attached to Source VM -----------------------
log_info "STEP 1: Retrieving volumes attached to source VM..."

VM_URL="${POWER_API_ENDPOINT}/pcloud/v1/cloud-instances/${CLOUD_INSTANCE_ID}/pvm-instances/${SOURCE_PVM_ID}"
api_call "GET" "$VM_URL"
if [ $? -ne 0 ]; then
    log_error "Failed to retrieve VM details for ${SOURCE_PVM_ID}."
    exit 1
fi

# Extract volume IDs from pvmInstance response (volumeIDs array)
# Use awk to pull everything inside "volumeIDs":[...] 
VOLUME_IDS_RAW=$(print "$API_RESPONSE" | awk -F'"volumeIDs":\[' '{print $2}' | awk -F'\]' '{print $1}' | tr -d '"')
log_info "  Attached volumes: $VOLUME_IDS_RAW"

if [ -z "$VOLUME_IDS_RAW" ]; then
    log_error "No volumes found attached to VM ${SOURCE_PVM_ID}. Cannot clone."
    exit 1
fi

# Build JSON array of volume IDs for the clone request
VOL_ARRAY=$(print "$VOLUME_IDS_RAW" | awk -F',' '{
    printf "["
    for(i=1;i<=NF;i++){
        gsub(/^[ \t]+|[ \t]+$/, "", $i)
        printf "\"%s\"", $i
        if(i<NF) printf ","
    }
    printf "]"
}')

log_info "  Volume JSON array: $VOL_ARRAY"

# --- Step 2: Sync Filesystems Before Clone -----------------------------------
log_info "STEP 2: Syncing filesystems before clone operation..."
OS_TYPE=$(uname -s 2>/dev/null)
if [ "$OS_TYPE" = "AIX" ]; then
    sync; sync; sync
    log_info "  AIX filesystem sync complete."
else
    sync 2>/dev/null || true
    log_info "  Filesystem sync complete."
fi

# --- Step 3: Initiate Volume Clone via API -----------------------------------
log_info "STEP 3: Calling PowerVS API to start volume clone..."

# Build request body
REQUEST_BODY="{\"name\":\"${CLONE_NAME}\",\"volumeIDs\":${VOL_ARRAY},\"replicationEnabled\":${REPLICATION}}"
log_info "  Request body: $REQUEST_BODY"

CLONE_URL="${POWER_API_ENDPOINT}/pcloud/v1/cloud-instances/${CLOUD_INSTANCE_ID}/volumes/clone"
api_call "POST" "$CLONE_URL" "$REQUEST_BODY"
if [ $? -ne 0 ]; then
    log_error "Volume clone API call failed."
    exit 1
fi

CLONE_TASK_ID=$(json_value "cloneTaskID" "$API_RESPONSE")
if [ -z "$CLONE_TASK_ID" ]; then
    CLONE_TASK_ID=$(json_value "taskID" "$API_RESPONSE")
fi

log_info "  Clone task initiated. Task ID: ${CLONE_TASK_ID}"

# --- Step 4: Poll Clone Task Until Complete ----------------------------------
log_info "STEP 4: Waiting for clone task to complete..."

if [ -n "$CLONE_TASK_ID" ]; then
    TASK_URL="${POWER_API_ENDPOINT}/pcloud/v1/cloud-instances/${CLOUD_INSTANCE_ID}/volumes/clone/${CLONE_TASK_ID}"
    ELAPSED=0
    MAX_WAIT="${MAX_WAIT_SECS:-900}"
    INTERVAL="${POLL_INTERVAL_SECS:-20}"

    while [ "$ELAPSED" -lt "$MAX_WAIT" ]; do
        sleep "$INTERVAL"
        ELAPSED=$(expr $ELAPSED + $INTERVAL)

        api_call "GET" "$TASK_URL"
        TASK_STATUS=$(json_value "status" "$API_RESPONSE")
        TASK_PERCENT=$(json_value_num "percentComplete" "$API_RESPONSE")
        log_info "  Clone status at ${ELAPSED}s: ${TASK_STATUS} (${TASK_PERCENT:-?}% complete)"

        case "$TASK_STATUS" in
            completed|COMPLETED)
                log_info "  Clone completed successfully."
                break
                ;;
            failed|FAILED|error|ERROR)
                log_error "Clone task failed: $(json_value 'failedReason' "$API_RESPONSE")"
                exit 1
                ;;
        esac
    done

    if [ "$ELAPSED" -ge "$MAX_WAIT" ]; then
        log_error "Clone timed out after ${MAX_WAIT}s."
        exit 1
    fi
else
    log_warn "Could not retrieve clone task ID. Check IBM Cloud Console for clone status."
fi

# --- Step 5: Display Cloned Volume Information -------------------------------
log_info "STEP 5: Retrieving cloned volume details..."

api_call "GET" "$TASK_URL"
CLONED_VOLUMES=$(print "$API_RESPONSE" | awk -F'"clonedVolumes":\[' '{print $2}' | awk -F'\]' '{print $1}')

log_info "========================================================"
log_info "SUCCESS: Volume clone '${CLONE_NAME}' is complete."
log_info "Clone Task ID    : ${CLONE_TASK_ID}"
log_info "Cloned Volumes   : ${CLONED_VOLUMES}"
log_info "Log file         : ${LOG_FILE}"
log_info ""
log_info "Next steps:"
log_info "  1. Create a new PowerVS VM and attach the cloned volumes."
log_info "  2. Boot the new VM to validate the clone."
log_info "========================================================"
exit 0
