#!/usr/bin/env bash
# 99 — Teardown: removes everything created by 01–17, in reverse order.
# PERMANENT: empties and deletes all buckets from .env, including the data lake
# and all CloudTrail logs. Leaves the Access Grants instance itself in place.
source "$(dirname "$0")/lib.sh"

echo "This PERMANENTLY deletes the data lake setup in ${FEEDER_ACCOUNT_ID} and ${STORAGE_ACCOUNT_ID}, including:"
for b in "$DATALAKE_BUCKET" "$STORAGE_CT_BUCKET" "$FEEDER_CT_REPLICA_BUCKET" "$ATHENA_RESULTS_BUCKET" "$INVENTORY_BUCKET" "$FEEDER_CT_BUCKET"; do
  echo "  - s3://$b (all objects, versions and delete markers)"
done
read -r -p "Type 'delete' to continue: " answer
[ "$answer" = "delete" ] || { echo "Aborted."; exit 1; }

S=(--region "$REGION" --profile "$STORAGE_PROFILE")
F=(--region "$REGION" --profile "$FEEDER_PROFILE")
quiet() { "$@" >/dev/null 2>&1 || true; }   # ignore "not found"

# delete_role <profile> <role> — inline policies, managed attachments, role
delete_role() {
  local p
  for p in $(aws iam list-role-policies --role-name "$2" --profile "$1" --query 'PolicyNames[]' --output text 2>/dev/null); do
    aws iam delete-role-policy --role-name "$2" --policy-name "$p" --profile "$1"
  done
  for p in $(aws iam list-attached-role-policies --role-name "$2" --profile "$1" --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null); do
    aws iam detach-role-policy --role-name "$2" --policy-arn "$p" --profile "$1"
  done
  quiet aws iam delete-role --role-name "$2" --profile "$1"
  log "role $2 deleted"
}

# empty_and_delete_bucket <profile> <bucket> — all versions + delete markers, 1000 per call
empty_and_delete_bucket() {
  aws s3api head-bucket --bucket "$2" --profile "$1" >/dev/null 2>&1 || { log "bucket $2 not found"; return 0; }
  local q='{Objects: [Versions[].{Key: Key, VersionId: VersionId} || `[]`, DeleteMarkers[].{Key: Key, VersionId: VersionId} || `[]`][], Quiet: `true`}'
  local batch
  while :; do
    batch=$(aws s3api list-object-versions --bucket "$2" --profile "$1" --no-paginate --max-keys 1000 --query "$q" --output json)
    grep -q '"VersionId"' <<<"$batch" || break
    aws s3api delete-objects --bucket "$2" --profile "$1" --delete "$batch" >/dev/null
  done
  aws s3api delete-bucket --bucket "$2" --profile "$1"
  log "bucket $2 deleted"
}

# --- Storage: inventory, Glue/Athena, trail -----------------------------------
for r in AccessGrantsInventoryOnChange AccessGrantsInventoryDaily; do
  quiet aws events remove-targets --rule "$r" --ids inventory "${S[@]}"
  quiet aws events delete-rule --name "$r" "${S[@]}"
done
quiet aws lambda delete-function --function-name AccessGrantsInventory "${S[@]}"
for t in access_grants feeder_trail storage_datalake_trail; do
  quiet aws glue delete-table --database-name "$GLUE_DATABASE" --name "$t" "${S[@]}"
done
quiet aws glue delete-database --name "$GLUE_DATABASE" "${S[@]}"
quiet aws athena delete-work-group --work-group "$ATHENA_WORKGROUP" --recursive-delete-option "${S[@]}"
quiet aws cloudtrail delete-trail --name "$STORAGE_TRAIL" "${S[@]}"
log "Storage inventory, Glue, Athena, trail removed"

# --- Feeder: Lambda, replication, trail ---------------------------------------
quiet aws lambda delete-function --function-name DataLakePocObjects "${F[@]}"
quiet aws s3api delete-bucket-replication --bucket "$FEEDER_CT_BUCKET" --profile "$FEEDER_PROFILE"
quiet aws cloudtrail delete-trail --name "$FEEDER_TRAIL" "${F[@]}"
log "Feeder Lambda, replication, trail removed"

# --- Storage: RAM share, grant, location --------------------------------------
SHARE_ARN=$(aws ram get-resource-shares --resource-owner SELF --name "$RAM_SHARE_NAME" "${S[@]}" \
  --query "resourceShares[?status=='ACTIVE'].resourceShareArn | [0]" --output text)
[ "$SHARE_ARN" != "None" ] && quiet aws ram delete-resource-share --resource-share-arn "$SHARE_ARN" "${S[@]}"

SCOPE="s3://${DATALAKE_BUCKET}/*"
LOCATION_ID=$(aws s3control list-access-grants-locations --account-id "$STORAGE_ACCOUNT_ID" "${S[@]}" \
  --query "AccessGrantsLocationsList[?LocationScope=='${SCOPE}'].AccessGrantsLocationId | [0]" --output text)
if [ "$LOCATION_ID" != "None" ]; then
  for g in $(aws s3control list-access-grants --account-id "$STORAGE_ACCOUNT_ID" "${S[@]}" \
             --query "AccessGrantsList[?AccessGrantsLocationId=='${LOCATION_ID}'].AccessGrantId" --output text); do
    aws s3control delete-access-grant --account-id "$STORAGE_ACCOUNT_ID" --access-grant-id "$g" "${S[@]}"
  done
  aws s3control delete-access-grants-location --account-id "$STORAGE_ACCOUNT_ID" --access-grants-location-id "$LOCATION_ID" "${S[@]}"
fi
log "RAM share, grants and location removed"

# --- IAM roles -----------------------------------------------------------------
delete_role "$STORAGE_PROFILE" AccessGrantsInventoryRole
delete_role "$STORAGE_PROFILE" S3AccessGrantsLocationRole
delete_role "$FEEDER_PROFILE"  FeederAccessGrantsRole
delete_role "$FEEDER_PROFILE"  FeederDataLakeLambdaRole
delete_role "$FEEDER_PROFILE"  CloudTrailReplicationRole

# --- Buckets (data lake bucket policy is removed first, else the admin check applies) ---
quiet aws s3api delete-bucket-policy --bucket "$DATALAKE_BUCKET" --profile "$STORAGE_PROFILE"
for b in "$DATALAKE_BUCKET" "$STORAGE_CT_BUCKET" "$FEEDER_CT_REPLICA_BUCKET" "$ATHENA_RESULTS_BUCKET" "$INVENTORY_BUCKET"; do
  empty_and_delete_bucket "$STORAGE_PROFILE" "$b"
done
empty_and_delete_bucket "$FEEDER_PROFILE" "$FEEDER_CT_BUCKET"

log "teardown complete"
