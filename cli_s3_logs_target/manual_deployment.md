# Data lake audit — CORE and STORAGE accounts

All CLI commands to set up the configuration, on one page.

## Overview

Two kinds of AWS accounts:

| Account | How many | Contains |
|---|---|---|
| **CORE** | one | the data **consumers** (IAM users and roles); the central **CloudTrail log bucket**; the grants history; **Glue**, **Athena**; the **Lambdas**; the **alerts** |
| **STORAGE** | several | a **data lake bucket**, reachable only through **S3 Access Grants**; a **CloudTrail trail** that writes **directly into CORE's log bucket**; an **EventBridge** rule that forwards events to CORE |

```
STORAGE account (×N)                                   CORE account
────────────────────                                   ────────────
data lake bucket ◀── S3 calls with vended credentials ── consumers (users / roles)
Access Grants instance ◀──────── GetDataAccess ────────  (shared with CORE through RAM)
  grants → consumer ARNs in CORE

CloudTrail StorageDataLakeTrail ─── writes directly ──▶  log bucket (Object Lock 365 days)
                                                           AWSLogs/<STORAGE account>/CloudTrail/…
EventBridge rule ── grant changes, trail changes ──────▶  default event bus
                                                           ├─ Lambda AccessGrantsInventory ──▶ grants history CSV (one per account)
                                                           └─ SNS alert: trail stopped / changed
role AccessGrantsInventoryReadRole ◀── AssumeRole ─────   Lambda AccessGrantsInventory
                                                          Lambda LogDeliveryMonitor (every 30 min)
                                                           └─ CloudWatch alarm per account ──▶ SNS alert: no logs
                                                          Glue + Athena: who accessed which file
```

**Why CloudTrail writes directly to CORE:** a trail can deliver to a bucket in
another account. There is no log bucket in the STORAGE accounts and no
replication; the logs are out of reach of the STORAGE accounts' admins as soon
as they are written. The weak spot: an admin of a STORAGE account can stop or
change their own trail. Two alerts cover that (step 9):

- **trail changed** (immediate): `StopLogging`, `DeleteTrail`, `UpdateTrail` or
  `PutEventSelectors` in a STORAGE account → email;
- **no logs** (within the hour): a Lambda checks every 30 minutes when the last
  log of each STORAGE account arrived in CORE → CloudWatch alarm → email. This
  also catches everything else: a broken bucket policy, a deleted trail, a
  missing account.

**Order:** CORE first (steps 1–4), then each STORAGE account (step 5), then CORE
again (steps 6–11). The roles and policies name each other, and IAM checks that
a named principal exists when a policy is saved.

---

## 0. Variables

Run everything in **bash** (type `bash` first if your terminal uses zsh): the
account lists below are bash arrays. Set the CORE values once. Bucket names are
global across AWS, so keep the account ID in them.

```bash
export REGION="eu-west-1"                         # one region for everything

# CORE
export CORE_PROFILE="core"                        # CLI profile of the CORE account
export CORE_ACCOUNT_ID="111111111111"             # <- change

# All STORAGE accounts (add new accounts here, see step 13)
STORAGE_ACCOUNTS=("222222222222" "333333333333")  # <- change

# Data consumers in CORE: IAM users or roles that get grants in every STORAGE account
CONSUMER_ARNS=("arn:aws:iam::${CORE_ACCOUNT_ID}:role/DataLakeReader")   # <- change

# CORE buckets
export LOG_BUCKET="cloudtrail-logs-datalake-${CORE_ACCOUNT_ID}"
export ATHENA_RESULTS_BUCKET="athena-query-results-datalake-${CORE_ACCOUNT_ID}"
export INVENTORY_BUCKET="access-grants-inventory-${CORE_ACCOUNT_ID}"
export GRANTS_PREFIX="access-grants-history/"     # one CSV per STORAGE account: <prefix><account>.csv

# CloudTrail log bucket: Object Lock and lifecycle (read 1.1 before choosing the mode)
export OBJECT_LOCK_MODE="GOVERNANCE"              # GOVERNANCE (testing) or COMPLIANCE (production)
export OBJECT_LOCK_DAYS=365
export LOG_RETENTION_DAYS=365                     # must be >= OBJECT_LOCK_DAYS

# Names (the same in every STORAGE account)
export STORAGE_TRAIL="StorageDataLakeTrail"
export GLUE_DATABASE="cloudtrail_logs"
export ATHENA_WORKGROUP="cloudtrail-correlation"
export ALERT_EMAIL="you@example.com"              # <- change: receives the alerts
```

Helpers used by later steps:

```bash
# json_list a b c  ->  "a","b","c"
json_list() { local out="" x; for x in "$@"; do out+="${out:+,}\"$x\""; done; echo "$out"; }

CORE=(--region "$REGION" --profile "$CORE_PROFILE")
TRAIL_ARNS=(); for a in "${STORAGE_ACCOUNTS[@]}"; do TRAIL_ARNS+=("arn:aws:cloudtrail:${REGION}:${a}:trail/${STORAGE_TRAIL}"); done
STORAGE_ACCOUNTS_CSV=$(IFS=,; echo "${STORAGE_ACCOUNTS[*]}")
```

The commands write their JSON and code files to the current folder; run them in
an empty working folder.

---

## 1. CORE — buckets

| Bucket | Content | Specials |
|---|---|---|
| `$LOG_BUCKET` | CloudTrail logs of all STORAGE accounts | Object Lock, bucket policy, lifecycle |
| `$ATHENA_RESULTS_BUCKET` | Athena query results | — |
| `$INVENTORY_BUCKET` | grants history, one CSV per STORAGE account | no lifecycle: the history is kept |

New buckets get Block Public Access and SSE-S3 encryption by default.

### 1.1 CloudTrail log bucket

**Object Lock** keeps every log file unchangeable for `OBJECT_LOCK_DAYS` days:

| Mode | Who can delete a locked log early? | Use for |
|---|---|---|
| `GOVERNANCE` | only principals with `s3:BypassGovernanceRetention`, with an explicit bypass flag | testing |
| `COMPLIANCE` | **nobody**, not even root; the bucket can't be deleted until the newest log is 365 days old | production |

Object Lock can only be turned on at creation (with `s3api create-bucket`), can
never be turned off, and turns on versioning.

```bash
aws s3api create-bucket --bucket "$LOG_BUCKET" --object-lock-enabled-for-bucket \
  --create-bucket-configuration "LocationConstraint=$REGION" "${CORE[@]}"
# (in us-east-1: leave out --create-bucket-configuration)

cat > object-lock.json <<EOF
{ "ObjectLockEnabled": "Enabled",
  "Rule": { "DefaultRetention": { "Mode": "${OBJECT_LOCK_MODE}", "Days": ${OBJECT_LOCK_DAYS} } } }
EOF
aws s3api put-object-lock-configuration --bucket "$LOG_BUCKET" "${CORE[@]}" \
  --object-lock-configuration file://object-lock.json
```

**Bucket policy:**

| Sid | Effect | Purpose |
|---|---|---|
| `AWSCloudTrailAclCheck` | Allow | the STORAGE trails may check the bucket ACL |
| `AWSCloudTrailWrite<account>` | Allow | one per STORAGE account: its trail may write, **only under its own** `AWSLogs/<account>/` |
| `DenyWritesExceptCloudTrail` | Deny | nobody else can upload (no forged logs) |
| `DenyDeleteMarkers` | Deny | nobody can hide a log behind a delete marker |

CloudTrail's requests carry the trail's ARN in `aws:SourceArn`; requests from
users and roles carry none, and a missing key counts as "not equal", so the
Deny applies to them. Both Deny statements apply to administrators too. The
lifecycle rule isn't affected (S3 runs it; bucket policies don't apply).

```bash
WRITE_STATEMENTS=""
for a in "${STORAGE_ACCOUNTS[@]}"; do
  WRITE_STATEMENTS+=$(cat <<EOF
    {
      "Sid": "AWSCloudTrailWrite${a}",
      "Effect": "Allow",
      "Principal": { "Service": "cloudtrail.amazonaws.com" },
      "Action": "s3:PutObject",
      "Resource": "arn:aws:s3:::${LOG_BUCKET}/AWSLogs/${a}/*",
      "Condition": { "StringEquals": {
        "s3:x-amz-acl": "bucket-owner-full-control",
        "aws:SourceArn": "arn:aws:cloudtrail:${REGION}:${a}:trail/${STORAGE_TRAIL}" } }
    },
EOF
)
done

cat > log-bucket-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AWSCloudTrailAclCheck",
      "Effect": "Allow",
      "Principal": { "Service": "cloudtrail.amazonaws.com" },
      "Action": "s3:GetBucketAcl",
      "Resource": "arn:aws:s3:::${LOG_BUCKET}",
      "Condition": { "StringEquals": { "aws:SourceArn": [ $(json_list "${TRAIL_ARNS[@]}") ] } }
    },
${WRITE_STATEMENTS}
    {
      "Sid": "DenyWritesExceptCloudTrail",
      "Effect": "Deny",
      "Principal": "*",
      "Action": "s3:PutObject",
      "Resource": "arn:aws:s3:::${LOG_BUCKET}/*",
      "Condition": { "StringNotEquals": { "aws:SourceArn": [ $(json_list "${TRAIL_ARNS[@]}") ] } }
    },
    {
      "Sid": "DenyDeleteMarkers",
      "Effect": "Deny",
      "Principal": "*",
      "Action": "s3:DeleteObject",
      "Resource": "arn:aws:s3:::${LOG_BUCKET}/*"
    }
  ]
}
EOF
aws s3api put-bucket-policy --bucket "$LOG_BUCKET" "${CORE[@]}" --policy file://log-bucket-policy.json
```

**Lifecycle:** after `LOG_RETENTION_DAYS` a log gets a delete marker; a day later
the version is deleted (its lock has expired by then).

```bash
cat > lifecycle.json <<EOF
{ "Rules": [
  { "ID": "expire-logs-and-old-versions", "Status": "Enabled", "Filter": {},
    "Expiration": { "Days": ${LOG_RETENTION_DAYS} },
    "NoncurrentVersionExpiration": { "NoncurrentDays": 1 } },
  { "ID": "remove-expired-delete-markers", "Status": "Enabled", "Filter": {},
    "Expiration": { "ExpiredObjectDeleteMarker": true } } ] }
EOF
aws s3api put-bucket-lifecycle-configuration --bucket "$LOG_BUCKET" "${CORE[@]}" \
  --lifecycle-configuration file://lifecycle.json
```

### 1.2 Athena results and grants history buckets

```bash
aws s3 mb "s3://$ATHENA_RESULTS_BUCKET" "${CORE[@]}"
aws s3 mb "s3://$INVENTORY_BUCKET"      "${CORE[@]}"
```

No bucket policy: access comes from the IAM policies of the Lambda (step 3) and
of the people running queries.

---

## 2. CORE — alert topic (SNS)

All alerts go to one SNS topic with an email subscription. **Confirm the
subscription** in the email AWS sends, or no alert arrives.

```bash
TOPIC_ARN=$(aws sns create-topic --name DataLakeAlerts "${CORE[@]}" --query TopicArn --output text)
aws sns subscribe --topic-arn "$TOPIC_ARN" --protocol email --notification-endpoint "$ALERT_EMAIL" "${CORE[@]}"
```

Topic policy: the account itself, EventBridge (trail-change alert, step 8) and
CloudWatch alarms (step 9) may publish.

```bash
cat > topic-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    { "Sid": "AccountOwner", "Effect": "Allow",
      "Principal": { "AWS": "arn:aws:iam::${CORE_ACCOUNT_ID}:root" },
      "Action": ["sns:Publish", "sns:Subscribe", "sns:GetTopicAttributes", "sns:SetTopicAttributes"],
      "Resource": "${TOPIC_ARN}" },
    { "Sid": "EventBridgeTrailChangeAlert", "Effect": "Allow",
      "Principal": { "Service": "events.amazonaws.com" }, "Action": "sns:Publish", "Resource": "${TOPIC_ARN}",
      "Condition": { "ArnEquals": { "aws:SourceArn": "arn:aws:events:${REGION}:${CORE_ACCOUNT_ID}:rule/TrailChangeAlert" } } },
    { "Sid": "CloudWatchAlarms", "Effect": "Allow",
      "Principal": { "Service": "cloudwatch.amazonaws.com" }, "Action": "sns:Publish", "Resource": "${TOPIC_ARN}",
      "Condition": { "ArnLike": { "aws:SourceArn": "arn:aws:cloudwatch:${REGION}:${CORE_ACCOUNT_ID}:alarm:*" } } }
  ]
}
EOF
aws sns set-topic-attributes --topic-arn "$TOPIC_ARN" --attribute-name Policy \
  --attribute-value file://topic-policy.json "${CORE[@]}"
```

---

## 3. CORE — IAM roles and the consumer policy

| Role / policy | Used by | Permissions |
|---|---|---|
| `AccessGrantsInventoryRole` | Lambda `AccessGrantsInventory` | assume `AccessGrantsInventoryReadRole` in each STORAGE account; read/write the grants history CSVs |
| `LogDeliveryMonitorRole` | Lambda `LogDeliveryMonitor` | list the log bucket; publish one CloudWatch metric |
| `DataLakeConsumerAccess` (managed policy) | the consumers | ask the STORAGE accounts' Access Grants for credentials |

```bash
cat > lambda-trust.json <<'EOF'
{ "Version": "2012-10-17",
  "Statement": [ { "Effect": "Allow", "Principal": { "Service": "lambda.amazonaws.com" }, "Action": "sts:AssumeRole" } ] }
EOF
```

### 3.1 `AccessGrantsInventoryRole`

```bash
aws iam create-role --role-name AccessGrantsInventoryRole --assume-role-policy-document file://lambda-trust.json "${CORE[@]}"
aws iam attach-role-policy --role-name AccessGrantsInventoryRole "${CORE[@]}" \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole

READ_ROLE_ARNS=(); for a in "${STORAGE_ACCOUNTS[@]}"; do READ_ROLE_ARNS+=("arn:aws:iam::${a}:role/AccessGrantsInventoryReadRole"); done
cat > inventory-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow", "Action": "sts:AssumeRole", "Resource": [ $(json_list "${READ_ROLE_ARNS[@]}") ] },
    { "Effect": "Allow", "Action": ["s3:GetObject", "s3:PutObject"],
      "Resource": "arn:aws:s3:::${INVENTORY_BUCKET}/${GRANTS_PREFIX}*" },
    { "Effect": "Allow", "Action": "s3:ListBucket", "Resource": "arn:aws:s3:::${INVENTORY_BUCKET}",
      "Condition": { "StringLike": { "s3:prefix": "${GRANTS_PREFIX}*" } } }
  ]
}
EOF
aws iam put-role-policy --role-name AccessGrantsInventoryRole --policy-name AccessGrantsInventoryPolicy \
  --policy-document file://inventory-policy.json "${CORE[@]}"
```

### 3.2 `LogDeliveryMonitorRole`

```bash
aws iam create-role --role-name LogDeliveryMonitorRole --assume-role-policy-document file://lambda-trust.json "${CORE[@]}"
aws iam attach-role-policy --role-name LogDeliveryMonitorRole "${CORE[@]}" \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole

cat > monitor-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow", "Action": "s3:ListBucket", "Resource": "arn:aws:s3:::${LOG_BUCKET}",
      "Condition": { "StringLike": { "s3:prefix": "AWSLogs/*" } } },
    { "Effect": "Allow", "Action": "cloudwatch:PutMetricData", "Resource": "*",
      "Condition": { "StringEquals": { "cloudwatch:namespace": "DataLake/CloudTrailDelivery" } } }
  ]
}
EOF
aws iam put-role-policy --role-name LogDeliveryMonitorRole --policy-name LogDeliveryMonitorPolicy \
  --policy-document file://monitor-policy.json "${CORE[@]}"
```

### 3.3 Consumer policy `DataLakeConsumerAccess`

Consumers need **no S3 permissions**: they only ask Access Grants for
credentials, which are scoped to their grant. This policy lets them ask every
STORAGE account's instance.

```bash
INSTANCE_ARNS=(); for a in "${STORAGE_ACCOUNTS[@]}"; do INSTANCE_ARNS+=("arn:aws:s3:${REGION}:${a}:access-grants/default"); done
cat > consumer-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow", "Action": ["s3:GetDataAccess", "s3:GetAccessGrantsInstanceForPrefix"],
      "Resource": [ $(json_list "${INSTANCE_ARNS[@]}") ] }
  ]
}
EOF
CONSUMER_POLICY_ARN=$(aws iam create-policy --policy-name DataLakeConsumerAccess \
  --policy-document file://consumer-policy.json "${CORE[@]}" --query Policy.Arn --output text)
```

Attach it to each consumer (a role or a user):

```bash
aws iam attach-role-policy --role-name DataLakeReader      --policy-arn "$CONSUMER_POLICY_ARN" "${CORE[@]}"
# for an IAM user:
# aws iam attach-user-policy --user-name <user-name> --policy-arn "$CONSUMER_POLICY_ARN" "${CORE[@]}"
```

### 3.4 Event bus: let the STORAGE accounts send events to CORE

```bash
for a in "${STORAGE_ACCOUNTS[@]}"; do
  aws events put-permission --event-bus-name default --action events:PutEvents \
    --principal "$a" --statement-id "AllowStorage${a}" "${CORE[@]}"
done
```

---

## 4. CORE — check before the STORAGE accounts

```bash
aws s3api get-bucket-policy --bucket "$LOG_BUCKET" "${CORE[@]}" --query Policy --output text | grep -o '"Sid":"[^"]*"'
aws s3api get-object-lock-configuration --bucket "$LOG_BUCKET" "${CORE[@]}" --query ObjectLockConfiguration.Rule
for r in AccessGrantsInventoryRole LogDeliveryMonitorRole; do aws iam get-role --role-name "$r" "${CORE[@]}" --query Role.Arn --output text; done
aws events describe-event-bus --name default "${CORE[@]}" --query Policy --output text | grep -o 'AllowStorage[0-9]*'
```

Expected: the four kinds of Sids (one `AWSCloudTrailWrite…` per account), the lock
mode and days, both role ARNs, one `AllowStorage…` per account.

---

## 5. STORAGE — repeat for every STORAGE account

Set the values of **the account you're configuring**, then run 5.1–5.9. Repeat
with the next account.

```bash
export STORAGE_PROFILE="storage-a"                      # <- CLI profile of this STORAGE account
export STORAGE_ACCOUNT_ID="222222222222"                # <- its account ID (must be in STORAGE_ACCOUNTS)
export DATALAKE_BUCKET="datalake-${STORAGE_ACCOUNT_ID}" # its data lake bucket (existing or new)
export STORAGE_ADMIN_ARN="arn:aws:iam::${STORAGE_ACCOUNT_ID}:role/CHANGE-ME"   # <- admin role or user, see 5.1

ST=(--region "$REGION" --profile "$STORAGE_PROFILE")
AG_INSTANCE_ARN="arn:aws:s3:${REGION}:${STORAGE_ACCOUNT_ID}:access-grants/default"
```

### 5.1 Data lake bucket (Access Grants only)

Create it if it doesn't exist yet:

```bash
aws s3 mb "s3://$DATALAKE_BUCKET" "${ST[@]}"
```

The policy denies every request unless it uses credentials from **this**
account's Access Grants instance, comes from an AWS service, or comes from
`STORAGE_ADMIN_ARN`.

> ⚠️ `STORAGE_ADMIN_ARN` must be an IAM **role or user** ARN
> (`arn:aws:iam::…:role/…`), not an `arn:aws:sts::…:assumed-role/…` session. If
> it's wrong you lock yourself out, and only the account's root user can remove
> the policy.

```bash
cat > datalake-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    { "Sid": "AllowOnlyViaAccessGrants", "Effect": "Deny", "Principal": "*", "Action": "s3:*",
      "Resource": ["arn:aws:s3:::${DATALAKE_BUCKET}", "arn:aws:s3:::${DATALAKE_BUCKET}/*"],
      "Condition": {
        "StringNotEquals": { "s3:accessgrantsinstancearn": "${AG_INSTANCE_ARN}" },
        "Bool":            { "aws:ViaAWSService": "false" },
        "ArnNotEquals":    { "aws:PrincipalArn": "${STORAGE_ADMIN_ARN}" } } }
  ]
}
EOF
aws s3api put-bucket-policy --bucket "$DATALAKE_BUCKET" --policy file://datalake-policy.json "${ST[@]}"
```

### 5.2 Access Grants instance

One instance per account and region. If it exists already, the command fails
with `AccessGrantsInstanceAlreadyExists`: that's fine.

```bash
aws s3control create-access-grants-instance --account-id "$STORAGE_ACCOUNT_ID" "${ST[@]}"
```

### 5.3 Location role `S3AccessGrantsLocationRole`

Access Grants assumes it to vend credentials; it's the only identity with real
S3 permissions on the data lake, and its name appears as the caller of every S3
event (`…/S3AccessGrantsLocationRole/access-grants-<uuid>`). Skip this if a
location for the data lake bucket exists already (it keeps its own role).

```bash
cat > location-trust.json <<EOF
{ "Version": "2012-10-17",
  "Statement": [ { "Effect": "Allow", "Principal": { "Service": "access-grants.s3.amazonaws.com" },
    "Action": ["sts:AssumeRole", "sts:SetSourceIdentity"],
    "Condition": { "StringEquals": { "aws:SourceAccount": "${STORAGE_ACCOUNT_ID}" } } } ] }
EOF
aws iam create-role --role-name S3AccessGrantsLocationRole --assume-role-policy-document file://location-trust.json "${ST[@]}"

cat > location-s3.json <<EOF
{ "Version": "2012-10-17",
  "Statement": [ { "Sid": "S3ReadWrite", "Effect": "Allow",
    "Action": ["s3:GetObject", "s3:GetObjectVersion", "s3:GetObjectAcl", "s3:GetObjectVersionAcl",
               "s3:GetObjectTagging", "s3:GetObjectVersionTagging", "s3:PutObject", "s3:PutObjectAcl",
               "s3:PutObjectTagging", "s3:DeleteObject", "s3:DeleteObjectVersion", "s3:AbortMultipartUpload",
               "s3:ListMultipartUploadParts", "s3:ListBucket", "s3:ListBucketVersions", "s3:ListBucketMultipartUploads"],
    "Resource": ["arn:aws:s3:::${DATALAKE_BUCKET}", "arn:aws:s3:::${DATALAKE_BUCKET}/*"] } ] }
EOF
aws iam put-role-policy --role-name S3AccessGrantsLocationRole --policy-name S3AccessGrantsLocationS3Policy \
  --policy-document file://location-s3.json "${ST[@]}"
```

(Bucket with SSE-KMS? Also allow `kms:Decrypt` and `kms:GenerateDataKey` on its key.)

### 5.4 Location and grants

The location covers the whole bucket; each consumer from `CONSUMER_ARNS` gets
its own grant. **One grant per consumer**: the attribution query goes from a
grant to its grantee. Wait a minute after 5.3 if the location fails with an
invalid-role error (IAM propagation).

```bash
LOCATION_ID=$(aws s3control create-access-grants-location --account-id "$STORAGE_ACCOUNT_ID" \
  --location-scope "s3://${DATALAKE_BUCKET}/*" \
  --iam-role-arn "arn:aws:iam::${STORAGE_ACCOUNT_ID}:role/S3AccessGrantsLocationRole" \
  "${ST[@]}" --query AccessGrantsLocationId --output text)
echo "location: $LOCATION_ID"

for c in "${CONSUMER_ARNS[@]}"; do
  aws s3control create-access-grant --account-id "$STORAGE_ACCOUNT_ID" \
    --access-grants-location-id "$LOCATION_ID" --permission READ \
    --grantee "GranteeType=IAM,GranteeIdentifier=${c}" \
    "${ST[@]}" --query '[AccessGrantId, Grantee.GranteeIdentifier, Permission]' --output text
done
```

Change `--permission` to `READWRITE` for consumers that also write. A grant can
be limited to a sub-prefix with `--access-grants-location-configuration
S3SubPrefix=<prefix>/*`.

### 5.5 RAM share with CORE

A grant to an identity in another account only works if the instance is also
shared with that account. Without AWS Organizations, CORE must accept the
invitation (step 6).

```bash
aws ram create-resource-share --name S3AccessGrantsCoreShare --allow-external-principals \
  --resource-arns "$AG_INSTANCE_ARN" --principals "$CORE_ACCOUNT_ID" \
  "${ST[@]}" --query resourceShare.resourceShareArn --output text
```

Don't also put a resource policy on the instance: RAM turns that into a second
share.

### 5.6 Role for the grants inventory: `AccessGrantsInventoryReadRole`

CORE's Lambda assumes this role to list this account's grants. It can do
nothing else.

```bash
cat > read-role-trust.json <<EOF
{ "Version": "2012-10-17",
  "Statement": [ { "Effect": "Allow",
    "Principal": { "AWS": "arn:aws:iam::${CORE_ACCOUNT_ID}:role/AccessGrantsInventoryRole" },
    "Action": "sts:AssumeRole" } ] }
EOF
aws iam create-role --role-name AccessGrantsInventoryReadRole --assume-role-policy-document file://read-role-trust.json "${ST[@]}"

cat > read-role-policy.json <<EOF
{ "Version": "2012-10-17",
  "Statement": [ { "Effect": "Allow", "Action": "s3:ListAccessGrants", "Resource": "${AG_INSTANCE_ARN}" } ] }
EOF
aws iam put-role-policy --role-name AccessGrantsInventoryReadRole --policy-name ListAccessGrants \
  --policy-document file://read-role-policy.json "${ST[@]}"
```

### 5.7 CloudTrail trail → CORE log bucket

The trail writes directly to CORE's bucket. Creating it fails with
`InsufficientS3BucketPolicyException` if this account isn't in CORE's bucket
policy (step 1.1).

```bash
aws cloudtrail create-trail --name "$STORAGE_TRAIL" --s3-bucket-name "$LOG_BUCKET" \
  --no-is-multi-region-trail --no-include-global-service-events --enable-log-file-validation "${ST[@]}"

cat > trail-selectors.json <<EOF
[
  { "Name": "Management events (exclude KMS and RDS Data API)",
    "FieldSelectors": [ { "Field": "eventCategory", "Equals": ["Management"] },
                        { "Field": "eventSource", "NotEquals": ["kms.amazonaws.com", "rdsdata.amazonaws.com"] } ] },
  { "Name": "S3 data events on the data lake",
    "FieldSelectors": [ { "Field": "eventCategory", "Equals": ["Data"] },
                        { "Field": "resources.type", "Equals": ["AWS::S3::Object"] },
                        { "Field": "resources.ARN", "StartsWith": ["arn:aws:s3:::${DATALAKE_BUCKET}/"] } ] }
]
EOF
aws cloudtrail put-event-selectors --trail-name "$STORAGE_TRAIL" --advanced-event-selectors file://trail-selectors.json "${ST[@]}"
aws cloudtrail start-logging --name "$STORAGE_TRAIL" "${ST[@]}"
```

Management events carry `GetDataAccess`, Access Grants' internal `AssumeRole`
and grant changes; data events the actual reads and writes, on the data lake
bucket only (the trailing `/` keeps `<bucket>-backup` from matching).

### 5.8 EventBridge: forward events to CORE

One rule forwards **grant changes** (for the grants history) and **trail
changes** (for the alert) to CORE's default event bus. EventBridge needs a role
to send to another account's bus.

```bash
cat > events-trust.json <<'EOF'
{ "Version": "2012-10-17",
  "Statement": [ { "Effect": "Allow", "Principal": { "Service": "events.amazonaws.com" }, "Action": "sts:AssumeRole" } ] }
EOF
aws iam create-role --role-name EventBridgeForwardToCoreRole --assume-role-policy-document file://events-trust.json "${ST[@]}"

cat > forward-policy.json <<EOF
{ "Version": "2012-10-17",
  "Statement": [ { "Effect": "Allow", "Action": "events:PutEvents",
    "Resource": "arn:aws:events:${REGION}:${CORE_ACCOUNT_ID}:event-bus/default" } ] }
EOF
aws iam put-role-policy --role-name EventBridgeForwardToCoreRole --policy-name PutEventsToCore \
  --policy-document file://forward-policy.json "${ST[@]}"

cat > forward-pattern.json <<'EOF'
{
  "source": ["aws.s3", "aws.cloudtrail"],
  "detail-type": ["AWS API Call via CloudTrail"],
  "detail": {
    "eventName": ["CreateAccessGrant", "DeleteAccessGrant",
                  "StopLogging", "DeleteTrail", "UpdateTrail", "PutEventSelectors"]
  }
}
EOF
aws events put-rule --name ForwardToCore --event-pattern file://forward-pattern.json "${ST[@]}"
aws events put-targets --rule ForwardToCore "${ST[@]}" --targets \
  "Id=core,Arn=arn:aws:events:${REGION}:${CORE_ACCOUNT_ID}:event-bus/default,RoleArn=arn:aws:iam::${STORAGE_ACCOUNT_ID}:role/EventBridgeForwardToCoreRole"
```

The pattern is compared exactly, case included: `AWS API Call via CloudTrail`
with a capital T.

### 5.9 Check this STORAGE account

```bash
aws cloudtrail get-trail-status --name "$STORAGE_TRAIL" "${ST[@]}" --query '{logging:IsLogging, error:LatestDeliveryError}'
aws s3control list-access-grants --account-id "$STORAGE_ACCOUNT_ID" "${ST[@]}" \
  --query 'AccessGrantsList[].[AccessGrantId, Grantee.GranteeIdentifier, Permission]' --output table
aws ram get-resource-shares --resource-owner SELF --name S3AccessGrantsCoreShare "${ST[@]}" --query 'resourceShares[].status'
aws events list-targets-by-rule --rule ForwardToCore "${ST[@]}" --query 'Targets[].Arn' --output text
```

Expected: `logging: true` with no error; one grant per consumer; the share
`ACTIVE`; CORE's event bus as target. After 5–15 minutes the first logs appear
in CORE under `s3://$LOG_BUCKET/AWSLogs/$STORAGE_ACCOUNT_ID/CloudTrail/$REGION/`.

**Next STORAGE account:** go back to the start of step 5.

---

## 6. CORE — accept the RAM invitations

One invitation per STORAGE account.

```bash
for inv in $(aws ram get-resource-share-invitations "${CORE[@]}" \
               --query "resourceShareInvitations[?status=='PENDING'].resourceShareInvitationArn" --output text); do
  aws ram accept-resource-share-invitation --resource-share-invitation-arn "$inv" "${CORE[@]}" \
    --query 'resourceShareInvitation.[senderAccountId, status]' --output text
done
```

Expected: one line `<STORAGE account> ACCEPTED` per account. New grants and
shares need a few minutes before they work.

---

## 7. CORE — Lambda functions

| Function | Role | Runs | Does |
|---|---|---|---|
| `AccessGrantsInventory` | `AccessGrantsInventoryRole` | after every grant change in a STORAGE account, and daily | appends grant changes to the account's CSV |
| `LogDeliveryMonitor` | `LogDeliveryMonitorRole` | every 30 minutes | publishes, per STORAGE account, the minutes since its last log in CORE |

### 7.1 `AccessGrantsInventory`

For each STORAGE account it assumes `AccessGrantsInventoryReadRole`, lists the
grants and **appends** to `s3://$INVENTORY_BUCKET/${GRANTS_PREFIX}<account>.csv`:
a `CREATED` line for every new grant, a `DELETED` line for every grant that
disappeared. Existing lines are never changed. The upload is conditional on the
ETag, so two runs can't lose lines (a conflicting run fails and Lambda retries
it). Called by a grant change, it updates only that account; otherwise all.

```bash
cat > access_grants_inventory.py <<'EOF'
"""Append-only history of S3 Access Grants grants, one CSV per STORAGE account."""
import csv
import io
import json
import os
from datetime import datetime, timezone

import boto3
from botocore.exceptions import ClientError

ACCOUNTS  = [a.strip() for a in os.environ["STORAGE_ACCOUNTS"].split(",") if a.strip()]
ROLE_NAME = os.environ["READ_ROLE_NAME"]
BUCKET    = os.environ["BUCKET"]
PREFIX    = os.environ["PREFIX"]
REGION    = os.environ.get("AWS_REGION")

FIELDS = ["observed_at", "event", "grant_id", "grant_arn", "grantee_type",
          "grantee_identifier", "permission", "grant_scope", "location_id", "created_at"]

s3  = boto3.client("s3")
sts = boto3.client("sts")


def s3control_for(account):
    c = sts.assume_role(RoleArn=f"arn:aws:iam::{account}:role/{ROLE_NAME}",
                        RoleSessionName="AccessGrantsInventory")["Credentials"]
    return boto3.client("s3control", region_name=REGION, aws_access_key_id=c["AccessKeyId"],
                        aws_secret_access_key=c["SecretAccessKey"], aws_session_token=c["SessionToken"])


def list_grants(account):
    client, grants, token = s3control_for(account), {}, None
    while True:
        kwargs = {"AccountId": account, "MaxResults": 1000}
        if token:
            kwargs["NextToken"] = token
        resp = client.list_access_grants(**kwargs)
        for g in resp.get("AccessGrantsList", []):
            grants[g["AccessGrantId"]] = g
        token = resp.get("NextToken")
        if not token:
            return grants


def read_history(key):
    try:
        obj = s3.get_object(Bucket=BUCKET, Key=key)
    except ClientError as e:
        if e.response["Error"]["Code"] in ("NoSuchKey", "404"):
            return "", None
        raise
    return obj["Body"].read().decode("utf-8"), obj["ETag"]


def active_grants(text):
    last = {}
    for row in csv.DictReader(io.StringIO(text)):
        last[row["grant_id"]] = row
    return {gid: row for gid, row in last.items() if row["event"] == "CREATED"}


def to_row(now, event, g):
    return {"observed_at": now, "event": event, "grant_id": g["AccessGrantId"],
            "grant_arn": g["AccessGrantArn"], "grantee_type": g["Grantee"]["GranteeType"],
            "grantee_identifier": g["Grantee"]["GranteeIdentifier"], "permission": g["Permission"],
            "grant_scope": g.get("GrantScope", ""), "location_id": g.get("AccessGrantsLocationId", ""),
            "created_at": g["CreatedAt"].isoformat()}


def update(account):
    key = f"{PREFIX}{account}.csv"
    text, etag = read_history(key)
    current = list_grants(account)
    active  = active_grants(text)
    now = datetime.now(timezone.utc).isoformat(timespec="seconds")

    rows = [to_row(now, "CREATED", g) for gid, g in sorted(current.items()) if gid not in active]
    for gid in sorted(set(active) - set(current)):
        row = dict(active[gid])
        row.update(observed_at=now, event="DELETED")
        rows.append(row)

    if rows:
        buf = io.StringIO()
        w = csv.DictWriter(buf, fieldnames=FIELDS, quoting=csv.QUOTE_ALL, lineterminator="\n")
        if not text:
            w.writeheader()
        w.writerows(rows)
        if text and not text.endswith("\n"):
            text += "\n"
        cond = {"IfMatch": etag} if etag else {"IfNoneMatch": "*"}
        s3.put_object(Bucket=BUCKET, Key=key, Body=(text + buf.getvalue()).encode("utf-8"),
                      ContentType="text/csv", **cond)

    return {"account": account, "current_grants": len(current), "appended": len(rows),
            "created": sum(r["event"] == "CREATED" for r in rows),
            "deleted": sum(r["event"] == "DELETED" for r in rows), "file": f"s3://{BUCKET}/{key}"}


def lambda_handler(event, context):
    event = event or {}
    source_account = event.get("account")
    if event.get("source") == "aws.s3" and source_account in ACCOUNTS:
        targets = [source_account]          # a grant changed in this account
    else:
        targets = ACCOUNTS                  # schedule or manual run: all accounts
    results, errors = [], []
    for account in targets:
        try:
            results.append(update(account))
        except Exception as e:              # keep going with the other accounts
            errors.append(f"{account}: {e}")
    print(json.dumps({"results": results, "errors": errors}))
    if errors:
        raise RuntimeError("; ".join(errors))   # Lambda retries; finished accounts append nothing twice
    return {"results": results}
EOF

zip -q access_grants_inventory.zip access_grants_inventory.py
aws lambda create-function --function-name AccessGrantsInventory \
  --runtime python3.12 --handler access_grants_inventory.lambda_handler --timeout 300 \
  --role "arn:aws:iam::${CORE_ACCOUNT_ID}:role/AccessGrantsInventoryRole" \
  --zip-file fileb://access_grants_inventory.zip \
  --environment "Variables={STORAGE_ACCOUNTS=${STORAGE_ACCOUNTS_CSV},READ_ROLE_NAME=AccessGrantsInventoryReadRole,BUCKET=${INVENTORY_BUCKET},PREFIX=${GRANTS_PREFIX}}" \
  "${CORE[@]}"
```

Optional, one run at a time (skip if the account's concurrency limit is 10):

```bash
aws lambda put-function-concurrency --function-name AccessGrantsInventory --reserved-concurrent-executions 1 "${CORE[@]}"
```

First run, all accounts:

```bash
aws lambda invoke --function-name AccessGrantsInventory "${CORE[@]}" out.json >/dev/null; cat out.json
```

Expected: one result per STORAGE account, `"created"` = its number of grants.
`AccessDenied` on `AssumeRole` right after setup is IAM propagation: retry in a
few minutes.

### 7.2 `LogDeliveryMonitor`

For each STORAGE account it finds the newest log file under
`AWSLogs/<account>/CloudTrail/<region>/` (today, or yesterday just after
midnight) and publishes **`MinutesSinceLastLog`** (namespace
`DataLake/CloudTrailDelivery`, dimension `Account`). No log for two days gives
`9999`.

```bash
cat > log_delivery_monitor.py <<'EOF'
"""Publishes, per STORAGE account, the minutes since its last CloudTrail log arrived in CORE."""
import json
import os
from datetime import datetime, timedelta, timezone

import boto3

BUCKET    = os.environ["LOG_BUCKET"]
ACCOUNTS  = [a.strip() for a in os.environ["STORAGE_ACCOUNTS"].split(",") if a.strip()]
REGION    = os.environ.get("TRAIL_REGION") or os.environ["AWS_REGION"]
NAMESPACE = "DataLake/CloudTrailDelivery"

s3 = boto3.client("s3")
cw = boto3.client("cloudwatch")


def newest_log(account, now):
    for day in (now, now - timedelta(days=1)):
        prefix, newest = f"AWSLogs/{account}/CloudTrail/{REGION}/{day:%Y/%m/%d}/", None
        for page in s3.get_paginator("list_objects_v2").paginate(Bucket=BUCKET, Prefix=prefix):
            for obj in page.get("Contents", []):
                if newest is None or obj["LastModified"] > newest:
                    newest = obj["LastModified"]
        if newest:
            return newest
    return None


def lambda_handler(event, context):
    now, minutes, data = datetime.now(timezone.utc), {}, []
    for account in ACCOUNTS:
        newest = newest_log(account, now)
        minutes[account] = round((now - newest).total_seconds() / 60, 1) if newest else 9999
        data.append({"MetricName": "MinutesSinceLastLog", "Unit": "None", "Value": minutes[account],
                     "Dimensions": [{"Name": "Account", "Value": account}]})
    for i in range(0, len(data), 20):
        cw.put_metric_data(Namespace=NAMESPACE, MetricData=data[i:i + 20])
    print(json.dumps(minutes))
    return minutes
EOF

zip -q log_delivery_monitor.zip log_delivery_monitor.py
aws lambda create-function --function-name LogDeliveryMonitor \
  --runtime python3.12 --handler log_delivery_monitor.lambda_handler --timeout 120 \
  --role "arn:aws:iam::${CORE_ACCOUNT_ID}:role/LogDeliveryMonitorRole" \
  --zip-file fileb://log_delivery_monitor.zip \
  --environment "Variables={LOG_BUCKET=${LOG_BUCKET},STORAGE_ACCOUNTS=${STORAGE_ACCOUNTS_CSV}}" \
  "${CORE[@]}"

aws lambda invoke --function-name LogDeliveryMonitor "${CORE[@]}" out.json >/dev/null; cat out.json
```

Expected: one value per STORAGE account, normally below 15 (minutes).

---

## 8. CORE — EventBridge rules

All on CORE's **default** bus. The forwarded events keep the STORAGE account's
ID in `account`.

| Rule | Trigger | Target |
|---|---|---|
| `AccessGrantsInventoryOnChange` | `CreateAccessGrant` / `DeleteAccessGrant` from a STORAGE account | Lambda `AccessGrantsInventory` |
| `AccessGrantsInventoryDaily` | every day (safety net) | Lambda `AccessGrantsInventory` |
| `LogDeliveryMonitorSchedule` | every 30 minutes | Lambda `LogDeliveryMonitor` |
| `TrailChangeAlert` | `StopLogging`, `DeleteTrail`, `UpdateTrail`, `PutEventSelectors` from a STORAGE account | SNS topic (email) |

```bash
LAMBDA_ARN="arn:aws:lambda:${REGION}:${CORE_ACCOUNT_ID}:function"

# allow_rule <function> <rule> — lets one rule invoke one function
allow_rule() {
  aws lambda add-permission --function-name "$1" --statement-id "$2" --action lambda:InvokeFunction \
    --principal events.amazonaws.com --source-arn "arn:aws:events:${REGION}:${CORE_ACCOUNT_ID}:rule/$2" \
    "${CORE[@]}" >/dev/null
}

cat > grant-change-pattern.json <<EOF
{ "source": ["aws.s3"], "detail-type": ["AWS API Call via CloudTrail"],
  "account": [ $(json_list "${STORAGE_ACCOUNTS[@]}") ],
  "detail": { "eventSource": ["s3.amazonaws.com"], "eventName": ["CreateAccessGrant", "DeleteAccessGrant"] } }
EOF
aws events put-rule --name AccessGrantsInventoryOnChange --event-pattern file://grant-change-pattern.json "${CORE[@]}"
aws events put-targets --rule AccessGrantsInventoryOnChange --targets "Id=inventory,Arn=${LAMBDA_ARN}:AccessGrantsInventory" "${CORE[@]}"
allow_rule AccessGrantsInventory AccessGrantsInventoryOnChange

aws events put-rule --name AccessGrantsInventoryDaily --schedule-expression "rate(1 day)" "${CORE[@]}"
aws events put-targets --rule AccessGrantsInventoryDaily --targets "Id=inventory,Arn=${LAMBDA_ARN}:AccessGrantsInventory" "${CORE[@]}"
allow_rule AccessGrantsInventory AccessGrantsInventoryDaily

aws events put-rule --name LogDeliveryMonitorSchedule --schedule-expression "rate(30 minutes)" "${CORE[@]}"
aws events put-targets --rule LogDeliveryMonitorSchedule --targets "Id=monitor,Arn=${LAMBDA_ARN}:LogDeliveryMonitor" "${CORE[@]}"
allow_rule LogDeliveryMonitor LogDeliveryMonitorSchedule
```

**Trail-change alert**, with a readable email text (input transformer):

```bash
cat > trail-change-pattern.json <<EOF
{ "source": ["aws.cloudtrail"], "detail-type": ["AWS API Call via CloudTrail"],
  "account": [ $(json_list "${STORAGE_ACCOUNTS[@]}") ],
  "detail": { "eventSource": ["cloudtrail.amazonaws.com"],
              "eventName": ["StopLogging", "DeleteTrail", "UpdateTrail", "PutEventSelectors"] } }
EOF
aws events put-rule --name TrailChangeAlert --event-pattern file://trail-change-pattern.json "${CORE[@]}"

cat > trail-change-target.json <<EOF
[ { "Id": "email", "Arn": "${TOPIC_ARN}",
    "InputTransformer": {
      "InputPathsMap": { "account": "\$.account", "event": "\$.detail.eventName", "trail": "\$.detail.requestParameters.name",
                         "who": "\$.detail.userIdentity.arn", "time": "\$.time" },
      "InputTemplate": "\"CloudTrail changed in STORAGE account <account>: <event> on trail <trail> by <who> at <time>. Check that the trail still logs to CORE.\"" } } ]
EOF
aws events put-targets --rule TrailChangeAlert --targets file://trail-change-target.json "${CORE[@]}"
```

---

## 9. CORE — CloudWatch alarms

**"No logs" alarm, one per STORAGE account:** fires when the newest log is more
than 2 hours old. Missing data also counts as a problem
(`--treat-missing-data breaching`), so the alarm also fires if the monitor
Lambda stops running. An account with management events on normally produces
a log file every few minutes; raise the threshold for very quiet accounts.

```bash
for a in "${STORAGE_ACCOUNTS[@]}"; do
  aws cloudwatch put-metric-alarm --alarm-name "CloudTrailLogsMissing-${a}" \
    --alarm-description "No CloudTrail log from STORAGE account ${a} in CORE for over 2 hours" \
    --namespace DataLake/CloudTrailDelivery --metric-name MinutesSinceLastLog --dimensions "Name=Account,Value=${a}" \
    --statistic Maximum --period 1800 --evaluation-periods 1 --threshold 120 \
    --comparison-operator GreaterThanThreshold --treat-missing-data breaching \
    --alarm-actions "$TOPIC_ARN" --ok-actions "$TOPIC_ARN" "${CORE[@]}"
done
```

**Grants inventory failing:**

```bash
aws cloudwatch put-metric-alarm --alarm-name AccessGrantsInventoryErrors \
  --alarm-description "The grants history Lambda failed" \
  --namespace AWS/Lambda --metric-name Errors --dimensions Name=FunctionName,Value=AccessGrantsInventory \
  --statistic Sum --period 3600 --evaluation-periods 1 --threshold 0 \
  --comparison-operator GreaterThanThreshold --treat-missing-data notBreaching \
  --alarm-actions "$TOPIC_ARN" "${CORE[@]}"
```

Check:

```bash
aws cloudwatch describe-alarms --alarm-name-prefix CloudTrailLogsMissing "${CORE[@]}" \
  --query 'MetricAlarms[].[AlarmName, StateValue]' --output table
```

Right after creation the alarms may show `INSUFFICIENT_DATA` or `ALARM` until the
monitor has run; after its first runs they should be `OK`.

---

## 10. CORE — Glue and Athena

### 10.1 Workgroup and database

```bash
aws athena create-work-group --name "$ATHENA_WORKGROUP" "${CORE[@]}" \
  --configuration "ResultConfiguration={OutputLocation=s3://${ATHENA_RESULTS_BUCKET}/,EncryptionConfiguration={EncryptionOption=SSE_S3}},EnforceWorkGroupConfiguration=true,PublishCloudWatchMetricsEnabled=true"
aws glue create-database --database-input "Name=${GLUE_DATABASE}" "${CORE[@]}"
```

Helper to run SQL from the CLI (or paste the SQL into the Athena console):

```bash
athena_run() {   # athena_run <sql-file>
  local qid state
  qid=$(aws athena start-query-execution --work-group "$ATHENA_WORKGROUP" --query-string "file://$1" \
        "${CORE[@]}" --query QueryExecutionId --output text)
  while :; do
    state=$(aws athena get-query-execution --query-execution-id "$qid" "${CORE[@]}" \
            --query QueryExecution.Status.State --output text)
    case "$state" in
      SUCCEEDED) echo "$1: OK"; return 0;;
      FAILED|CANCELLED) aws athena get-query-execution --query-execution-id "$qid" "${CORE[@]}" \
                          --query QueryExecution.Status.StateChangeReason --output text; return 1;;
    esac
    sleep 2
  done
}
```

### 10.2 Table `storage_trail`: CloudTrail logs of all STORAGE accounts

Partitioned by **`account`**, `year`, `month`, `day` with partition projection:
no crawler, new days are found automatically. The STORAGE accounts are listed in
`projection.account.values` (update it when adding an account, step 13).
Queries should filter on `year`/`month` (and `account` if useful) to avoid
scanning all logs.

```bash
cat > ddl_storage_trail.sql <<EOF
CREATE EXTERNAL TABLE IF NOT EXISTS ${GLUE_DATABASE}.storage_trail (
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
PARTITIONED BY (account string, year string, month string, day string)
ROW FORMAT SERDE 'org.apache.hive.hcatalog.data.JsonSerDe'
STORED AS INPUTFORMAT 'com.amazon.emr.cloudtrail.CloudTrailInputFormat'
OUTPUTFORMAT 'org.apache.hadoop.hive.ql.io.HiveIgnoreKeyTextOutputFormat'
LOCATION 's3://${LOG_BUCKET}/AWSLogs/'
TBLPROPERTIES (
  'classification'='cloudtrail',
  'projection.enabled'='true',
  'projection.account.type'='enum',  'projection.account.values'='${STORAGE_ACCOUNTS_CSV}',
  'projection.year.type'='integer',  'projection.year.range'='2026,2035',
  'projection.month.type'='integer', 'projection.month.range'='1,12', 'projection.month.digits'='2',
  'projection.day.type'='integer',   'projection.day.range'='1,31',   'projection.day.digits'='2',
  'storage.location.template'='s3://${LOG_BUCKET}/AWSLogs/\${account}/CloudTrail/${REGION}/\${year}/\${month}/\${day}'
)
EOF
athena_run ddl_storage_trail.sql
```

### 10.3 Table `access_grants_history`: grants of all STORAGE accounts

Reads every CSV under the prefix (one per account); the header line of each
file is skipped. Grant IDs are unique across accounts.

```bash
cat > ddl_access_grants_history.sql <<EOF
CREATE EXTERNAL TABLE IF NOT EXISTS ${GLUE_DATABASE}.access_grants_history (
  observed_at string, event string, grant_id string, grant_arn string,
  grantee_type string, grantee_identifier string, permission string,
  grant_scope string, location_id string, created_at string
)
ROW FORMAT SERDE 'org.apache.hadoop.hive.serde2.OpenCSVSerde'
WITH SERDEPROPERTIES ('separatorChar' = ',', 'quoteChar' = '"', 'escapeChar' = '\\\\')
LOCATION 's3://${INVENTORY_BUCKET}/${GRANTS_PREFIX}'
TBLPROPERTIES ('skip.header.line.count' = '1')
EOF
athena_run ddl_access_grants_history.sql
```

---

## 11. CORE — the queries

Athena → **Query editor** in CORE, workgroup **`cloudtrail-correlation`**,
database **`cloudtrail_logs`**. Set `year` / `month` in every CTE. CloudTrail
delivers after 5–15 minutes; management events can arrive later than data
events.

### 11.1 Who accessed which file, in which STORAGE account

For every S3 operation made through Access Grants: the STORAGE account, the
**ARN of the consumer** in CORE (the grantee), the operation and the file.

| Step | From → to | Join | Exact? |
|---|---|---|---|
| 1 | S3 data event → Access Grants' internal `AssumeRole` | same account + session name `access-grants-<uuid>` | yes |
| 2 | → `GetDataAccess` | same account + timestamp within ±2 s | timing only |
| 3 | → grant | `matchedAccessGrantArn` | yes |
| 4 | → consumer ARN | `access_grants_history` (`CREATED` line) | yes |

The account appears in every join: events of different STORAGE accounts are
never paired, even within the same two seconds.

```sql
WITH grants AS (               -- grant IDs are never reused, so deleted grants still resolve
    SELECT DISTINCT grant_id, grantee_identifier AS consumer_arn
    FROM cloudtrail_logs.access_grants_history
    WHERE event = 'CREATED'
),
ag_sessions AS (               -- Access Grants vends a scoped session
    SELECT account, from_iso8601_timestamp(eventtime) AS t,
           regexp_extract(requestparameters, '"roleSessionName"\s*:\s*"([^"]+)"', 1) AS session_name
    FROM cloudtrail_logs.storage_trail
    WHERE year = '2026' AND month = '11'
      AND eventsource = 'sts.amazonaws.com' AND eventname = 'AssumeRole'
      AND requestparameters LIKE '%access-grants-%'
),
gda AS (                       -- GetDataAccess: which grant was matched
    SELECT account, from_iso8601_timestamp(eventtime) AS t,
           regexp_extract(additionaleventdata, 'grant/([a-f0-9-]+)', 1) AS grant_id
    FROM cloudtrail_logs.storage_trail
    WHERE year = '2026' AND month = '11' AND eventname = 'GetDataAccess'
),
s3_events AS (
    SELECT account, eventtime, eventname,
           useridentity.sessioncontext.sourceidentity AS source_identity,
           regexp_extract(useridentity.arn, '(access-grants-[a-f0-9-]+)$', 1) AS session_name,
           regexp_extract(requestparameters, '"bucketName"\s*:\s*"([^"]+)"', 1) AS bucket,
           regexp_extract(requestparameters, '"key"\s*:\s*"([^"]+)"', 1)        AS file_path
    FROM cloudtrail_logs.storage_trail
    WHERE year = '2026' AND month = '11'
      AND eventsource = 's3.amazonaws.com'
      AND eventname IN ('GetObject', 'PutObject', 'DeleteObject', 'CopyObject', 'ListObjects')
      AND regexp_like(useridentity.arn, '/access-grants-[a-f0-9-]+$')   -- any location role name
)
SELECT DISTINCT
    s3.account AS storage_account,
    s3.eventtime,
    gr.consumer_arn,
    s3.source_identity,
    s3.eventname AS operation,
    s3.bucket,
    s3.file_path
FROM s3_events s3
JOIN ag_sessions ag ON ag.account = s3.account AND ag.session_name = s3.session_name          -- exact
JOIN gda g          ON g.account = ag.account AND abs(to_unixtime(g.t) - to_unixtime(ag.t)) <= 2  -- timing only
JOIN grants gr      ON gr.grant_id = g.grant_id                                              -- exact
ORDER BY s3.eventtime DESC
```

Only one STORAGE account? Add `AND account = '<account>'` to the three
CloudTrail CTEs: Athena then reads only that account's logs.

### 11.2 Current grants of all STORAGE accounts

```sql
SELECT regexp_extract(grant_arn, ':s3:[^:]*:([0-9]{12}):', 1) AS storage_account,
       grant_id, grantee_identifier AS consumer_arn, permission, grant_scope, created_at
FROM (
    SELECT *, row_number() OVER (PARTITION BY grant_id ORDER BY observed_at DESC, event DESC) AS rn
    FROM cloudtrail_logs.access_grants_history
)
WHERE rn = 1 AND event = 'CREATED'
ORDER BY storage_account, created_at;
```

### 11.3 Logs arriving per STORAGE account

```sql
SELECT account, eventcategory, count(*) AS events, max(eventtime) AS last
FROM cloudtrail_logs.storage_trail
WHERE year = '2026' AND month = '11'
GROUP BY account, eventcategory
ORDER BY account, eventcategory;
```

Expected: `Management` and `Data` per account. Only `Management` → nothing
accessed that data lake yet, or the data event selector (5.7) doesn't match its
bucket.

---

## 12. Test end to end

### 12.1 A consumer reads a STORAGE data lake

As a consumer in CORE (a profile that uses the consumer role or user), ask one
STORAGE account's Access Grants for credentials, then use them:

```bash
CONSUMER_PROFILE="core-reader"          # <- a CLI profile for a consumer in CORE
TARGET_ACCOUNT="222222222222"           # <- a STORAGE account
TARGET_BUCKET="datalake-${TARGET_ACCOUNT}"

read -r AK SK ST_TOKEN < <(aws s3control get-data-access --account-id "$TARGET_ACCOUNT" \
  --target "s3://${TARGET_BUCKET}/*" --permission READ --region "$REGION" --profile "$CONSUMER_PROFILE" \
  --query 'Credentials.[AccessKeyId, SecretAccessKey, SessionToken]' --output text)

AWS_ACCESS_KEY_ID=$AK AWS_SECRET_ACCESS_KEY=$SK AWS_SESSION_TOKEN=$ST_TOKEN \
  aws s3 ls "s3://${TARGET_BUCKET}/" --region "$REGION"
```

`AccessDenied` on `get-data-access`: the RAM invitation isn't accepted (step 6),
the consumer has no grant (5.4) or no `DataLakeConsumerAccess` policy (3.3), or
it's propagation (wait a few minutes). After 5–15 minutes the access shows up
in query 11.1 with the consumer's ARN.

### 12.2 The alerts

- **Grant change → history:** create or delete a grant in a STORAGE account;
  within a few minutes a line is appended to
  `s3://$INVENTORY_BUCKET/${GRANTS_PREFIX}<account>.csv`.
- **Trail change → email:** in a STORAGE account, `aws cloudtrail stop-logging
  --name "$STORAGE_TRAIL" "${ST[@]}"`; the email arrives within a few minutes.
  **Restart logging right away:** `aws cloudtrail start-logging --name
  "$STORAGE_TRAIL" "${ST[@]}"`.
- **No logs → email:** leave the trail stopped for more than 2 hours (only in a
  test account), or wait for the next real gap. The alarm
  `CloudTrailLogsMissing-<account>` goes to `ALARM` and sends an email; after
  logging restarts it returns to `OK` and sends another.

---

## 13. Adding a STORAGE account later

1. Add it to `STORAGE_ACCOUNTS` in step 0 and run the helpers again.
2. CORE: run **1.1 bucket policy** (rebuilt with all accounts), **3.1** policy
   (`put-role-policy` only), **3.3** (create a new policy version:
   `aws iam create-policy-version --policy-arn "$CONSUMER_POLICY_ARN"
   --policy-document file://consumer-policy.json --set-as-default`), **3.4**
   for the new account.
3. The new account: all of **step 5**.
4. CORE: **step 6**; update the Lambdas' `STORAGE_ACCOUNTS`:
   ```bash
   aws lambda update-function-configuration --function-name AccessGrantsInventory "${CORE[@]}" \
     --environment "Variables={STORAGE_ACCOUNTS=${STORAGE_ACCOUNTS_CSV},READ_ROLE_NAME=AccessGrantsInventoryReadRole,BUCKET=${INVENTORY_BUCKET},PREFIX=${GRANTS_PREFIX}}"
   aws lambda update-function-configuration --function-name LogDeliveryMonitor "${CORE[@]}" \
     --environment "Variables={LOG_BUCKET=${LOG_BUCKET},STORAGE_ACCOUNTS=${STORAGE_ACCOUNTS_CSV}}"
   ```
   then **step 8** patterns (`put-rule` for `AccessGrantsInventoryOnChange` and
   `TrailChangeAlert`), **step 9** alarm for the new account, and the table's
   account list:
   ```sql
   ALTER TABLE cloudtrail_logs.storage_trail
   SET TBLPROPERTIES ('projection.account.values' = '<all STORAGE accounts, comma-separated>');
   ```
5. Invoke `AccessGrantsInventory` once: it creates the new account's CSV.
