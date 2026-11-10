# Data lake with S3 Access Grants — how it is built

This document explains, step by step, how the data lake is set up across two
AWS accounts and why each piece is there. It contains no CLI commands — those
are in [`DATALAKE_CLI_SETUP.md`](DATALAKE_CLI_SETUP.md), which follows the same
steps in the same order. Here you find the reasoning and the **JSON of every
policy and configuration**.

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
| `<INVENTORY_BUCKET>` | Snapshots of the Access Grants grants (Storage) |
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
  `S3AccessGrantsLocationRole/access-grants-<uuid>`, a session that Access Grants
  creates itself. There is no `onBehalfOf` field for IAM principals.
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
| `<INVENTORY_BUCKET>` | Grants snapshots | off | none (history is needed) |

### 2.1 Lifecycle for log buckets

Log buckets keep logs for a fixed number of days (30 below). Because the
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

Lets the Feeder replication role (step 5) write replicated objects and hand
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

These roles are created before the grant (step 4), because the grant names
`FeederAccessGrantsRole` as its grantee.

---

## 4. Storage account — Access Grants

The Access Grants instance already exists. Three things are attached to it.

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

The grantee role ARN can be found from Storage's logs alone (step 9). But two
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

Events:

```json
{ "action": "list" }
{ "action": "create", "key": "a.txt", "body": "hello" }
{ "action": "delete", "key": "a.txt" }
```

On failure it returns `operation` (`AssumeRole`, `GetDataAccess` or the S3
call), so you can see which step was denied. The code is in
`DATALAKE_CLI_SETUP.md`, step 6.

---

## 8. Storage account — grants inventory

### 8.1 Why

The attribution query (step 10) needs to translate a grant ID into the grantee
role ARN. Grants are configuration, not log events: their creation may have
happened long before the oldest log you still keep. So the current grants are
exported regularly to a table instead of being hardcoded in the query.

### 8.2 How

- A Lambda **`AccessGrantsInventory`** lists all grants of the instance and
  writes them as one JSON-lines file per run to
  `s3://<INVENTORY_BUCKET>/access-grants/<timestamp>.json`. One line per grant:
  grant ID, grant ARN, grantee type and identifier, permission, scope,
  location ID, creation time, export time.
- Old snapshots are kept, so grants that were deleted later still resolve for
  old log events. Grant IDs are never reused.
- Two **EventBridge** rules invoke it: once a day, and right after every
  `CreateAccessGrant` or `DeleteAccessGrant`. Those calls are CloudTrail
  management events, which EventBridge receives in the same region without any
  extra configuration. The daily run catches anything the on-change rule
  misses.

Role `AccessGrantsInventoryRole` — trust policy: same as in 3.1 (Lambda
service). Permissions: `AWSLambdaBasicExecutionRole` plus:

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
      "Action": "s3:PutObject",
      "Resource": "arn:aws:s3:::<INVENTORY_BUCKET>/access-grants/*"
    }
  ]
}
```

EventBridge rule `AccessGrantsInventoryDaily`: schedule `rate(1 day)`.

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

Each rule needs a Lambda resource permission allowing
`events.amazonaws.com` to invoke the function, limited to that rule's ARN.

> Not yet tested end to end: in the PoC the grants lookup used a fixed list.
> After creating a grant, check that a new snapshot appears within a few minutes.

---

## 9. Storage account — Glue and Athena

- **Athena workgroup `cloudtrail-correlation`**: results written to
  `<ATHENA_RESULTS_BUCKET>` with SSE-S3; workgroup settings enforced.
- **Glue database `cloudtrail_logs`**, with one table per log source:

| Table | Data | Location |
|---|---|---|
| `storage_datalake_trail` | Storage CloudTrail | `s3://<STORAGE_CT_BUCKET>/AWSLogs/<STORAGE_ACCOUNT_ID>/CloudTrail/<REGION>/` |
| `feeder_trail` | Replicated Feeder CloudTrail | `s3://<FEEDER_CT_REPLICA_BUCKET>/AWSLogs/<FEEDER_ACCOUNT_ID>/CloudTrail/<REGION>/` |
| `access_grants` | Grants snapshots | `s3://<INVENTORY_BUCKET>/access-grants/` |

The two CloudTrail tables use AWS's standard CloudTrail schema with
**partition projection** on `year`/`month`/`day` (no `MSCK REPAIR` needed; queries
must filter on these columns to avoid full scans). One addition matters:
`useridentity.sessioncontext` declares a **`sourceidentity`** field. Without it
Athena can't read `SourceIdentity`, even though it is in the raw logs.

The `access_grants` table is plain JSON lines (OpenX JSON SerDe) with columns
`grant_id`, `grant_arn`, `grantee_type`, `grantee_identifier`, `permission`,
`grant_scope`, `location_id`, `created_at`, `exported_at`.

---

## 10. Attribution: which role accessed which file

The query links four records, all in Storage:

| Step | From → to | Join | Exact? |
|---|---|---|---|
| 1 | S3 data event → Access Grants internal `AssumeRole` | session name `access-grants-<uuid>` | yes |
| 2 | → `GetDataAccess` | timestamp within ±2 s | timing only |
| 3 | → grant | `matchedAccessGrantArn` | yes |
| 4 | → grantee role ARN | `access_grants` table | yes |

Step 2 is the only weak link: Access Grants records no shared ID between the
`GetDataAccess` call and the session it creates. In the PoC they were always
logged in the same second. If two **different** grantees call within the same
two seconds, one S3 event can appear twice, once per grantee.

```sql
WITH grants AS (
    SELECT DISTINCT grant_id, grantee_identifier AS grantee_role_arn
    FROM cloudtrail_logs.access_grants
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
      AND useridentity.arn LIKE '%S3AccessGrantsLocationRole/access-grants-%'
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

Two other variants — one that joins Storage's and Feeder's logs, one with the
grants hardcoded — are in [SQL_QUERIES.md](SQL_QUERIES.md).

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
5. Create a test grant and check that a new inventory snapshot appears.

---

## 12. Teardown

Reverse order: EventBridge rules and their targets, the inventory Lambda, both
trails, the RAM share, the grant and location, Glue tables and database, the
Athena workgroup, the Feeder Lambda, the replication rule, then the IAM roles
(remove inline policies and detach managed policies first). Versioned buckets
must be emptied of **all versions and delete markers** before they can be
deleted; a plain "empty" in the console only adds delete markers.
