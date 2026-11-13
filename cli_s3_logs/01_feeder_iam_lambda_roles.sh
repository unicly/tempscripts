#!/usr/bin/env bash
# 01 — Feeder: Lambda execution role + Access Grants grantee role.
#   FeederDataLakeLambdaRole  : Lambda exec role, may only assume the grantee role
#   FeederAccessGrantsRole    : the grantee (grant in Storage is issued to it),
#                               may only call GetDataAccess on the Storage instance
# Must exist before the grant (06) because the grant names the grantee role.
source "$(dirname "$0")/lib.sh"

# --- FeederDataLakeLambdaRole -------------------------------------------------
cat > lambda-trust.json <<'EOF'
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}
EOF
ensure_role "$FEEDER_PROFILE" FeederDataLakeLambdaRole lambda-trust.json
aws iam attach-role-policy --role-name FeederDataLakeLambdaRole --profile "$FEEDER_PROFILE" \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole

cat > exec-assume.json <<EOF
{"Version":"2012-10-17","Statement":[{"Effect":"Allow",
  "Action":["sts:AssumeRole","sts:SetSourceIdentity"],
  "Resource":"arn:aws:iam::${FEEDER_ACCOUNT_ID}:role/FeederAccessGrantsRole"}]}
EOF
aws iam put-role-policy --role-name FeederDataLakeLambdaRole --profile "$FEEDER_PROFILE" \
  --policy-name AssumeFeederAccessGrantsRole --policy-document file://exec-assume.json

# --- FeederAccessGrantsRole (grantee) ------------------------------------------
cat > grantee-trust.json <<EOF
{"Version":"2012-10-17","Statement":[{"Effect":"Allow",
  "Principal":{"AWS":"arn:aws:iam::${FEEDER_ACCOUNT_ID}:role/FeederDataLakeLambdaRole"},
  "Action":["sts:AssumeRole","sts:SetSourceIdentity"]}]}
EOF
# the exec role may not be visible to IAM yet -> retry on "Invalid principal"
retry 6 ensure_role "$FEEDER_PROFILE" FeederAccessGrantsRole grantee-trust.json

cat > grantee-gda.json <<EOF
{"Version":"2012-10-17","Statement":[{"Effect":"Allow",
  "Action":["s3:GetDataAccess","s3:GetAccessGrantsInstanceForPrefix"],
  "Resource":"${AG_INSTANCE_ARN}"}]}
EOF
aws iam put-role-policy --role-name FeederAccessGrantsRole --profile "$FEEDER_PROFILE" \
  --policy-name GetDataAccessOnStorage --policy-document file://grantee-gda.json

log "done: FeederDataLakeLambdaRole, FeederAccessGrantsRole"
