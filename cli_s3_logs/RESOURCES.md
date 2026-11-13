# Resources to create

One table per resource: the resource and its policies, with their names.
`<S>` = Storage account ID, `<F>` = Feeder account ID.
Names in `.env` can be changed there; the others are written in the scripts.

---

## Storage account

### Data lake bucket

| Type | Name |
|---|---|
| S3 bucket | `datalake-<S>` (`.env` `DATALAKE_BUCKET`) |
| Bucket policy | statement `AllowOnlyViaAccessGrants` |

### CloudTrail log bucket

| Type | Name |
|---|---|
| S3 bucket | `cloudtrail-logs-datalake-<S>` (`.env` `STORAGE_CT_BUCKET`) |
| Bucket policy | statements `AWSCloudTrailAclCheck`, `AWSCloudTrailWrite` |
| Lifecycle rule | `expire-logs-and-old-versions` |
| Lifecycle rule | `remove-expired-delete-markers` |

### Athena results bucket

| Type | Name |
|---|---|
| S3 bucket | `athena-query-results-datalake-<S>` (`.env` `ATHENA_RESULTS_BUCKET`) |

### Grants history bucket

| Type | Name |
|---|---|
| S3 bucket | `access-grants-inventory-<S>` (`.env` `INVENTORY_BUCKET`) |
| CSV file | `access-grants-history/access_grants_history.csv` (`.env` `GRANTS_CSV_KEY`) |

### Access Grants location role

| Type | Name |
|---|---|
| IAM role | `S3AccessGrantsLocationRole` |
| Trust policy | trusts `access-grants.s3.amazonaws.com` |
| Inline policy | `S3AccessGrantsLocationS3Policy` |

### Grants history Lambda role

| Type | Name |
|---|---|
| IAM role | `AccessGrantsInventoryRole` |
| Trust policy | trusts `lambda.amazonaws.com` |
| Managed policy | `AWSLambdaBasicExecutionRole` |
| Inline policy | `AccessGrantsInventoryPolicy` |

### Access Grants

| Type | Name |
|---|---|
| Access Grants instance (must already exist) | `default` |
| Location | `s3://datalake-<S>/*` (ID generated) |
| Grant | to `FeederAccessGrantsRole`, `READWRITE` (ID generated) |

### RAM share

| Type | Name |
|---|---|
| Resource share | `S3AccessGrantsFeederShare` (`.env` `RAM_SHARE_NAME`) |

### CloudTrail trail

| Type | Name |
|---|---|
| Trail | `StorageDataLakeTrail` (`.env` `STORAGE_TRAIL`) |
| Event selector | `Management events (exclude KMS and RDS Data API)` |
| Event selector | `S3 data events on the data lake` |

### Grants history Lambda

| Type | Name |
|---|---|
| Lambda function | `AccessGrantsInventory` |
| Execution role | `AccessGrantsInventoryRole` |
| Resource-based policy | statements `AccessGrantsInventoryOnChange`, `AccessGrantsInventoryDaily` |

### EventBridge rule: on grant change

| Type | Name |
|---|---|
| EventBridge rule (`default` bus) | `AccessGrantsInventoryOnChange` |
| Target | `inventory` → `AccessGrantsInventory` |

### EventBridge rule: daily

| Type | Name |
|---|---|
| EventBridge rule (`default` bus) | `AccessGrantsInventoryDaily` |
| Target | `inventory` → `AccessGrantsInventory` |

### Athena workgroup

| Type | Name |
|---|---|
| Athena workgroup | `cloudtrail-correlation` (`.env` `ATHENA_WORKGROUP`) |

### Glue database

| Type | Name |
|---|---|
| Glue database | `cloudtrail_logs` (`.env` `GLUE_DATABASE`) |
| Glue table | `storage_datalake_trail` |
| Glue table | `access_grants_history` |

---

## Feeder account

### Lambda execution role

| Type | Name |
|---|---|
| IAM role | `FeederDataLakeLambdaRole` |
| Trust policy | trusts `lambda.amazonaws.com` |
| Managed policy | `AWSLambdaBasicExecutionRole` |
| Inline policy | `AssumeFeederAccessGrantsRole` |

### Grantee role

| Type | Name |
|---|---|
| IAM role | `FeederAccessGrantsRole` |
| Trust policy | trusts `FeederDataLakeLambdaRole` |
| Inline policy | `GetDataAccessOnStorage` |

### Data lake Lambda

| Type | Name |
|---|---|
| Lambda function | `DataLakePocObjects` |
| Execution role | `FeederDataLakeLambdaRole` |
