#!/usr/bin/ksh
# =============================================================================
# scripts/export.ksh - Export a PowerVS VM Snapshot to IBM Cloud Object Storage
#
# This script exports an existing PowerVS snapshot to an IBM Cloud Object
# Storage (COS) bucket for long-term retention, disaster recovery, or
# cross-region portability.
#
# Prerequisites:
#   - A snapshot must already exist (run snapshot.ksh first)
#   - An IBM Cloud Object Storage bucket and HMAC credentials are required
#     (HMAC = access key + secret key, used for S3-compatible auth to COS)
#
# Usage:
#   ./scripts/export.ksh -i <snapshot-id> -b <cos-bucket> -r <cos-region> [-p <prefix>]
#
# Options:
#   -i  Snapshot ID to export (required)
#   -b  COS bucket name (required)
#   -r  COS region (e.g. us-south, eu-de) (required)
#   -p  Object key prefix in the bucket (optional, defaults to "powervs-exports/")
#
# Examples:
#   ./scripts/export.ksh -i "snap-abc123" -b "my-backup-bucket" -r "us-south"
#   ./scripts/export.ksh -i "snap-abc123" -b "dr-bucket" -r "eu-de" -p "aix-exports/"
# =============================================================================

SCRIPT_DIR=$(dirname "$0")
. "${SCRIPT_DIR}/../config/powervs.conf"
. "${SCRIPT_DIR}/../lib/auth.ksh"
. "${SCRIPT_DIR}/../lib/utils.ksh"

# --- Argument Parsing --------------------------------------------------------
SNAPSHOT_ID=""
COS_BUCKET=""
COS_REGION=""
EXPORT_PREFIX="powervs-exports/"

while getopts "i:b:r:p:" OPT; do
    case "$OPT" in
        i) SNAPSHOT_ID="$OPTARG" ;;
        b) COS_BUCKET="$OPTARG" ;;
        r) COS_REGION="$OPTARG" ;;
        p) EXPORT_PREFIX="$OPTARG" ;;
        *) print "Usage: $0 -i <snapshot-id> -b <bucket> -r <cos-region> [-p <prefix>]"; exit 1 ;;
    esac
done

if [ -z "$SNAPSHOT_ID" ] || [ -z "$COS_BUCKET" ] || [ -z "$COS_REGION" ]; then
    log_error "Snapshot ID (-i), COS bucket (-b), and COS region (-r) are all required."
    exit 1
fi

require_vars IBMCLOUD_API_KEY POWER_CRN CLOUD_INSTANCE_ID POWER_API_ENDPOINT \
             COS_ACCESS_KEY COS_SECRET_KEY
[ $? -ne 0 ] && exit 1

log_info "========================================================"
log_info "PowerVS Snapshot Export Script Starting"
log_info "Snapshot ID   : $SNAPSHOT_ID"
log_info "COS Bucket    : $COS_BUCKET"
log_info "COS Region    : $COS_REGION"
log_info "Object Prefix : $EXPORT_PREFIX"
log_info "========================================================"

# --- Step 1: Verify Snapshot Exists and is Available ------------------------
log_info "STEP 1: Verifying snapshot status..."

SNAPSHOT_URL="${POWER_API_ENDPOINT}/pcloud/v1/cloud-instances/${CLOUD_INSTANCE_ID}/snapshots/${SNAPSHOT_ID}"
api_call "GET" "$SNAPSHOT_URL"
if [ $? -ne 0 ]; then
    log_error "Failed to retrieve snapshot ${SNAPSHOT_ID}. Verify the ID is correct."
    exit 1
fi

SNAP_STATUS=$(json_value "status" "$API_RESPONSE")
SNAP_NAME=$(json_value "name" "$API_RESPONSE")
log_info "  Snapshot name: $SNAP_NAME | Status: $SNAP_STATUS"

if [ "$SNAP_STATUS" != "available" ]; then
    log_error "Snapshot is not in 'available' state (current: ${SNAP_STATUS}). Cannot export."
    exit 1
fi
log_info "  Snapshot is available. Proceeding with export."

# --- Step 2: Build Export API Request ----------------------------------------
log_info "STEP 2: Initiating export to COS..."

# COS endpoint for S3-compatible access
COS_ENDPOINT="s3.${COS_REGION}.cloud-object-storage.appdomain.cloud"

REQUEST_BODY="{
  \"snapshotID\": \"${SNAPSHOT_ID}\",
  \"bucketName\": \"${COS_BUCKET}\",
  \"bucketRegion\": \"${COS_REGION}\",
  \"bucketAccess\": \"user-defined\",
  \"accessKey\": \"${COS_ACCESS_KEY}\",
  \"secretKey\": \"${COS_SECRET_KEY}\",
  \"imageFilename\": \"${EXPORT_PREFIX}${SNAP_NAME}-$(date +%Y%m%d%H%M%S)\"
}"

log_info "  COS Endpoint  : $COS_ENDPOINT"
log_info "  Target object : ${EXPORT_PREFIX}${SNAP_NAME}-<timestamp>"

EXPORT_URL="${POWER_API_ENDPOINT}/pcloud/v1/cloud-instances/${CLOUD_INSTANCE_ID}/snapshots/${SNAPSHOT_ID}/export"
api_call "POST" "$EXPORT_URL" "$REQUEST_BODY"
if [ $? -ne 0 ]; then
    log_error "Export API call failed."
    exit 1
fi

EXPORT_JOB_ID=$(json_value "jobID" "$API_RESPONSE")
if [ -z "$EXPORT_JOB_ID" ]; then
    EXPORT_JOB_ID=$(json_value "id" "$API_RESPONSE")
fi

log_info "  Export job submitted. Job ID: ${EXPORT_JOB_ID}"

# --- Step 3: Poll Export Job Status ------------------------------------------
log_info "STEP 3: Waiting for export to complete (this may take 10-60 minutes)..."

if [ -n "$EXPORT_JOB_ID" ]; then
    JOB_URL="${POWER_API_ENDPOINT}/pcloud/v1/cloud-instances/${CLOUD_INSTANCE_ID}/jobs/${EXPORT_JOB_ID}"
    ELAPSED=0
    MAX_WAIT="${MAX_WAIT_SECS:-3600}"    # exports can take longer, default 1 hour
    INTERVAL="${POLL_INTERVAL_SECS:-30}"

    while [ "$ELAPSED" -lt "$MAX_WAIT" ]; do
        sleep "$INTERVAL"
        ELAPSED=$(expr $ELAPSED + $INTERVAL)

        api_call "GET" "$JOB_URL"
        JOB_STATUS=$(json_value "status" "$API_RESPONSE")
        JOB_PERCENT=$(json_value_num "percentComplete" "$API_RESPONSE")
        log_info "  Export status at ${ELAPSED}s: ${JOB_STATUS} (${JOB_PERCENT:-?}% complete)"

        case "$JOB_STATUS" in
            completed|COMPLETED|succeeded|SUCCEEDED)
                break
                ;;
            failed|FAILED|error|ERROR)
                FAIL_REASON=$(json_value "failedReason" "$API_RESPONSE")
                log_error "Export job failed: ${FAIL_REASON}"
                exit 1
                ;;
        esac
    done

    if [ "$ELAPSED" -ge "$MAX_WAIT" ]; then
        log_error "Export timed out after ${MAX_WAIT}s. Check IBM Cloud Console for status."
        exit 1
    fi
else
    log_warn "Could not retrieve export job ID. Polling skipped."
    log_warn "Check IBM Cloud Console > PowerVS workspace > Jobs for export status."
fi

log_info "========================================================"
log_info "SUCCESS: Snapshot export complete."
log_info "Snapshot ID   : ${SNAPSHOT_ID}"
log_info "Snapshot Name : ${SNAP_NAME}"
log_info "COS Bucket    : ${COS_BUCKET} (${COS_REGION})"
log_info "Export Job ID : ${EXPORT_JOB_ID}"
log_info "Log file      : ${LOG_FILE}"
log_info ""
log_info "The exported image is now in your COS bucket."
log_info "It can be imported into another PowerVS workspace for cross-region DR."
log_info "========================================================"
exit 0
