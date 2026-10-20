# Creating a Delta table stored on Databricks' own infrastructure (default storage)

How to create a Delta table whose files are stored in **Databricks default storage** (Databricks'
cloud account) instead of your own S3 bucket. Do you need a new catalog, and how does it work?

> From the Databricks docs. Not tested. ⚠️ marks points to check.

> **Correction (October 2026):** an earlier version said a plain `CREATE CATALOG` without a location
> uses default storage. That's wrong when the **metastore has a storage root**: the catalog then
> inherits that root, which is **your** bucket. Default storage must be chosen **explicitly** when
> creating the catalog. Observed in practice: a catalog without its own path still put its tables in the
> customer's bucket.

## Short answer

Default storage is only available in **serverless** workspaces. You create a **catalog** and
**explicitly choose default storage** for it (the storage is chosen per catalog, not per table). Every managed table you then create in that
catalog is stored in Databricks' storage, without you setting up any S3 bucket.

## Prerequisites

| What | Why |
|---|---|
| A **serverless workspace** | Default storage is only available there ⚠️ (newer docs say serverless workspaces get it automatically) |
| `CREATE CATALOG` privilege on the metastore | To create the catalog |
| **Serverless compute** (serverless SQL warehouse, serverless notebooks or jobs) | Classic clusters can't read or write default storage |

## Where a managed table's storage comes from

A new managed table uses the **first** location it finds, in this order:

| Order | Level | Set with |
|---|---|---|
| 1 | **Schema** managed location | `CREATE SCHEMA … MANAGED LOCATION 's3://…'` |
| 2 | **Catalog** managed location / storage root | `CREATE CATALOG … MANAGED LOCATION 's3://…'`, or **"Default storage"** chosen when creating the catalog |
| 3 | **Metastore storage root** | Set by the account admin (common on older metastores) |

So a catalog created **without** a location and **without** choosing default storage falls back to
the **metastore storage root**. If that root is your bucket, its tables land in your bucket.

The table path gives a hint ⚠️ (naming isn't officially documented):

| Path pattern | Usually means |
|---|---|
| `s3://<bucket>/…/__unitystorage/schemas/<id>/tables/<uuid>` | Schema managed location |
| `s3://<bucket>/…/__unitystorage/catalogs/<id>/tables/<uuid>` | Catalog managed location |
| `s3://<bucket>/<prefix>/<metastore-id>/tables/<uuid>` | **Metastore storage root** |
| No `s3://` path from your account | Default storage |

## Steps

| Step | What | How |
|---|---|---|
| 1 | **Create a catalog on default storage** | Catalog Explorer → **+ → Create catalog** → choose the **"Default storage"** option explicitly. ⚠️ A plain `CREATE CATALOG` without a location **doesn't** do this if the metastore has a storage root. If the option isn't offered, the workspace isn't serverless or default storage isn't enabled |
| 2 | **Create a schema** in it | `CREATE SCHEMA sandbox.analytics;` (no `MANAGED LOCATION`) |
| 3 | **Create the table** without `LOCATION` (it's managed, so it lands in default storage) | SQL or Python below |
| 4 | **Use serverless compute** to load and query it | Serverless SQL warehouse, serverless notebook or job |
| 5 | **Grant access** | `GRANT USE CATALOG, USE SCHEMA, SELECT … TO …` |
| 6 | **Other workspaces** (optional) | By default only the creating workspace can use the catalog. Bind other workspaces to it in Catalog Explorer (catalog → Workspaces). They must also use serverless compute |
| 7 | **Check** | `DESCRIBE TABLE EXTENDED sandbox.analytics.events;` → the "Location" must **not** be an `s3://` path in your account. An empty storage root on the catalog alone isn't proof: the table may still inherit the metastore root |

```sql
-- in a serverless workspace, on a serverless SQL warehouse or notebook
-- Step 1 is done in Catalog Explorer ("Default storage" option). Then:
-- (a plain CREATE CATALOG sandbox; would inherit the metastore storage root if one exists)
CREATE SCHEMA  sandbox.analytics;                     -- no MANAGED LOCATION

CREATE TABLE sandbox.analytics.events (               -- no LOCATION → managed Delta table
  event_id BIGINT,
  user_id  STRING,
  ts       TIMESTAMP,
  payload  STRING
)
CLUSTER BY (ts);

INSERT INTO sandbox.analytics.events VALUES (1, 'u1', current_timestamp(), '{"a":1}');

GRANT USE CATALOG ON CATALOG sandbox TO `analysts`;
GRANT USE SCHEMA, SELECT ON SCHEMA sandbox.analytics TO `analysts`;
```

```python
# Same from a serverless notebook (PySpark)
df = spark.createDataFrame([(2, "u2", "2026-10-20 10:00:00", "{}")],
                           "event_id BIGINT, user_id STRING, ts STRING, payload STRING")
df.selectExpr("event_id", "user_id", "to_timestamp(ts) AS ts", "payload") \
  .write.mode("append").saveAsTable("sandbox.analytics.events")
```

## Diagnose where an existing table was stored

```sql
DESCRIBE TABLE   EXTENDED <catalog>.<schema>.<table>;   -- "Location" of the table
DESCRIBE SCHEMA  EXTENDED <catalog>.<schema>;           -- schema managed location, if set
DESCRIBE CATALOG EXTENDED <catalog>;                    -- catalog storage root, if set
```

Metastore root: account console → **Catalog → metastore → details** ("Storage root"), or
`databricks metastores summary` (field `storage_root`).

| Result | Location came from |
|---|---|
| Schema shows an `s3://` location | Schema |
| Only the catalog shows one | Catalog |
| Neither shows one, but the table path is in your bucket | **Metastore storage root** |

## Do I need a new catalog?

| Situation | Answer |
|---|---|
| Your existing catalogs use **your own bucket** (`MANAGED LOCATION`) | Yes, create a **new** catalog on default storage. An existing catalog's storage can't be switched to default storage ⚠️ |
| The catalog is already on default storage | No: just create schemas and tables in it |
| You want only some tables in default storage | Put those in a separate catalog on default storage. The rest stay in catalogs on your bucket |

## Good to know

| Point | Detail |
|---|---|
| **No direct file access** | You never see an S3 path in your account. No AWS Backup, S3 versioning or your own KMS keys |
| **Backups and restore** | Only through Databricks features: `RESTORE`, `UNDROP`, time travel, deep clone to another catalog, OpenSharing copies, managed disaster recovery |
| **Other engines** | Through Unity Catalog's open APIs (Iceberg REST for Iceberg tables or Delta with Iceberg reads, the Unity REST API for Delta), not by path |
| **Moving later** | To move tables to your own bucket: create a catalog with `MANAGED LOCATION` and `DEEP CLONE` the tables (new tables) |
| **Costs** | Storage is billed by Databricks instead of your cloud provider ⚠️ (check your contract) |

## In short

In a serverless workspace, create a catalog and **explicitly choose "Default storage"** in Catalog
Explorer (a catalog without a location inherits the metastore storage root, if there is one), then
create schemas and tables in it **without** `LOCATION`, and use serverless compute. Check with
`DESCRIBE TABLE EXTENDED` that the table location isn't in your bucket. If your
existing catalogs point to your own bucket, you need a **new** catalog for this.

## Related

- [`06-delta-table-types-and-storage.md`](06-delta-table-types-and-storage.md): the three storage variants compared
- [`../unity-catalog/02-where-managed-tables-are-stored.md`](../unity-catalog/02-where-managed-tables-are-stored.md): where managed tables are stored

## Sources

- [Databricks: Default storage in Databricks](https://docs.databricks.com/aws/en/storage/default-storage)
- [Databricks: Default storage in serverless workspaces](https://docs.databricks.com/aws/storage/express-storage)
- [Databricks: Unity Catalog managed tables](https://docs.databricks.com/aws/tables/managed)
- [Databricks: Limit catalog access to specific workspaces (workspace bindings)](https://docs.databricks.com/aws/en/catalogs/binding)
