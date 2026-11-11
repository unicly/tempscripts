#!/usr/bin/env bash
# 15 — Storage: grants history. Bucket + role + Lambda AccessGrantsInventory,
# which keeps an APPEND-ONLY CSV of all S3 Access Grants grants:
#   s3://<INVENTORY_BUCKET>/<GRANTS_CSV_KEY>
# Each run appends a CREATED line for every new grant and a DELETED line for
# every grant that disappeared. Existing lines are never changed or removed.
# Triggers (EventBridge): 16. Glue table access_grants_history: 17.
# Code: lambda/access_grants_history.py.
source "$(dirname "$0")/lib.sh"

make_bucket "$STORAGE_PROFILE" "$INVENTORY_BUCKET"

cat > lambda-trust.json <<'EOF'
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}
EOF
ensure_role "$STORAGE_PROFILE" AccessGrantsInventoryRole lambda-trust.json
aws iam attach-role-policy --role-name AccessGrantsInventoryRole --profile "$STORAGE_PROFILE" \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole

# GetObject + PutObject on the CSV only; ListBucket so a missing file returns
# "NoSuchKey" (first run) instead of AccessDenied.
cat > inventory-policy.json <<EOF
{"Version":"2012-10-17","Statement":[
 {"Effect":"Allow","Action":"s3:ListAccessGrants","Resource":"${AG_INSTANCE_ARN}"},
 {"Effect":"Allow","Action":["s3:GetObject","s3:PutObject"],"Resource":"arn:aws:s3:::${INVENTORY_BUCKET}/${GRANTS_CSV_KEY}"},
 {"Effect":"Allow","Action":"s3:ListBucket","Resource":"arn:aws:s3:::${INVENTORY_BUCKET}",
  "Condition":{"StringLike":{"s3:prefix":"${GRANTS_CSV_PREFIX}*"}}}
]}
EOF
aws iam put-role-policy --role-name AccessGrantsInventoryRole --profile "$STORAGE_PROFILE" \
  --policy-name AccessGrantsInventoryPolicy --policy-document file://inventory-policy.json

deploy_lambda "$STORAGE_PROFILE" AccessGrantsInventory \
  "arn:aws:iam::${STORAGE_ACCOUNT_ID}:role/AccessGrantsInventoryRole" \
  "${LAMBDA_DIR}/access_grants_history.py" access_grants_history.lambda_handler 60 \
  "ACCOUNT_ID=${STORAGE_ACCOUNT_ID},BUCKET=${INVENTORY_BUCKET},KEY=${GRANTS_CSV_KEY}"

# One run at a time: the file is read, extended and written back, so two
# parallel runs could otherwise race. (The write is also conditional on the
# ETag.) Throttled EventBridge invocations are queued and retried by Lambda.
aws lambda put-function-concurrency --function-name AccessGrantsInventory \
  --reserved-concurrent-executions 1 --region "$REGION" --profile "$STORAGE_PROFILE" >/dev/null

log "first run:"
retry 3 aws lambda invoke --function-name AccessGrantsInventory --region "$REGION" --profile "$STORAGE_PROFILE" \
  inventory-out.json >/dev/null
cat inventory-out.json; echo

log "done: AccessGrantsInventory -> s3://${INVENTORY_BUCKET}/${GRANTS_CSV_KEY}"
