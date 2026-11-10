#!/usr/bin/env bash
# 11 — Feeder: bucket for the Feeder CloudTrail logs. Versioned (source of the
# replication), lifecycle, and the policy that lets only FeederTrail write.
source "$(dirname "$0")/lib.sh"

make_bucket "$FEEDER_PROFILE" "$FEEDER_CT_BUCKET"
aws s3api put-bucket-versioning --bucket "$FEEDER_CT_BUCKET" --profile "$FEEDER_PROFILE" \
  --versioning-configuration Status=Enabled
put_log_lifecycle "$FEEDER_PROFILE" "$FEEDER_CT_BUCKET"

TRAIL_ARN="arn:aws:cloudtrail:${REGION}:${FEEDER_ACCOUNT_ID}:trail/${FEEDER_TRAIL}"
cat > feeder-ct-policy.json <<EOF
{"Version":"2012-10-17","Statement":[
 {"Sid":"AWSCloudTrailAclCheck","Effect":"Allow","Principal":{"Service":"cloudtrail.amazonaws.com"},
  "Action":"s3:GetBucketAcl","Resource":"arn:aws:s3:::${FEEDER_CT_BUCKET}",
  "Condition":{"StringEquals":{"aws:SourceArn":"${TRAIL_ARN}"}}},
 {"Sid":"AWSCloudTrailWrite","Effect":"Allow","Principal":{"Service":"cloudtrail.amazonaws.com"},
  "Action":"s3:PutObject","Resource":"arn:aws:s3:::${FEEDER_CT_BUCKET}/AWSLogs/${FEEDER_ACCOUNT_ID}/*",
  "Condition":{"StringEquals":{"s3:x-amz-acl":"bucket-owner-full-control","aws:SourceArn":"${TRAIL_ARN}"}}}
]}
EOF
aws s3api put-bucket-policy --bucket "$FEEDER_CT_BUCKET" --profile "$FEEDER_PROFILE" --policy file://feeder-ct-policy.json

log "done: ${FEEDER_CT_BUCKET}"
