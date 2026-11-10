# Data lake with S3 Access Grants — setup with the AWS CLI

Rebuilds, in two new accounts and with the AWS CLI only, the setup tested on
2026-11-09 in the Feeder/Storage PoC:

```
FEEDER account                                         STORAGE account
──────────────                                         ───────────────
Lambda DataLakePocObjects                              Access Grants instance (already exists)
  exec role FeederDataLakeLambdaRole                     ├─ location  s3://<DATALAKE_BUCKET>/*  (role S3AccessGrantsLocationRole)
  └─ sts:AssumeRole + SourceIdentity                     ├─ grant     FeederAccessGrantsRole → READWRITE
      └─ FeederAccessGrantsRole  ── GetDataAccess ──▶    └─ RAM share → FEEDER account
             (cross-account, via RAM share)
                                                       <DATALAKE_BUCKET>  (only reachable via Access Grants)
CloudTrail FeederTrail (management events)
  └─ <FEEDER_CT_BUCKET> ── S3 replication ──────────▶  <FEEDER_CT_REPLICA_BUCKET>
                                                       CloudTrail StorageDataLakeTrail
                                                         (management + data events on <DATALAKE_BUCKET>)
                                                         └─ <STORAGE_CT_BUCKET>
                                                       Lambda AccessGrantsInventory  ◀── EventBridge
                                                         (daily + on Create/DeleteAccessGrant)
                                                         └─ <INVENTORY_BUCKET>/access-grants/*.json
                                                       Glue DB cloudtrail_logs + Athena workgroup
                                                         tables: storage_datalake_trail, feeder_trail,
                                                                 access_grants
```

What you get at the end: an Athena query that returns, for every S3 operation
on the data lake, the **ARN of the grantee role** (e.g.
`arn:aws:iam::<FEEDER>:role/FeederAccessGrantsRole`) — from the Storage logs
alone, without hardcoded grant IDs and without relying on callers setting
`SourceIdentity`.

**Known behaviour (verified in the PoC):**
- S3 data events made through Access Grants only show
  `S3AccessGrantsLocationRole/access-grants-<uuid>` as the caller. No `onBehalfOf`.
- Access Grants does **not** put the caller's access key in `sourceIdentity`.
  It only passes on a `SourceIdentity` the caller set itself.
- Storage sees a Feeder caller of `GetDataAccess` only as `AWSAccount` + role ID
  (`AROA…`). The full session ARN and *who assumed the grantee role* are only in
  the Feeder logs (that's what the replicated `feeder_trail` is for).
- Access Grants may reuse a vended `access-grants-<uuid>` session for several
  `GetDataAccess` calls of the same grant.
- New IAM roles, grants and RAM shares take **~3–4 minutes** to work reliably;
  `AccessDenied` in that window is propagation, not a mistake.

---

## 0. Prerequisites and variables

- AWS CLI v2, `zip`, `bash` (run everything in **bash**, not zsh — zsh treats
  `$VAR:something` and unquoted variables differently).
- Two CLI profiles with admin rights: one per account.
- The Access Grants instance already exists in the Storage account (default
  instance, same region as below). Check:
  ```bash
  aws s3control get-access-grants-instance --account-id "$STORAGE_ACCOUNT_ID" \
    --region "$REGION" --profile "$STORAGE_PROFILE"
  ```

Set the variables once per shell (bucket names are global — keep the account
suffix or pick your own unique names):

```bash
export REGION="eu-west-1"
export FEEDER_PROFILE="feeder"
export STORAGE_PROFILE="storage"
export FEEDER_ACCOUNT_ID="111111111111"     # <- change
export STORAGE_ACCOUNT_ID="222222222222"    # <- change

# The IAM role/user you use for admin work in Storage. It stays allowed on the
# data lake bucket despite the Access-Grants-only bucket policy.
# Must be a ROLE or USER ARN (arn:aws:iam::...), NOT an sts assumed-role ARN.
# For SSO, use the role: arn:aws:iam::<STORAGE>:role/aws-reserved/sso.amazonaws.com/<region>/AWSReservedSSO_...
export STORAGE_ADMIN_ARN="arn:aws:iam::${STORAGE_ACCOUNT_ID}:role/CHANGE-ME"

export DATALAKE_BUCKET="datalake-${STORAGE_ACCOUNT_ID}"
export STORAGE_CT_BUCKET="cloudtrail-logs-datalake-${STORAGE_ACCOUNT_ID}"
export FEEDER_CT_BUCKET="cloudtrail-logs-feeder-${FEEDER_ACCOUNT_ID}"
export FEEDER_CT_REPLICA_BUCKET="cloudtrail-logs-for-feeder-${STORAGE_ACCOUNT_ID}"
export ATHENA_RESULTS_BUCKET="athena-query-results-datalake-${STORAGE_ACCOUNT_ID}"
export INVENTORY_BUCKET="access-grants-inventory-${STORAGE_ACCOUNT_ID}"

export LOG_RETENTION_DAYS=30                 # CloudTrail log buckets lifecycle

export AG_INSTANCE_ARN="arn:aws:s3:${REGION}:${STORAGE_ACCOUNT_ID}:access-grants/default"
export WORK="$HOME/datalake-setup"; mkdir -p "$WORK"; cd "$WORK"

# us-east-1 must NOT get a LocationConstraint
if [ "$REGION" = "us-east-1" ]; then export LOC_ARGS=""; else export LOC_ARGS="--create-bucket-configuration LocationConstraint=${REGION}"; fi
```

Helper used below to create a private, encrypted bucket:

```bash
make_bucket() {   # make_bucket <profile> <bucket>
  aws s3api create-bucket --bucket "$2" --region "$REGION" --profile "$1" $LOC_ARGS
  aws s3api put-public-access-block --bucket "$2" --profile "$1" \
    --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
  aws s3api put-bucket-encryption --bucket "$2" --profile "$1" \
    --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
}

# Lifecycle for log buckets: expire files, purge old versions, drop leftover delete markers
put_log_lifecycle() {   # put_log_lifecycle <profile> <bucket>
  cat > lifecycle.json <<EOF
{"Rules":[
  {"ID":"expire-logs-and-old-versions","Status":"Enabled","Filter":{},
   "Expiration":{"Days":${LOG_RETENTION_DAYS}},
   "NoncurrentVersionExpiration":{"NoncurrentDays":1}},
  {"ID":"remove-expired-delete-markers","Status":"Enabled","Filter":{},
   "Expiration":{"ExpiredObjectDeleteMarker":true}}
]}
EOF
  aws s3api put-bucket-lifecycle-configuration --bucket "$2" --profile "$1" --lifecycle-configuration file://lifecycle.json
}
```

---

## 1. Storage — buckets

```bash
make_bucket "$STORAGE_PROFILE" "$DATALAKE_BUCKET"
make_bucket "$STORAGE_PROFILE" "$STORAGE_CT_BUCKET"
make_bucket "$STORAGE_PROFILE" "$FEEDER_CT_REPLICA_BUCKET"
make_bucket "$STORAGE_PROFILE" "$ATHENA_RESULTS_BUCKET"
make_bucket "$STORAGE_PROFILE" "$INVENTORY_BUCKET"

# Replication destination must be versioned
aws s3api put-bucket-versioning --bucket "$FEEDER_CT_REPLICA_BUCKET" --profile "$STORAGE_PROFILE" \
  --versioning-configuration Status=Enabled

put_log_lifecycle "$STORAGE_PROFILE" "$STORAGE_CT_BUCKET"
put_log_lifecycle "$STORAGE_PROFILE" "$FEEDER_CT_REPLICA_BUCKET"
```

### 1a. Data lake bucket policy — only via Access Grants

Denies every S3 request unless it uses Access-Grants-vended credentials, comes
from an AWS service, or is made by `STORAGE_ADMIN_ARN`.

> ⚠️ If `STORAGE_ADMIN_ARN` is wrong you lock yourself out of the bucket
> (only the account root can then delete the policy). Double-check it.

```bash
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
aws s3api put-bucket-policy --bucket "$DATALAKE_BUCKET" --profile "$STORAGE_PROFILE" --policy file://datalake-policy.json
```

### 1b. Replica bucket policy — allow the Feeder replication role

```bash
cat > replica-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "AllowFeederReplication",
    "Effect": "Allow",
    "Principal": {"AWS": "arn:aws:iam::${FEEDER_ACCOUNT_ID}:role/CloudTrailReplicationRole"},
    "Action": ["s3:ReplicateObject","s3:ReplicateDelete","s3:ReplicateTags",
               "s3:GetBucketVersioning","s3:PutBucketVersioning","s3:ObjectOwnerOverrideToBucketOwner"],
    "Resource": ["arn:aws:s3:::${FEEDER_CT_REPLICA_BUCKET}", "arn:aws:s3:::${FEEDER_CT_REPLICA_BUCKET}/*"]
  }]
}
EOF
```

The role is created in step 5; IAM validates the principal when the policy is
saved, so **apply this policy in step 5c**, after the role exists.

---

## 2. Feeder — IAM roles for the Lambda (needed before the grant)

```bash
# 2a. Lambda execution role — may only assume the grantee role
cat > lambda-trust.json <<'EOF'
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}
EOF
aws iam create-role --role-name FeederDataLakeLambdaRole --profile "$FEEDER_PROFILE" \
  --assume-role-policy-document file://lambda-trust.json
aws iam attach-role-policy --role-name FeederDataLakeLambdaRole --profile "$FEEDER_PROFILE" \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole

cat > exec-assume.json <<EOF
{"Version":"2012-10-17","Statement":[{"Effect":"Allow",
  "Action":["sts:AssumeRole","sts:SetSourceIdentity"],
  "Resource":"arn:aws:iam::${FEEDER_ACCOUNT_ID}:role/FeederAccessGrantsRole"}]}
EOF
aws iam put-role-policy --role-name FeederDataLakeLambdaRole --profile "$FEEDER_PROFILE" \
  --policy-name AssumeFeederAccessGrantsRole --policy-document file://exec-assume.json

# 2b. Grantee role — the identity the Access Grants grant is issued to
cat > grantee-trust.json <<EOF
{"Version":"2012-10-17","Statement":[{"Effect":"Allow",
  "Principal":{"AWS":"arn:aws:iam::${FEEDER_ACCOUNT_ID}:role/FeederDataLakeLambdaRole"},
  "Action":["sts:AssumeRole","sts:SetSourceIdentity"]}]}
EOF
aws iam create-role --role-name FeederAccessGrantsRole --profile "$FEEDER_PROFILE" \
  --assume-role-policy-document file://grantee-trust.json

cat > grantee-gda.json <<EOF
{"Version":"2012-10-17","Statement":[{"Effect":"Allow",
  "Action":["s3:GetDataAccess","s3:GetAccessGrantsInstanceForPrefix"],
  "Resource":"${AG_INSTANCE_ARN}"}]}
EOF
aws iam put-role-policy --role-name FeederAccessGrantsRole --profile "$FEEDER_PROFILE" \
  --policy-name GetDataAccessOnStorage --policy-document file://grantee-gda.json
```

> If creating `FeederAccessGrantsRole` fails with "Invalid principal", the
> exec role is not propagated yet — wait 10 s and retry.

---

## 3. Storage — Access Grants location, grant, RAM share

The instance exists already. Skip the parts you have (check with
`aws s3control list-access-grants-locations` / `list-access-grants`).

### 3a. Location role (Access Grants assumes it to vend credentials)

```bash
cat > location-trust.json <<EOF
{"Version":"2012-10-17","Statement":[{"Effect":"Allow",
  "Principal":{"Service":"access-grants.s3.amazonaws.com"},
  "Action":["sts:AssumeRole","sts:SetSourceIdentity"],
  "Condition":{"StringEquals":{"aws:SourceAccount":"${STORAGE_ACCOUNT_ID}"}}}]}
EOF
aws iam create-role --role-name S3AccessGrantsLocationRole --profile "$STORAGE_PROFILE" \
  --assume-role-policy-document file://location-trust.json

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
```

(If the bucket uses SSE-KMS, also allow `kms:Decrypt` / `kms:GenerateDataKey` on the key.)

### 3b. Location + grant

```bash
sleep 15   # let the location role propagate
LOCATION_ID=$(aws s3control create-access-grants-location --account-id "$STORAGE_ACCOUNT_ID" \
  --region "$REGION" --profile "$STORAGE_PROFILE" \
  --location-scope "s3://${DATALAKE_BUCKET}/*" \
  --iam-role-arn "arn:aws:iam::${STORAGE_ACCOUNT_ID}:role/S3AccessGrantsLocationRole" \
  --query AccessGrantsLocationId --output text)
echo "LOCATION_ID=$LOCATION_ID"

aws s3control create-access-grant --account-id "$STORAGE_ACCOUNT_ID" \
  --region "$REGION" --profile "$STORAGE_PROFILE" \
  --access-grants-location-id "$LOCATION_ID" --permission READWRITE \
  --grantee "GranteeType=IAM,GranteeIdentifier=arn:aws:iam::${FEEDER_ACCOUNT_ID}:role/FeederAccessGrantsRole"
```

One grant per consuming role — the attribution query maps grant → grantee.

### 3c. Cross-account access to the instance: RAM share

Standard RAM share to the Feeder **account** (tested). If both accounts are in
the same AWS Organization, you can share with the org/OU instead and drop
`--allow-external-principals`.

```bash
SHARE_ARN=$(aws ram create-resource-share --region "$REGION" --profile "$STORAGE_PROFILE" \
  --name S3AccessGrantsFeederShare --allow-external-principals \
  --resource-arns "$AG_INSTANCE_ARN" --principals "$FEEDER_ACCOUNT_ID" \
  --query resourceShare.resourceShareArn --output text)
echo "SHARE_ARN=$SHARE_ARN"

# Feeder accepts the invitation
sleep 10
INVITE_ARN=$(aws ram get-resource-share-invitations --region "$REGION" --profile "$FEEDER_PROFILE" \
  --query "resourceShareInvitations[?resourceShareArn=='${SHARE_ARN}' && status=='PENDING'].resourceShareInvitationArn | [0]" --output text)
aws ram accept-resource-share-invitation --region "$REGION" --profile "$FEEDER_PROFILE" \
  --resource-share-invitation-arn "$INVITE_ARN"

# Verify: status ASSOCIATED
aws ram get-resource-share-associations --association-type PRINCIPAL --resource-share-arns "$SHARE_ARN" \
  --region "$REGION" --profile "$STORAGE_PROFILE" --query 'resourceShareAssociations[].[associatedEntity,status]' --output text
```

> Don't also put a resource policy on the Access Grants instance
> (`put-access-grants-instance-resource-policy`): RAM turns that into its own
> share, and the two would overlap.

---

## 4. Storage — CloudTrail (management + data events on the data lake)

```bash
cat > storage-ct-policy.json <<EOF
{"Version":"2012-10-17","Statement":[
 {"Sid":"AWSCloudTrailAclCheck","Effect":"Allow","Principal":{"Service":"cloudtrail.amazonaws.com"},
  "Action":"s3:GetBucketAcl","Resource":"arn:aws:s3:::${STORAGE_CT_BUCKET}",
  "Condition":{"StringEquals":{"aws:SourceArn":"arn:aws:cloudtrail:${REGION}:${STORAGE_ACCOUNT_ID}:trail/StorageDataLakeTrail"}}},
 {"Sid":"AWSCloudTrailWrite","Effect":"Allow","Principal":{"Service":"cloudtrail.amazonaws.com"},
  "Action":"s3:PutObject","Resource":"arn:aws:s3:::${STORAGE_CT_BUCKET}/AWSLogs/${STORAGE_ACCOUNT_ID}/*",
  "Condition":{"StringEquals":{"s3:x-amz-acl":"bucket-owner-full-control",
    "aws:SourceArn":"arn:aws:cloudtrail:${REGION}:${STORAGE_ACCOUNT_ID}:trail/StorageDataLakeTrail"}}}
]}
EOF
aws s3api put-bucket-policy --bucket "$STORAGE_CT_BUCKET" --profile "$STORAGE_PROFILE" --policy file://storage-ct-policy.json

aws cloudtrail create-trail --name StorageDataLakeTrail --s3-bucket-name "$STORAGE_CT_BUCKET" \
  --no-is-multi-region-trail --no-include-global-service-events --enable-log-file-validation \
  --region "$REGION" --profile "$STORAGE_PROFILE"

cat > storage-selectors.json <<EOF
[
 {"Name":"Management events (exclude KMS and RDS Data API)",
  "FieldSelectors":[{"Field":"eventCategory","Equals":["Management"]},
                    {"Field":"eventSource","NotEquals":["kms.amazonaws.com","rdsdata.amazonaws.com"]}]},
 {"Name":"S3 data events on the data lake",
  "FieldSelectors":[{"Field":"eventCategory","Equals":["Data"]},
                    {"Field":"resources.type","Equals":["AWS::S3::Object"]},
                    {"Field":"resources.ARN","StartsWith":["arn:aws:s3:::${DATALAKE_BUCKET}/"]}]}
]
EOF
aws cloudtrail put-event-selectors --trail-name StorageDataLakeTrail --region "$REGION" --profile "$STORAGE_PROFILE" \
  --advanced-event-selectors file://storage-selectors.json
aws cloudtrail start-logging --name StorageDataLakeTrail --region "$REGION" --profile "$STORAGE_PROFILE"
```

The trailing `/` in `StartsWith` matters: it keeps e.g. `<bucket>-backup` from matching.

---

## 5. Feeder — CloudTrail + replication to Storage

Feeder's management events are needed in Storage for *who assumed the grantee
role* and for the full session ARN of `GetDataAccess`. Keep management events
on (a data-events-only trail would replicate nothing useful).

### 5a. Log bucket + trail

```bash
make_bucket "$FEEDER_PROFILE" "$FEEDER_CT_BUCKET"
aws s3api put-bucket-versioning --bucket "$FEEDER_CT_BUCKET" --profile "$FEEDER_PROFILE" \
  --versioning-configuration Status=Enabled
put_log_lifecycle "$FEEDER_PROFILE" "$FEEDER_CT_BUCKET"

cat > feeder-ct-policy.json <<EOF
{"Version":"2012-10-17","Statement":[
 {"Sid":"AWSCloudTrailAclCheck","Effect":"Allow","Principal":{"Service":"cloudtrail.amazonaws.com"},
  "Action":"s3:GetBucketAcl","Resource":"arn:aws:s3:::${FEEDER_CT_BUCKET}",
  "Condition":{"StringEquals":{"aws:SourceArn":"arn:aws:cloudtrail:${REGION}:${FEEDER_ACCOUNT_ID}:trail/FeederTrail"}}},
 {"Sid":"AWSCloudTrailWrite","Effect":"Allow","Principal":{"Service":"cloudtrail.amazonaws.com"},
  "Action":"s3:PutObject","Resource":"arn:aws:s3:::${FEEDER_CT_BUCKET}/AWSLogs/${FEEDER_ACCOUNT_ID}/*",
  "Condition":{"StringEquals":{"s3:x-amz-acl":"bucket-owner-full-control",
    "aws:SourceArn":"arn:aws:cloudtrail:${REGION}:${FEEDER_ACCOUNT_ID}:trail/FeederTrail"}}}
]}
EOF
aws s3api put-bucket-policy --bucket "$FEEDER_CT_BUCKET" --profile "$FEEDER_PROFILE" --policy file://feeder-ct-policy.json

aws cloudtrail create-trail --name FeederTrail --s3-bucket-name "$FEEDER_CT_BUCKET" \
  --no-is-multi-region-trail --no-include-global-service-events --enable-log-file-validation \
  --region "$REGION" --profile "$FEEDER_PROFILE"

cat > feeder-selectors.json <<'EOF'
[{"Name":"Management events (exclude KMS and RDS Data API)",
  "FieldSelectors":[{"Field":"eventCategory","Equals":["Management"]},
                    {"Field":"eventSource","NotEquals":["kms.amazonaws.com","rdsdata.amazonaws.com"]}]}]
EOF
aws cloudtrail put-event-selectors --trail-name FeederTrail --region "$REGION" --profile "$FEEDER_PROFILE" \
  --advanced-event-selectors file://feeder-selectors.json
aws cloudtrail start-logging --name FeederTrail --region "$REGION" --profile "$FEEDER_PROFILE"
```

### 5b. Replication role (Feeder)

```bash
cat > s3-trust.json <<'EOF'
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"s3.amazonaws.com"},"Action":"sts:AssumeRole"}]}
EOF
aws iam create-role --role-name CloudTrailReplicationRole --profile "$FEEDER_PROFILE" \
  --assume-role-policy-document file://s3-trust.json

cat > replication-policy.json <<EOF
{"Version":"2012-10-17","Statement":[
 {"Effect":"Allow","Action":["s3:GetReplicationConfiguration","s3:ListBucket"],
  "Resource":"arn:aws:s3:::${FEEDER_CT_BUCKET}"},
 {"Effect":"Allow","Action":["s3:GetObjectVersionForReplication","s3:GetObjectVersionAcl","s3:GetObjectVersionTagging"],
  "Resource":"arn:aws:s3:::${FEEDER_CT_BUCKET}/*"},
 {"Effect":"Allow","Action":["s3:ReplicateObject","s3:ReplicateDelete","s3:ReplicateTags","s3:ObjectOwnerOverrideToBucketOwner"],
  "Resource":"arn:aws:s3:::${FEEDER_CT_REPLICA_BUCKET}/*"}
]}
EOF
aws iam put-role-policy --role-name CloudTrailReplicationRole --profile "$FEEDER_PROFILE" \
  --policy-name CloudTrailReplicationPolicy --policy-document file://replication-policy.json
```

### 5c. Destination bucket policy (Storage) — now that the role exists

```bash
sleep 10
aws s3api put-bucket-policy --bucket "$FEEDER_CT_REPLICA_BUCKET" --profile "$STORAGE_PROFILE" --policy file://replica-policy.json
```

### 5d. Replication rule (Feeder)

Delete-marker replication is **disabled**: deleting files in Feeder (e.g. in the
console) doesn't hide them in Storage. Each bucket expires its own copies via lifecycle.

```bash
cat > replication.json <<EOF
{"Role":"arn:aws:iam::${FEEDER_ACCOUNT_ID}:role/CloudTrailReplicationRole",
 "Rules":[{"ID":"replicate-to-storage","Status":"Enabled","Priority":1,"Filter":{},
   "DeleteMarkerReplication":{"Status":"Disabled"},
   "Destination":{"Bucket":"arn:aws:s3:::${FEEDER_CT_REPLICA_BUCKET}","Account":"${STORAGE_ACCOUNT_ID}",
                  "StorageClass":"STANDARD","AccessControlTranslation":{"Owner":"Destination"}}}]}
EOF
aws s3api put-bucket-replication --bucket "$FEEDER_CT_BUCKET" --profile "$FEEDER_PROFILE" \
  --replication-configuration file://replication.json
```

Check after ~15 min (first log files): `aws s3api head-object --bucket "$FEEDER_CT_BUCKET" --key <a log key> --profile "$FEEDER_PROFILE" --query ReplicationStatus` → `COMPLETED`.

> Versioning must stay **Enabled** on both buckets — suspending it on either
> side breaks replication.

---

## 6. Feeder — Lambda DataLakePocObjects (list / create / delete)

```bash
mkdir -p lambda-feeder && cat > lambda-feeder/data_lake_poc_objects.py <<'EOF'
"""
DataLakePocObjects Lambda
-------------------------
Lists, creates or deletes objects in the data lake bucket on the Storage
account. Access chain: assume ASSUME_ROLE_ARN (the Access Grants grantee),
then call S3 Access Grants on the Storage account for scoped credentials.

Event:
  {"action": "list"}
  {"action": "create"}                 # key optional, generated if absent
  {"action": "create", "key": "a.txt", "body": "hello"}
  {"action": "delete", "key": "a.txt"}
  Add "no_source_identity": true to skip SourceIdentity (testing).

Environment variables:
  BUCKET_NAME         Name of the target S3 bucket on the Storage account.
  STORAGE_ACCOUNT_ID  AWS account ID of the Storage account.
  ASSUME_ROLE_ARN     ARN of the grantee role to assume.
"""

import json
import logging
import os
import uuid
from datetime import datetime, timezone

import boto3
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(logging.INFO)

BUCKET_NAME        = os.environ["BUCKET_NAME"]
STORAGE_ACCOUNT_ID = os.environ["STORAGE_ACCOUNT_ID"]
ASSUME_ROLE_ARN    = os.environ["ASSUME_ROLE_ARN"]


def scoped_s3_client(target, permission, set_source_identity=True):
    # Step 1: assume the grantee role.
    # SourceIdentity = this Lambda's role name; STS keeps it on the chained
    # session so it can show up in Storage's CloudTrail.
    sts = boto3.client("sts")
    kwargs = {
        "RoleArn":         ASSUME_ROLE_ARN,
        "RoleSessionName": os.environ["AWS_LAMBDA_FUNCTION_NAME"],
    }
    if set_source_identity:
        kwargs["SourceIdentity"] = sts.get_caller_identity()["Arn"].split("/")[1]
    assumed = sts.assume_role(**kwargs)
    creds = assumed["Credentials"]

    # Step 2: obtain scoped credentials from Storage's S3 Access Grants.
    s3control = boto3.client(
        "s3control",
        aws_access_key_id     = creds["AccessKeyId"],
        aws_secret_access_key = creds["SecretAccessKey"],
        aws_session_token     = creds["SessionToken"],
    )
    scoped_creds = s3control.get_data_access(
        AccountId  = STORAGE_ACCOUNT_ID,
        Target     = target,
        Permission = permission,
    )["Credentials"]

    # Step 3: S3 client using the scoped credentials.
    return boto3.client(
        "s3",
        aws_access_key_id     = scoped_creds["AccessKeyId"],
        aws_secret_access_key = scoped_creds["SecretAccessKey"],
        aws_session_token     = scoped_creds["SessionToken"],
    )


def lambda_handler(event, context):
    event  = event or {}
    action = event.get("action", "list")
    si     = not event.get("no_source_identity", False)

    try:
        if action == "list":
            s3 = scoped_s3_client(f"s3://{BUCKET_NAME}/*", "READ", si)
            files = []
            for page in s3.get_paginator("list_objects_v2").paginate(Bucket=BUCKET_NAME):
                files.extend(obj["Key"] for obj in page.get("Contents", []))
            result = {"status": "success", "action": action, "files": files, "count": len(files)}

        elif action == "create":
            timestamp = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")
            key = event.get("key") or f"upload-{timestamp}-{uuid.uuid4().hex[:8]}.txt"
            s3 = scoped_s3_client(f"s3://{BUCKET_NAME}/{key}", "WRITE", si)
            s3.put_object(
                Bucket      = BUCKET_NAME,
                Key         = key,
                Body        = event.get("body", "").encode(),
                ContentType = "text/plain",
            )
            result = {"status": "success", "action": action, "key": key}

        elif action == "delete":
            key = event["key"]
            s3 = scoped_s3_client(f"s3://{BUCKET_NAME}/{key}", "WRITE", si)
            s3.delete_object(Bucket=BUCKET_NAME, Key=key)
            result = {"status": "success", "action": action, "key": key}

        else:
            result = {"status": "error", "message": f"Unknown action '{action}' (use list, create or delete)"}

    except ClientError as e:
        result = {
            "status":     "error",
            "action":     action,
            "operation":  e.operation_name,   # AssumeRole / GetDataAccess / S3 call
            "error_code": e.response["Error"]["Code"],
            "message":    e.response["Error"]["Message"],
        }

    logger.info(json.dumps(result))
    return result
EOF
(cd lambda-feeder && zip -q ../data_lake_poc_objects.zip data_lake_poc_objects.py)

aws lambda create-function --function-name DataLakePocObjects --region "$REGION" --profile "$FEEDER_PROFILE" \
  --runtime python3.12 --handler data_lake_poc_objects.lambda_handler --timeout 30 \
  --role "arn:aws:iam::${FEEDER_ACCOUNT_ID}:role/FeederDataLakeLambdaRole" \
  --zip-file fileb://data_lake_poc_objects.zip \
  --environment "Variables={BUCKET_NAME=${DATALAKE_BUCKET},STORAGE_ACCOUNT_ID=${STORAGE_ACCOUNT_ID},ASSUME_ROLE_ARN=arn:aws:iam::${FEEDER_ACCOUNT_ID}:role/FeederAccessGrantsRole}"
```

Update the code later with
`aws lambda update-function-code --function-name DataLakePocObjects --zip-file fileb://data_lake_poc_objects.zip --region "$REGION" --profile "$FEEDER_PROFILE"`.

---

## 7. Storage — grants inventory (Lambda + EventBridge)

Writes the current grants (grant ID → grantee ARN) as a JSON-lines snapshot to
`s3://<INVENTORY_BUCKET>/access-grants/<timestamp>.json`. Runs daily and right
after every `CreateAccessGrant` / `DeleteAccessGrant`. Snapshots are kept, so
deleted grants still resolve for old log events (grant IDs are never reused).

### 7a. Role

```bash
aws iam create-role --role-name AccessGrantsInventoryRole --profile "$STORAGE_PROFILE" \
  --assume-role-policy-document file://lambda-trust.json
aws iam attach-role-policy --role-name AccessGrantsInventoryRole --profile "$STORAGE_PROFILE" \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole

cat > inventory-policy.json <<EOF
{"Version":"2012-10-17","Statement":[
 {"Effect":"Allow","Action":"s3:ListAccessGrants","Resource":"${AG_INSTANCE_ARN}"},
 {"Effect":"Allow","Action":"s3:PutObject","Resource":"arn:aws:s3:::${INVENTORY_BUCKET}/access-grants/*"}
]}
EOF
aws iam put-role-policy --role-name AccessGrantsInventoryRole --profile "$STORAGE_PROFILE" \
  --policy-name AccessGrantsInventoryPolicy --policy-document file://inventory-policy.json
```

### 7b. Lambda

```bash
mkdir -p lambda-inventory && cat > lambda-inventory/access_grants_inventory.py <<'EOF'
"""
AccessGrantsInventory Lambda
----------------------------
Snapshots all S3 Access Grants (grant ID -> grantee) to S3 as JSON lines,
one file per run: s3://<BUCKET>/<PREFIX><timestamp>.json

Environment variables:
  ACCOUNT_ID  Account that owns the Access Grants instance.
  BUCKET      Inventory bucket.
  PREFIX      Key prefix, e.g. "access-grants/".
"""

import json
import os
from datetime import datetime, timezone

import boto3

ACCOUNT_ID = os.environ["ACCOUNT_ID"]
BUCKET     = os.environ["BUCKET"]
PREFIX     = os.environ.get("PREFIX", "access-grants/")


def lambda_handler(event, context):
    s3control = boto3.client("s3control")
    now = datetime.now(timezone.utc)
    lines, token = [], None
    while True:
        kwargs = {"AccountId": ACCOUNT_ID, "MaxResults": 1000}
        if token:
            kwargs["NextToken"] = token
        resp = s3control.list_access_grants(**kwargs)
        for g in resp.get("AccessGrantsList", []):
            lines.append(json.dumps({
                "grant_id":           g["AccessGrantId"],
                "grant_arn":          g["AccessGrantArn"],
                "grantee_type":       g["Grantee"]["GranteeType"],
                "grantee_identifier": g["Grantee"]["GranteeIdentifier"],
                "permission":         g["Permission"],
                "grant_scope":        g.get("GrantScope"),
                "location_id":        g.get("AccessGrantsLocationId"),
                "created_at":         g["CreatedAt"].isoformat(),
                "exported_at":        now.isoformat(),
            }))
        token = resp.get("NextToken")
        if not token:
            break

    key = f"{PREFIX}{now.strftime('%Y%m%dT%H%M%SZ')}.json"
    boto3.client("s3").put_object(Bucket=BUCKET, Key=key,
                                  Body="\n".join(lines).encode(),
                                  ContentType="application/json")
    return {"grants": len(lines), "key": key}
EOF
(cd lambda-inventory && zip -q ../access_grants_inventory.zip access_grants_inventory.py)

sleep 10   # role propagation
aws lambda create-function --function-name AccessGrantsInventory --region "$REGION" --profile "$STORAGE_PROFILE" \
  --runtime python3.12 --handler access_grants_inventory.lambda_handler --timeout 60 \
  --role "arn:aws:iam::${STORAGE_ACCOUNT_ID}:role/AccessGrantsInventoryRole" \
  --zip-file fileb://access_grants_inventory.zip \
  --environment "Variables={ACCOUNT_ID=${STORAGE_ACCOUNT_ID},BUCKET=${INVENTORY_BUCKET},PREFIX=access-grants/}"
```

### 7c. EventBridge rules (daily + on grant changes)

`CreateAccessGrant` / `DeleteAccessGrant` are CloudTrail management events;
EventBridge receives them in the same region without extra setup.

```bash
FN_ARN="arn:aws:lambda:${REGION}:${STORAGE_ACCOUNT_ID}:function:AccessGrantsInventory"

# Daily snapshot
aws events put-rule --name AccessGrantsInventoryDaily --schedule-expression "rate(1 day)" \
  --region "$REGION" --profile "$STORAGE_PROFILE"
aws events put-targets --rule AccessGrantsInventoryDaily --targets "Id=inventory,Arn=${FN_ARN}" \
  --region "$REGION" --profile "$STORAGE_PROFILE"
aws lambda add-permission --function-name AccessGrantsInventory --statement-id eventbridge-daily \
  --action lambda:InvokeFunction --principal events.amazonaws.com \
  --source-arn "arn:aws:events:${REGION}:${STORAGE_ACCOUNT_ID}:rule/AccessGrantsInventoryDaily" \
  --region "$REGION" --profile "$STORAGE_PROFILE"

# On every grant change
cat > grant-change-pattern.json <<'EOF'
{"source":["aws.s3"],
 "detail-type":["AWS API Call via CloudTrail"],
 "detail":{"eventSource":["s3.amazonaws.com"],
           "eventName":["CreateAccessGrant","DeleteAccessGrant"]}}
EOF
aws events put-rule --name AccessGrantsInventoryOnChange --event-pattern file://grant-change-pattern.json \
  --region "$REGION" --profile "$STORAGE_PROFILE"
aws events put-targets --rule AccessGrantsInventoryOnChange --targets "Id=inventory,Arn=${FN_ARN}" \
  --region "$REGION" --profile "$STORAGE_PROFILE"
aws lambda add-permission --function-name AccessGrantsInventory --statement-id eventbridge-on-change \
  --action lambda:InvokeFunction --principal events.amazonaws.com \
  --source-arn "arn:aws:events:${REGION}:${STORAGE_ACCOUNT_ID}:rule/AccessGrantsInventoryOnChange" \
  --region "$REGION" --profile "$STORAGE_PROFILE"

# First snapshot now
aws lambda invoke --function-name AccessGrantsInventory --region "$REGION" --profile "$STORAGE_PROFILE" /dev/stdout
```

> The on-change rule was not tested in the PoC (the PoC tested the grants
> lookup with a hardcoded list). If no new snapshot appears a few minutes after
> creating a grant, check the rule's metrics in EventBridge; the daily run still
> catches up.

---

## 8. Storage — Glue database, Athena workgroup, tables

```bash
aws glue create-database --database-input Name=cloudtrail_logs --region "$REGION" --profile "$STORAGE_PROFILE"

aws athena create-work-group --name cloudtrail-correlation --region "$REGION" --profile "$STORAGE_PROFILE" \
  --configuration "ResultConfiguration={OutputLocation=s3://${ATHENA_RESULTS_BUCKET}/,EncryptionConfiguration={EncryptionOption=SSE_S3}},EnforceWorkGroupConfiguration=true,PublishCloudWatchMetricsEnabled=true"

# helper: run one Athena statement from a file and wait for it
athena_run() {   # athena_run <file.sql>
  local qid state
  qid=$(aws athena start-query-execution --work-group cloudtrail-correlation --region "$REGION" --profile "$STORAGE_PROFILE" \
        --query-string "file://$1" --query QueryExecutionId --output text)
  while :; do
    state=$(aws athena get-query-execution --query-execution-id "$qid" --region "$REGION" --profile "$STORAGE_PROFILE" \
            --query QueryExecution.Status.State --output text)
    case "$state" in SUCCEEDED) echo "$1: OK"; return 0;; FAILED|CANCELLED)
      aws athena get-query-execution --query-execution-id "$qid" --region "$REGION" --profile "$STORAGE_PROFILE" \
        --query QueryExecution.Status.StateChangeReason --output text; return 1;; esac
    sleep 2
  done
}
```

### 8a. CloudTrail tables (partition projection, `sourceidentity` declared)

```bash
cloudtrail_ddl() {   # cloudtrail_ddl <table> <bucket> <account>
cat > "ddl_$1.sql" <<EOF
CREATE EXTERNAL TABLE cloudtrail_logs.$1 (
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
LOCATION 's3://$2/AWSLogs/$3/CloudTrail/${REGION}/'
TBLPROPERTIES (
  'classification'='cloudtrail',
  'projection.enabled'='true',
  'projection.year.type'='integer',  'projection.year.range'='2026,2035',
  'projection.month.type'='integer', 'projection.month.range'='1,12', 'projection.month.digits'='2',
  'projection.day.type'='integer',   'projection.day.range'='1,31',   'projection.day.digits'='2',
  'storage.location.template'='s3://$2/AWSLogs/$3/CloudTrail/${REGION}/\${year}/\${month}/\${day}'
)
EOF
athena_run "ddl_$1.sql"
}

cloudtrail_ddl storage_datalake_trail "$STORAGE_CT_BUCKET"        "$STORAGE_ACCOUNT_ID"
cloudtrail_ddl feeder_trail           "$FEEDER_CT_REPLICA_BUCKET" "$FEEDER_ACCOUNT_ID"
```

### 8b. Grants inventory table

```bash
cat > ddl_access_grants.sql <<EOF
CREATE EXTERNAL TABLE cloudtrail_logs.access_grants (
  grant_id string, grant_arn string, grantee_type string, grantee_identifier string,
  permission string, grant_scope string, location_id string, created_at string, exported_at string
)
ROW FORMAT SERDE 'org.openx.data.jsonserde.JsonSerDe'
LOCATION 's3://${INVENTORY_BUCKET}/access-grants/'
EOF
athena_run ddl_access_grants.sql
```

---

## 9. Test

```bash
fn() { aws lambda invoke --function-name DataLakePocObjects --region "$REGION" --profile "$FEEDER_PROFILE" \
         --cli-binary-format raw-in-base64-out --payload "$1" /dev/stdout; echo; }

fn '{"action":"list"}'
fn '{"action":"create","key":"test.txt","body":"hello"}'
fn '{"action":"list"}'
fn '{"action":"delete","key":"test.txt"}'
fn '{"action":"create","key":"test-no-si.txt","no_source_identity":true}'   # without SourceIdentity
fn '{"action":"delete","key":"test-no-si.txt","no_source_identity":true}'
```

- `AccessDenied` in the first ~4 min after setup → propagation, retry.
- Errors include `operation` (`AssumeRole` / `GetDataAccess` / S3 call) to show which step failed.
- Direct access must be refused (bucket policy), e.g. from a Feeder admin:
  `aws s3 ls s3://$DATALAKE_BUCKET --profile "$FEEDER_PROFILE"` → AccessDenied.

Wait **5–15 min** for CloudTrail, then run the query below. Don't empty the log
buckets before that.

---

## 10. Attribution query — grantee role ARN per S3 operation

Storage logs + grants inventory only. Adjust `year`/`month` (partition filter,
avoids full scans) — they appear in three CTEs.

```bash
cat > attribution.sql <<'EOF'
WITH grants AS (               -- from the inventory snapshots; grant IDs are unique
    SELECT DISTINCT grant_id, grantee_identifier AS grantee_role_arn
    FROM cloudtrail_logs.access_grants
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
      AND useridentity.arn LIKE '%S3AccessGrantsLocationRole/access-grants-%'
)
SELECT DISTINCT
    s3.eventtime,
    gr.grantee_role_arn,
    s3.source_identity,                -- only if the caller set SourceIdentity
    s3.eventname AS operation,
    s3.bucket,
    s3.file_path
FROM s3_events s3
JOIN ag_sessions ag ON ag.session_name = s3.session_name                    -- exact
JOIN gda g          ON abs(to_unixtime(g.t) - to_unixtime(ag.t)) <= 2       -- timing only (no shared ID)
JOIN grants gr      ON gr.grant_id = g.grant_id                             -- exact
ORDER BY s3.eventtime DESC
EOF
```

Run it in the Athena console (workgroup `cloudtrail-correlation`) or:

```bash
QID=$(aws athena start-query-execution --work-group cloudtrail-correlation --query-string file://attribution.sql \
      --region "$REGION" --profile "$STORAGE_PROFILE" --query QueryExecutionId --output text)
sleep 10
aws athena get-query-results --query-execution-id "$QID" --region "$REGION" --profile "$STORAGE_PROFILE" \
  --query 'ResultSet.Rows[].Data[].VarCharValue' --output text
```

**Limits**
- One grant per consuming role; otherwise a grant ID doesn't identify one role.
- Two different grantees calling within the same 2 s can give two rows for one S3 event.
- Returns the **grantee** role. *Who assumed it* (user / workload) is only in
  Feeder's logs: Feeder `AssumeRole` events on `FeederAccessGrantsRole` in
  `feeder_trail`. The Storage and Feeder copies of the same `GetDataAccess`
  call share `sharedeventid` and `requestid` (verified in the PoC).

---

## 11. Teardown (reverse order)

```bash
# Storage
aws events remove-targets --rule AccessGrantsInventoryOnChange --ids inventory --region "$REGION" --profile "$STORAGE_PROFILE"
aws events delete-rule    --name AccessGrantsInventoryOnChange              --region "$REGION" --profile "$STORAGE_PROFILE"
aws events remove-targets --rule AccessGrantsInventoryDaily    --ids inventory --region "$REGION" --profile "$STORAGE_PROFILE"
aws events delete-rule    --name AccessGrantsInventoryDaily                 --region "$REGION" --profile "$STORAGE_PROFILE"
aws lambda delete-function --function-name AccessGrantsInventory            --region "$REGION" --profile "$STORAGE_PROFILE"
aws cloudtrail delete-trail --name StorageDataLakeTrail                     --region "$REGION" --profile "$STORAGE_PROFILE"
aws ram delete-resource-share --resource-share-arn "$SHARE_ARN"             --region "$REGION" --profile "$STORAGE_PROFILE"
# grants / location: aws s3control delete-access-grant / delete-access-grants-location (IDs from list-access-grants*)
# Glue: aws glue delete-table --database-name cloudtrail_logs --name <table>; aws glue delete-database --name cloudtrail_logs
# Athena: aws athena delete-work-group --work-group cloudtrail-correlation --recursive-delete-option

# Feeder
aws lambda delete-function --function-name DataLakePocObjects               --region "$REGION" --profile "$FEEDER_PROFILE"
aws s3api delete-bucket-replication --bucket "$FEEDER_CT_BUCKET"            --profile "$FEEDER_PROFILE"
aws cloudtrail delete-trail --name FeederTrail                              --region "$REGION" --profile "$FEEDER_PROFILE"

# IAM: delete-role-policy / detach-role-policy, then delete-role for
#   Feeder:  FeederDataLakeLambdaRole, FeederAccessGrantsRole, CloudTrailReplicationRole
#   Storage: S3AccessGrantsLocationRole, AccessGrantsInventoryRole

# Buckets: versioned buckets must be emptied of ALL versions and delete markers
# first (empty_cloudtrail_buckets.sh in the PoC repo does that), then:
#   aws s3api delete-bucket --bucket <name> --profile <profile>
```
