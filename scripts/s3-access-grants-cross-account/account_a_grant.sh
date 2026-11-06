#!/usr/bin/env bash
#
# ACCOUNT A (owner of S3 Access Grants and of the bucket).
# Run with credentials for account A, AFTER account_b_setup.sh step 1 (the role must exist).
#
#   1. Resource policy on the Access Grants instance: lets account B request credentials.
#   2. Access grant: READWRITE for the account B role on s3://BUCKET/PREFIX*.
#
# Prerequisites in account A: an Access Grants instance, a registered location covering the
# bucket (with its IAM role that can access the bucket, and KMS key if SSE-KMS is used).
set -euo pipefail

# ---- Edit these -------------------------------------------------------------------
PROFILE="account-a"                # AWS CLI profile for account A
REGION="eu-west-1"                       # region of the Access Grants instance (and bucket)
ACCOUNT_A_ID="111111111111"              # this account
ACCOUNT_B_ID="222222222222"              # account with the Lambda
ROLE_NAME="s3-access-grants-lambda-role" # role created in account B
BUCKET="my-bucket"
PREFIX="data/"                           # "" for the whole bucket
# -----------------------------------------------------------------------------------

ROLE_ARN="arn:aws:iam::${ACCOUNT_B_ID}:role/${ROLE_NAME}"
INSTANCE_ARN="arn:aws:s3:${REGION}:${ACCOUNT_A_ID}:access-grants/default"
WORKDIR="$(mktemp -d)"; trap 'rm -rf "$WORKDIR"' EXIT

# Make sure the profile is for account A
PROFILE_ACCOUNT="$(aws sts get-caller-identity --profile "$PROFILE" --query Account --output text)"
[[ "$PROFILE_ACCOUNT" == "$ACCOUNT_A_ID" ]] \
  || { echo "Profile '$PROFILE' is for account $PROFILE_ACCOUNT, not account A ($ACCOUNT_A_ID)."; exit 1; }

# Find the registered location that covers the bucket. "s3://" is the default location
# (whole account); a location such as s3://my-bucket/ also works.
echo "Registered locations:"
aws s3control list-access-grants-locations --profile "$PROFILE" --account-id "$ACCOUNT_A_ID" --region "$REGION" \
  --query 'AccessGrantsLocationsList[].[AccessGrantsLocationId,LocationScope]' --output table

LOCATION_ID="$(aws s3control list-access-grants-locations --profile "$PROFILE" --account-id "$ACCOUNT_A_ID" --region "$REGION" \
  --query "AccessGrantsLocationsList[?LocationScope=='s3://${BUCKET}/' || LocationScope=='s3://${BUCKET}' || LocationScope=='s3://'] | [0].AccessGrantsLocationId" \
  --output text)"
[[ -n "$LOCATION_ID" && "$LOCATION_ID" != "None" ]] || { echo "No location covers s3://${BUCKET}. Register one first."; exit 1; }

# With the default location "s3://", the sub-prefix includes the bucket name.
LOCATION_SCOPE="$(aws s3control get-access-grants-location --profile "$PROFILE" --account-id "$ACCOUNT_A_ID" --region "$REGION" \
  --access-grants-location-id "$LOCATION_ID" --query LocationScope --output text)"
if [[ "$LOCATION_SCOPE" == "s3://" ]]; then SUB_PREFIX="${BUCKET}/${PREFIX}*"; else SUB_PREFIX="${PREFIX}*"; fi
echo "Using location $LOCATION_ID ($LOCATION_SCOPE), sub-prefix $SUB_PREFIX"

# ---- 1. Resource policy on the Access Grants instance ------------------------------
# WARNING: this REPLACES the instance's current resource policy. If one exists, merge it.
echo "Current resource policy (if any):"
aws s3control get-access-grants-instance-resource-policy --profile "$PROFILE" --account-id "$ACCOUNT_A_ID" --region "$REGION" \
  --query Policy --output text 2>/dev/null || echo "(none)"

cat > "$WORKDIR/instance-policy.json" <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowAccountB",
      "Effect": "Allow",
      "Principal": { "AWS": "${ACCOUNT_B_ID}" },
      "Action": [
        "s3:GetDataAccess",
        "s3:GetAccessGrantsInstanceForPrefix",
        "s3:ListCallerAccessGrants"
      ],
      "Resource": "${INSTANCE_ARN}"
    }
  ]
}
JSON
aws s3control put-access-grants-instance-resource-policy --profile "$PROFILE" --account-id "$ACCOUNT_A_ID" --region "$REGION" \
  --policy "file://$WORKDIR/instance-policy.json"

# ---- 2. Grant for the account B role --------------------------------------------------
aws s3control create-access-grant --profile "$PROFILE" --account-id "$ACCOUNT_A_ID" --region "$REGION" \
  --access-grants-location-id "$LOCATION_ID" \
  --access-grants-location-configuration "S3SubPrefix=${SUB_PREFIX}" \
  --permission READWRITE \
  --grantee "GranteeType=IAM,GranteeIdentifier=${ROLE_ARN}" \
  --query '[AccessGrantId,GrantScope]' --output text

echo "Done. Grants for ${ROLE_ARN}:"
aws s3control list-access-grants --profile "$PROFILE" --account-id "$ACCOUNT_A_ID" --region "$REGION" \
  --grantee-type IAM --grantee-identifier "$ROLE_ARN" \
  --query 'AccessGrantsList[].[AccessGrantId,Permission,GrantScope]' --output table
