#!/usr/bin/env bash
# Shared setup for all numbered scripts: loads .env, checks it, defines helpers.
# Sourced, not executed:  source "$(dirname "$0")/lib.sh"

set -euo pipefail

CLI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
set -a; source "${CLI_DIR}/.env"; set +a

for v in REGION FEEDER_PROFILE STORAGE_PROFILE FEEDER_ACCOUNT_ID STORAGE_ACCOUNT_ID STORAGE_ADMIN_ARN; do
  [ -n "${!v:-}" ] || { echo "ERROR: $v is not set in .env" >&2; exit 1; }
done
case "$FEEDER_ACCOUNT_ID$STORAGE_ACCOUNT_ID$STORAGE_ADMIN_ARN" in
  *111111111111*|*222222222222*|*CHANGE-ME*) echo "ERROR: edit .env first (account IDs / STORAGE_ADMIN_ARN)" >&2; exit 1;;
esac

AG_INSTANCE_ARN="arn:aws:s3:${REGION}:${STORAGE_ACCOUNT_ID}:access-grants/default"
LAMBDA_DIR="${CLI_DIR}/lambda"
BUILD="${CLI_DIR}/build"            # generated JSON/SQL/zip files land here
mkdir -p "$BUILD"; cd "$BUILD"

# us-east-1 must not get a LocationConstraint
if [ "$REGION" = "us-east-1" ]; then LOC_ARGS=(); else LOC_ARGS=(--create-bucket-configuration "LocationConstraint=${REGION}"); fi

log() { echo "==> $*"; }

# make_bucket <profile> <bucket> — private, SSE-S3; skips creation if it exists
make_bucket() {
  if aws s3api head-bucket --bucket "$2" --profile "$1" >/dev/null 2>&1; then
    log "bucket $2 exists"
  else
    log "creating bucket $2"
    aws s3api create-bucket --bucket "$2" --region "$REGION" --profile "$1" "${LOC_ARGS[@]}" >/dev/null
  fi
  aws s3api put-public-access-block --bucket "$2" --profile "$1" \
    --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
  aws s3api put-bucket-encryption --bucket "$2" --profile "$1" \
    --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
}

# put_log_lifecycle <profile> <bucket> — expire logs, purge old versions, drop delete markers
put_log_lifecycle() {
  cat > lifecycle.json <<EOF
{"Rules":[
  {"ID":"expire-logs-and-old-versions","Status":"Enabled","Filter":{},
   "Expiration":{"Days":${LOG_RETENTION_DAYS}},
   "NoncurrentVersionExpiration":{"NoncurrentDays":1}},
  {"ID":"remove-expired-delete-markers","Status":"Enabled","Filter":{},
   "Expiration":{"ExpiredObjectDeleteMarker":true}}
]}
EOF
  aws s3api put-bucket-lifecycle-configuration --bucket "$2" --profile "$1" --lifecycle-configuration file://lifecycle.json
  log "lifecycle on $2: ${LOG_RETENTION_DAYS} days"
}

# ensure_role <profile> <role-name> <trust-policy-file> — create or update trust policy
ensure_role() {
  if aws iam get-role --role-name "$2" --profile "$1" >/dev/null 2>&1; then
    log "role $2 exists, updating trust policy"
    aws iam update-assume-role-policy --role-name "$2" --profile "$1" --policy-document "file://$3"
  else
    log "creating role $2"
    aws iam create-role --role-name "$2" --profile "$1" --assume-role-policy-document "file://$3" >/dev/null
  fi
}

# retry <n> <cmd...> — for IAM propagation ("invalid principal", "cannot be assumed")
retry() {
  local n=$1; shift
  for i in $(seq 1 "$n"); do
    if "$@"; then return 0; fi
    echo "   retry $i/$n in 10 s (IAM propagation)..." >&2; sleep 10
  done
  return 1
}

# deploy_lambda <profile> <name> <role-arn> <py-file> <handler> <timeout> <env-vars>
deploy_lambda() {
  local zip="${BUILD}/$2.zip"
  rm -f "$zip"; (cd "$(dirname "$4")" && zip -q "$zip" "$(basename "$4")")
  if aws lambda get-function --function-name "$2" --region "$REGION" --profile "$1" >/dev/null 2>&1; then
    log "updating Lambda $2"
    aws lambda update-function-code --function-name "$2" --zip-file "fileb://$zip" --region "$REGION" --profile "$1" >/dev/null
    aws lambda wait function-updated --function-name "$2" --region "$REGION" --profile "$1"
    aws lambda update-function-configuration --function-name "$2" --role "$3" --handler "$5" --timeout "$6" \
      --environment "Variables={$7}" --region "$REGION" --profile "$1" >/dev/null
    aws lambda wait function-updated --function-name "$2" --region "$REGION" --profile "$1"
  else
    log "creating Lambda $2"
    retry 6 aws lambda create-function --function-name "$2" --runtime python3.12 --handler "$5" --timeout "$6" \
      --role "$3" --zip-file "fileb://$zip" --environment "Variables={$7}" \
      --region "$REGION" --profile "$1" >/dev/null
  fi
  aws lambda wait function-active-v2 --function-name "$2" --region "$REGION" --profile "$1"
}

# athena_run <sql-file> — run one statement in the workgroup and wait
athena_run() {
  local qid state
  qid=$(aws athena start-query-execution --work-group "$ATHENA_WORKGROUP" --region "$REGION" --profile "$STORAGE_PROFILE" \
        --query-string "file://$1" --query QueryExecutionId --output text)
  while :; do
    state=$(aws athena get-query-execution --query-execution-id "$qid" --region "$REGION" --profile "$STORAGE_PROFILE" \
            --query QueryExecution.Status.State --output text)
    case "$state" in
      SUCCEEDED) log "$(basename "$1"): OK"; return 0;;
      FAILED|CANCELLED)
        aws athena get-query-execution --query-execution-id "$qid" --region "$REGION" --profile "$STORAGE_PROFILE" \
          --query QueryExecution.Status.StateChangeReason --output text >&2
        return 1;;
    esac
    sleep 2
  done
}
