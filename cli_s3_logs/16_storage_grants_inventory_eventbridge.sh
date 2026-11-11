#!/usr/bin/env bash
# 16 — Storage: EventBridge rules that run AccessGrantsInventory (15), which
# appends grant changes to the grants history CSV.
#   AccessGrantsInventoryOnChange  : after every CreateAccessGrant / DeleteAccessGrant
#   AccessGrantsInventoryDaily     : once a day, as a safety net for missed events
# Those calls are CloudTrail management events; EventBridge receives them in the
# same region. A run without changes appends nothing, so extra runs are harmless.
# Not tested end to end in the PoC — after creating a grant, check that a
# CREATED line appears in the CSV within a few minutes.
source "$(dirname "$0")/lib.sh"

FN_ARN="arn:aws:lambda:${REGION}:${STORAGE_ACCOUNT_ID}:function:AccessGrantsInventory"

# allow_rule <rule-name> — Lambda resource permission for one rule (idempotent)
allow_rule() {
  aws lambda remove-permission --function-name AccessGrantsInventory --statement-id "$1" \
    --region "$REGION" --profile "$STORAGE_PROFILE" >/dev/null 2>&1 || true
  aws lambda add-permission --function-name AccessGrantsInventory --statement-id "$1" \
    --action lambda:InvokeFunction --principal events.amazonaws.com \
    --source-arn "arn:aws:events:${REGION}:${STORAGE_ACCOUNT_ID}:rule/$1" \
    --region "$REGION" --profile "$STORAGE_PROFILE" >/dev/null
}

aws events put-rule --name AccessGrantsInventoryDaily --schedule-expression "rate(1 day)" \
  --region "$REGION" --profile "$STORAGE_PROFILE" >/dev/null
aws events put-targets --rule AccessGrantsInventoryDaily --targets "Id=inventory,Arn=${FN_ARN}" \
  --region "$REGION" --profile "$STORAGE_PROFILE" >/dev/null
allow_rule AccessGrantsInventoryDaily

cat > grant-change-pattern.json <<'EOF'
{"source":["aws.s3"],
 "detail-type":["AWS API Call via CloudTrail"],
 "detail":{"eventSource":["s3.amazonaws.com"],
           "eventName":["CreateAccessGrant","DeleteAccessGrant"]}}
EOF
aws events put-rule --name AccessGrantsInventoryOnChange --event-pattern file://grant-change-pattern.json \
  --region "$REGION" --profile "$STORAGE_PROFILE" >/dev/null
aws events put-targets --rule AccessGrantsInventoryOnChange --targets "Id=inventory,Arn=${FN_ARN}" \
  --region "$REGION" --profile "$STORAGE_PROFILE" >/dev/null
allow_rule AccessGrantsInventoryOnChange

log "done: AccessGrantsInventoryDaily, AccessGrantsInventoryOnChange"
