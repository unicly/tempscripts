#!/usr/bin/env bash
# 15 — Storage: grants inventory. Bucket + role + Lambda AccessGrantsInventory,
# which snapshots all grants (grant ID -> grantee ARN) as JSON lines to
# s3://<INVENTORY_BUCKET>/access-grants/<timestamp>.json. Snapshots are kept so
# deleted grants still resolve for old log events. Triggers: 16.
# Code: lambda/access_grants_inventory.py.
source "$(dirname "$0")/lib.sh"

make_bucket "$STORAGE_PROFILE" "$INVENTORY_BUCKET"

cat > lambda-trust.json <<'EOF'
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}
EOF
ensure_role "$STORAGE_PROFILE" AccessGrantsInventoryRole lambda-trust.json
aws iam attach-role-policy --role-name AccessGrantsInventoryRole --profile "$STORAGE_PROFILE" \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole

cat > inventory-policy.json <<EOF
{"Version":"2012-10-17","Statement":[
 {"Effect":"Allow","Action":"s3:ListAccessGrants","Resource":"${AG_INSTANCE_ARN}"},
 {"Effect":"Allow","Action":"s3:PutObject","Resource":"arn:aws:s3:::${INVENTORY_BUCKET}/access-grants/*"}
]}
EOF
aws iam put-role-policy --role-name AccessGrantsInventoryRole --profile "$STORAGE_PROFILE" \
  --policy-name AccessGrantsInventoryPolicy --policy-document file://inventory-policy.json

deploy_lambda "$STORAGE_PROFILE" AccessGrantsInventory \
  "arn:aws:iam::${STORAGE_ACCOUNT_ID}:role/AccessGrantsInventoryRole" \
  "${LAMBDA_DIR}/access_grants_inventory.py" access_grants_inventory.lambda_handler 60 \
  "ACCOUNT_ID=${STORAGE_ACCOUNT_ID},BUCKET=${INVENTORY_BUCKET},PREFIX=access-grants/"

log "first snapshot:"
retry 3 aws lambda invoke --function-name AccessGrantsInventory --region "$REGION" --profile "$STORAGE_PROFILE" \
  inventory-out.json >/dev/null
cat inventory-out.json; echo

log "done: AccessGrantsInventory"
