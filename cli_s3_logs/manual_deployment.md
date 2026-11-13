# Manual deployment

Step-by-step instructions to set up the configuration by hand, in the
**Storage** account, with the AWS CLI.

## 0. Variables

Set these once in your shell (bash or zsh); every command below uses them.
Bucket names are global across all AWS accounts, so keep the account ID in them
or choose other unique names.

```bash
export REGION="eu-west-1"
export STORAGE_PROFILE="storage"                 # CLI profile of the Storage account
export STORAGE_ACCOUNT_ID="222222222222"         # <- change

export STORAGE_CT_BUCKET="cloudtrail-logs-datalake-${STORAGE_ACCOUNT_ID}"
export ATHENA_RESULTS_BUCKET="athena-query-results-datalake-${STORAGE_ACCOUNT_ID}"
export INVENTORY_BUCKET="access-grants-inventory-${STORAGE_ACCOUNT_ID}"

export STORAGE_TRAIL="StorageDataLakeTrail"      # trail created in a later step
export LOG_RETENTION_DAYS=30
```

In `us-east-1`, leave out `--create-bucket-configuration` in the
`create-bucket` commands below.

---

## 1. Buckets

Three buckets, all in the Storage account:

| Bucket | Content | Bucket policy | Lifecycle |
|---|---|---|---|
| `$STORAGE_CT_BUCKET` | CloudTrail logs | yes: only the trail may write | yes: delete logs after `LOG_RETENTION_DAYS` |
| `$ATHENA_RESULTS_BUCKET` | Athena query results | none | none |
| `$INVENTORY_BUCKET` | Grants history CSV (export of Access Grants) | none | none: the history must be kept |

Every bucket gets **Block Public Access** fully on and default encryption
**SSE-S3**.

### 1.1 CloudTrail log bucket

Create the bucket, block public access, turn on encryption:

```bash
aws s3api create-bucket --bucket "$STORAGE_CT_BUCKET" \
  --region "$REGION" --profile "$STORAGE_PROFILE" \
  --create-bucket-configuration "LocationConstraint=$REGION"

aws s3api put-public-access-block --bucket "$STORAGE_CT_BUCKET" --profile "$STORAGE_PROFILE" \
  --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

aws s3api put-bucket-encryption --bucket "$STORAGE_CT_BUCKET" --profile "$STORAGE_PROFILE" \
  --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
```

**Bucket policy:** CloudTrail may check the bucket ACL and write log files, but
only for the trail `$STORAGE_TRAIL` of this account. The trail doesn't need to
exist yet.

```bash
cat > storage-ct-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AWSCloudTrailAclCheck",
      "Effect": "Allow",
      "Principal": { "Service": "cloudtrail.amazonaws.com" },
      "Action": "s3:GetBucketAcl",
      "Resource": "arn:aws:s3:::${STORAGE_CT_BUCKET}",
      "Condition": {
        "StringEquals": {
          "aws:SourceArn": "arn:aws:cloudtrail:${REGION}:${STORAGE_ACCOUNT_ID}:trail/${STORAGE_TRAIL}"
        }
      }
    },
    {
      "Sid": "AWSCloudTrailWrite",
      "Effect": "Allow",
      "Principal": { "Service": "cloudtrail.amazonaws.com" },
      "Action": "s3:PutObject",
      "Resource": "arn:aws:s3:::${STORAGE_CT_BUCKET}/AWSLogs/${STORAGE_ACCOUNT_ID}/*",
      "Condition": {
        "StringEquals": {
          "s3:x-amz-acl": "bucket-owner-full-control",
          "aws:SourceArn": "arn:aws:cloudtrail:${REGION}:${STORAGE_ACCOUNT_ID}:trail/${STORAGE_TRAIL}"
        }
      }
    }
  ]
}
EOF

aws s3api put-bucket-policy --bucket "$STORAGE_CT_BUCKET" --profile "$STORAGE_PROFILE" \
  --policy file://storage-ct-policy.json
```

**Lifecycle:** delete logs after `LOG_RETENTION_DAYS` days. The second rule
removes the delete markers left behind (it can't be combined with `Days` in one
rule), and old versions are removed after 1 day if versioning is ever turned on.

```bash
cat > lifecycle.json <<EOF
{
  "Rules": [
    {
      "ID": "expire-logs-and-old-versions",
      "Status": "Enabled",
      "Filter": {},
      "Expiration": { "Days": ${LOG_RETENTION_DAYS} },
      "NoncurrentVersionExpiration": { "NoncurrentDays": 1 }
    },
    {
      "ID": "remove-expired-delete-markers",
      "Status": "Enabled",
      "Filter": {},
      "Expiration": { "ExpiredObjectDeleteMarker": true }
    }
  ]
}
EOF

aws s3api put-bucket-lifecycle-configuration --bucket "$STORAGE_CT_BUCKET" --profile "$STORAGE_PROFILE" \
  --lifecycle-configuration file://lifecycle.json
```

The lifecycle rules apply to the whole bucket: keep only CloudTrail logs in it.

### 1.2 Athena results bucket

```bash
aws s3api create-bucket --bucket "$ATHENA_RESULTS_BUCKET" \
  --region "$REGION" --profile "$STORAGE_PROFILE" \
  --create-bucket-configuration "LocationConstraint=$REGION"

aws s3api put-public-access-block --bucket "$ATHENA_RESULTS_BUCKET" --profile "$STORAGE_PROFILE" \
  --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

aws s3api put-bucket-encryption --bucket "$ATHENA_RESULTS_BUCKET" --profile "$STORAGE_PROFILE" \
  --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
```

**Policy:** no bucket policy. Athena writes the results with the permissions of
the user who runs the query, so access is controlled by that user's IAM policy.
The Athena workgroup (later step) points at this bucket.

### 1.3 Grants history bucket (export of Access Grants as CSV)

```bash
aws s3api create-bucket --bucket "$INVENTORY_BUCKET" \
  --region "$REGION" --profile "$STORAGE_PROFILE" \
  --create-bucket-configuration "LocationConstraint=$REGION"

aws s3api put-public-access-block --bucket "$INVENTORY_BUCKET" --profile "$STORAGE_PROFILE" \
  --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

aws s3api put-bucket-encryption --bucket "$INVENTORY_BUCKET" --profile "$STORAGE_PROFILE" \
  --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
```

**Policy:** no bucket policy and **no lifecycle rule**: the history must be kept.
The Lambda `AccessGrantsInventory` (later step) writes the CSV to
`access-grants-history/access_grants_history.csv`, with an IAM policy on its
role that allows only that file.

### 1.4 Check

```bash
for b in "$STORAGE_CT_BUCKET" "$ATHENA_RESULTS_BUCKET" "$INVENTORY_BUCKET"; do
  echo "== $b"
  aws s3api get-bucket-encryption --bucket "$b" --profile "$STORAGE_PROFILE" \
    --query 'ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.SSEAlgorithm' --output text
  aws s3api get-public-access-block --bucket "$b" --profile "$STORAGE_PROFILE" \
    --query 'PublicAccessBlockConfiguration' --output text
done

aws s3api get-bucket-policy --bucket "$STORAGE_CT_BUCKET" --profile "$STORAGE_PROFILE" --query Policy --output text
aws s3api get-bucket-lifecycle-configuration --bucket "$STORAGE_CT_BUCKET" --profile "$STORAGE_PROFILE" \
  --query 'Rules[].ID' --output text
```

Expected: `AES256` and `True True True True` for each bucket; the CloudTrail
policy; the rules `expire-logs-and-old-versions` and
`remove-expired-delete-markers`.
