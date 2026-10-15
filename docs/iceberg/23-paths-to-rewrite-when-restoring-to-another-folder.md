# Restoring an Iceberg table to another folder: which metadata files contain paths

Question: when restoring an Iceberg table to another folder, which metadata files have to be modified
to change all references to the folders and paths?

> Based on the Apache Iceberg spec. Not tested. ⚠️ marks fields to check for your Iceberg version.

## Short answer

These files contain **absolute paths** that must point to the new location:

- every `metadata.json`
- every manifest list (`snap-*.avro`)
- every manifest (`*.avro`)
- **position delete files**, whose contents are paths
- possibly the deletion vector references in v3 tables.

Data Parquet files contain no paths.

Most of these files are **binary Avro**, so you can't edit them with search-and-replace. Rewriting a
file also changes its size, which the file referencing it records. **Don't edit them by hand.** Use
Iceberg's `rewrite_table_path`, which rewrites all of them consistently
([`08-…md`](08-incremental-rewrite-table-path-explained.md)).

## Which files contain paths, and which fields

```
metadata/00042-….metadata.json      (JSON)
  ├─ location                         ← table root
  ├─ snapshots[].manifest-list        ← path to snap-*.avro
  ├─ metadata-log[].metadata-file     ← paths to older metadata.json files
  ├─ statistics[].statistics-path     ← Puffin stats files
  ├─ partition-statistics[].statistics-path
  └─ properties: write.data.path, write.metadata.path, write.object-storage.path (if set)
        │
        ▼
metadata/snap-….avro                 (manifest list, Avro)
  └─ manifest_path (+ manifest_length = size of that manifest)
        │
        ▼
metadata/….avro                      (manifests, Avro)
  ├─ data_file.file_path              ← data files and delete files
  ├─ data_file.file_size_in_bytes     ← changes if a delete file is rewritten
  └─ data_file.referenced_data_file   ← v3 deletion vectors / position deletes ⚠️
        │
        ├─▶ data/….parquet            no paths inside ✅
        ├─▶ position delete files (v2, Parquet/Avro): column file_path = absolute data file paths ❗ contents must be rewritten
        └─▶ deletion vectors (v3, Puffin): blob property referenced-data-file ⚠️
```

| File | Format | Fields with paths | Must change? |
|---|---|---|---|
| `*.metadata.json` (all versions you want to keep) | JSON | `location`, `snapshots[].manifest-list`, `metadata-log[].metadata-file`, `statistics[].statistics-path`, `partition-statistics[].statistics-path`, `properties.write.*.path` | ✅ |
| `snap-*.avro` manifest lists | Avro (binary) | `manifest_path` | ✅, plus `manifest_length` must match the rewritten manifest's new size |
| `*.avro` manifests | Avro (binary) | `file_path`, `referenced_data_file` | ✅, plus `file_size_in_bytes` for rewritten delete files |
| Position delete files (v2) | Parquet / Avro | Column `file_path` (the data file each deleted row belongs to) | ✅ **contents** must be rewritten |
| Deletion vectors (v3, Puffin) | Puffin | Blob property `referenced-data-file` ⚠️ | ⚠️ Check whether your tool handles v3 |
| Statistics files (Puffin) | Puffin | Usually none | ❌ |
| Data files (`*.parquet`) | Parquet | None | ❌ (copy as is) |
| `version-hint.text` (Hadoop catalog only) | Text | A version number, not a path | ❌ |

**Why you can't do this by hand:** every file records the size of the files it points to. A manifest
list stores each manifest's length, and a manifest stores each delete file's size. If you rewrite one
file, its size changes, so the file that points to it has to be rewritten too. The Avro files also
have to stay valid Avro, with the right schema and metadata. `rewrite_table_path` handles that whole
chain.

## How to do it properly

```sql
-- OSS Spark with the Iceberg runtime. The source table must be loadable:
-- register the restored metadata.json in a temporary catalog first (Glue / Hadoop), or point at it directly.
CALL glue.system.register_table('tmp.orders_src',
     's3://restore-bucket/old-path/metadata/00042-….metadata.json');

CALL glue.system.rewrite_table_path(
  table            => 'tmp.orders_src',
  source_prefix    => 's3://uc-bucket/__unitystorage/…/tables/7f3a…',   -- prefix inside the old metadata
  target_prefix    => 's3://my-lake/restored/orders',                    -- new folder
  staging_location => 's3://my-lake/_staging/orders/');
-- returns: latest_version (rewritten metadata.json) + file_list_location (CSV: source → target)
```

| Step | What |
|---|---|
| 1 | **Find the source prefix:** open the restored `metadata.json` and read its `location`. That's the prefix written in every path, usually the **old** location, not the folder you restored to |
| 2 | **Load the table** from the restored `metadata.json` (temporary `register_table`). The old paths must be readable from there, so `source_prefix` must match the paths *inside* the files. If the files now sit in a different folder than their paths say, first copy them back under the old prefix, or point a catalog with a path mapping at them ⚠️ |
| 3 | **`rewrite_table_path`** with `source_prefix` = old location and `target_prefix` = new folder. It writes rewritten `metadata.json` files, manifest lists, manifests and position delete files to the staging folder |
| 4 | **Copy** using the file list: data files from the old location, rewritten metadata and delete files from staging, all to the new folder. Copy data first and `metadata.json` last |
| 5 | **Register** the rewritten `metadata.json` in the target catalog: `CALL glue.system.register_table('db.orders', 's3://my-lake/restored/orders/metadata/00042-….metadata.json')` |
| 6 | **Check:** row counts, `SELECT * FROM glue.db.orders.snapshots`, and a query on old snapshots (time travel) |

**Version note:** `rewrite_table_path` exists as a Spark procedure in recent Iceberg versions (1.7+ as
an action). ⚠️ Check that your version rewrites position delete files and v3 deletion vectors. If v3
isn't supported, the fallback is to read the restored table (PyIceberg `StaticTable`, or Spark via the
temporary registration) and write it as a **new** table with `CREATE TABLE … AS SELECT`. That loses
the snapshot history but needs no path rewriting.

## For managed Iceberg specifically

Even with all paths rewritten, Unity Catalog **won't accept** the folder as a managed table
([`21-…md`](21-why-swapping-the-s3-folder-fails.md)). The rewritten folder becomes a **standard
Iceberg table** in Glue. To get it back into Databricks, either federate Glue (read-only,
[`15-…md`](15-add-foreign-iceberg-table-to-unity-catalog.md)) or `DEEP CLONE` it into a new managed
table ([`19-…md`](19-backup-managed-iceberg-with-aws-backup.md), scenario B).

**Shortcut without rewriting:** if the old location still exists and is readable, register the old
`metadata.json` as it is and copy the data out with `CREATE TABLE new AS SELECT`. No path changes are
needed, because reads go to the old paths.

## For comparison: Delta

Nothing to modify. Paths in `_delta_log/` are **relative to the table folder**, so a Delta folder
restored elsewhere works directly with `CREATE TABLE … LOCATION '<new folder>'`. Exceptions with
absolute paths: **shallow clones**, and deletion vectors stored with an absolute path ⚠️ (rare).

## Related

- [`08-incremental-rewrite-table-path-explained.md`](08-incremental-rewrite-table-path-explained.md): how `rewrite_table_path` works, with a worked example
- [`21-why-swapping-the-s3-folder-fails.md`](21-why-swapping-the-s3-folder-fails.md): which fields identify a table
- [`../delta/02-backup-delta-with-aws-backup.md`](../delta/02-backup-delta-with-aws-backup.md): restoring Delta tables to a new location

## Sources

- [Apache Iceberg: Table spec (metadata.json, manifest lists, manifests, delete files, deletion vectors)](https://iceberg.apache.org/spec/)
- [Apache Iceberg: Puffin spec (deletion vectors, statistics)](https://iceberg.apache.org/puffin-spec/)
- [Apache Iceberg: Spark procedures (`rewrite_table_path`, `register_table`)](https://iceberg.apache.org/docs/latest/spark-procedures/)
- [Apache Iceberg Javadoc: RewriteTablePath](https://iceberg.apache.org/javadoc/1.11.0/org/apache/iceberg/actions/RewriteTablePath.html)
- [Dremio: Disaster recovery for Iceberg tables (rewrite_table_path walkthrough)](https://www.dremio.com/blog/disaster-recovery-for-apache-iceberg-tables-restoring-from-backup-and-getting-back-online/)
