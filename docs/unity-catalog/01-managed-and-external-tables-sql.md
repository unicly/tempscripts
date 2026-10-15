# Declaring managed and external tables with SQL (Unity Catalog)

How to create **managed** and **external** tables in Databricks SQL, for Delta and Iceberg.

> Standard Databricks SQL forms. Not tested in a specific workspace. ⚠️ marks points to check.

## Short answer

The difference is the **`LOCATION`** clause:

- **Managed:** no `LOCATION`. Unity Catalog decides where the files go, in the managed storage of the
  catalog, schema or metastore.
- **External:** `LOCATION 's3://…'` pointing to a path inside a Unity Catalog **external location**.

For **Iceberg**, Unity Catalog only has **managed** tables. Iceberg tables owned by another catalog
appear as **foreign** tables through federation.

## Managed tables

```sql
-- Delta (default format, USING DELTA is optional)
CREATE TABLE main.sales.orders (
  order_id   BIGINT,
  customer   STRING,
  amount     DECIMAL(18,2),
  order_ts   TIMESTAMP
)
CLUSTER BY (order_ts);                 -- liquid clustering (optional)

-- Iceberg (managed only)
CREATE TABLE main.sales.orders_ice (
  order_id   BIGINT,
  customer   STRING,
  amount     DECIMAL(18,2),
  order_ts   TIMESTAMP
)
USING ICEBERG
CLUSTER BY (order_ts);

-- From a query (CTAS)
CREATE TABLE main.sales.orders_2026 AS SELECT * FROM main.sales.orders WHERE year(order_ts) = 2026;
CREATE TABLE main.sales.orders_ice_copy USING ICEBERG AS SELECT * FROM main.sales.orders;
```

### Choosing where managed tables are stored

Set the location at catalog or schema level, never on the table:

```sql
CREATE CATALOG finance MANAGED LOCATION 's3://finance-bucket/uc/';
CREATE SCHEMA  finance.ledger MANAGED LOCATION 's3://finance-bucket/uc/ledger/';
-- every table created in finance.ledger without LOCATION is managed and stored there
```

## External tables (Delta)

**Prerequisites:** the path must be covered by an external location backed by a storage credential.

```sql
-- once, by an admin
CREATE STORAGE CREDENTIAL lake_cred …;          -- IAM role (usually created in Catalog Explorer)
CREATE EXTERNAL LOCATION lake
  URL 's3://my-lake/warehouse/'
  WITH (STORAGE CREDENTIAL lake_cred);
GRANT CREATE EXTERNAL TABLE ON EXTERNAL LOCATION lake TO `data_engineers`;
```

```sql
-- New external table at a path
CREATE TABLE main.sales.orders_ext (
  order_id BIGINT,
  customer STRING,
  amount   DECIMAL(18,2),
  order_ts TIMESTAMP
)
USING DELTA
LOCATION 's3://my-lake/warehouse/sales/orders/';

-- Register an EXISTING Delta folder (schema is read from _delta_log)
CREATE TABLE main.sales.orders_restored
USING DELTA
LOCATION 's3://restore-bucket/orders/';

-- External table from a query
CREATE TABLE main.sales.orders_ext_2026
LOCATION 's3://my-lake/warehouse/sales/orders_2026/'
AS SELECT * FROM main.sales.orders WHERE year(order_ts) = 2026;
```

## Iceberg tables from another catalog (foreign, read-only)

There's no `CREATE TABLE … USING ICEBERG LOCATION …` in Unity Catalog. Connect the catalog instead
(details in [`../iceberg/15-…md`](../iceberg/15-add-foreign-iceberg-table-to-unity-catalog.md)):

```sql
CREATE CONNECTION glue_conn TYPE hive_metastore OPTIONS (…);     -- ⚠️ options, see doc 15
CREATE FOREIGN CATALOG glue_cat USING CONNECTION glue_conn
  OPTIONS (authorized_paths 's3://my-lake/warehouse/');
SELECT * FROM glue_cat.sales.orders;                             -- foreign Iceberg table, read-only
```

## Check which type a table is

```sql
DESCRIBE TABLE EXTENDED main.sales.orders;   -- "Type": MANAGED / EXTERNAL / FOREIGN, "Provider": delta / iceberg, "Location"
DESCRIBE DETAIL main.sales.orders;           -- format, location, size (Delta)
```

## What differs in practice

| | Managed | External |
|---|---|---|
| `LOCATION` on the table | ❌ Not allowed | ✅ Required |
| Formats | Delta, Iceberg | Delta (and Parquet, CSV… as non-transactional tables) |
| `DROP TABLE` | Data deleted after **8 days** (`UNDROP` within 7) | **Only the definition** is removed. Files stay |
| Maintenance | Predictive optimization (automatic) | You run `OPTIMIZE` / `VACUUM` (or enable predictive optimization where supported) |
| Change location | ❌ Copy into a new table ([`../iceberg/24-…md`](../iceberg/24-change-bucket-of-managed-iceberg-table.md)) | ✅ `ALTER TABLE … SET LOCATION` ⚠️ |
| Recommended by Databricks | ✅ Default choice | When other tools must own the path, or for existing data |

## Converting

```sql
-- External Delta → managed (⚠️ check availability in your workspace)
ALTER TABLE main.sales.orders_ext SET MANAGED;

-- Any table → managed copy
CREATE TABLE main.sales.orders_managed DEEP CLONE main.sales.orders_ext;
```

## In short

Leave out `LOCATION` for a managed table (Delta or Iceberg), and add `LOCATION 's3://…'` under an
external location for an external Delta table. Iceberg tables from Glue or Hive Metastore come in as
foreign tables through a federated catalog.

## Related

- [`../delta/03-restore-delta-from-aws-backup-to-new-folder.md`](../delta/03-restore-delta-from-aws-backup-to-new-folder.md): registering a restored Delta folder as an external table
- [`../iceberg/15-add-foreign-iceberg-table-to-unity-catalog.md`](../iceberg/15-add-foreign-iceberg-table-to-unity-catalog.md): foreign Iceberg tables
- [`../iceberg/24-change-bucket-of-managed-iceberg-table.md`](../iceberg/24-change-bucket-of-managed-iceberg-table.md): moving managed tables to another bucket

## Sources

- [Databricks: Unity Catalog managed tables](https://docs.databricks.com/aws/tables/managed)
- [Databricks: Work with external tables](https://docs.databricks.com/aws/en/tables/external)
- [Databricks: CREATE TABLE \[USING\]](https://docs.databricks.com/aws/en/sql/language-manual/sql-ref-syntax-ddl-create-table-using)
- [Databricks: CREATE EXTERNAL LOCATION](https://docs.databricks.com/aws/en/sql/language-manual/sql-ref-syntax-ddl-create-location)
- [Databricks: What is Apache Iceberg in Databricks?](https://docs.databricks.com/aws/en/iceberg/)
- [Databricks: Work with foreign tables](https://learn.microsoft.com/en-us/azure/databricks/tables/foreign)
