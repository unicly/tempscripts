# Leaving Databricks: taking over a managed Iceberg table with AWS Glue

Question: if I stop using Databricks, can I take over the managed Iceberg table with Glue and
continue to work on it?

> Not tested. Databricks doesn't document an "export to Glue" path. ⚠️ marks the risky points.

## Short answer

Yes, you can continue the table in Glue. It just can't become the *same* Unity Catalog table. Unity
Catalog owns the pointer and the storage location, so you move the table out: either as a **copy with
its full history**, or as a **fresh copy of the data**. Glue then becomes the only owner, and you
continue with EMR, Athena, Glue ETL, Trino and so on.

## Three ways out

| Option | How | History kept? | Effort | Recommended? |
|---|---|---|---|---|
| **A. Copy the data** through Unity Catalog's Iceberg REST catalog | OSS Spark (EMR) reads `uc.sales.orders` and `CREATE TABLE glue.sales.orders AS SELECT …` into your own bucket | ❌ New history | Low | ✅ Simplest and cleanest |
| **B. Copy the files with history** | Read the last `metadata.json` from Unity Catalog's managed storage, `rewrite_table_path` to a new location in your bucket, copy the files, `register_table` in Glue | ✅ All snapshots | Medium | ✅ If history or time travel matters |
| **C. Register the files in place** | `register_table` in Glue pointing at the `metadata.json` **inside Unity Catalog's managed storage** | ✅ | Low | ❌ **Don't** (see below) |

### Why not C (taking over the files in place)

- The files stay in Unity Catalog's **managed storage** (`…/__unitystorage/…`). Unity Catalog still considers them its own:
  - **predictive optimization** keeps expiring snapshots and deleting files that Glue's pointer may still need
  - if you **drop** the table in Unity Catalog, it **deletes the files after 8 days**, including the data Glue now relies on.
- Two catalogs would then point to the same files: the two-owners problem ([`16-…md`](16-managed-iceberg-on-aws-glue-storage.md)).
- So always move the files to a location **you** own (A or B).

## Steps for a clean takeover

| Step | What | Tool |
|---|---|---|
| 1 | **Check access:** is the catalog on your own S3 bucket, or on Databricks default storage? Default storage means no direct file access, so only option A works | `DESCRIBE CATALOG EXTENDED` in Databricks |
| 2 | **Prepare Glue:** Glue database, Lake Formation / IAM permissions, a target bucket (`s3://my-lake/warehouse/`) | AWS |
| 3 | **Initial copy:** **A** = OSS Spark on EMR with two catalogs (Unity Catalog REST + Glue): `spark.table("uc.sales.orders").writeTo("glue.sales.orders").create()`. **B** = load the last `metadata.json` (PyIceberg `StaticTable` or a temporary `register_table`), run `rewrite_table_path` to `s3://my-lake/...`, copy the file list (S3 copy or DataSync), then `register_table` in Glue | EMR, S3 / DataSync |
| 4 | **Catch-up while Databricks keeps running:** apply the changes since the initial copy. A = changelog or watermark `MERGE` ([`04-…md`](04-incremental-prod-to-dev-sync.md)). B = incremental `rewrite_table_path` ([`08-…md`](08-incremental-rewrite-table-path-explained.md)) | EMR |
| 5 | **Freeze:** stop all writes in Databricks (revoke `MODIFY`, stop jobs) | Databricks |
| 6 | **Final sync and checks:** last catch-up, then compare row counts, checksums and schemas | EMR / Athena |
| 7 | **Switch:** point all writers and readers to the Glue table | Your pipelines |
| 8 | **Glue now owns maintenance:** schedule `rewrite_data_files`, `expire_snapshots`, `remove_orphan_files` (Glue's automatic table optimization or your own jobs) | Glue / EMR |
| 9 | **Retire the Unity Catalog table** only after the switch is verified: `DROP TABLE` in Databricks. Its files are deleted after 8 days, so your copy must be complete | Databricks |

## What you take with you, and what you don't

| Kept | Lost |
|---|---|
| All data | Unity Catalog permissions, row filters, column masks, tags and comments. Recreate them in Lake Formation |
| Schema, partitioning / sort order | Lineage and audit history from Unity Catalog |
| Snapshot history (option B only) | Predictive optimization. You schedule maintenance yourself |
| Table format (Iceberg v2 / v3) | Databricks-specific table properties (ignored by other engines) |

## Points to check before you start

- ⚠️ **Iceberg v3 tables:** your engines (Athena, EMR, Glue ETL) must support v3 and deletion vectors. A Databricks community post reported deletion vectors written as `.bin` files instead of the spec's Puffin format. If that applies, option B may produce a table other engines can't read. Option A rewrites the data cleanly. On **v2** tables this doesn't come up.
- **Partitioning:** the copy keeps the managed table's layout (identity partitions or clustering). In Glue you can change to partition transforms afterwards, for example `ALTER TABLE … ADD PARTITION FIELD days(ts)`.
- **Size and cost:** a full copy of a large table costs compute (option A) or copy and request costs (option B). It all stays in the same region, so there's no egress.
- **Access to Unity Catalog's managed storage (option B):** you need an IAM role that can read it. Databricks discourages direct access, so use a temporary migration role.

## In short

Yes, you can continue in Glue, as a **new** Glue-owned table in your own bucket. Use option **A** for
simplicity, or **B** to keep the snapshot history. Run both systems in parallel with incremental
catch-up until the switch, and only then drop the table in Unity Catalog.

## Related

- [`16-managed-iceberg-on-aws-glue-storage.md`](16-managed-iceberg-on-aws-glue-storage.md): where the table is stored, why two catalogs can't own one table
- [`12-managed-iceberg-summary-aws-azure.md`](12-managed-iceberg-summary-aws-azure.md) §2.3: reading managed storage without Unity Catalog
- [`08-incremental-rewrite-table-path-explained.md`](08-incremental-rewrite-table-path-explained.md): how `rewrite_table_path` works

## Sources

- [Databricks: Access Databricks tables from Apache Iceberg clients](https://learn.microsoft.com/en-us/azure/databricks/external-access/iceberg)
- [Databricks: Unity Catalog managed tables (DROP deletes data after 8 days)](https://docs.databricks.com/en/tables/managed.html)
- [Databricks: Use Apache Iceberg v3 features](https://docs.databricks.com/aws/en/iceberg/iceberg-v3)
- [Databricks Community: Iceberg v3 deletion vector compatibility issue](https://community.databricks.com/t5/data-engineering/cross-engine-iceberg-v3-compatibility-issue-databricks-delete/td-p/164734)
- [Apache Iceberg: Spark procedures (`rewrite_table_path`, `register_table`, maintenance)](https://iceberg.apache.org/docs/latest/spark-procedures/)
- [Apache Iceberg: Maintenance](https://iceberg.apache.org/docs/latest/maintenance/)
- [BigData Boutique: Apache Iceberg on AWS (Glue, Athena, EMR, S3 Tables)](https://bigdataboutique.com/blog/apache-iceberg-on-aws)
