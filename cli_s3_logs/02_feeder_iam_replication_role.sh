#!/usr/bin/env bash
# 02 — Feeder: role S3 uses to replicate CloudTrail logs to Storage.
# Created early because the Storage replica bucket policy (05) names it.
source "$(dirname "$0")/lib.sh"

cat > s3-trust.json <<'EOF'
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"s3.amazonaws.com"},"Action":"sts:AssumeRole"}]}
EOF
ensure_role "$FEEDER_PROFILE" CloudTrailReplicationRole s3-trust.json

cat > replication-policy.json <<EOF
{"Version":"2012-10-17","Statement":[
 {"Effect":"Allow","Action":["s3:GetReplicationConfiguration","s3:ListBucket"],
  "Resource":"arn:aws:s3:::${FEEDER_CT_BUCKET}"},
 {"Effect":"Allow","Action":["s3:GetObjectVersionForReplication","s3:GetObjectVersionAcl","s3:GetObjectVersionTagging"],
  "Resource":"arn:aws:s3:::${FEEDER_CT_BUCKET}/*"},
 {"Effect":"Allow","Action":["s3:ReplicateObject","s3:ReplicateDelete","s3:ReplicateTags","s3:ObjectOwnerOverrideToBucketOwner"],
  "Resource":"arn:aws:s3:::${FEEDER_CT_REPLICA_BUCKET}/*"}
]}
EOF
aws iam put-role-policy --role-name CloudTrailReplicationRole --profile "$FEEDER_PROFILE" \
  --policy-name CloudTrailReplicationPolicy --policy-document file://replication-policy.json

log "done: CloudTrailReplicationRole"
