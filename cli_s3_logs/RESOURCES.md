# Resources to create

Every AWS resource the setup needs, per account, with the name the scripts use.
Use it to choose your own names before you start.

**Where a name comes from:**
- **`.env`**: change it in `.env` only; all scripts pick it up.
- **script**: the name is written in the scripts themselves. To rename it, change
  it in **every** file listed in the table's last column, including the docs and
  `99_teardown.sh` (search the folder for the name).

Bucket names are global across all AWS accounts, which is why they end in the
account ID by default.

`<S>` = Storage account ID, `<F>` = Feeder account ID, `<REGION>` = `REGION` in `.env`.

---

## Prerequisite (not created by the scripts)

| Resource | Account | Name / ARN | Note |
|---|---|---|---|
| S3 Access Grants instance | Storage | `arn:aws:s3:<REGION>:<S>:access-grants/default` | One per account and region; the name is always `default` |
| Admin IAM role or user | Storage | `STORAGE_ADMIN_ARN` in `.env` | Stays allowed on the data lake bucket despite its Deny policy |

---

## Storage account

### S3 buckets

| Purpose | Default name | Set in | Script | Settings |
|---|---|---|---|---|
| Data lake | `datalake-<S>` | `.env` `DATALAKE_BUCKET` | 03 | Block public access, SSE-S3, bucket policy (below) |
| Storage CloudTrail logs | `cloudtrail-logs-datalake-<S>` | `.env` `STORAGE_CT_BUCKET` | 04 | Block public access, SSE-S3, lifecycle, bucket policy |
| Replica of Feeder's CloudTrail logs | `cloudtrail-logs-for-feeder-<S>` | `.env` `FEEDER_CT_REPLICA_BUCKET` | 05 | **Versioning on** (required by replication), lifecycle, bucket policy |
| Athena query results | `athena-query-results-datalake-<S>` | `.env` `ATHENA_RESULTS_BUCKET` | 06 | Block public access, SSE-S3 |
| Grants history CSV | `access-grants-inventory-<S>` | `.env` `INVENTORY_BUCKET` | 15 | Block public access, SSE-S3 |

Object key of the grants history CSV: `access-grants-history/access_grants_history.csv`
(`.env` `GRANTS_CSV_PREFIX`, `GRANTS_CSV_KEY`). Keep only this file under the prefix:
the Glue table reads every file in it.

### Bucket policies

| Bucket | Statements (Sid) | Script |
|---|---|---|
| Data lake | `AllowOnlyViaAccessGrants`: Deny `s3:*` unless the request comes through the Access Grants instance, through an AWS service, or from `STORAGE_ADMIN_ARN` | 03 |
| Storage CloudTrail logs | `AWSCloudTrailAclCheck`, `AWSCloudTrailWrite` (for trail `StorageDataLakeTrail`) | 04 |
| Feeder log replica | Allows Feeder's `CloudTrailReplicationRole` to replicate objects into it | 05 |

### Lifecycle rules (both CloudTrail log buckets: Storage logs, Feeder replica)

| Rule ID | Does |
|---|---|
| `expire-logs-and-old-versions` | Deletes logs after `LOG_RETENTION_DAYS` (`.env`, default 30); old versions after 1 day |
| `remove-expired-delete-markers` | Removes delete markers left behind |

### IAM roles and policies

| Role | Set in | Trusted by | Policies | Script |
|---|---|---|---|---|
| `S3AccessGrantsLocationRole` | script (07, 08) | `access-grants.s3.amazonaws.com` (condition `aws:SourceAccount` = `<S>`), with `sts:SetSourceIdentity` | Inline **`S3AccessGrantsLocationS3Policy`**: read/write/list on the data lake bucket | 07 |
| `AccessGrantsInventoryRole` | script (15) | `lambda.amazonaws.com` | Managed **`AWSLambdaBasicExecutionRole`**; inline **`AccessGrantsInventoryPolicy`**: `s3:ListAccessGrants` on the instance, `s3:GetObject`/`s3:PutObject` on the CSV, `s3:ListBucket` on the CSV prefix | 15 |

If your Access Grants location already exists with another role, you don't
need `S3AccessGrantsLocationRole` (see the README, section 4).

### S3 Access Grants

| Resource | Value | Script |
|---|---|---|
| Location | Scope `s3://<DATALAKE_BUCKET>/*`, role `S3AccessGrantsLocationRole` | 08 |
| Grant | Grantee `arn:aws:iam::<F>:role/FeederAccessGrantsRole`, type IAM, permission `READWRITE` | 08 |

Locations and grants get generated IDs; you can't name them.

### RAM (Resource Access Manager)

| Resource | Default name | Set in | Script |
|---|---|---|---|
| Resource share of the Access Grants instance with the Feeder account (external principals allowed) | `S3AccessGrantsFeederShare` | `.env` `RAM_SHARE_NAME` | 09 |

The Feeder account must accept the invitation (script 09 does it).

### CloudTrail

| Trail | Set in | Writes to | Event selectors | Script |
|---|---|---|---|---|
| `StorageDataLakeTrail` | `.env` `STORAGE_TRAIL` | Storage CloudTrail log bucket | 1. `Management events (exclude KMS and RDS Data API)` <br>2. `S3 data events on the data lake`: objects whose ARN starts with `arn:aws:s3:::<DATALAKE_BUCKET>/` | 10 |

Single-region trail, log file validation on.

### Lambda

| Function | Set in | Role | Code / handler | Runtime, timeout | Environment variables | Script |
|---|---|---|---|---|---|---|
| `AccessGrantsInventory` | script (15, 16) | `AccessGrantsInventoryRole` | `lambda/access_grants_history.py`, `access_grants_history.lambda_handler` | python3.12, 60 s | `ACCOUNT_ID`, `BUCKET`, `KEY` | 15 |

- Reserved concurrency 1 (skipped with a warning if the account limit is too low).
- Resource-based permissions (who can invoke it): statement IDs
  `AccessGrantsInventoryDaily` and `AccessGrantsInventoryOnChange`, principal
  `events.amazonaws.com` (script 16).
- Created automatically by Lambda: log group `/aws/lambda/AccessGrantsInventory`.

### EventBridge (default event bus)

| Rule | Set in | Trigger | Target | Script |
|---|---|---|---|---|
| `AccessGrantsInventoryOnChange` | script (16) | Pattern: `source` `aws.s3`, `detail-type` `AWS API Call via CloudTrail`, `eventName` `CreateAccessGrant` / `DeleteAccessGrant` | Lambda `AccessGrantsInventory` (target ID `inventory`) | 16 |
| `AccessGrantsInventoryDaily` | script (16) | Schedule `rate(1 day)` | Lambda `AccessGrantsInventory` (target ID `inventory`) | 16 |

The rules must be on the **default** bus, in the same region as Access Grants.

### Glue and Athena

| Resource | Default name | Set in | Reads | Script |
|---|---|---|---|---|
| Athena workgroup | `cloudtrail-correlation` | `.env` `ATHENA_WORKGROUP` | Results go to the Athena results bucket | 17 |
| Glue database | `cloudtrail_logs` | `.env` `GLUE_DATABASE` | | 17 |
| Table `storage_datalake_trail` | script (17, SQL) | | `s3://<STORAGE_CT_BUCKET>/AWSLogs/<S>/CloudTrail/<REGION>/` | 17 |
| Table `feeder_trail` | script (17, SQL) | | `s3://<FEEDER_CT_REPLICA_BUCKET>/AWSLogs/<F>/CloudTrail/<REGION>/` | 17 |
| Table `access_grants_history` | script (17, SQL) | | `s3://<INVENTORY_BUCKET>/access-grants-history/` | 17 |

The two CloudTrail tables use partition projection (year/month/day): no crawler
and no partitions to add. Table names are also used in the queries
(`SQL_QUERIES.md`, `TROUBLESHOOTING.md`).

---

## Feeder account

### S3 buckets

| Purpose | Default name | Set in | Script | Settings |
|---|---|---|---|---|
| Feeder CloudTrail logs | `cloudtrail-logs-feeder-<F>` | `.env` `FEEDER_CT_BUCKET` | 11 | **Versioning on**, block public access, SSE-S3, lifecycle (same 2 rules), bucket policy (`AWSCloudTrailAclCheck`, `AWSCloudTrailWrite` for trail `FeederTrail`), replication rule |

### Replication rule (on the Feeder log bucket)

| Rule ID | Role | Destination | Script |
|---|---|---|---|
| `replicate-to-storage` | `CloudTrailReplicationRole` | Storage bucket `cloudtrail-logs-for-feeder-<S>`, owner changed to Storage; delete markers not replicated | 13 |

### IAM roles and policies

| Role | Set in | Trusted by | Policies | Script |
|---|---|---|---|---|
| `FeederDataLakeLambdaRole` | script (01, 14) | `lambda.amazonaws.com` | Managed **`AWSLambdaBasicExecutionRole`**; inline **`AssumeFeederAccessGrantsRole`**: `sts:AssumeRole` + `sts:SetSourceIdentity` on `FeederAccessGrantsRole` | 01 |
| `FeederAccessGrantsRole` | script (01, 08, 14, queries) | `FeederDataLakeLambdaRole`, with `sts:SetSourceIdentity` | Inline **`GetDataAccessOnStorage`**: `s3:GetDataAccess` + `s3:GetAccessGrantsInstanceForPrefix` on Storage's Access Grants instance | 01 |
| `CloudTrailReplicationRole` | script (02, 05, 13) | `s3.amazonaws.com` | Inline **`CloudTrailReplicationPolicy`**: read the Feeder log bucket, replicate into the Storage replica bucket | 02 |

`FeederAccessGrantsRole` is the **grantee**: its ARN is in the grant (script 08)
and is what the queries return.

### CloudTrail

| Trail | Set in | Writes to | Event selectors | Script |
|---|---|---|---|---|
| `FeederTrail` | `.env` `FEEDER_TRAIL` | Feeder CloudTrail log bucket | `Management events (exclude KMS and RDS Data API)`. Must stay on: it records Feeder's copy of `GetDataAccess` | 12 |

### Lambda

| Function | Set in | Role | Code / handler | Runtime, timeout | Environment variables | Script |
|---|---|---|---|---|---|---|
| `DataLakePocObjects` | script (14) | `FeederDataLakeLambdaRole` | `lambda/data_lake_poc_objects.py`, `data_lake_poc_objects.lambda_handler` | python3.12, 30 s | `BUCKET_NAME`, `STORAGE_ACCOUNT_ID`, `ASSUME_ROLE_ARN` | 14 |

Created automatically by Lambda: log group `/aws/lambda/DataLakePocObjects`.

---

## Count

| | Storage | Feeder |
|---|---|---|
| S3 buckets | 5 | 1 |
| IAM roles | 2 (+ your admin role) | 3 |
| Inline policies | 2 | 3 |
| Bucket policies | 3 | 1 |
| Lambda functions | 1 | 1 |
| EventBridge rules | 2 | 0 |
| CloudTrail trails | 1 | 1 |
| Access Grants location + grant | 1 + 1 | 0 |
| RAM shares | 1 (accepted in Feeder) | |
| Athena workgroup | 1 | 0 |
| Glue database + tables | 1 + 3 | 0 |
