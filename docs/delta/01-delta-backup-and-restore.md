# Backup and restore of Delta tables on Databricks

How backup and restore work for **Delta** tables on Databricks (managed and external), and how this
compares with managed Iceberg (see
[`../iceberg/12-managed-iceberg-summary-aws-azure.md`](../iceberg/12-managed-iceberg-summary-aws-azure.md)).

> Mostly long-standing Delta behaviour, described from Databricks documentation and experience.
> Not tested. ⚠️ marks points to verify.

In short, backup and restore are much easier with Delta than with managed Iceberg:

- Delta has a mature `RESTORE` command.
- Deep clones are incremental.
- File paths are relative, so copied files still work in a new location.

## How a Delta table is stored

```
s3://…/orders/
 ├── _delta_log/
 │    ├── 00000000000000000000.json   ← commit 0 (add/remove file actions)
 │    ├── …
 │    ├── 00000000000000000010.checkpoint.parquet
 │    └── 00000000000000000042.json   ← latest version
 ├── part-0001-….parquet               ← data files
 └── deletion_vector_….bin             ← deletion vectors (if enabled)
```

- Every write is a new **version** in `_delta_log`. Old data files stay until `VACUUM` removes them.
- File paths in the log are **relative to the table folder**, except for shallow clones. So a copied
  table folder works at a new location without rewriting anything. Iceberg needs
  `rewrite_table_path` for that.

## Layer 1: protection inside the table (mistakes, bad writes)

| Feature | What it does | Example | Limit |
|---|---|---|---|
| **Time travel** | Read an old version | `SELECT * FROM orders VERSION AS OF 40` / `TIMESTAMP AS OF '2026-10-12'` | Files must still exist (see retention below) |
| **`RESTORE`** | Roll the table back in place, as a new version | `RESTORE TABLE orders TO VERSION AS OF 40` | Same. The restore can itself be undone with another `RESTORE` |
| **`UNDROP`** (managed tables) | Recover a dropped managed table, with its history | `UNDROP TABLE orders` | Recovery window **7 days by default, configurable at catalog or schema level**. Afterwards the files are purged (S3 versioning can still keep them) |
| **History** | See who changed what | `DESCRIBE HISTORY orders` | `delta.logRetentionDuration` (default 30 days) |

**How far back you can go** depends on two table properties:

| Property | Default | Controls |
|---|---|---|
| `delta.logRetentionDuration` | 30 days | How long log entries (versions) are kept |
| `delta.deletedFileRetentionDuration` | 7 days | How long `VACUUM` keeps files no longer used by the current version. From DBR 18.0 it also blocks time travel beyond this |

On **managed** tables, predictive optimization runs `VACUUM` automatically, so the real window is
about **7 days** unless you raise it:

```sql
ALTER TABLE orders SET TBLPROPERTIES (
  'delta.deletedFileRetentionDuration' = '30 days',
  'delta.logRetentionDuration'         = '60 days');
```

Longer windows cost more storage.

## Layer 2: backup copies (beyond retention, other storage, other region or cloud)

| Method | How | Incremental? | Notes |
|---|---|---|---|
| **Deep clone** | `CREATE OR REPLACE TABLE backup.sales.orders DEEP CLONE prod.sales.orders` | ✅ Re-runs copy only changes since the last clone | Documented by Databricks for disaster recovery. The target gets its own history. Put it in a separate catalog and storage |
| **Deep clone of a specific version** | `… DEEP CLONE prod.sales.orders VERSION AS OF 40` | — | Back up a known-good state |
| **History of the backup itself** | The backup table's own versions give point-in-time backups | — | Keep its retention long. Or create dated clones (`orders_20261013`) |
| **Shallow clone** | `SHALLOW CLONE` | — | ❌ **Not a backup**: it points to the source's files, and `VACUUM` on the source breaks it |
| **Other cloud / other metastore** | OpenSharing (Databricks to Databricks) + incremental deep clone on the other side | ✅ | Only changed files cross clouds (the Mercedes-Benz setup). ⚠️ Incremental clone from a share is a community report |
| **Change data feed** | `delta.enableChangeDataFeed = true`, stream `readChangeFeed` → `MERGE` into the backup | ✅ Row level | Fine-grained. Also works through a share |

## Layer 3: storage-level backup (S3 / ADLS)

| Table type | Storage-level backup useful? | How to restore |
|---|---|---|
| **External Delta table** (your `LOCATION`) | ✅ Yes | Restore the folder (`_delta_log` + data) from S3 versioning, AWS Backup, Blob versioning or a copy. Then `CREATE TABLE … LOCATION 's3://…/orders'`, or the existing table simply works again |
| **Managed Delta table** | ⚠️ Emergency only | Unity Catalog won't register files back into managed storage. Copy the restored folder to a **new path**, `CREATE TABLE tmp USING DELTA LOCATION '…'` (external), then `CREATE TABLE prod.sales.orders DEEP CLONE tmp` to make it managed again. ⚠️ Not documented. Test it |

Because Delta paths are relative, a plain file copy (AzCopy, DataSync, `aws s3 sync`) of the whole
table folder is a valid backup of an **external** Delta table. Copy `_delta_log` last, or from a
moment when no writes happen.

## Restore by situation

| Situation | Restore with |
|---|---|
| Bad `UPDATE`/`DELETE`/`MERGE` within retention | `RESTORE TABLE … TO VERSION AS OF n` |
| Table dropped (managed, within the recovery window) | `UNDROP TABLE` |
| Table dropped (external) | Files are still there: `CREATE TABLE … LOCATION '…'` |
| Error found after retention | From the backup clone: `CREATE OR REPLACE TABLE prod DEEP CLONE backup.orders VERSION AS OF n` |
| Storage, region or cloud lost | Backup clone on the other cloud or region, shared back or cloned |
| Ransomware / deliberate deletion | Clone or file copy in an **immutable** location (S3 Object Lock, Azure immutable storage) |

After a restore by `RESTORE` or `UNDROP`, the table keeps its ID, permissions and history. After a
restore by clone it's a **new** table, so re-apply permissions, tags, row filters and column masks,
and reset any replication watermark or streaming checkpoint.

## Compared with managed Iceberg

| | Delta (managed) | Managed Iceberg |
|---|---|---|
| `RESTORE` in place | ✅ Mature, generally available | ✅ Same command, covered by the table history docs. ⚠️ Managed Iceberg is in preview |
| Incremental deep clone | ✅ | ❌ Full copy every time |
| Change data feed | ✅ | ❌ |
| File copy works at a new location | ✅ Relative paths | ❌ Absolute paths, and no registration |
| Storage-level restore | ✅ External tables / ⚠️ managed via external + clone | ⚠️ Only via standard Iceberg tools (doc 12 §2.3) |

## Region loss: Databricks managed disaster recovery

Databricks offers **managed disaster recovery**: continuous replication of Unity Catalog metadata,
managed table data and workspace assets to another region, with failover from the account console.
It's Databricks' recommended option for cross-region recovery on AWS and Azure. Writes from external
engines through open APIs may not be captured. It doesn't replace backups against bad writes or
deliberate deletion, which are replicated too.

## Recommended setup

- Raise the retention properties to the window you need for everyday mistakes. `RESTORE` and
  `UNDROP` cover that window.
- Add a daily **incremental deep clone** into a backup catalog on separate, immutable storage, and on
  the other cloud through OpenSharing.
- Turn on storage versioning as an extra safety net.

## Related

- [`03-restore-delta-from-aws-backup-to-new-folder.md`](03-restore-delta-from-aws-backup-to-new-folder.md): restoring from AWS Backup to a new folder (updated October 2026)
- [`02-backup-delta-with-aws-backup.md`](02-backup-delta-with-aws-backup.md): AWS Backup for Delta tables, and whether a restore is transparent for Databricks

## Sources

- [Databricks: UNDROP](https://docs.databricks.com/aws/en/sql/language-manual/sql-ref-syntax-ddl-undrop-table)
- [Databricks: Object storage lifecycle in Unity Catalog](https://docs.databricks.com/aws/en/data-governance/unity-catalog/object-storage-lifecycle)
- [Databricks: Managed disaster recovery](https://docs.databricks.com/aws/en/admin/managed-disaster-recovery)
- [Databricks: Disaster recovery](https://docs.databricks.com/aws/en/admin/disaster-recovery)

- [Databricks: Work with table history (time travel, RESTORE, retention)](https://docs.databricks.com/aws/en/tables/history)
- [Databricks: Clone a table on Databricks](https://docs.databricks.com/aws/en/tables/operations/clone)
- [Databricks: CREATE TABLE CLONE](https://docs.databricks.com/aws/en/sql/language-manual/delta-clone)
- [Databricks: Unity Catalog managed tables](https://docs.databricks.com/en/tables/managed.html)
- [Databricks: Use change data feed](https://docs.databricks.com/aws/en/tables/features/change-data-feed)
- [Databricks: Read data shared using Databricks-to-Databricks OpenSharing](https://docs.databricks.com/aws/en/opensharing/read-data-databricks)
- [Databricks Community: How deep clone works](https://community.databricks.com/t5/data-engineering/how-deep-clone-works/td-p/155236)
- [Databricks Community: Backup Unity Catalog and managed tables](https://community.databricks.com/t5/data-governance/backup-unity-catalog-and-managed-tables/m-p/18707)
- [Databricks blog: Mercedes-Benz cross-cloud data mesh with Delta Sharing and deep clone](https://databricks.com/blog/mercedes-benz-builds-cross-cloud-data-mesh-delta-sharing-and-intelligent-replication-cutting)
