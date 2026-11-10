#!/usr/bin/env bash
# 05 — Storage: destination bucket for the replicated Feeder CloudTrail logs.
# Versioned (required by replication), lifecycle, and a policy that accepts
# replication from Feeder's CloudTrailReplicationRole (created in 02).
source "$(dirname "$0")/lib.sh"

make_bucket "$STORAGE_PROFILE" "$FEEDER_CT_REPLICA_BUCKET"
aws s3api put-bucket-versioning --bucket "$FEEDER_CT_REPLICA_BUCKET" --profile "$STORAGE_PROFILE" \
  --versioning-configuration Status=Enabled
put_log_lifecycle "$STORAGE_PROFILE" "$FEEDER_CT_REPLICA_BUCKET"

cat > replica-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "AllowFeederReplication",
    "Effect": "Allow",
    "Principal": {"AWS": "arn:aws:iam::${FEEDER_ACCOUNT_ID}:role/CloudTrailReplicationRole"},
    "Action": ["s3:ReplicateObject","s3:ReplicateDelete","s3:ReplicateTags",
               "s3:GetBucketVersioning","s3:PutBucketVersioning","s3:ObjectOwnerOverrideToBucketOwner"],
    "Resource": ["arn:aws:s3:::${FEEDER_CT_REPLICA_BUCKET}", "arn:aws:s3:::${FEEDER_CT_REPLICA_BUCKET}/*"]
  }]
}
EOF
# IAM validates the cross-account principal; retry while the new role propagates
retry 6 aws s3api put-bucket-policy --bucket "$FEEDER_CT_REPLICA_BUCKET" --profile "$STORAGE_PROFILE" --policy file://replica-policy.json

log "done: ${FEEDER_CT_REPLICA_BUCKET}"
