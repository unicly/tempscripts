#!/usr/bin/env bash
# 13 — Feeder: replicate the Feeder CloudTrail bucket to the Storage replica
# bucket (05). Storage becomes owner of the copies.
# Delete-marker replication is DISABLED: deletes in Feeder don't hide files in
# Storage; each bucket expires its own copies via lifecycle.
# Versioning must stay Enabled on both buckets.
source "$(dirname "$0")/lib.sh"

cat > replication.json <<EOF
{"Role":"arn:aws:iam::${FEEDER_ACCOUNT_ID}:role/CloudTrailReplicationRole",
 "Rules":[{"ID":"replicate-to-storage","Status":"Enabled","Priority":1,"Filter":{},
   "DeleteMarkerReplication":{"Status":"Disabled"},
   "Destination":{"Bucket":"arn:aws:s3:::${FEEDER_CT_REPLICA_BUCKET}","Account":"${STORAGE_ACCOUNT_ID}",
                  "StorageClass":"STANDARD","AccessControlTranslation":{"Owner":"Destination"}}}]}
EOF
aws s3api put-bucket-replication --bucket "$FEEDER_CT_BUCKET" --profile "$FEEDER_PROFILE" \
  --replication-configuration file://replication.json

log "done: ${FEEDER_CT_BUCKET} -> ${FEEDER_CT_REPLICA_BUCKET}"
echo "Check after ~15 min: newest object in ${FEEDER_CT_BUCKET} should have ReplicationStatus COMPLETED:"
echo "  aws s3api head-object --bucket ${FEEDER_CT_BUCKET} --key <key> --profile ${FEEDER_PROFILE} --query ReplicationStatus"
