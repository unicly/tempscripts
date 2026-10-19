# Delta table types on Databricks: external, managed in your bucket, managed in Databricks storage

Short overview of the three ways a Delta table can be stored with Unity Catalog, how each is created
and configured, and what that means in practice.

> From the Databricks docs. Not tested. ⚠️ marks points to check for your account.

## The three variants

| | **External table** | **Managed table, your bucket** | **Managed table, Databricks default storage** |
|---|---|---|---|
| Where the files are | Your S3 path, chosen **per table** (`LOCATION`) | Your S3 bucket, chosen **per catalog or schema** (`MANAGED LOCATION`). Unity Catalog picks the table folder | **Databricks' own storage**, in Databricks' cloud account |
| Who manages files and lifecycle | You | Unity Catalog | Unity Catalog |
| `DROP TABLE` | Only the definition. Files stay | Files deleted after 8 days (`UNDROP` within the window) | Same as managed in your bucket |
| Maintenance (`OPTIMIZE`, `VACUUM`) | You (or predictive optimization where enabled) | Automatic (predictive optimization) | Automatic |
| Compute | Classic and serverless | Classic and serverless | **Serverless only** |
| Direct S3 access, AWS Backup, versioning, your KMS keys | ✅ | ✅ (break-glass only, discouraged) | ❌ |
| Other engines (Spark, Trino, Snowflake…) | By path or through Unity Catalog | Through Unity Catalog only | Through Unity Catalog only |
| Recommended by Databricks | For data other tools must own | ✅ Default choice | Quick start without cloud setup |

## Prerequisites (once, by an admin)

| Variant | Setup |
|---|---|
| External | **Storage credential** (IAM role) + **external location** covering the path, with `CREATE EXTERNAL TABLE` granted |
| Managed, your bucket | Storage credential + external location for the bucket, then a catalog or schema with **`MANAGED LOCATION`** (or a metastore storage root) |
| Managed, default storage | Nothing: create the catalog on default storage in a **serverless workspace** |

```sql
-- once, for your own bucket (used by external tables and by managed locations)
CREATE STORAGE CREDENTIAL lake_cred …;                       -- IAM role, usually created in Catalog Explorer
CREATE EXTERNAL LOCATION lake URL 's3://my-lake/' WITH (STORAGE CREDENTIAL lake_cred);
```

## How each is created

### 1. External table

```sql
GRANT CREATE EXTERNAL TABLE ON EXTERNAL LOCATION lake TO `data_engineers`;

CREATE TABLE main.sales.orders_ext (
  order_id BIGINT, customer STRING, amount DECIMAL(18,2), order_ts TIMESTAMP
)
USING DELTA
LOCATION 's3://my-lake/warehouse/sales/orders/';

-- register an existing Delta folder (schema read from _delta_log)
CREATE TABLE main.sales.orders_old USING DELTA LOCATION 's3://my-lake/archive/orders/';
```

### 2. Managed table in your bucket

```sql
-- storage chosen at catalog or schema level
CREATE CATALOG finance MANAGED LOCATION 's3://my-lake/uc/finance/';
CREATE SCHEMA  finance.ledger;                                -- inherits the catalog location
-- or: CREATE SCHEMA finance.ledger MANAGED LOCATION 's3://my-lake/uc/ledger/';

CREATE TABLE finance.ledger.entries (                        -- no LOCATION = managed
  entry_id BIGINT, account STRING, amount DECIMAL(18,2), booked_at TIMESTAMP
)
CLUSTER BY (booked_at);
```

### 3. Managed table in Databricks default storage

```sql
-- in a serverless workspace: a catalog without location uses default storage
-- (or tick "Use default storage" when creating the catalog in Catalog Explorer)
CREATE CATALOG sandbox;
CREATE SCHEMA  sandbox.analytics;
CREATE TABLE   sandbox.analytics.events (id BIGINT, ts TIMESTAMP, payload STRING);
```

⚠️ Default storage is only available in serverless workspaces. Its catalogs are accessible by default
only from the workspace that created them, and only with serverless compute.

## Useful table settings (all variants)

| Setting | Purpose | Example |
|---|---|---|
| `CLUSTER BY` | Liquid clustering for query performance | `CLUSTER BY (order_ts)` |
| `delta.enableChangeDataFeed` | Row-level change feed (replication, CDC) | `TBLPROPERTIES ('delta.enableChangeDataFeed' = 'true')` |
| `delta.deletedFileRetentionDuration` / `delta.logRetentionDuration` | How far back time travel and `RESTORE` go | `'30 days'` / `'60 days'` |
| `delta.enableIcebergCompatV2` + `delta.universalFormat.enabledFormats` | Iceberg reads (UniForm) for other engines | `'iceberg'` |
| `delta.feature.catalogManaged` | Catalog commits (managed tables only, off by default) | ⚠️ affects folder-level restores |

## Check which variant a table is

```sql
DESCRIBE TABLE EXTENDED main.sales.orders;   -- Type: MANAGED / EXTERNAL, Location
DESCRIBE CATALOG EXTENDED main;              -- storage root: s3://… (your bucket) or default storage
DESCRIBE SCHEMA EXTENDED main.sales;         -- schema managed location, if set
```

## Converting between them

| From → to | How |
|---|---|
| External → managed | `ALTER TABLE … SET MANAGED` ⚠️, or `CREATE TABLE … DEEP CLONE` |
| Managed → external | `CREATE TABLE … LOCATION 's3://…' AS SELECT …` or `DEEP CLONE … LOCATION` (new table) |
| Default storage → your bucket | New catalog/schema with `MANAGED LOCATION`, then `DEEP CLONE` (new table) |

## Which to choose

| Need | Variant |
|---|---|
| Standard Databricks tables, automatic maintenance, backups under your control | **Managed, your bucket** |
| Other tools must write the path, or existing Delta data must stay where it is | **External** |
| Quick start or sandbox, no cloud setup, serverless only | **Managed, default storage** |

## Related

- [`../unity-catalog/01-managed-and-external-tables-sql.md`](../unity-catalog/01-managed-and-external-tables-sql.md): SQL for managed and external tables
- [`../unity-catalog/02-where-managed-tables-are-stored.md`](../unity-catalog/02-where-managed-tables-are-stored.md): where managed tables are stored
- [`04-restore-external-delta-table-after-accidental-delete.md`](04-restore-external-delta-table-after-accidental-delete.md) / [`05-restore-managed-delta-table-after-accidental-delete.md`](05-restore-managed-delta-table-after-accidental-delete.md): restore per variant

## Sources

- [Databricks: Unity Catalog managed tables](https://docs.databricks.com/aws/tables/managed)
- [Databricks: Work with external tables](https://docs.databricks.com/aws/en/tables/external)
- [Databricks: Default storage in Databricks](https://docs.databricks.com/aws/en/storage/default-storage)
- [Databricks: Specify a managed storage location in Unity Catalog](https://docs.databricks.com/aws/en/connect/unity-catalog/cloud-storage/managed-storage)
- [Databricks: Convert external or foreign Delta Lake tables to managed tables](https://docs.databricks.com/aws/en/tables/convert-to-managed)
- [Databricks: Read Delta tables with Iceberg clients (UniForm)](https://docs.databricks.com/aws/en/delta/uniform)
