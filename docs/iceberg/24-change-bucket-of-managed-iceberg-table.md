# Moving a managed Iceberg table to another S3 bucket: can Unity Catalog's location be changed?

Question: a managed Iceberg table on Databricks stores its data in an S3 bucket. If the bucket
changes, `rewrite_table_path` could fix the paths in the Iceberg files. But can the table's location
in Unity Catalog be updated to the new bucket?

> From the Databricks docs and how managed storage works. Not tested. ⚠️ marks points to verify.

## Short answer

No. Unity Catalog doesn't let you change the storage location of a **managed** table: there's no
`ALTER TABLE … SET LOCATION` for managed tables, and managed Iceberg has no `register_table`.
`rewrite_table_path` doesn't help either. Unity Catalog would still point to the old `metadata.json` in
the old bucket, and won't accept the rewritten files as the same table
([`21-…md`](21-why-swapping-the-s3-folder-fails.md)).

To move managed tables to a new bucket, change where **new** managed tables are created, then **copy
the tables through Unity Catalog** into that location.

## Where the location comes from

| Level | Who sets it | Can you change it? |
|---|---|---|
| **Table** | Unity Catalog assigns a folder (`…/__unitystorage/…/tables/<uuid>/`) when the table is created | ❌ Fixed for the table's lifetime |
| **Schema** managed location | `CREATE SCHEMA … MANAGED LOCATION 's3://…'` | ⚠️ Changing it, if allowed, only affects **new** tables |
| **Catalog** managed location | `CREATE CATALOG … MANAGED LOCATION 's3://…'` | ⚠️ Same: only new tables |
| **Metastore** storage root | Account admin | Same: only new tables |

So existing tables always stay in the bucket they were created in. Only **new** tables use a new
location.

## How to move a managed Iceberg table to a new bucket

| Step | What | Example |
|---|---|---|
| 1 | Register the new bucket in Unity Catalog: storage credential (IAM role) + external location | `CREATE EXTERNAL LOCATION new_lake URL 's3://new-bucket/uc/' WITH (STORAGE CREDENTIAL new_cred);` |
| 2 | Create a catalog or schema whose **managed location** is the new bucket | `CREATE SCHEMA main.sales_new MANAGED LOCATION 's3://new-bucket/uc/sales/';` |
| 3 | **Copy** each table into it | `CREATE TABLE main.sales_new.orders DEEP CLONE main.sales.orders;` (or `CREATE TABLE … USING ICEBERG AS SELECT …`) |
| 4 | Catch up on changes while production keeps running | Re-run the clone (a full copy for managed Iceberg), or use a watermark `MERGE` ([`06-…md`](06-managed-iceberg-replication-deep-dive.md)) |
| 5 | Freeze writes, do a final sync, and check row counts | — |
| 6 | Swap names so consumers keep using the same table name | `ALTER TABLE main.sales.orders RENAME TO main.sales.orders_old;` then move or rename the new one into place, or point consumers to the new schema |
| 7 | Re-apply grants, tags, row filters, column masks and comments. Reset streaming checkpoints and replication watermarks | Clones don't copy grants or history |
| 8 | Drop the old table once the switch is verified. Its files are deleted after 8 days | `DROP TABLE main.sales.orders_old;` |

**What you lose:** the table's **history** (time travel to versions before the move) and its table
ID. If you need the old history, keep the old table for a while, or export it to a standard Iceberg
backup first ([`19-…md`](19-backup-managed-iceberg-with-aws-backup.md)).

## Why not `rewrite_table_path` + changing the location?

| Approach | Why it doesn't work for managed tables |
|---|---|
| `rewrite_table_path` + copy files to the new bucket | The rewritten files form a valid **standard** Iceberg table, but Unity Catalog still points to the old `metadata.json` and there's no command to repoint it |
| `ALTER TABLE … SET LOCATION` | Only for **external** tables (Delta). Managed Iceberg tables have no external variant in Unity Catalog |
| Copying files into Unity Catalog's new managed folder | Unity Catalog assigns its own table folders. Copied files aren't recognized ([`21-…md`](21-why-swapping-the-s3-folder-fails.md)) |

`rewrite_table_path` is still useful if the goal is to move the table **out** of Unity Catalog, for
example into Glue ([`18-…md`](18-migrate-managed-iceberg-from-databricks-to-glue.md)), but not to
repoint a managed table.

## For comparison: Delta

| Table type | Change the bucket |
|---|---|
| **External Delta** | ✅ Copy the folder (paths are relative), then `ALTER TABLE … SET LOCATION 's3://new-bucket/…'` |
| **Managed Delta** | Same as managed Iceberg: new schema or catalog location + `DEEP CLONE`. But for Delta the clone is **incremental**, so the catch-up phase (step 4) is cheap |

## In short

- You can't change a managed table's location in Unity Catalog.
- Point a schema or catalog at the new bucket, then copy the tables there with `DEEP CLONE` or
  `CREATE TABLE … AS SELECT`. Swap the names, re-apply permissions, and drop the old tables.
- `rewrite_table_path` doesn't help for managed tables. It's only for standard Iceberg tables or for
  moving out of Unity Catalog.

## Related

- [`21-why-swapping-the-s3-folder-fails.md`](21-why-swapping-the-s3-folder-fails.md): why Unity Catalog doesn't accept swapped files
- [`23-paths-to-rewrite-when-restoring-to-another-folder.md`](23-paths-to-rewrite-when-restoring-to-another-folder.md): which files contain paths
- [`18-migrate-managed-iceberg-from-databricks-to-glue.md`](18-migrate-managed-iceberg-from-databricks-to-glue.md): moving out of Unity Catalog

## Sources

- [Databricks: Unity Catalog managed tables](https://docs.databricks.com/aws/tables/managed)
- [Databricks blog: Your data, your storage, your rules: storing Unity Catalog managed tables](https://www.databricks.com/blog/your-data-your-storage-your-rules-2026-guide-storing-unity-catalog-managed-tables)
- [Databricks: Clone a managed Iceberg table](https://learn.microsoft.com/en-us/azure/databricks/iceberg/clone)
- [Databricks: CREATE TABLE CLONE](https://docs.databricks.com/aws/en/sql/language-manual/delta-clone)
- [Databricks: What is Apache Iceberg in Databricks?](https://docs.databricks.com/aws/en/iceberg/)
