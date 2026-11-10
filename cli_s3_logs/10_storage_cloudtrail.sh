#!/usr/bin/env bash
# 10 — Storage: CloudTrail trail with management events (incl. GetDataAccess,
# Access Grants' internal AssumeRole, grant changes) and S3 data events on the
# data lake bucket only. Needs the log bucket from 04.
source "$(dirname "$0")/lib.sh"

if aws cloudtrail get-trail --name "$STORAGE_TRAIL" --region "$REGION" --profile "$STORAGE_PROFILE" >/dev/null 2>&1; then
  log "trail ${STORAGE_TRAIL} exists"
else
  log "creating trail ${STORAGE_TRAIL}"
  aws cloudtrail create-trail --name "$STORAGE_TRAIL" --s3-bucket-name "$STORAGE_CT_BUCKET" \
    --no-is-multi-region-trail --no-include-global-service-events --enable-log-file-validation \
    --region "$REGION" --profile "$STORAGE_PROFILE" >/dev/null
fi

# trailing "/" in StartsWith: keeps "<bucket>-backup" from matching
cat > storage-selectors.json <<EOF
[
 {"Name":"Management events (exclude KMS and RDS Data API)",
  "FieldSelectors":[{"Field":"eventCategory","Equals":["Management"]},
                    {"Field":"eventSource","NotEquals":["kms.amazonaws.com","rdsdata.amazonaws.com"]}]},
 {"Name":"S3 data events on the data lake",
  "FieldSelectors":[{"Field":"eventCategory","Equals":["Data"]},
                    {"Field":"resources.type","Equals":["AWS::S3::Object"]},
                    {"Field":"resources.ARN","StartsWith":["arn:aws:s3:::${DATALAKE_BUCKET}/"]}]}
]
EOF
aws cloudtrail put-event-selectors --trail-name "$STORAGE_TRAIL" --region "$REGION" --profile "$STORAGE_PROFILE" \
  --advanced-event-selectors file://storage-selectors.json >/dev/null
aws cloudtrail start-logging --name "$STORAGE_TRAIL" --region "$REGION" --profile "$STORAGE_PROFILE"

log "done: ${STORAGE_TRAIL} -> ${STORAGE_CT_BUCKET}"
