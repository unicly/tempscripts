#!/usr/bin/env bash
# 18 — Test: Lambda list/create/delete through Access Grants (with and without
# SourceIdentity), direct access refused, grants history CSV present.
# AccessDenied in the first ~4 minutes after setup = IAM/RAM propagation; retry.
# Then wait 5–15 min for CloudTrail and run SQL_QUERIES.md or
# DATALAKE_README.md section 10. Don't empty the log buckets before that.
source "$(dirname "$0")/lib.sh"

invoke() {   # invoke <json-payload>
  aws lambda invoke --function-name DataLakePocObjects --region "$REGION" --profile "$FEEDER_PROFILE" \
    --cli-binary-format raw-in-base64-out --payload "$1" out.json >/dev/null
  printf '%-75s -> %s\n' "$1" "$(cat out.json)"
}

log "Lambda through Access Grants ($(date -u +%H:%M:%S) UTC)"
invoke '{"action":"list"}'
invoke '{"action":"create","key":"test.txt","body":"hello"}'
invoke '{"action":"list"}'
invoke '{"action":"delete","key":"test.txt"}'
invoke '{"action":"create","key":"test-no-si.txt","no_source_identity":true}'
invoke '{"action":"delete","key":"test-no-si.txt","no_source_identity":true}'

log "direct access from Feeder must be refused:"
if aws s3 ls "s3://${DATALAKE_BUCKET}" --profile "$FEEDER_PROFILE" >/dev/null 2>&1; then
  echo "   UNEXPECTED: direct listing worked"
else
  echo "   OK: refused"
fi

log "grants history CSV (last lines):"
aws s3 cp "s3://${INVENTORY_BUCKET}/${GRANTS_CSV_KEY}" - --profile "$STORAGE_PROFILE" | tail -5
