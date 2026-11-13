# Manual deployment

Step-by-step instructions to set up the configuration by hand with the AWS
CLI. Most steps are in the **Storage** account; each command names its account
through `--profile`.

## 0. Variables

Set these once in your shell (bash or zsh); every command below uses them.
Bucket names are global across all AWS accounts, so keep the account ID in them
or choose other unique names.

```bash
export REGION="eu-west-1"
export STORAGE_PROFILE="storage"                 # CLI profile of the Storage account
export STORAGE_ACCOUNT_ID="222222222222"         # <- change
export FEEDER_PROFILE="feeder"                   # CLI profile of the Feeder account
export FEEDER_ACCOUNT_ID="111111111111"          # <- change

export DATALAKE_BUCKET="datalake-${STORAGE_ACCOUNT_ID}"   # the data lake bucket (existing or new)
export AG_INSTANCE_ARN="arn:aws:s3:${REGION}:${STORAGE_ACCOUNT_ID}:access-grants/default"

export STORAGE_CT_BUCKET="cloudtrail-logs-datalake-${STORAGE_ACCOUNT_ID}"
export ATHENA_RESULTS_BUCKET="athena-query-results-datalake-${STORAGE_ACCOUNT_ID}"
export INVENTORY_BUCKET="access-grants-inventory-${STORAGE_ACCOUNT_ID}"

export GRANTS_CSV_PREFIX="access-grants-history/"
export GRANTS_CSV_KEY="${GRANTS_CSV_PREFIX}access_grants_history.csv"

export STORAGE_TRAIL="StorageDataLakeTrail"      # trail created in a later step
export LOG_RETENTION_DAYS=30
```

---

## 1. Buckets

Three buckets, all in the Storage account:

| Bucket | Content | Bucket policy | Lifecycle |
|---|---|---|---|
| `$STORAGE_CT_BUCKET` | CloudTrail logs | yes: only the trail may write | yes: delete logs after `LOG_RETENTION_DAYS` |
| `$ATHENA_RESULTS_BUCKET` | Athena query results | none | none |
| `$INVENTORY_BUCKET` | Grants history CSV (export of Access Grants) | none | none: the history must be kept |

New buckets get **Block Public Access** fully on and default encryption
**SSE-S3** automatically (S3 defaults since 2023), so no extra commands are
needed for that; check 1.4 confirms it.

### 1.1 CloudTrail log bucket

Create the bucket:

```bash
aws s3 mb "s3://$STORAGE_CT_BUCKET" --region "$REGION" --profile "$STORAGE_PROFILE"
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
aws s3 mb "s3://$ATHENA_RESULTS_BUCKET" --region "$REGION" --profile "$STORAGE_PROFILE"
```

**Policy:** no bucket policy. Athena writes the results with the permissions of
the user who runs the query, so access is controlled by that user's IAM policy.
The Athena workgroup (later step) points at this bucket.

### 1.3 Grants history bucket (export of Access Grants as CSV)

```bash
aws s3 mb "s3://$INVENTORY_BUCKET" --region "$REGION" --profile "$STORAGE_PROFILE"
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

---

## 2. IAM roles

Four roles, two in each account:

| Role | Account | Used by | Policies |
|---|---|---|---|
| `FeederDataLakeLambdaRole` | Feeder | the Lambda `DataLakePocObjects` (execution role) | managed `AWSLambdaBasicExecutionRole`, inline `AssumeFeederAccessGrantsRole` |
| `FeederAccessGrantsRole` | Feeder | the **grantee**: the grant in Storage is issued to it | inline `GetDataAccessOnStorage` |
| `S3AccessGrantsLocationRole` | Storage | Access Grants, to vend credentials on the data lake | inline `S3AccessGrantsLocationS3Policy` |
| `AccessGrantsInventoryRole` | Storage | the Lambda `AccessGrantsInventory` (execution role) | managed `AWSLambdaBasicExecutionRole`, inline `AccessGrantsInventoryPolicy` |

Create them **in this order**: the trust policy of `FeederAccessGrantsRole`
names `FeederDataLakeLambdaRole`, and IAM checks that a named principal exists
when the policy is saved. If a command fails with `Invalid principal`, the role
it names isn't visible to IAM yet: wait 10–20 seconds and run it again.

New roles need a few minutes before they work everywhere. `AccessDenied` right
after creating them is usually propagation, not a mistake.

### 2.1 `FeederDataLakeLambdaRole` (Feeder)

The Lambda's execution role. It can do only one thing: assume the grantee role
(and write its own logs).

**Trust policy:** only Lambda can use the role.

```bash
cat > feeder-lambda-trust.json <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Service": "lambda.amazonaws.com" },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

aws iam create-role --role-name FeederDataLakeLambdaRole --profile "$FEEDER_PROFILE" \
  --assume-role-policy-document file://feeder-lambda-trust.json
```

**Managed policy** `AWSLambdaBasicExecutionRole`: CloudWatch Logs for the Lambda.

```bash
aws iam attach-role-policy --role-name FeederDataLakeLambdaRole --profile "$FEEDER_PROFILE" \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
```

**Inline policy** `AssumeFeederAccessGrantsRole`: may assume the grantee role,
and pass a `SourceIdentity` along.

```bash
cat > assume-feeder-access-grants-role.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["sts:AssumeRole", "sts:SetSourceIdentity"],
      "Resource": "arn:aws:iam::${FEEDER_ACCOUNT_ID}:role/FeederAccessGrantsRole"
    }
  ]
}
EOF

aws iam put-role-policy --role-name FeederDataLakeLambdaRole --profile "$FEEDER_PROFILE" \
  --policy-name AssumeFeederAccessGrantsRole --policy-document file://assume-feeder-access-grants-role.json
```

### 2.2 `FeederAccessGrantsRole` (Feeder) — the grantee

The identity the grant in Storage is issued to. It has **no S3 permissions**:
it can only ask Access Grants in Storage for credentials. Its ARN is what the
attribution queries return.

**Trust policy:** only `FeederDataLakeLambdaRole` may assume it.

```bash
cat > feeder-access-grants-trust.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "AWS": "arn:aws:iam::${FEEDER_ACCOUNT_ID}:role/FeederDataLakeLambdaRole" },
      "Action": ["sts:AssumeRole", "sts:SetSourceIdentity"]
    }
  ]
}
EOF

aws iam create-role --role-name FeederAccessGrantsRole --profile "$FEEDER_PROFILE" \
  --assume-role-policy-document file://feeder-access-grants-trust.json
```

**Inline policy** `GetDataAccessOnStorage`: may call Access Grants on the
Storage account's instance. (`GetAccessGrantsInstanceForPrefix` is only used by
the S3 Access Grants SDK plugin; harmless otherwise.)

```bash
cat > get-data-access-on-storage.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:GetDataAccess", "s3:GetAccessGrantsInstanceForPrefix"],
      "Resource": "${AG_INSTANCE_ARN}"
    }
  ]
}
EOF

aws iam put-role-policy --role-name FeederAccessGrantsRole --profile "$FEEDER_PROFILE" \
  --policy-name GetDataAccessOnStorage --policy-document file://get-data-access-on-storage.json
```

### 2.3 `S3AccessGrantsLocationRole` (Storage)

Access Grants assumes this role to vend credentials, narrowed to the granted
prefix and permission. It is the **only** identity with real S3 permissions on
the data lake, and its name appears as the caller of every S3 event in
CloudTrail (`…:assumed-role/S3AccessGrantsLocationRole/access-grants-<uuid>`).

> Skip this role if an Access Grants **location for the data lake bucket
> already exists**: that location keeps its own role.

**Trust policy:** only the Access Grants service, and only for this account.
`sts:SetSourceIdentity` lets Access Grants carry a caller's `SourceIdentity` onto
the credentials it vends.

```bash
cat > location-role-trust.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Service": "access-grants.s3.amazonaws.com" },
      "Action": ["sts:AssumeRole", "sts:SetSourceIdentity"],
      "Condition": {
        "StringEquals": { "aws:SourceAccount": "${STORAGE_ACCOUNT_ID}" }
      }
    }
  ]
}
EOF

aws iam create-role --role-name S3AccessGrantsLocationRole --profile "$STORAGE_PROFILE" \
  --assume-role-policy-document file://location-role-trust.json
```

**Inline policy** `S3AccessGrantsLocationS3Policy`: read, write and list on the
data lake bucket. If the bucket uses SSE-KMS, also allow `kms:Decrypt` and
`kms:GenerateDataKey` on its key.

```bash
cat > location-role-s3.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "S3ReadWrite",
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:GetObjectVersion",
        "s3:GetObjectAcl",
        "s3:GetObjectVersionAcl",
        "s3:GetObjectTagging",
        "s3:GetObjectVersionTagging",
        "s3:PutObject",
        "s3:PutObjectAcl",
        "s3:PutObjectTagging",
        "s3:DeleteObject",
        "s3:DeleteObjectVersion",
        "s3:AbortMultipartUpload",
        "s3:ListMultipartUploadParts",
        "s3:ListBucket",
        "s3:ListBucketVersions",
        "s3:ListBucketMultipartUploads"
      ],
      "Resource": [
        "arn:aws:s3:::${DATALAKE_BUCKET}",
        "arn:aws:s3:::${DATALAKE_BUCKET}/*"
      ]
    }
  ]
}
EOF

aws iam put-role-policy --role-name S3AccessGrantsLocationRole --profile "$STORAGE_PROFILE" \
  --policy-name S3AccessGrantsLocationS3Policy --policy-document file://location-role-s3.json
```

### 2.4 `AccessGrantsInventoryRole` (Storage)

Execution role of the Lambda that keeps the grants history CSV. It may list the
grants and read and write **only** the CSV file.

**Trust policy:** only Lambda can use the role.

```bash
cat > inventory-lambda-trust.json <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Service": "lambda.amazonaws.com" },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

aws iam create-role --role-name AccessGrantsInventoryRole --profile "$STORAGE_PROFILE" \
  --assume-role-policy-document file://inventory-lambda-trust.json
```

**Managed policy** `AWSLambdaBasicExecutionRole`: CloudWatch Logs for the Lambda.

```bash
aws iam attach-role-policy --role-name AccessGrantsInventoryRole --profile "$STORAGE_PROFILE" \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
```

**Inline policy** `AccessGrantsInventoryPolicy`. `s3:ListBucket` (limited to the
CSV's prefix) is there so that on the first run, before the file exists, S3
answers "not found" instead of "access denied".

```bash
cat > access-grants-inventory-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "s3:ListAccessGrants",
      "Resource": "${AG_INSTANCE_ARN}"
    },
    {
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject"],
      "Resource": "arn:aws:s3:::${INVENTORY_BUCKET}/${GRANTS_CSV_KEY}"
    },
    {
      "Effect": "Allow",
      "Action": "s3:ListBucket",
      "Resource": "arn:aws:s3:::${INVENTORY_BUCKET}",
      "Condition": { "StringLike": { "s3:prefix": "${GRANTS_CSV_PREFIX}*" } }
    }
  ]
}
EOF

aws iam put-role-policy --role-name AccessGrantsInventoryRole --profile "$STORAGE_PROFILE" \
  --policy-name AccessGrantsInventoryPolicy --policy-document file://access-grants-inventory-policy.json
```

### 2.5 Check

Each role with its inline and managed policies:

```bash
check_role() {   # check_role <profile> <role>
  echo "== $2"
  aws iam list-role-policies --role-name "$2" --profile "$1" --query 'PolicyNames' --output text
  aws iam list-attached-role-policies --role-name "$2" --profile "$1" \
    --query 'AttachedPolicies[].PolicyName' --output text
}
check_role "$FEEDER_PROFILE"  FeederDataLakeLambdaRole
check_role "$FEEDER_PROFILE"  FeederAccessGrantsRole
check_role "$STORAGE_PROFILE" S3AccessGrantsLocationRole
check_role "$STORAGE_PROFILE" AccessGrantsInventoryRole
```

Expected:

| Role | Inline | Managed |
|---|---|---|
| `FeederDataLakeLambdaRole` | `AssumeFeederAccessGrantsRole` | `AWSLambdaBasicExecutionRole` |
| `FeederAccessGrantsRole` | `GetDataAccessOnStorage` | (none) |
| `S3AccessGrantsLocationRole` | `S3AccessGrantsLocationS3Policy` | (none) |
| `AccessGrantsInventoryRole` | `AccessGrantsInventoryPolicy` | `AWSLambdaBasicExecutionRole` |
