# Data lake with S3 Access Grants — how it is built

This document explains, step by step, how the data lake is set up across two
AWS accounts and why each piece is there. It contains no CLI commands — those
are the numbered scripts in this folder, configured by one file, `.env`.
Here you find the reasoning and the **JSON of every policy and configuration**.

**Before you start**

- AWS CLI v2 and `zip` installed; run everything in **bash**, not zsh
  (`bash 01_…sh`).
- Two CLI profiles with admin rights: one for the Feeder account, one for the
  Storage account.
- An **S3 Access Grants instance already exists** in the Storage account, in the
  region you'll use. The scripts don't create it. Check with
  `aws s3control get-access-grants-instance --account-id <STORAGE_ACCOUNT_ID> --region <REGION>`.

**Running the scripts**

1. Edit `.env`: account IDs, profile names, region, `STORAGE_ADMIN_ARN` (read
   section 2.2 first), bucket names.
2. Run the scripts **in number order**: `bash 01_feeder_iam_lambda_roles.sh`,
   then `02_…`, and so on. The scripts refuse to run while `.env` still holds
   the example values.
3. Each script checks what already exists and can be re-run safely. Script 03
   asks for confirmation before applying the bucket policy.
4. Generated JSON/SQL/zip files go to `build/` (ignored by git).
5. Then test with `18_test.sh` (section 11) and query with `SQL_QUERIES.md`.
   If something returns nothing, use `TROUBLESHOOTING.md`.

| Script | Account | Task | Section below |
|---|---|---|---|
| `01_feeder_iam_lambda_roles.sh` | Feeder | Lambda exec role + grantee role | 3 |
| `02_feeder_iam_replication_role.sh` | Feeder | Replication role | 6.3 |
| `03_storage_s3_datalake.sh` | Storage | Data lake bucket + Access-Grants-only policy (asks before applying) | 2.2 |
| `04_storage_s3_cloudtrail_logs.sh` | Storage | Storage CloudTrail log bucket + lifecycle + policy | 2.1, 5 |
| `05_storage_s3_feeder_replica.sh` | Storage | Replica bucket + versioning + lifecycle + policy | 2.1, 2.3 |
| `06_storage_s3_athena_results.sh` | Storage | Athena results bucket | 9 |
| `07_storage_access_grants_location_role.sh` | Storage | Location role | 4.1 |
| `08_storage_access_grants_location_and_grant.sh` | Storage | Location + grant (reuses existing) | 4.2 |
| `09_ram_share_access_grants.sh` | both | RAM share + accept invitation | 4.3 |
| `10_storage_cloudtrail.sh` | Storage | Trail + event selectors | 5 |
| `11_feeder_s3_cloudtrail_logs.sh` | Feeder | Feeder log bucket + versioning + lifecycle + policy | 2.1, 6.2 |
| `12_feeder_cloudtrail.sh` | Feeder | Trail + event selectors | 6.2 |
| `13_feeder_s3_replication.sh` | Feeder | Replication rule | 6.4 |
| `14_feeder_lambda_datalake.sh` | Feeder | Lambda `DataLakePocObjects` (code in `lambda/`) | 7 |
| `15_storage_grants_inventory_lambda.sh` | Storage | Grants history: bucket + role + Lambda (append-only CSV) | 8 |
| `16_storage_grants_inventory_eventbridge.sh` | Storage | EventBridge rules: on grant change + daily | 8 |
| `17_storage_glue_athena.sh` | Storage | Workgroup, Glue database, tables | 9 |
| `18_test.sh` | both | Tests | 11 |
| `99_teardown.sh` | both | Remove everything (asks for confirmation) | 12 |

The script order differs slightly from the sections below: roles that other
policies name as principals are created first, because IAM checks a principal
when a policy is saved.

Placeholders used throughout:

| Placeholder | Meaning |
|---|---|
| `<REGION>` | Region of everything, e.g. `eu-west-1` |
| `<FEEDER_ACCOUNT_ID>` | Account that consumes the data lake |
| `<STORAGE_ACCOUNT_ID>` | Account that owns the data lake and the Access Grants instance |
| `<DATALAKE_BUCKET>` | The data lake bucket (Storage) |
| `<STORAGE_CT_BUCKET>` | CloudTrail logs of the Storage account (Storage) |
| `<FEEDER_CT_BUCKET>` | CloudTrail logs of the Feeder account (Feeder) |
| `<FEEDER_CT_REPLICA_BUCKET>` | Replica of the Feeder CloudTrail logs (Storage) |
| `<ATHENA_RESULTS_BUCKET>` | Athena query results (Storage) |
| `<INVENTORY_BUCKET>` | Grants history CSV (Storage) |
| `<STORAGE_ADMIN_ARN>` | IAM role or user used for admin work in Storage |
| `<AG_INSTANCE_ARN>` | `arn:aws:s3:<REGION>:<STORAGE_ACCOUNT_ID>:access-grants/default` |

---

## 1. The idea

The data lake lives in the **Storage** account. Consumers live in other
accounts — here the **Feeder** account. Nobody gets direct S3 permissions on the
data lake. Instead, every access goes through **S3 Access Grants**:

1. A workload in Feeder (here a Lambda) assumes a Feeder role that has been
   given a *grant* on the data lake.
2. With that role it calls `s3:GetDataAccess` on the Access Grants instance in
   Storage.
3. Access Grants checks the grant and returns short-lived credentials scoped to
   the requested prefix and permission.
4. The workload uses those credentials for the actual S3 calls.

On top of that, every access is logged with CloudTrail so it can be audited in
Athena: *which role did what on which file, and when.*

```
FEEDER account                                         STORAGE account
──────────────                                         ───────────────
Lambda DataLakePocObjects                              Access Grants instance
  exec role FeederDataLakeLambdaRole                     ├─ location  s3://<DATALAKE_BUCKET>/*
  └─ sts:AssumeRole (+ SourceIdentity)                   ├─ grant     FeederAccessGrantsRole → READWRITE
      └─ FeederAccessGrantsRole ── GetDataAccess ──▶     └─ shared with Feeder via RAM
                                                       <DATALAKE_BUCKET>  (reachable only via Access Grants)
CloudTrail FeederTrail
  └─ <FEEDER_CT_BUCKET> ── S3 replication ─────────▶  <FEEDER_CT_REPLICA_BUCKET>
                                                       CloudTrail StorageDataLakeTrail → <STORAGE_CT_BUCKET>
                                                       Lambda AccessGrantsInventory → <INVENTORY_BUCKET>
                                                       Glue database cloudtrail_logs + Athena
```

### What we learned in the proof of concept

These findings drive several design choices below:

- **The S3 log entry never shows the real caller.** S3 calls made with Access
  Grants credentials appear in CloudTrail as
  `<location role>/access-grants-<uuid>` (here
  `S3AccessGrantsLocationRole/access-grants-<uuid>`), a session that Access
  Grants creates itself. There is no `onBehalfOf` field for IAM principals.
- **Access Grants does not record the caller's access key** anywhere you can
  join on. It only passes along a `SourceIdentity` if the caller set one — and
  callers can't be forced to.
- **Storage sees a Feeder caller only partially.** On `GetDataAccess`, Storage
  records the Feeder account and the role *ID* (`AROA…`), not the role name or
  ARN. The full ARN and *who assumed the role* are only in Feeder's own logs.
- **The grant is the reliable link.** Each `GetDataAccess` event in Storage
  records which grant it matched (`matchedAccessGrantArn`). With one grant per
  consuming role, the grant identifies the role. This is what the attribution
  query uses.
- **Access Grants may reuse a credential session** for several calls on the
  same grant, so per-call details such as `SourceIdentity` can be missing on
  some S3 events. The grant, and therefore the role, stays correct.
- **New IAM roles, grants and RAM shares need ~3–4 minutes** before they work
  reliably. `AccessDenied` right after setup is propagation, not a mistake.

---

## 2. Storage account — buckets

Five buckets are created, all with **Block Public Access** fully on and
**default encryption SSE-S3 (AES256)**:

| Bucket | Purpose | Versioning | Lifecycle |
|---|---|---|---|
| `<DATALAKE_BUCKET>` | The data | off | none |
| `<STORAGE_CT_BUCKET>` | Storage CloudTrail logs | off | yes |
| `<FEEDER_CT_REPLICA_BUCKET>` | Replicated Feeder CloudTrail logs | **on** (required by replication) | yes |
| `<ATHENA_RESULTS_BUCKET>` | Athena query results | off | none |
| `<INVENTORY_BUCKET>` | Grants history CSV | off | none (history is needed) |

### 2.1 Lifecycle for log buckets

Log buckets keep logs for a fixed number of days: `LOG_RETENTION_DAYS` in
`.env`, 30 in the example below. Because the
replica bucket is versioned, the rule also removes old versions and the delete
markers left behind — otherwise deleted logs keep occupying (and costing)
storage invisibly. The same rule is used on the Feeder log bucket.

```json
{
  "Rules": [
    {
      "ID": "expire-logs-and-old-versions",
      "Status": "Enabled",
      "Filter": {},
      "Expiration": { "Days": 30 },
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
```

`ExpiredObjectDeleteMarker` can't be combined with `Days` in one rule, hence
two rules.

### 2.2 Data lake bucket policy — Access Grants only

A single **Deny** statement blocks every S3 request on the data lake unless at
least one of these is true:

- the request uses credentials vended by **this** Access Grants instance
  (`s3:accessgrantsinstancearn`),
- the request is made by an AWS service on your behalf (`aws:ViaAWSService`),
- the request comes from the admin principal (`aws:PrincipalArn`).

So even an administrator in Storage with `s3:*` can't read the data directly —
except the one admin role you name here.

> ⚠️ `<STORAGE_ADMIN_ARN>` must be an IAM **role or user** ARN
> (`arn:aws:iam::…:role/…`), not an `arn:aws:sts::…:assumed-role/…` session ARN.
> If it's wrong you lock yourself out, and only the account root user can
> remove the policy.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowOnlyViaAccessGrants",
      "Effect": "Deny",
      "Principal": "*",
      "Action": "s3:*",
      "Resource": [
        "arn:aws:s3:::<DATALAKE_BUCKET>",
        "arn:aws:s3:::<DATALAKE_BUCKET>/*"
      ],
      "Condition": {
        "StringNotEquals": { "s3:accessgrantsinstancearn": "<AG_INSTANCE_ARN>" },
        "Bool":            { "aws:ViaAWSService": "false" },
        "ArnNotEquals":    { "aws:PrincipalArn": "<STORAGE_ADMIN_ARN>" }
      }
    }
  ]
}
```

### 2.3 Replica bucket policy — accept replication from Feeder

Lets the Feeder replication role (section 6.3, script 02) write replicated objects and hand
their ownership to Storage. Apply it **after** that role exists: IAM checks the
principal when the policy is saved.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowFeederReplication",
      "Effect": "Allow",
      "Principal": { "AWS": "arn:aws:iam::<FEEDER_ACCOUNT_ID>:role/CloudTrailReplicationRole" },
      "Action": [
        "s3:ReplicateObject",
        "s3:ReplicateDelete",
        "s3:ReplicateTags",
        "s3:GetBucketVersioning",
        "s3:PutBucketVersioning",
        "s3:ObjectOwnerOverrideToBucketOwner"
      ],
      "Resource": [
        "arn:aws:s3:::<FEEDER_CT_REPLICA_BUCKET>",
        "arn:aws:s3:::<FEEDER_CT_REPLICA_BUCKET>/*"
      ]
    }
  ]
}
```

---

## 3. Feeder account — the roles a consumer uses

Two roles, deliberately separate:

- **`FeederDataLakeLambdaRole`** — the Lambda's execution role. It can do
  only one thing: assume the grantee role.
- **`FeederAccessGrantsRole`** — the **grantee**: the identity the grant in
  Storage is issued to. It can do only one thing: call `GetDataAccess` on the
  Storage instance.

Keeping them apart means the grant is tied to one stable role, while any number
of workloads can be allowed to assume it. Both steps allow
`sts:SetSourceIdentity`, so a caller *can* pass its own name along the chain
(useful, but not relied on).

### 3.1 `FeederDataLakeLambdaRole`

Trust policy — only Lambda can use it:

```json
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
```

Permissions — the AWS managed policy `AWSLambdaBasicExecutionRole` (CloudWatch
Logs), plus this inline policy:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["sts:AssumeRole", "sts:SetSourceIdentity"],
      "Resource": "arn:aws:iam::<FEEDER_ACCOUNT_ID>:role/FeederAccessGrantsRole"
    }
  ]
}
```

### 3.2 `FeederAccessGrantsRole` (the grantee)

Trust policy — only the Lambda execution role may assume it:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "AWS": "arn:aws:iam::<FEEDER_ACCOUNT_ID>:role/FeederDataLakeLambdaRole" },
      "Action": ["sts:AssumeRole", "sts:SetSourceIdentity"]
    }
  ]
}
```

Permissions — call Access Grants in the **Storage** account. No S3 permissions
at all: S3 access comes only from the credentials Access Grants returns.
(`GetAccessGrantsInstanceForPrefix` is only needed by the S3 Access Grants SDK
plugin; harmless otherwise.)

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:GetDataAccess", "s3:GetAccessGrantsInstanceForPrefix"],
      "Resource": "<AG_INSTANCE_ARN>"
    }
  ]
}
```

These roles are created before the grant (section 4), because the grant names
`FeederAccessGrantsRole` as its grantee.

---

## 4. Storage account — Access Grants

The Access Grants instance already exists (the scripts don't create it).
Three things are attached to it: a location role, a location with a grant, and
a RAM share.

**Existing Access Grants setup?** If a location for the data lake bucket
already exists, script 08 reuses it — with whatever location role it has — and
the role from 4.1 stays unused. That role's name is what appears in the S3 log
entries; the queries in `SQL_QUERIES.md` match any role name.

### 4.1 Location role `S3AccessGrantsLocationRole`

When Access Grants vends credentials, it assumes this role and narrows it down
to the granted prefix and permission. This role is therefore the **only**
identity with real S3 permissions on the data lake — and the one that appears
in every S3 log entry.

Trust policy — only the Access Grants service of this account:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Service": "access-grants.s3.amazonaws.com" },
      "Action": ["sts:AssumeRole", "sts:SetSourceIdentity"],
      "Condition": {
        "StringEquals": { "aws:SourceAccount": "<STORAGE_ACCOUNT_ID>" }
      }
    }
  ]
}
```

`sts:SetSourceIdentity` lets Access Grants carry a caller's `SourceIdentity`
onto the vended session.

Permissions — read/write on the data lake bucket (add `kms:Decrypt` /
`kms:GenerateDataKey` on the key if the bucket uses SSE-KMS):

```json
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
        "arn:aws:s3:::<DATALAKE_BUCKET>",
        "arn:aws:s3:::<DATALAKE_BUCKET>/*"
      ]
    }
  ]
}
```

### 4.2 Location and grant

- **Location:** scope `s3://<DATALAKE_BUCKET>/*`, using `S3AccessGrantsLocationRole`.
- **Grant:** on that location, permission **READWRITE**, grantee type **IAM**,
  grantee `arn:aws:iam::<FEEDER_ACCOUNT_ID>:role/FeederAccessGrantsRole`.

Rule for auditing: **one grant per consuming role.** The attribution query goes
from a grant to its grantee; if two roles shared a grant, you couldn't tell
them apart. A grant can be narrowed to a sub-prefix if a consumer should only
see part of the bucket.

### 4.3 Cross-account access: RAM share

A grant to a role in another account is not enough on its own: the Storage
instance must also accept `GetDataAccess` calls from the Feeder account. That
is done by sharing the Access Grants instance with **AWS RAM**:

- Resource share `S3AccessGrantsFeederShare`, resource `<AG_INSTANCE_ARN>`,
  principal: the Feeder account `<FEEDER_ACCOUNT_ID>`.
- Without AWS Organizations the share must allow external principals, and
  **Feeder has to accept the invitation**. Once accepted the association shows
  `ASSOCIATED`.
- If both accounts are in the same Organization, share with the organization or
  an OU instead; no invitation is needed then.

Both sides must agree, as always for cross-account access in AWS: Feeder allows
its role to call `GetDataAccess` (policy in 3.2), and Storage allows the Feeder
account in (this share).

> Alternative tested in the PoC: a resource policy directly on the Access
> Grants instance. RAM silently turns such a policy into its own share
> (type `CREATED_FROM_POLICY`). Use one mechanism, not both.

---

## 5. Storage account — CloudTrail

Trail **`StorageDataLakeTrail`**, single-region, log file validation on,
writing to `<STORAGE_CT_BUCKET>`. It records:

- **all management events** (except KMS and RDS Data API, which are very
  noisy). This includes `GetDataAccess`, the Access Grants internal
  `AssumeRole`, cross-account `AssumeRole`, and grant changes;
- **S3 data events on the data lake only.**

Event selectors:

```json
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
      { "Field": "resources.ARN", "StartsWith": ["arn:aws:s3:::<DATALAKE_BUCKET>/"] }
    ]
  }
]
```

The trailing `/` matters: without it, a bucket named `<DATALAKE_BUCKET>-backup`
would match too. `ListObjects` counts as an object-level data event and is
logged.

Bucket policy for `<STORAGE_CT_BUCKET>` — CloudTrail may check the ACL and write
logs, but only for this trail:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AWSCloudTrailAclCheck",
      "Effect": "Allow",
      "Principal": { "Service": "cloudtrail.amazonaws.com" },
      "Action": "s3:GetBucketAcl",
      "Resource": "arn:aws:s3:::<STORAGE_CT_BUCKET>",
      "Condition": {
        "StringEquals": {
          "aws:SourceArn": "arn:aws:cloudtrail:<REGION>:<STORAGE_ACCOUNT_ID>:trail/StorageDataLakeTrail"
        }
      }
    },
    {
      "Sid": "AWSCloudTrailWrite",
      "Effect": "Allow",
      "Principal": { "Service": "cloudtrail.amazonaws.com" },
      "Action": "s3:PutObject",
      "Resource": "arn:aws:s3:::<STORAGE_CT_BUCKET>/AWSLogs/<STORAGE_ACCOUNT_ID>/*",
      "Condition": {
        "StringEquals": {
          "s3:x-amz-acl": "bucket-owner-full-control",
          "aws:SourceArn": "arn:aws:cloudtrail:<REGION>:<STORAGE_ACCOUNT_ID>:trail/StorageDataLakeTrail"
        }
      }
    }
  ]
}
```

---

## 6. Feeder account — CloudTrail and replication to Storage

### 6.1 Why Feeder's logs go to Storage

The grantee role ARN can be found from Storage's logs alone (section 10). But two
things are **only** in Feeder's logs:

- the full session ARN of the `GetDataAccess` caller
  (`arn:aws:sts::<FEEDER_ACCOUNT_ID>:assumed-role/FeederAccessGrantsRole/<session>`);
- **who assumed the grantee role** — the user or workload behind it
  (here `FeederDataLakeLambdaRole`), recorded on Feeder's `AssumeRole` event.

These are **management events**, so Feeder's trail must keep management
events on. A Feeder trail limited to S3 data events on the data lake would
capture nothing: data events made with Access Grants credentials belong to the
Storage account and are only delivered there.

The Storage and Feeder copies of the same `GetDataAccess` call share the same
`sharedEventID` and `requestID`, so they can be joined exactly.

### 6.2 Trail `FeederTrail`

Single-region, log file validation on, writing to `<FEEDER_CT_BUCKET>`
(versioned — required for replication — with the lifecycle from 2.1).

Event selectors — management events only:

```json
[
  {
    "Name": "Management events (exclude KMS and RDS Data API)",
    "FieldSelectors": [
      { "Field": "eventCategory", "Equals": ["Management"] },
      { "Field": "eventSource", "NotEquals": ["kms.amazonaws.com", "rdsdata.amazonaws.com"] }
    ]
  }
]
```

> Using an existing Feeder trail? Its **management events must be on**
> (console: trail → *Management events* → Read and Write). A trail with only
> data events logs no `GetDataAccess` in Feeder, and Query 1 then can't find the
> grantee ARN. You may add data-event selectors on top; note that saving
> selectors with the CLI replaces all of them.

Bucket policy for `<FEEDER_CT_BUCKET>`:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AWSCloudTrailAclCheck",
      "Effect": "Allow",
      "Principal": { "Service": "cloudtrail.amazonaws.com" },
      "Action": "s3:GetBucketAcl",
      "Resource": "arn:aws:s3:::<FEEDER_CT_BUCKET>",
      "Condition": {
        "StringEquals": {
          "aws:SourceArn": "arn:aws:cloudtrail:<REGION>:<FEEDER_ACCOUNT_ID>:trail/FeederTrail"
        }
      }
    },
    {
      "Sid": "AWSCloudTrailWrite",
      "Effect": "Allow",
      "Principal": { "Service": "cloudtrail.amazonaws.com" },
      "Action": "s3:PutObject",
      "Resource": "arn:aws:s3:::<FEEDER_CT_BUCKET>/AWSLogs/<FEEDER_ACCOUNT_ID>/*",
      "Condition": {
        "StringEquals": {
          "s3:x-amz-acl": "bucket-owner-full-control",
          "aws:SourceArn": "arn:aws:cloudtrail:<REGION>:<FEEDER_ACCOUNT_ID>:trail/FeederTrail"
        }
      }
    }
  ]
}
```

### 6.3 Replication role `CloudTrailReplicationRole`

S3 assumes this role to copy new log files to Storage.

Trust policy:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Service": "s3.amazonaws.com" },
      "Action": "sts:AssumeRole"
    }
  ]
}
```

Permissions — read the source versions, write to the destination:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:GetReplicationConfiguration", "s3:ListBucket"],
      "Resource": "arn:aws:s3:::<FEEDER_CT_BUCKET>"
    },
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetObjectVersionForReplication",
        "s3:GetObjectVersionAcl",
        "s3:GetObjectVersionTagging"
      ],
      "Resource": "arn:aws:s3:::<FEEDER_CT_BUCKET>/*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "s3:ReplicateObject",
        "s3:ReplicateDelete",
        "s3:ReplicateTags",
        "s3:ObjectOwnerOverrideToBucketOwner"
      ],
      "Resource": "arn:aws:s3:::<FEEDER_CT_REPLICA_BUCKET>/*"
    }
  ]
}
```

### 6.4 Replication rule

Replicates the whole bucket to `<FEEDER_CT_REPLICA_BUCKET>` and makes Storage
the owner of the copies. **Delete-marker replication is disabled**: deleting
files in Feeder (for example in the console) does not hide them in Storage.
Each bucket expires its own copies through its lifecycle rule; lifecycle
deletions are never replicated.

```json
{
  "Role": "arn:aws:iam::<FEEDER_ACCOUNT_ID>:role/CloudTrailReplicationRole",
  "Rules": [
    {
      "ID": "replicate-to-storage",
      "Status": "Enabled",
      "Priority": 1,
      "Filter": {},
      "DeleteMarkerReplication": { "Status": "Disabled" },
      "Destination": {
        "Bucket": "arn:aws:s3:::<FEEDER_CT_REPLICA_BUCKET>",
        "Account": "<STORAGE_ACCOUNT_ID>",
        "StorageClass": "STANDARD",
        "AccessControlTranslation": { "Owner": "Destination" }
      }
    }
  ]
}
```

Replication only copies objects written after the rule exists. Versioning must
stay **enabled** on both buckets — suspending it on either side stops
replication.

---

## 7. Feeder account — Lambda `DataLakePocObjects`

A small Python 3.12 Lambda that lists, creates and deletes files in the data
lake. It runs as `FeederDataLakeLambdaRole` and has three environment
variables: the data lake bucket name, the Storage account ID, and the ARN of
the grantee role to assume (`FeederAccessGrantsRole`).

For every call it:

1. assumes `FeederAccessGrantsRole`, with its function name as session name
   and — unless the event says `"no_source_identity": true` — its own role name
   as `SourceIdentity`;
2. calls `GetDataAccess` on the **Storage** account's instance for the exact
   target: `s3://<DATALAKE_BUCKET>/*` with `READ` to list, or
   `s3://<DATALAKE_BUCKET>/<key>` with `WRITE` to create or delete;
3. makes the S3 call with the returned credentials.

Events — **one JSON object per invocation** (a list of actions in one event
doesn't work):

| Test event | Effect |
|---|---|
| `{ "action": "list" }` | lists all files (also the default without `action`) |
| `{ "action": "create", "key": "a.txt", "body": "hello" }` | creates `a.txt`; without `key` a name `upload-<timestamp>-<id>.txt` is generated |
| `{ "action": "delete", "key": "a.txt" }` | deletes `a.txt` |
| add `"no_source_identity": true` | same, without setting `SourceIdentity` (testing) |

In the Lambda console, save each as a named test event (**Test** → **Create new
event**) and run them one after another; `18_test.sh` runs a sequence from the CLI.

On failure it returns `operation` (`AssumeRole`, `GetDataAccess` or the S3
call), so you can see which step was denied. The code is in
`lambda/data_lake_poc_objects.py`.

---

## 8. Storage account — grants history

### 8.1 Why

The attribution query (section 10) needs to translate a grant ID into the grantee
role ARN. Grants are configuration, not log events: their creation may have
happened long before the oldest log you still keep. So the grants are recorded
in a file of their own instead of being hardcoded in the query.

### 8.2 How

- A Lambda **`AccessGrantsInventory`** keeps an **append-only CSV** of all
  grants: `s3://<INVENTORY_BUCKET>/access-grants-history/access_grants_history.csv`.
- Each run lists the current grants and compares them with the file:
  a grant that is new gets a **`CREATED`** line, a grant that has disappeared
  gets a **`DELETED`** line, and if nothing changed nothing is written.
- Lines are **never changed or removed**. S3 can't append to an object, so the
  Lambda reads the file, adds the new lines at the end and uploads the whole
  file again — the old content unchanged. Because a grant's `CREATED` line
  stays after the grant is deleted, old log events still resolve to the right
  role. Grant IDs are never reused.
- Two runs must not overwrite each other: the upload is **conditional** on the
  file's ETag — if the file changed since it was read, the upload fails and
  Lambda retries the run. In addition the script reserves a **concurrency of
  1** (one run at a time). New accounts with a concurrency limit of 10 can't
  reserve any; the script then only warns, and the conditional write still
  protects the file.
- Columns: `observed_at` (when the Lambda saw the change), `event`,
  `grant_id`, `grant_arn`, `grantee_type`, `grantee_identifier`, `permission`,
  `grant_scope`, `location_id`, `created_at` (when the grant was created).
- Two **EventBridge** rules invoke it: right after every `CreateAccessGrant`
  or `DeleteAccessGrant`, and once a day as a safety net. Those calls are
  CloudTrail management events, which EventBridge receives in the same region.
  Extra runs are harmless — a run without changes appends nothing.

Example content:

```
"observed_at","event","grant_id","grant_arn","grantee_type","grantee_identifier","permission","grant_scope","location_id","created_at"
"2026-11-11T08:55:29+00:00","CREATED","9d46a38b-…","arn:aws:s3:<REGION>:<STORAGE_ACCOUNT_ID>:access-grants/default/grant/9d46a38b-…","IAM","arn:aws:iam::<FEEDER_ACCOUNT_ID>:role/FeederAccessGrantsRole","READWRITE","s3://<DATALAKE_BUCKET>/*","0e3b4f96-…","2026-11-09T21:11:22.718000+00:00"
"2026-11-12T10:02:11+00:00","DELETED","9d46a38b-…", …same details…
```

Role `AccessGrantsInventoryRole` — trust policy: same as in 3.1 (Lambda
service). Permissions: `AWSLambdaBasicExecutionRole` plus the policy below.
`s3:ListBucket` (limited to the prefix) is there so that on the first run a
missing file is reported as "not found" instead of "access denied".

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "s3:ListAccessGrants",
      "Resource": "<AG_INSTANCE_ARN>"
    },
    {
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject"],
      "Resource": "arn:aws:s3:::<INVENTORY_BUCKET>/access-grants-history/access_grants_history.csv"
    },
    {
      "Effect": "Allow",
      "Action": "s3:ListBucket",
      "Resource": "arn:aws:s3:::<INVENTORY_BUCKET>",
      "Condition": { "StringLike": { "s3:prefix": "access-grants-history/*" } }
    }
  ]
}
```

EventBridge rule `AccessGrantsInventoryOnChange`, event pattern:

```json
{
  "source": ["aws.s3"],
  "detail-type": ["AWS API Call via CloudTrail"],
  "detail": {
    "eventSource": ["s3.amazonaws.com"],
    "eventName": ["CreateAccessGrant", "DeleteAccessGrant"]
  }
}
```

Values are compared **exactly, including upper/lower case**:
`"AWS API Call via Cloudtrail"` (lowercase *t*) is valid JSON but never
matches, and the rule silently never fires.

EventBridge rule `AccessGrantsInventoryDaily`: schedule `rate(1 day)`.

Each rule needs a Lambda resource permission allowing
`events.amazonaws.com` to invoke the function, limited to that rule's ARN.

### 8.3 Setting up the rules in the console (instead of script 16)

Storage account, **same region** as the Access Grants instance.

**On-change rule:** EventBridge → **Rules** → **Create rule**

1. Name `AccessGrantsInventoryOnChange`, event bus **`default`** (AWS service
   events only arrive on the default bus — don't create a custom bus), rule
   type **Rule with an event pattern** → Next.
2. Event source **AWS events or EventBridge partner events**, creation method
   **Custom pattern (JSON editor)**, paste the pattern above → Next.
3. Target **AWS service** → **Lambda function** → `AccessGrantsInventory` →
   Next. The console adds the Lambda permission for EventBridge itself.
4. Next → **Create rule**.

**Daily run:** EventBridge → **Scheduler** → **Schedules** → **Create schedule**:
name `AccessGrantsInventoryDaily`, **Recurring schedule** → **Rate-based** `1`
days, flexible time window **Off**; target **AWS Lambda – Invoke** →
`AccessGrantsInventory`; permissions **Create new role for this schedule**.
Use this *or* the rule from script 16, not both. It's a safety net: a missed
grant change would otherwise only be caught at the next change.

**Check it works:** create a test grant, wait 2–5 minutes, then look at the
rule's **Monitoring** tab (`TriggeredRules`, `Invocations`), the Lambda's
CloudWatch log (`"created": 1`) and the last line of the CSV. If nothing
happens, follow `TROUBLESHOOTING.md` check 8.

> Tested: the append logic (first run, no change, new grant, deleted grant,
> concurrent change) and the Glue table + attribution query in the PoC
> (2026-11-11); the on-change rule firing on a new grant (2026-11-12).

---

## 9. Storage account — Glue and Athena

- **Athena workgroup `cloudtrail-correlation`**: results written to
  `<ATHENA_RESULTS_BUCKET>` with SSE-S3; workgroup settings enforced.
- **Glue database `cloudtrail_logs`**, with one table per log source:

| Table | Data | Location |
|---|---|---|
| `storage_datalake_trail` | Storage CloudTrail | `s3://<STORAGE_CT_BUCKET>/AWSLogs/<STORAGE_ACCOUNT_ID>/CloudTrail/<REGION>/` |
| `feeder_trail` | Replicated Feeder CloudTrail | `s3://<FEEDER_CT_REPLICA_BUCKET>/AWSLogs/<FEEDER_ACCOUNT_ID>/CloudTrail/<REGION>/` |
| `access_grants_history` | Grants history (CSV) | `s3://<INVENTORY_BUCKET>/access-grants-history/` |

The two CloudTrail tables use AWS's standard CloudTrail schema with
**partition projection** on `year`/`month`/`day` (no `MSCK REPAIR` needed; queries
must filter on these columns to avoid full scans). One addition matters:
`useridentity.sessioncontext` declares a **`sourceidentity`** field. Without it
Athena can't read `SourceIdentity`, even though it is in the raw logs.

The `access_grants_history` table reads the CSV with the OpenCSV SerDe
(header line skipped, all columns strings): `observed_at`, `event`,
`grant_id`, `grant_arn`, `grantee_type`, `grantee_identifier`, `permission`,
`grant_scope`, `location_id`, `created_at`. It reads every file under the
prefix, so keep only the history CSV there.

---

## 10. Attribution: which role accessed which file

The query links four records, all in Storage:

| Step | From → to | Join | Exact? |
|---|---|---|---|
| 1 | S3 data event → Access Grants internal `AssumeRole` | session name `access-grants-<uuid>` | yes |
| 2 | → `GetDataAccess` | timestamp within ±2 s | timing only |
| 3 | → grant | `matchedAccessGrantArn` | yes |
| 4 | → grantee role ARN | `access_grants_history` table (`CREATED` line) | yes |

Step 2 is the only weak link: Access Grants records no shared ID between the
`GetDataAccess` call and the session it creates. In the PoC they were always
logged in the same second. If two **different** grantees call within the same
two seconds, one S3 event can appear twice, once per grantee.

```sql
WITH grants AS (               -- grant IDs are never reused, so deleted grants still resolve
    SELECT DISTINCT grant_id, grantee_identifier AS grantee_role_arn
    FROM cloudtrail_logs.access_grants_history
    WHERE event = 'CREATED'
),
ag_sessions AS (
    SELECT from_iso8601_timestamp(eventtime) AS t,
           regexp_extract(requestparameters, '"roleSessionName"\s*:\s*"([^"]+)"', 1) AS session_name
    FROM cloudtrail_logs.storage_datalake_trail
    WHERE year = '2026' AND month = '11'
      AND eventsource = 'sts.amazonaws.com' AND eventname = 'AssumeRole'
      AND requestparameters LIKE '%access-grants-%'
),
gda AS (
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
JOIN ag_sessions ag ON ag.session_name = s3.session_name
JOIN gda g          ON abs(to_unixtime(g.t) - to_unixtime(ag.t)) <= 2
JOIN grants gr      ON gr.grant_id = g.grant_id
ORDER BY s3.eventtime DESC
```

Adjust `year` and `month` in the three CTEs to the period you query.

This is Query 3 in [SQL_QUERIES.md](SQL_QUERIES.md) (plus the
`source_identity` column). Two other variants — one that joins Storage's and
Feeder's logs, one with the grants hardcoded — are there too, with queries to
list the grants.

What the columns tell you:

- **`grantee_role_arn`** — always filled, e.g.
  `arn:aws:iam::<FEEDER_ACCOUNT_ID>:role/FeederAccessGrantsRole`. Doesn't depend
  on callers' discipline.
- **`source_identity`** — only filled if the caller set `SourceIdentity` and
  Access Grants didn't serve the call from an earlier session. Treat it as a
  bonus, not as evidence.
- **Who assumed the grantee role** is not in this result. For that, look up
  Feeder's `AssumeRole` events on `FeederAccessGrantsRole` in `feeder_trail`.
  If several people or workloads share a grantee role, this is the only way to
  tell them apart — or give each of them its own role and grant.

---

## 11. Testing

1. Invoke the Lambda with `list`, then `create`, `list`, `delete`. Expect
   success for all four; `AccessDenied` in the first minutes after setup is
   propagation.
2. Try to list the data lake directly with an admin from Feeder, and with a
   Storage admin other than `<STORAGE_ADMIN_ARN>`. Both must be refused by the
   bucket policy.
3. Check replication: new Feeder log files show replication status `COMPLETED`
   and appear in `<FEEDER_CT_REPLICA_BUCKET>`.
4. Wait **5–15 minutes** for CloudTrail delivery (management events can arrive
   later than data events), then run the attribution query. Each of your test
   operations should appear with `FeederAccessGrantsRole` as grantee. Don't
   empty the log buckets before the logs have been read.
5. Create a test grant and check that a `CREATED` line for it is appended to the
   grants history CSV within a few minutes; delete it and check for `DELETED`.

---

## 12. Teardown

Reverse order: EventBridge rules and their targets, the grants history Lambda, both
trails, the RAM share, the grant and location, Glue tables and database, the
Athena workgroup, the Feeder Lambda, the replication rule, then the IAM roles
(remove inline policies and detach managed policies first). Versioned buckets
must be emptied of **all versions and delete markers** before they can be
deleted; a plain "empty" in the console only adds delete markers.
