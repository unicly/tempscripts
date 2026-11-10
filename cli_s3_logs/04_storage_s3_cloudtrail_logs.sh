#!/usr/bin/env bash
# 04 — Storage: bucket for the Storage CloudTrail logs, with lifecycle and the
# policy that lets only the StorageDataLakeTrail trail write to it.
source "$(dirname "$0")/lib.sh"

make_bucket "$STORAGE_PROFILE" "$STORAGE_CT_BUCKET"
put_log_lifecycle "$STORAGE_PROFILE" "$STORAGE_CT_BUCKET"

TRAIL_ARN="arn:aws:cloudtrail:${REGION}:${STORAGE_ACCOUNT_ID}:trail/${STORAGE_TRAIL}"
cat > storage-ct-policy.json <<EOF
{"Version":"2012-10-17","Statement":[
 {"Sid":"AWSCloudTrailAclCheck","Effect":"Allow","Principal":{"Service":"cloudtrail.amazonaws.com"},
  "Action":"s3:GetBucketAcl","Resource":"arn:aws:s3:::${STORAGE_CT_BUCKET}",
  "Condition":{"StringEquals":{"aws:SourceArn":"${TRAIL_ARN}"}}},
 {"Sid":"AWSCloudTrailWrite","Effect":"Allow","Principal":{"Service":"cloudtrail.amazonaws.com"},
  "Action":"s3:PutObject","Resource":"arn:aws:s3:::${STORAGE_CT_BUCKET}/AWSLogs/${STORAGE_ACCOUNT_ID}/*",
  "Condition":{"StringEquals":{"s3:x-amz-acl":"bucket-owner-full-control","aws:SourceArn":"${TRAIL_ARN}"}}}
]}
EOF
aws s3api put-bucket-policy --bucket "$STORAGE_CT_BUCKET" --profile "$STORAGE_PROFILE" --policy file://storage-ct-policy.json

log "done: ${STORAGE_CT_BUCKET}"
