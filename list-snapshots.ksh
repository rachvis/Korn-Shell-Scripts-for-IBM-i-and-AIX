#!/usr/bin/ksh
# =============================================================================
# scripts/list-snapshots.ksh - List all Snapshots for a PowerVS VM
#
# Displays all snapshots associated with the configured PVM instance,
# including their IDs, names, status, and creation time.
# Useful for finding snapshot IDs to pass to export.ksh.
#
# Usage:
#   ./scripts/list-snapshots.ksh [-s <pvm-instance-id>]
#
# Options:
#   -s  PVM Instance ID (optional, defaults to PVM_INSTANCE_ID in config)
# =============================================================================

SCRIPT_DIR=$(dirname "$0")
. "${SCRIPT_DIR}/../config/powervs.conf"
. "${SCRIPT_DIR}/../lib/auth.ksh"
. "${SCRIPT_DIR}/../lib/utils.ksh"

SOURCE_PVM_ID=""
while getopts "s:" OPT; do
    case "$OPT" in
        s) SOURCE_PVM_ID="$OPTARG" ;;
        *) print "Usage: $0 [-s <pvm-instance-id>]"; exit 1 ;;
    esac
done
[ -z "$SOURCE_PVM_ID" ] && SOURCE_PVM_ID="$PVM_INSTANCE_ID"

require_vars IBMCLOUD_API_KEY POWER_CRN CLOUD_INSTANCE_ID SOURCE_PVM_ID POWER_API_ENDPOINT
[ $? -ne 0 ] && exit 1

log_info "Listing snapshots for PVM Instance: $SOURCE_PVM_ID"

SNAP_LIST_URL="${POWER_API_ENDPOINT}/pcloud/v1/cloud-instances/${CLOUD_INSTANCE_ID}/pvm-instances/${SOURCE_PVM_ID}/snapshots"
api_call "GET" "$SNAP_LIST_URL"
if [ $? -ne 0 ]; then
    log_error "Failed to retrieve snapshot list."
    exit 1
fi

# Print a simple table from the JSON response
print ""
print "Snapshots for VM: $SOURCE_PVM_ID"
print "-------------------------------------------------------------------"
print "$API_RESPONSE" | awk -F'"snapshotID":"' '{
    for(i=2;i<=NF;i++){
        snap_id = $i; sub(/".*/, "", snap_id)
        rest = $i
        name = rest; sub(/.*"name":"/, "", name); sub(/".*/, "", name)
        status = rest; sub(/.*"status":"/, "", status); sub(/".*/, "", status)
        created = rest; sub(/.*"creationDate":"/, "", created); sub(/".*/, "", created)
        printf "ID: %-38s  Name: %-30s  Status: %-12s  Created: %s\n", snap_id, name, status, created
    }
}'
print "-------------------------------------------------------------------"
print ""
exit 0
