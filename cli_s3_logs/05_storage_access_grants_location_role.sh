#!/usr/bin/env bash
# 05 — Storage: S3AccessGrantsLocationRole. Access Grants assumes it to vend
# scoped credentials; it is the only identity with real S3 permissions on the
# data lake. Skip if your existing Access Grants setup already has a location
# for the data lake bucket: 06 reuses an existing location with its own role,
# and this role then stays unused. The role's name shows up as the caller of
# every S3 event (…:assumed-role/<role>/access-grants-<uuid>).
# (Bucket uses SSE-KMS? Add kms:Decrypt / kms:GenerateDataKey on the key.)
source "$(dirname "$0")/lib.sh"

cat > location-trust.json <<EOF
{"Version":"2012-10-17","Statement":[{"Effect":"Allow",
  "Principal":{"Service":"access-grants.s3.amazonaws.com"},
  "Action":["sts:AssumeRole","sts:SetSourceIdentity"],
  "Condition":{"StringEquals":{"aws:SourceAccount":"${STORAGE_ACCOUNT_ID}"}}}]}
EOF
ensure_role "$STORAGE_PROFILE" S3AccessGrantsLocationRole location-trust.json

cat > location-s3.json <<EOF
{"Version":"2012-10-17","Statement":[{"Sid":"S3ReadWrite","Effect":"Allow",
  "Action":["s3:GetObject","s3:GetObjectVersion","s3:GetObjectAcl","s3:GetObjectVersionAcl",
            "s3:GetObjectTagging","s3:GetObjectVersionTagging","s3:PutObject","s3:PutObjectAcl",
            "s3:PutObjectTagging","s3:DeleteObject","s3:DeleteObjectVersion","s3:AbortMultipartUpload",
            "s3:ListMultipartUploadParts","s3:ListBucket","s3:ListBucketVersions","s3:ListBucketMultipartUploads"],
  "Resource":["arn:aws:s3:::${DATALAKE_BUCKET}","arn:aws:s3:::${DATALAKE_BUCKET}/*"]}]}
EOF
aws iam put-role-policy --role-name S3AccessGrantsLocationRole --profile "$STORAGE_PROFILE" \
  --policy-name S3AccessGrantsLocationS3Policy --policy-document file://location-s3.json

log "done: S3AccessGrantsLocationRole"
