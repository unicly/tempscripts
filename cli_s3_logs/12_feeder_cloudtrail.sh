#!/usr/bin/env bash
# 12 — Feeder: CloudTrail trail with management events.
# Needed in Storage for: who assumed the grantee role (AssumeRole) and the full
# session ARN of GetDataAccess. A data-events-only trail would capture nothing
# useful here: data events made with Access Grants credentials go to Storage.
# Using an existing trail? Keep its management events ON (Read + Write); you may
# add data-event selectors, but put-event-selectors REPLACES all selectors.
source "$(dirname "$0")/lib.sh"

if aws cloudtrail get-trail --name "$FEEDER_TRAIL" --region "$REGION" --profile "$FEEDER_PROFILE" >/dev/null 2>&1; then
  log "trail ${FEEDER_TRAIL} exists"
else
  log "creating trail ${FEEDER_TRAIL}"
  aws cloudtrail create-trail --name "$FEEDER_TRAIL" --s3-bucket-name "$FEEDER_CT_BUCKET" \
    --no-is-multi-region-trail --no-include-global-service-events --enable-log-file-validation \
    --region "$REGION" --profile "$FEEDER_PROFILE" >/dev/null
fi

cat > feeder-selectors.json <<'EOF'
[{"Name":"Management events (exclude KMS and RDS Data API)",
  "FieldSelectors":[{"Field":"eventCategory","Equals":["Management"]},
                    {"Field":"eventSource","NotEquals":["kms.amazonaws.com","rdsdata.amazonaws.com"]}]}]
EOF
aws cloudtrail put-event-selectors --trail-name "$FEEDER_TRAIL" --region "$REGION" --profile "$FEEDER_PROFILE" \
  --advanced-event-selectors file://feeder-selectors.json >/dev/null
aws cloudtrail start-logging --name "$FEEDER_TRAIL" --region "$REGION" --profile "$FEEDER_PROFILE"

log "done: ${FEEDER_TRAIL} -> ${FEEDER_CT_BUCKET}"
