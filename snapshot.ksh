#!/usr/bin/ksh
# =============================================================================
# scripts/snapshot.ksh - Create a Crash-Consistent Snapshot of a PowerVS VM
#
# This script performs a crash-consistent snapshot of an AIX or IBM i VM by:
#   1. Quiescing the database and syncing filesystem buffers to disk
#   2. Calling the IBM Cloud PowerVS API to create the snapshot
#   3. Waiting for the snapshot to reach "available" status
#   4. Resuming normal database operations
#
# Usage:
#   ./scripts/snapshot.ksh -n <snapshot-name> [-d <description>] [-v <vol1,vol2,...>]
#
# Options:
#   -n  Snapshot name (required)
#   -d  Snapshot description (optional)
#   -v  Comma-separated list of volume IDs to snapshot (optional, defaults to all)
#
# Examples:
#   ./scripts/snapshot.ksh -n "pre-patch-snapshot-$(date +%Y%m%d)"
#   ./scripts/snapshot.ksh -n "weekly-backup" -d "Weekly consistent backup" -v "vol-id-1,vol-id-2"
# =============================================================================

SCRIPT_DIR=$(dirname "$0")
. "${SCRIPT_DIR}/../config/powervs.conf"
. "${SCRIPT_DIR}/../lib/auth.ksh"
. "${SCRIPT_DIR}/../lib/utils.ksh"

# --- Argument Parsing --------------------------------------------------------
SNAPSHOT_NAME=""
SNAPSHOT_DESC="Snapshot created by powervs-ksh-scripts on $(date)"
VOLUME_IDS=""

while getopts "n:d:v:" OPT; do
    case "$OPT" in
        n) SNAPSHOT_NAME="$OPTARG" ;;
        d) SNAPSHOT_DESC="$OPTARG" ;;
        v) VOLUME_IDS="$OPTARG" ;;
        *) print "Usage: $0 -n <name> [-d <description>] [-v <vol-id1,vol-id2>]"; exit 1 ;;
    esac
done

if [ -z "$SNAPSHOT_NAME" ]; then
    log_error "Snapshot name is required. Use -n <name>."
    exit 1
fi

require_vars IBMCLOUD_API_KEY POWER_CRN CLOUD_INSTANCE_ID PVM_INSTANCE_ID POWER_API_ENDPOINT
[ $? -ne 0 ] && exit 1

# --- Step 1: Pre-snapshot Quiesce --------------------------------------------
log_info "========================================================"
log_info "PowerVS Snapshot Script Starting"
log_info "Snapshot Name : $SNAPSHOT_NAME"
log_info "VM Instance   : $PVM_INSTANCE_ID"
log_info "========================================================"

log_info "STEP 1: Quiescing database and syncing filesystem..."

# Detect OS type
OS_TYPE=$(uname -s 2>/dev/null)

if [ "$OS_TYPE" = "AIX" ]; then
    log_info "  Detected AIX. Running DB2 quiesce and sync..."
    # Quiesce DB2 databases (if DB2 is running). Adjust DB2 instance name as needed.
    # This suspends I/O at the DB2 level to ensure consistency.
    if [ -n "$DB2_INSTANCE" ] && id "$DB2_INSTANCE" >/dev/null 2>&1; then
        su - "$DB2_INSTANCE" -c "db2 -v QUIESCE DATABASE IMMEDIATE FORCE CONNECTIONS" >> "$LOG_FILE" 2>&1
        if [ $? -ne 0 ]; then
            log_warn "  DB2 quiesce returned non-zero. DB2 may not be running — continuing."
        else
            log_info "  DB2 quiesce successful."
        fi
    else
        log_info "  DB2_INSTANCE not configured or not found — skipping DB2 quiesce."
    fi

    # Sync AIX filesystem buffers to disk
    log_info "  Running sync to flush filesystem buffers..."
    sync; sync; sync
    log_info "  Filesystem sync complete."

elif print "$OS_TYPE" | grep -qi "os400\|i5\|IBM_i" 2>/dev/null || [ "$(uname -v 2>/dev/null)" = "1" ]; then
    log_info "  Detected IBM i (OS/400). Running journal flush..."
    # On IBM i, use QSYS commands to ensure journal buffers are flushed.
    # Run via system() call or CL program. Adjust library/journal names.
    system "CHGJRN JRN(QSYS/QAUDJRN) JRNRCV(*GEN)" >> "$LOG_FILE" 2>&1
    log_warn "  NOTE: For full IBM i consistency, ensure all active journals are flushed."
    log_warn "  Review your IBM i quiesce runbook and adapt CHGJRN calls as needed."

else
    log_warn "  Unrecognised OS type '$OS_TYPE'. Attempting generic sync..."
    sync 2>/dev/null || true
fi

log_info "  Pre-snapshot quiesce complete."

# --- Step 2: Build API Request Body ------------------------------------------
log_info "STEP 2: Building snapshot API request..."

if [ -n "$VOLUME_IDS" ]; then
    # Convert comma-separated list to JSON array: vol1,vol2 -> ["vol1","vol2"]
    VOL_ARRAY=$(print "$VOLUME_IDS" | awk -F',' '{
        printf "["
        for(i=1;i<=NF;i++){
            printf "\"%s\"", $i
            if(i<NF) printf ","
        }
        printf "]"
    }')
    REQUEST_BODY="{\"name\":\"${SNAPSHOT_NAME}\",\"description\":\"${SNAPSHOT_DESC}\",\"volumeIDs\":${VOL_ARRAY}}"
else
    REQUEST_BODY="{\"name\":\"${SNAPSHOT_NAME}\",\"description\":\"${SNAPSHOT_DESC}\"}"
fi

log_info "  Request body: $REQUEST_BODY"

# --- Step 3: Call PowerVS Snapshot API ---------------------------------------
log_info "STEP 3: Calling PowerVS API to create snapshot..."

SNAPSHOT_URL="${POWER_API_ENDPOINT}/pcloud/v1/cloud-instances/${CLOUD_INSTANCE_ID}/pvm-instances/${PVM_INSTANCE_ID}/snapshots"

api_call "POST" "$SNAPSHOT_URL" "$REQUEST_BODY"
if [ $? -ne 0 ]; then
    log_error "Snapshot API call failed. Aborting."
    # Resume DB operations even if snapshot failed
    resume_db_operations
    exit 1
fi

SNAPSHOT_ID=$(json_value "snapshotID" "$API_RESPONSE")
if [ -z "$SNAPSHOT_ID" ]; then
    # Try alternate field name
    SNAPSHOT_ID=$(json_value "snapshot_id" "$API_RESPONSE")
fi

log_info "  Snapshot creation initiated. Snapshot ID: ${SNAPSHOT_ID}"

# --- Step 4: Resume Database Operations (as soon as snapshot is triggered) ---
log_info "STEP 4: Resuming database operations..."

if [ "$OS_TYPE" = "AIX" ] && [ -n "$DB2_INSTANCE" ] && id "$DB2_INSTANCE" >/dev/null 2>&1; then
    su - "$DB2_INSTANCE" -c "db2 -v UNQUIESCE DATABASE" >> "$LOG_FILE" 2>&1
    if [ $? -ne 0 ]; then
        log_warn "  DB2 unquiesce returned non-zero. Check DB2 status manually."
    else
        log_info "  DB2 unquiesce successful. Database is back online."
    fi
else
    log_info "  No DB2 unquiesce needed."
fi

# --- Step 5: Poll Until Snapshot is Available --------------------------------
log_info "STEP 5: Waiting for snapshot to become available..."

if [ -n "$SNAPSHOT_ID" ]; then
    POLL_URL="${POWER_API_ENDPOINT}/pcloud/v1/cloud-instances/${CLOUD_INSTANCE_ID}/snapshots/${SNAPSHOT_ID}"
    wait_for_status "$POLL_URL" "available" "${MAX_WAIT_SECS:-900}" "${POLL_INTERVAL_SECS:-20}"
    WAIT_RC=$?

    if [ $WAIT_RC -eq 0 ]; then
        log_info "========================================================"
        log_info "SUCCESS: Snapshot '${SNAPSHOT_NAME}' is available."
        log_info "Snapshot ID : ${SNAPSHOT_ID}"
        log_info "Log file    : ${LOG_FILE}"
        log_info "========================================================"
        exit 0
    else
        log_error "Snapshot did not reach 'available' state in time."
        log_error "Check IBM Cloud Console > PowerVS workspace > Snapshots for details."
        exit 1
    fi
else
    log_warn "Could not parse Snapshot ID from API response. Cannot poll for completion."
    log_warn "Check IBM Cloud Console to confirm snapshot status."
    log_warn "Full API response: $API_RESPONSE"
    exit 0
fi
