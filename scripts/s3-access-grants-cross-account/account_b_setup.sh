#!/usr/bin/env bash
#
# ACCOUNT B (the Lambda account). Run with credentials for account B.
#
#   ./account_b_setup.sh role     1. create the IAM role (then run account_a_grant.sh in account A)
#   ./account_b_setup.sh lambda   2. package and create/update the Lambda function
#   ./account_b_setup.sh invoke   3. run the function and show its result
#   ./account_b_setup.sh all      1 + 2 + 3 (only if the grant already exists in account A)
set -euo pipefail

# ---- Edit these -------------------------------------------------------------------
REGION="eu-west-1"                       # must be the region of the Access Grants instance in account A
ACCOUNT_A_ID="111111111111"              # owner of S3 Access Grants and the bucket
ROLE_NAME="s3-access-grants-lambda-role"
FUNCTION_NAME="s3-access-grants-test"
BUCKET="my-bucket"
PREFIX="data/"                           # "" for the whole bucket; must match the grant
# -----------------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKDIR="$(mktemp -d)"; trap 'rm -rf "$WORKDIR"' EXIT
export AWS_REGION="$REGION" AWS_DEFAULT_REGION="$REGION"
INSTANCE_ARN="arn:aws:s3:${REGION}:${ACCOUNT_A_ID}:access-grants/default"

create_role() {
  echo "==> IAM role $ROLE_NAME"
  cat > "$WORKDIR/trust.json" <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow", "Principal": { "Service": "lambda.amazonaws.com" }, "Action": "sts:AssumeRole" }
  ]
}
JSON
  # The role only needs to ask account A's Access Grants for credentials.
  # It gets no direct S3 permissions: those come from the grant.
  cat > "$WORKDIR/access-grants-policy.json" <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "UseAccessGrantsInAccountA",
      "Effect": "Allow",
      "Action": [ "s3:GetDataAccess", "s3:GetAccessGrantsInstanceForPrefix", "s3:ListCallerAccessGrants" ],
      "Resource": "${INSTANCE_ARN}"
    }
  ]
}
JSON
  if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
    echo "Role exists: updating its trust policy."
    aws iam update-assume-role-policy --role-name "$ROLE_NAME" --policy-document "file://$WORKDIR/trust.json"
  else
    aws iam create-role --role-name "$ROLE_NAME" \
      --assume-role-policy-document "file://$WORKDIR/trust.json" \
      --description "Lambda role granted through S3 Access Grants in account ${ACCOUNT_A_ID}" >/dev/null
  fi
  aws iam attach-role-policy --role-name "$ROLE_NAME" \
    --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
  aws iam put-role-policy --role-name "$ROLE_NAME" --policy-name s3-access-grants \
    --policy-document "file://$WORKDIR/access-grants-policy.json"
  aws iam wait role-exists --role-name "$ROLE_NAME"
  echo "Role ARN (use it in account_a_grant.sh): $(aws iam get-role --role-name "$ROLE_NAME" --query Role.Arn --output text)"
}

create_lambda() {
  echo "==> Lambda $FUNCTION_NAME"
  ROLE_ARN="$(aws iam get-role --role-name "$ROLE_NAME" --query Role.Arn --output text)"
  (cd "$SCRIPT_DIR/lambda" && zip -q "$WORKDIR/function.zip" lambda_function.py)
  ENV_VARS="Variables={ACCESS_GRANTS_ACCOUNT_ID=${ACCOUNT_A_ID},BUCKET=${BUCKET},PREFIX=${PREFIX}}"

  if aws lambda get-function --function-name "$FUNCTION_NAME" >/dev/null 2>&1; then
    echo "Function exists: updating code and configuration."
    aws lambda update-function-code --function-name "$FUNCTION_NAME" \
      --zip-file "fileb://$WORKDIR/function.zip" >/dev/null
    aws lambda wait function-updated-v2 --function-name "$FUNCTION_NAME"
    aws lambda update-function-configuration --function-name "$FUNCTION_NAME" \
      --role "$ROLE_ARN" --environment "$ENV_VARS" >/dev/null
  else
    # A new role can take a few seconds before Lambda can assume it: retry.
    for attempt in 1 2 3 4 5 6; do
      if aws lambda create-function --function-name "$FUNCTION_NAME" \
          --runtime python3.13 --architectures arm64 \
          --handler lambda_function.lambda_handler \
          --role "$ROLE_ARN" \
          --zip-file "fileb://$WORKDIR/function.zip" \
          --timeout 60 --memory-size 256 \
          --environment "$ENV_VARS" >/dev/null 2>"$WORKDIR/err"; then
        break
      fi
      grep -q "cannot be assumed" "$WORKDIR/err" || { cat "$WORKDIR/err" >&2; exit 1; }
      [[ $attempt -lt 6 ]] || { cat "$WORKDIR/err" >&2; exit 1; }
      echo "Role not ready yet (attempt $attempt), retrying in 10 s..."; sleep 10
    done
  fi
  aws lambda wait function-active-v2 --function-name "$FUNCTION_NAME"
  aws lambda wait function-updated-v2 --function-name "$FUNCTION_NAME"
  echo "Function ready: $(aws lambda get-function --function-name "$FUNCTION_NAME" --query Configuration.FunctionArn --output text)"
}

invoke_lambda() {
  echo "==> Invoke $FUNCTION_NAME"
  aws lambda invoke --function-name "$FUNCTION_NAME" \
    --cli-binary-format raw-in-base64-out --payload '{}' \
    --log-type Tail --query LogResult --output text "$WORKDIR/response.json" | base64 -d
  echo "--- Response:"
  cat "$WORKDIR/response.json"; echo
}

case "${1:-}" in
  role)   create_role ;;
  lambda) create_lambda ;;
  invoke) invoke_lambda ;;
  all)    create_role; create_lambda; invoke_lambda ;;
  *)      sed -n '3,9p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
