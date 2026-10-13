# Adding a foreign Iceberg table to Unity Catalog

You add a foreign Iceberg table **through its catalog**, not table by table. You connect the external
catalog to Unity Catalog with **catalog federation**, and its Iceberg tables then appear as
**foreign tables** that can only be read. You can't register a single Iceberg table by path (no
`CREATE TABLE … USING ICEBERG LOCATION …`).

The steps below are for **AWS Glue on Databricks on AWS**. The SQL options are approximate (⚠️),
because the exact syntax couldn't be confirmed. Catalog Explorer has the same steps in its UI, and
the connection type there is "Hive Metastore" with metastore type "AWS Glue".

> Based on Databricks documentation and third-party walkthroughs. Not tested.
> See also [`09-managed-vs-foreign-iceberg-glue.md`](09-managed-vs-foreign-iceberg-glue.md).

## Steps

| Step | What | How |
|---|---|---|
| 1 | **IAM role for Glue** (read `glue:GetDatabase*`, `glue:GetTable*`, `glue:GetPartitions`) → register it as a **service credential** in Unity Catalog | Catalog Explorer → External data → Credentials, or `CREATE SERVICE CREDENTIAL` |
| 2 | **IAM role for the S3 data** → **storage credential** and an **external location** covering the paths of the Iceberg tables | `CREATE EXTERNAL LOCATION glue_lake URL 's3://lake/warehouse/' WITH (STORAGE CREDENTIAL lake_cred);` |
| 3 | **Connection** to Glue | Catalog Explorer → Connections → Hive Metastore → AWS Glue, or `CREATE CONNECTION` ⚠️ |
| 4 | **Foreign catalog** using that connection, with **authorized paths**. Only tables under these paths can be queried | `CREATE FOREIGN CATALOG` ⚠️ |
| 5 | **Grant access** | ``GRANT USE CATALOG, USE SCHEMA, SELECT ON CATALOG glue_cat TO `analysts`;`` |
| 6 | **Query** with DBR 16.4+ or a SQL warehouse | `SELECT * FROM glue_cat.sales.orders;` |

```sql
-- ⚠️ option names to check against the current docs
CREATE CONNECTION glue_conn TYPE hive_metastore
  OPTIONS (metastore_type 'glue', aws_region 'eu-west-1', aws_account_id '123456789012',
           credential 'glue_service_cred');

CREATE FOREIGN CATALOG glue_cat USING CONNECTION glue_conn
  OPTIONS (authorized_paths 's3://lake/warehouse/');
```

**Privileges needed:**
- On the metastore: `CREATE SERVICE CREDENTIAL`, `CREATE CONNECTION`, `CREATE EXTERNAL LOCATION`, `CREATE CATALOG`.
- On the connection: ownership, or `CREATE FOREIGN CATALOG`.

## Which external catalogs work

| Catalog | Supported |
|---|---|
| AWS Glue | ✅ (⚠️ from **Azure** Databricks unconfirmed) |
| Hive Metastore (external, on any cloud) | ✅ |
| Snowflake Horizon | ✅ |
| Generic Iceberg REST catalogs (Polaris, Lakekeeper, Nessie…) | ❌ |
| An Iceberg folder with no catalog (path only) | ❌ |

## What you get, and the limits

- **Read-only** in Databricks and through Unity Catalog's Iceberg REST catalog. Writes still go through Glue.
- Unity Catalog permissions, lineage and audit apply to reads in Databricks.
- **Time travel** only to snapshots Databricks has already read.
- **Partition evolution** isn't supported on foreign tables.
- Writes made through Glue may need a **refresh** before Databricks sees them (`REFRESH FOREIGN TABLE` / `ALTER TABLE … REFRESH`, depending on the source ⚠️).
- Known issue: `NOT NULL` fields nested inside arrays or maps can make queries fail.
- To make the table **managed** (writable, governed by Unity Catalog), do a full copy:
  `CREATE TABLE uc.sales.orders DEEP CLONE glue_cat.sales.orders`.

## Sources

- [Databricks: What is catalog federation?](https://docs.databricks.com/aws/query-federation/catalog-federation)
- [Databricks: Enable Hive metastore federation for AWS Glue metastores](https://docs.databricks.com/aws/en/query-federation/hms-federation-glue)
- [Databricks: Enable Snowflake catalog federation](https://docs.databricks.com/aws/en/query-federation/snowflake-catalog-federation)
- [Databricks: What is query federation?](https://docs.databricks.com/aws/en/query-federation/database-federation)
- [Databricks blog: Announcing full Apache Iceberg support in Databricks](https://www.databricks.com/blog/announcing-full-apache-iceberg-support-databricks)
- [Medium: Unity Catalog federation with foreign Iceberg tables](https://medium.com/databricks-unity-catalog-sme/unlocking-catalog-interoperability-via-unity-catalog-federation-with-foreign-iceberg-tables-527a7ff0f9a7)
- [Medium: AWS Glue meets Unity Catalog](https://medium.com/@sidnahar13/aws-glue-meets-unity-catalog-effortless-data-governance-querying-in-databricks-5138f1e574a4)
- [AWS Lake Formation: Federate to Databricks Unity Catalog](https://docs.aws.amazon.com/lake-formation/latest/dg/catalog-federation-databricks.html)
