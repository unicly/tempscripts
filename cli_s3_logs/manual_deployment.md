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

export GLUE_DATABASE="cloudtrail_logs"
export ATHENA_WORKGROUP="cloudtrail-correlation"
```

Run the commands from the `cli_s3_logs` folder: step 4 zips the Lambda code
from `lambda/`, and the commands write their JSON files to the current folder.

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

---

## 3. CloudTrail

One trail in the **Storage** account, `$STORAGE_TRAIL`, writing to the log
bucket from 1.1. It records:

- **management events**, except KMS and RDS Data API (very noisy). These include
  `GetDataAccess`, Access Grants' internal `AssumeRole` and grant changes
  (`CreateAccessGrant`, `DeleteAccessGrant`), which EventBridge (step 5) reacts to;
- **S3 data events on the data lake bucket only**: the actual reads, writes and
  deletes. They are off by default and cost extra, hence the limit to one bucket.

### 3.1 Create the trail

Single-region, log file validation on. The bucket policy from 1.1 must be in
place, otherwise this fails with `InsufficientS3BucketPolicyException`.

```bash
aws cloudtrail create-trail --name "$STORAGE_TRAIL" --s3-bucket-name "$STORAGE_CT_BUCKET" \
  --no-is-multi-region-trail --no-include-global-service-events --enable-log-file-validation \
  --region "$REGION" --profile "$STORAGE_PROFILE"
```

### 3.2 Event selectors

Keep the trailing `/` after the bucket name: object ARNs start with it, and
without it a bucket named `<DATALAKE_BUCKET>-backup` would match too.
`put-event-selectors` **replaces** all selectors of the trail, so always send
both.

```bash
cat > trail-selectors.json <<EOF
[
  {
    "Name": "Management events (exclude KMS and RDS Data API)",
    "FieldSelectors": [
      { "Field": "eventCategory", "Equals": ["Management"] },
      { "Field": "eventSource", "NotEquals": ["kms.amazonaws.com", "rdsdata.amazonaws.com"] }
    ]
  },
  {
    "Name": "S3 data events on the data lake",
    "FieldSelectors": [
      { "Field": "eventCategory", "Equals": ["Data"] },
      { "Field": "resources.type", "Equals": ["AWS::S3::Object"] },
      { "Field": "resources.ARN", "StartsWith": ["arn:aws:s3:::${DATALAKE_BUCKET}/"] }
    ]
  }
]
EOF

aws cloudtrail put-event-selectors --trail-name "$STORAGE_TRAIL" \
  --advanced-event-selectors file://trail-selectors.json \
  --region "$REGION" --profile "$STORAGE_PROFILE"
```

### 3.3 Start logging

A new trail doesn't log until you start it.

```bash
aws cloudtrail start-logging --name "$STORAGE_TRAIL" --region "$REGION" --profile "$STORAGE_PROFILE"
```

### 3.4 Check

```bash
aws cloudtrail get-trail-status --name "$STORAGE_TRAIL" --region "$REGION" --profile "$STORAGE_PROFILE" \
  --query '{logging:IsLogging, lastDelivery:LatestDeliveryTime, error:LatestDeliveryError}'

aws cloudtrail get-event-selectors --trail-name "$STORAGE_TRAIL" --region "$REGION" --profile "$STORAGE_PROFILE" \
  --query 'AdvancedEventSelectors[].Name'
```

Expected: `logging: true` and both selector names. The first log files appear
in `s3://$STORAGE_CT_BUCKET/AWSLogs/$STORAGE_ACCOUNT_ID/CloudTrail/$REGION/`
after 5–15 minutes.

---

## 4. Lambda

Two functions, Python 3.12:

| Function | Account | Role (step 2) | Code | Purpose |
|---|---|---|---|---|
| `AccessGrantsInventory` | Storage | `AccessGrantsInventoryRole` | `lambda/access_grants_history.py` | keeps the grants history CSV |
| `DataLakePocObjects` | Feeder | `FeederDataLakeLambdaRole` | `lambda/data_lake_poc_objects.py` | test workload: lists, creates, deletes files through Access Grants |

`create-function` can fail with *"The role defined for the function cannot be
assumed by Lambda"* if the role is only a few seconds old: wait a minute and run
it again.

### 4.1 `AccessGrantsInventory` (Storage)

Each run lists all grants and **appends** to the CSV: a `CREATED` line for every
new grant, a `DELETED` line for every grant that disappeared. Existing lines are
never changed. Environment variables: the Storage account ID, the bucket and the
key of the CSV.

```bash
zip -j access_grants_history.zip lambda/access_grants_history.py

aws lambda create-function --function-name AccessGrantsInventory \
  --runtime python3.12 --handler access_grants_history.lambda_handler --timeout 60 \
  --role "arn:aws:iam::${STORAGE_ACCOUNT_ID}:role/AccessGrantsInventoryRole" \
  --zip-file fileb://access_grants_history.zip \
  --environment "Variables={ACCOUNT_ID=${STORAGE_ACCOUNT_ID},BUCKET=${INVENTORY_BUCKET},KEY=${GRANTS_CSV_KEY}}" \
  --region "$REGION" --profile "$STORAGE_PROFILE"
```

**Optional: one run at a time.** The Lambda reads the file, adds lines and writes
it back; the write only succeeds if the file hasn't changed in between, so
parallel runs can't lose lines. Reserving a concurrency of 1 avoids the retries.
New accounts with a concurrency limit of 10 can't reserve any; then skip it.

```bash
aws lambda put-function-concurrency --function-name AccessGrantsInventory \
  --reserved-concurrent-executions 1 --region "$REGION" --profile "$STORAGE_PROFILE"
```

**First run:** creates the CSV with a `CREATED` line for every existing grant.

```bash
aws lambda invoke --function-name AccessGrantsInventory \
  --region "$REGION" --profile "$STORAGE_PROFILE" inventory-out.json
cat inventory-out.json
```

Expected: `{"current_grants": …, "appended": …, "created": …, "deleted": 0, "file": "s3://…"}`.

### 4.2 `DataLakePocObjects` (Feeder)

Assumes `FeederAccessGrantsRole`, asks Access Grants in Storage for credentials,
and uses them on the data lake. It only works once the data lake bucket, the
Access Grants location, the grant to `FeederAccessGrantsRole` and the RAM share
with the Feeder account exist (scripts `02`, `06`, `07`).

```bash
zip -j data_lake_poc_objects.zip lambda/data_lake_poc_objects.py

aws lambda create-function --function-name DataLakePocObjects \
  --runtime python3.12 --handler data_lake_poc_objects.lambda_handler --timeout 30 \
  --role "arn:aws:iam::${FEEDER_ACCOUNT_ID}:role/FeederDataLakeLambdaRole" \
  --zip-file fileb://data_lake_poc_objects.zip \
  --environment "Variables={BUCKET_NAME=${DATALAKE_BUCKET},STORAGE_ACCOUNT_ID=${STORAGE_ACCOUNT_ID},ASSUME_ROLE_ARN=arn:aws:iam::${FEEDER_ACCOUNT_ID}:role/FeederAccessGrantsRole}" \
  --region "$REGION" --profile "$FEEDER_PROFILE"
```

**Test:** one action per invocation.

```bash
for payload in '{"action":"list"}' \
               '{"action":"create","key":"test.txt","body":"hello"}' \
               '{"action":"delete","key":"test.txt"}'; do
  aws lambda invoke --function-name DataLakePocObjects --cli-binary-format raw-in-base64-out \
    --payload "$payload" --region "$REGION" --profile "$FEEDER_PROFILE" out.json >/dev/null
  echo "$payload -> $(cat out.json)"
done
```

`AccessDenied` in the first minutes after setup is IAM/RAM propagation. On
failure the result names the step that was denied (`operation`).

**Deploying a code change later** (either function):

```bash
zip -j access_grants_history.zip lambda/access_grants_history.py
aws lambda update-function-code --function-name AccessGrantsInventory \
  --zip-file fileb://access_grants_history.zip --region "$REGION" --profile "$STORAGE_PROFILE"
```

---

## 5. EventBridge

Two rules in the **Storage** account, on the **`default` event bus** (AWS
service events only arrive there), in the same region as Access Grants. Both
invoke `AccessGrantsInventory`:

| Rule | Trigger |
|---|---|
| `AccessGrantsInventoryOnChange` | every `CreateAccessGrant` / `DeleteAccessGrant` (CloudTrail management event) |
| `AccessGrantsInventoryDaily` | once a day, as a safety net for missed events |

A run without changes appends nothing, so extra runs are harmless.

### 5.1 Rule on grant change

The pattern is compared **exactly, including upper and lower case**:
`AWS API Call via CloudTrail` with a capital T. `Cloudtrail` is valid JSON but
never matches.

```bash
cat > grant-change-pattern.json <<'EOF'
{
  "source": ["aws.s3"],
  "detail-type": ["AWS API Call via CloudTrail"],
  "detail": {
    "eventSource": ["s3.amazonaws.com"],
    "eventName": ["CreateAccessGrant", "DeleteAccessGrant"]
  }
}
EOF

aws events put-rule --name AccessGrantsInventoryOnChange \
  --event-pattern file://grant-change-pattern.json \
  --region "$REGION" --profile "$STORAGE_PROFILE"

aws events put-targets --rule AccessGrantsInventoryOnChange \
  --targets "Id=inventory,Arn=arn:aws:lambda:${REGION}:${STORAGE_ACCOUNT_ID}:function:AccessGrantsInventory" \
  --region "$REGION" --profile "$STORAGE_PROFILE"
```

**Permission:** allow EventBridge to invoke the Lambda, only from this rule.
(The console adds this itself; the CLI doesn't.)

```bash
aws lambda add-permission --function-name AccessGrantsInventory \
  --statement-id AccessGrantsInventoryOnChange \
  --action lambda:InvokeFunction --principal events.amazonaws.com \
  --source-arn "arn:aws:events:${REGION}:${STORAGE_ACCOUNT_ID}:rule/AccessGrantsInventoryOnChange" \
  --region "$REGION" --profile "$STORAGE_PROFILE"
```

### 5.2 Daily rule

```bash
aws events put-rule --name AccessGrantsInventoryDaily --schedule-expression "rate(1 day)" \
  --region "$REGION" --profile "$STORAGE_PROFILE"

aws events put-targets --rule AccessGrantsInventoryDaily \
  --targets "Id=inventory,Arn=arn:aws:lambda:${REGION}:${STORAGE_ACCOUNT_ID}:function:AccessGrantsInventory" \
  --region "$REGION" --profile "$STORAGE_PROFILE"

aws lambda add-permission --function-name AccessGrantsInventory \
  --statement-id AccessGrantsInventoryDaily \
  --action lambda:InvokeFunction --principal events.amazonaws.com \
  --source-arn "arn:aws:events:${REGION}:${STORAGE_ACCOUNT_ID}:rule/AccessGrantsInventoryDaily" \
  --region "$REGION" --profile "$STORAGE_PROFILE"
```

### 5.3 Check

```bash
for r in AccessGrantsInventoryOnChange AccessGrantsInventoryDaily; do
  aws events describe-rule --name "$r" --region "$REGION" --profile "$STORAGE_PROFILE" \
    --query '{rule:Name, state:State, bus:EventBusName}'
  aws events list-targets-by-rule --rule "$r" --region "$REGION" --profile "$STORAGE_PROFILE" \
    --query 'Targets[].Arn' --output text
done
```

Expected: both rules `ENABLED` on bus `default`, each with the
`AccessGrantsInventory` ARN as target.

**End-to-end test:** create or delete a grant, wait 2–5 minutes, then look at
the last lines of the CSV:

```bash
aws s3 cp "s3://${INVENTORY_BUCKET}/${GRANTS_CSV_KEY}" - --profile "$STORAGE_PROFILE" | tail -3
```

If nothing was appended, follow `TROUBLESHOOTING.md` check 7.

---

## 6. Glue

The Glue database and its two tables, in the **Storage** account. The tables are
created with SQL (`CREATE EXTERNAL TABLE`) run in Athena, so the Athena
workgroup comes first.

| Resource | Name | Reads |
|---|---|---|
| Athena workgroup | `$ATHENA_WORKGROUP` | writes results to `s3://$ATHENA_RESULTS_BUCKET/` |
| Glue database | `$GLUE_DATABASE` | |
| Table | `storage_datalake_trail` | the CloudTrail logs (bucket from 1.1) |
| Table | `access_grants_history` | the grants history CSV (bucket from 1.3) |

### 6.1 Athena workgroup

Results go to the bucket from 1.2, encrypted. "Override client-side settings"
is on (`EnforceWorkGroupConfiguration=true`): every query in this workgroup
writes there, users can't choose another location.

```bash
aws athena create-work-group --name "$ATHENA_WORKGROUP" \
  --configuration "ResultConfiguration={OutputLocation=s3://${ATHENA_RESULTS_BUCKET}/,EncryptionConfiguration={EncryptionOption=SSE_S3}},EnforceWorkGroupConfiguration=true,PublishCloudWatchMetricsEnabled=true" \
  --region "$REGION" --profile "$STORAGE_PROFILE"
```

### 6.2 Glue database

```bash
aws glue create-database --database-input "Name=${GLUE_DATABASE}" \
  --region "$REGION" --profile "$STORAGE_PROFILE"
```

### 6.3 Helper to run SQL from the CLI

Athena runs SQL asynchronously. This function starts a statement in the
workgroup and waits for the result. Alternatively, paste the SQL into the
Athena console (step 7 explains how): the `cat` commands below print it with
your values filled in.

```bash
athena_run() {   # athena_run <sql-file>
  local qid state
  qid=$(aws athena start-query-execution --work-group "$ATHENA_WORKGROUP" \
        --query-string "file://$1" --region "$REGION" --profile "$STORAGE_PROFILE" \
        --query QueryExecutionId --output text)
  while :; do
    state=$(aws athena get-query-execution --query-execution-id "$qid" \
            --region "$REGION" --profile "$STORAGE_PROFILE" \
            --query QueryExecution.Status.State --output text)
    case "$state" in
      SUCCEEDED) echo "$1: OK"; return 0;;
      FAILED|CANCELLED)
        aws athena get-query-execution --query-execution-id "$qid" \
          --region "$REGION" --profile "$STORAGE_PROFILE" \
          --query QueryExecution.Status.StateChangeReason --output text
        return 1;;
    esac
    sleep 2
  done
}
```

### 6.4 Table `storage_datalake_trail` (CloudTrail logs)

AWS's standard CloudTrail schema, with two details that matter:

- `useridentity.sessioncontext` declares **`sourceidentity`**. Without it Athena
  can't read `SourceIdentity`, even though it is in the logs.
- **Partition projection** on `year`/`month`/`day`: no crawler, no
  `MSCK REPAIR`, new days are found automatically. Queries must filter on these
  columns to avoid scanning all logs. The year range `2026,2035` sets which
  years can be queried.

```bash
cat > ddl_storage_datalake_trail.sql <<EOF
CREATE EXTERNAL TABLE IF NOT EXISTS ${GLUE_DATABASE}.storage_datalake_trail (
  eventversion string,
  useridentity struct<type:string,principalid:string,arn:string,accountid:string,invokedby:string,accesskeyid:string,username:string,
                      sessioncontext:struct<attributes:struct<mfaauthenticated:string,creationdate:string>,
                                            sessionissuer:struct<type:string,principalid:string,arn:string,accountid:string,username:string>,
                                            sourceidentity:string>>,
  eventtime string, eventsource string, eventname string, awsregion string, sourceipaddress string, useragent string,
  errorcode string, errormessage string, requestparameters string, responseelements string, additionaleventdata string,
  requestid string, eventid string, resources array<struct<arn:string,accountid:string,type:string>>,
  eventtype string, apiversion string, readonly string, recipientaccountid string, serviceeventdetails string,
  sharedeventid string, vpcendpointid string, eventcategory string,
  tlsdetails struct<tlsversion:string,ciphersuite:string,clientprovidedhostheader:string>
)
PARTITIONED BY (year string, month string, day string)
ROW FORMAT SERDE 'org.apache.hive.hcatalog.data.JsonSerDe'
STORED AS INPUTFORMAT 'com.amazon.emr.cloudtrail.CloudTrailInputFormat'
OUTPUTFORMAT 'org.apache.hadoop.hive.ql.io.HiveIgnoreKeyTextOutputFormat'
LOCATION 's3://${STORAGE_CT_BUCKET}/AWSLogs/${STORAGE_ACCOUNT_ID}/CloudTrail/${REGION}/'
TBLPROPERTIES (
  'classification'='cloudtrail',
  'projection.enabled'='true',
  'projection.year.type'='integer',  'projection.year.range'='2026,2035',
  'projection.month.type'='integer', 'projection.month.range'='1,12', 'projection.month.digits'='2',
  'projection.day.type'='integer',   'projection.day.range'='1,31',   'projection.day.digits'='2',
  'storage.location.template'='s3://${STORAGE_CT_BUCKET}/AWSLogs/${STORAGE_ACCOUNT_ID}/CloudTrail/${REGION}/\${year}/\${month}/\${day}'
)
EOF

cat ddl_storage_datalake_trail.sql      # check the values
athena_run ddl_storage_datalake_trail.sql
```

An **organization trail** writes to
`AWSLogs/<organization-id>/<account-id>/CloudTrail/…` instead: then change
`LOCATION` and `storage.location.template` accordingly.

### 6.5 Table `access_grants_history` (grants history CSV)

Reads every file under the CSV's prefix, so keep only the history CSV there.
All columns are strings (OpenCSV SerDe). **`skip.header.line.count = 1`** skips
the header line; without it the header shows up as a row.

```bash
cat > ddl_access_grants_history.sql <<EOF
CREATE EXTERNAL TABLE IF NOT EXISTS ${GLUE_DATABASE}.access_grants_history (
  observed_at string, event string, grant_id string, grant_arn string,
  grantee_type string, grantee_identifier string, permission string,
  grant_scope string, location_id string, created_at string
)
ROW FORMAT SERDE 'org.apache.hadoop.hive.serde2.OpenCSVSerde'
WITH SERDEPROPERTIES ('separatorChar' = ',', 'quoteChar' = '"', 'escapeChar' = '\\\\')
LOCATION 's3://${INVENTORY_BUCKET}/${GRANTS_CSV_PREFIX}'
TBLPROPERTIES ('skip.header.line.count' = '1')
EOF

cat ddl_access_grants_history.sql       # check the values
athena_run ddl_access_grants_history.sql
```

### 6.6 Check

```bash
aws glue get-tables --database-name "$GLUE_DATABASE" --region "$REGION" --profile "$STORAGE_PROFILE" \
  --query 'TableList[].[Name, StorageDescriptor.Location]' --output table
```

Expected: both tables, each with the S3 location of its data.

---

## 7. Athena: the SQL queries

Run the queries in the **Storage** account: **Athena** → **Query editor**.
Top right, select the workgroup **`cloudtrail-correlation`**; on the left, data
source `AwsDataCatalog` and database **`cloudtrail_logs`**. Paste a query, set
`year` / `month`, **Run**. (If you changed `ATHENA_WORKGROUP` or
`GLUE_DATABASE` in step 0, use your names here and replace `cloudtrail_logs.`
in the queries.)

CloudTrail delivers logs after 5–15 minutes; management events (`AssumeRole`,
`GetDataAccess`) can arrive later than the S3 data events. Query once both are
in.

To keep a query in the console, use **Save** (it's stored in the workgroup, not
in S3). The master copy stays in this repository.

### 7.1 Who accessed which file

For every S3 operation made through Access Grants: the **ARN of the grantee
role**, e.g. `arn:aws:iam::<FEEDER_ACCOUNT_ID>:role/FeederAccessGrantsRole`, plus
the operation, bucket and file. It uses only Storage's logs and the grants
history table, and works without callers setting `SourceIdentity`.

How it links the records:

| Step | From → to | Join | Exact? |
|---|---|---|---|
| 1 | S3 data event → Access Grants' internal `AssumeRole` | session name `access-grants-<uuid>` | yes |
| 2 | → `GetDataAccess` | timestamp within ±2 s | timing only |
| 3 | → grant | `matchedAccessGrantArn` | yes |
| 4 | → grantee role ARN | `access_grants_history` (`CREATED` line) | yes |

Set `year` and `month` in the three CloudTrail CTEs to the period you query.

```sql
WITH grants AS (               -- grant IDs are never reused, so deleted grants still resolve
    SELECT DISTINCT grant_id, grantee_identifier AS grantee_role_arn
    FROM cloudtrail_logs.access_grants_history
    WHERE event = 'CREATED'
),
ag_sessions AS (               -- Access Grants vends a scoped session
    SELECT from_iso8601_timestamp(eventtime) AS t,
           regexp_extract(requestparameters, '"roleSessionName"\s*:\s*"([^"]+)"', 1) AS session_name
    FROM cloudtrail_logs.storage_datalake_trail
    WHERE year = '2026' AND month = '11'
      AND eventsource = 'sts.amazonaws.com' AND eventname = 'AssumeRole'
      AND requestparameters LIKE '%access-grants-%'
),
gda AS (                       -- GetDataAccess: which grant was matched
    SELECT from_iso8601_timestamp(eventtime) AS t,
           regexp_extract(additionaleventdata, 'grant/([a-f0-9-]+)', 1) AS grant_id
    FROM cloudtrail_logs.storage_datalake_trail
    WHERE year = '2026' AND month = '11' AND eventname = 'GetDataAccess'
),
s3_events AS (
    SELECT eventtime, eventname,
           useridentity.sessioncontext.sourceidentity AS source_identity,
           regexp_extract(useridentity.arn, '(access-grants-[a-f0-9-]+)$', 1) AS session_name,
           regexp_extract(requestparameters, '"bucketName"\s*:\s*"([^"]+)"', 1) AS bucket,
           regexp_extract(requestparameters, '"key"\s*:\s*"([^"]+)"', 1)        AS file_path
    FROM cloudtrail_logs.storage_datalake_trail
    WHERE year = '2026' AND month = '11'
      AND eventsource = 's3.amazonaws.com'
      AND eventname IN ('GetObject', 'PutObject', 'DeleteObject', 'CopyObject', 'ListObjects')
      AND regexp_like(useridentity.arn, '/access-grants-[a-f0-9-]+$')   -- any location role name
)
SELECT DISTINCT
    s3.eventtime,
    gr.grantee_role_arn,
    s3.source_identity,
    s3.eventname AS operation,
    s3.bucket,
    s3.file_path
FROM s3_events s3
JOIN ag_sessions ag ON ag.session_name = s3.session_name                    -- exact
JOIN gda g          ON abs(to_unixtime(g.t) - to_unixtime(ag.t)) <= 2       -- timing only
JOIN grants gr      ON gr.grant_id = g.grant_id                             -- exact
ORDER BY s3.eventtime DESC
```

- **`grantee_role_arn`** is always filled; it doesn't depend on callers'
  discipline.
- **`source_identity`** is only filled if the caller set `SourceIdentity`. Treat
  it as a bonus, not as evidence.
- If two **different** grantees call within the same 2 seconds, one S3 event can
  appear twice, once per grantee.
- An S3 event is missing although you expect it → its grant has no `CREATED`
  line yet: invoke `AccessGrantsInventory` once and run the query again. If the
  query returns 0 rows, follow `TROUBLESHOOTING.md` checks 0–5.

### 7.2 Grants history

Every grant that ever existed, and when it appeared or disappeared:

```sql
SELECT observed_at, event, grant_id, grantee_identifier, permission, grant_scope, created_at
FROM cloudtrail_logs.access_grants_history
ORDER BY observed_at, grant_id;
```

### 7.3 Current grants

Only the grants that exist now, those whose last line is `CREATED`:

```sql
SELECT grant_id, grantee_type, grantee_identifier, permission, grant_scope, created_at
FROM (
    SELECT *, row_number() OVER (PARTITION BY grant_id
                                 ORDER BY observed_at DESC, event DESC) AS rn
    FROM cloudtrail_logs.access_grants_history
)
WHERE rn = 1 AND event = 'CREATED'
ORDER BY created_at;
```

The table is as current as the Lambda's last run (after every grant change, and
daily).

### 7.4 Are logs arriving?

A quick check that the CloudTrail table sees logs, by event category:

```sql
SELECT eventcategory, count(*) AS events, max(eventtime) AS last
FROM cloudtrail_logs.storage_datalake_trail
WHERE year = '2026' AND month = '11'
GROUP BY eventcategory;
```

Expected: `Management` and `Data` rows. Only `Management` → the data event
selector doesn't match the data lake bucket (3.2), or nothing accessed the data
lake yet.
