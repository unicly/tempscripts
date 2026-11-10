#!/usr/bin/env bash
# 08 — Storage: Access Grants location for the data lake + READWRITE grant to
# Feeder's FeederAccessGrantsRole. Reuses an existing location/grant if found.
# Rule for auditing: one grant per consuming role.
source "$(dirname "$0")/lib.sh"

SCOPE="s3://${DATALAKE_BUCKET}/*"
GRANTEE="arn:aws:iam::${FEEDER_ACCOUNT_ID}:role/FeederAccessGrantsRole"

LOCATION_ID=$(aws s3control list-access-grants-locations --account-id "$STORAGE_ACCOUNT_ID" \
  --region "$REGION" --profile "$STORAGE_PROFILE" \
  --query "AccessGrantsLocationsList[?LocationScope=='${SCOPE}'].AccessGrantsLocationId | [0]" --output text)
if [ -z "$LOCATION_ID" ] || [ "$LOCATION_ID" = "None" ]; then
  log "creating location ${SCOPE}"
  LOCATION_ID=$(retry 6 aws s3control create-access-grants-location --account-id "$STORAGE_ACCOUNT_ID" \
    --region "$REGION" --profile "$STORAGE_PROFILE" --location-scope "$SCOPE" \
    --iam-role-arn "arn:aws:iam::${STORAGE_ACCOUNT_ID}:role/S3AccessGrantsLocationRole" \
    --query AccessGrantsLocationId --output text)
else
  log "location ${SCOPE} exists: ${LOCATION_ID}"
fi

GRANT_ID=$(aws s3control list-access-grants --account-id "$STORAGE_ACCOUNT_ID" \
  --region "$REGION" --profile "$STORAGE_PROFILE" \
  --query "AccessGrantsList[?AccessGrantsLocationId=='${LOCATION_ID}' && Grantee.GranteeIdentifier=='${GRANTEE}'].AccessGrantId | [0]" --output text)
if [ -z "$GRANT_ID" ] || [ "$GRANT_ID" = "None" ]; then
  log "creating grant ${GRANTEE} -> READWRITE"
  GRANT_ID=$(aws s3control create-access-grant --account-id "$STORAGE_ACCOUNT_ID" \
    --region "$REGION" --profile "$STORAGE_PROFILE" \
    --access-grants-location-id "$LOCATION_ID" --permission READWRITE \
    --grantee "GranteeType=IAM,GranteeIdentifier=${GRANTEE}" \
    --query AccessGrantId --output text)
else
  log "grant exists: ${GRANT_ID}"
fi

log "done: location ${LOCATION_ID}, grant ${GRANT_ID}"
