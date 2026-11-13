#!/usr/bin/env bash
# 02 — Storage: data lake bucket, reachable only through S3 Access Grants.
# Bucket policy denies every request unless it uses credentials vended by the
# Access Grants instance, comes from an AWS service, or is made by STORAGE_ADMIN_ARN.
# WARNING: a wrong STORAGE_ADMIN_ARN locks you out (only root can remove the policy).
source "$(dirname "$0")/lib.sh"

make_bucket "$STORAGE_PROFILE" "$DATALAKE_BUCKET"

cat > datalake-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "AllowOnlyViaAccessGrants",
    "Effect": "Deny",
    "Principal": "*",
    "Action": "s3:*",
    "Resource": ["arn:aws:s3:::${DATALAKE_BUCKET}", "arn:aws:s3:::${DATALAKE_BUCKET}/*"],
    "Condition": {
      "StringNotEquals": {"s3:accessgrantsinstancearn": "${AG_INSTANCE_ARN}"},
      "Bool":            {"aws:ViaAWSService": "false"},
      "ArnNotEquals":    {"aws:PrincipalArn": "${STORAGE_ADMIN_ARN}"}
    }
  }]
}
EOF
echo "Admin principal kept on the bucket: ${STORAGE_ADMIN_ARN}"
read -r -p "Apply the Access-Grants-only policy to ${DATALAKE_BUCKET}? [y/N] " ok
[ "$ok" = "y" ] || { echo "Skipped bucket policy."; exit 0; }
aws s3api put-bucket-policy --bucket "$DATALAKE_BUCKET" --profile "$STORAGE_PROFILE" --policy file://datalake-policy.json

log "done: ${DATALAKE_BUCKET}"
