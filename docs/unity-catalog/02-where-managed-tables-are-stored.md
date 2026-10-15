# Where are managed tables stored?

Question: if a table is **managed** (not external), where is its content stored?

> From the Databricks docs. ⚠️ The folder naming below isn't a documented contract.

## Short answer

A managed table's files are stored in the **managed storage location** that Unity Catalog chooses.
That's an S3 bucket you registered with Unity Catalog, or, on newer accounts, Databricks' own
**default storage**. Unity Catalog creates a folder per table there. You don't choose the table's
folder; you choose the bucket at the **schema, catalog or metastore** level.

## Which location is used (first match wins)

| Order | Level | Set with | Example |
|---|---|---|---|
| 1 | **Schema** managed location | `CREATE SCHEMA … MANAGED LOCATION 's3://…'` | `s3://finance-bucket/uc/ledger/` |
| 2 | **Catalog** managed location | `CREATE CATALOG … MANAGED LOCATION 's3://…'` | `s3://finance-bucket/uc/` |
| 3 | **Metastore** storage root | Set by the account admin (optional on newer metastores) | `s3://uc-root-bucket/metastore/` |
| 4 | **Databricks default storage** | Used when none of the above is set (newer accounts, serverless) | Storage in **Databricks' account**, not yours |

## What the folder looks like

```
s3://finance-bucket/uc/__unitystorage/schemas/<schema-id>/tables/<table-uuid>/      ⚠️ naming may differ
   Delta:    _delta_log/  part-….parquet  (deletion vectors)
   Iceberg:  metadata/ (metadata.json, manifests)  data/ (Parquet)
```

- The folder name is a **generated UUID**, not the table name. Renaming the table doesn't move the folder.
- Each table has its own folder. Unity Catalog doesn't let tables share or overlap folders.

## How to find it

```sql
DESCRIBE TABLE EXTENDED main.sales.orders;    -- "Location": s3://…/__unitystorage/…/tables/<uuid>
DESCRIBE DETAIL main.sales.orders;            -- location, number of files, size (Delta)
DESCRIBE SCHEMA EXTENDED main.sales;          -- the schema's managed location, if set
DESCRIBE CATALOG EXTENDED main;               -- the catalog's storage root
```

## Who owns the storage, and who can access it

| | Your own bucket (levels 1–3) | Databricks default storage (level 4) |
|---|---|---|
| AWS account | **Yours**, through a storage credential (IAM role) | **Databricks'** |
| Direct S3 access | Possible for admins (break-glass), but Databricks discourages it because it bypasses Unity Catalog | ❌ None |
| AWS Backup, S3 versioning, Object Lock | ✅ You can configure them | ❌ Not possible |
| Encryption keys | Your KMS keys | Databricks-managed (customer-managed keys depending on plan ⚠️) |
| Other engines | Read and write through Unity Catalog, with temporary credentials it issues | Same |

## Compared with external tables

| | Managed | External |
|---|---|---|
| Who chooses the folder | Unity Catalog (inside the managed location) | You (`LOCATION 's3://…'`) |
| Folder name | Generated UUID | Your path |
| After `DROP TABLE` | Files deleted after **8 days** | Files stay |

## In short

A managed table lives in a Unity Catalog-generated folder under the managed location of its
**schema, catalog or metastore**, in that order. If none is set, it's in Databricks **default
storage**. Use `DESCRIBE TABLE EXTENDED` to see the exact path. For backups with AWS Backup, make sure
your catalogs or schemas point to **your own bucket**
([`../iceberg/19-…md`](../iceberg/19-backup-managed-iceberg-with-aws-backup.md)).

## Related

- [`01-managed-and-external-tables-sql.md`](01-managed-and-external-tables-sql.md): declaring managed and external tables
- [`../iceberg/16-managed-iceberg-on-aws-glue-storage.md`](../iceberg/16-managed-iceberg-on-aws-glue-storage.md): what lives in S3 vs. in Unity Catalog
- [`../iceberg/24-change-bucket-of-managed-iceberg-table.md`](../iceberg/24-change-bucket-of-managed-iceberg-table.md): moving managed tables to another bucket

## Sources

- [Databricks: Unity Catalog managed tables](https://docs.databricks.com/aws/tables/managed)
- [Databricks: Specify a managed storage location in Unity Catalog](https://docs.databricks.com/aws/en/connect/unity-catalog/cloud-storage/managed-storage)
- [Databricks blog: Your data, your storage, your rules: storing Unity Catalog managed tables](https://www.databricks.com/blog/your-data-your-storage-your-rules-2026-guide-storing-unity-catalog-managed-tables)
- [Databricks: DESCRIBE TABLE](https://docs.databricks.com/aws/en/sql/language-manual/sql-ref-syntax-aux-describe-table)
