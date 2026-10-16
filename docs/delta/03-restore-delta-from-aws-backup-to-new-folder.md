# Restoring Delta tables from AWS Backup, to another folder, and the best restore approach

Questions:

1. Can a Delta table be restored from AWS Backup?
2. Can it be restored to **another folder**, and can the table's location be changed to that folder?
3. How does restore work best for Delta tables?

> From the Databricks docs and Delta's design. Not tested. ⚠️ marks points to verify.

> **Update (October 2026):** re-checked against current Databricks docs. Changes: catalog commits
> are now generally available (off by default); path-based writes into managed storage are
> unsupported, so in-place restores into managed storage are a last resort; `ALTER TABLE … SET MANAGED`
> converts a restored external table back to managed; the `UNDROP` window is configurable; and
> Databricks managed disaster recovery covers region loss.

## Short answer

Yes to both, and it's much easier than with Iceberg. Delta stores its transaction log (`_delta_log/`)
**inside the table folder** with **relative paths**, so a folder restored somewhere else is a complete,
valid Delta table without rewriting anything. Whether you can **point the existing table** at the new
folder depends on whether it's external or managed.

## 1. Can I restore a Delta table from AWS Backup?

✅ Yes. AWS Backup restores every object under the table's prefix as of time T, including
`_delta_log/*.json`, checkpoints, `_last_checkpoint`, Parquet files and deletion vectors. That's
everything Delta needs.

Restore the **whole table prefix** (data plus `_delta_log/`), never single log files.

## 2. Restore to another folder and change the table's location?

| Table type | Restore to a new folder | Point the table at it |
|---|---|---|
| **External Delta** | ✅ Restore to a folder under a Unity Catalog **external location** | ✅ `ALTER TABLE sales.orders SET LOCATION 's3://restore-bucket/orders/'` ⚠️ (check that your workspace allows it for Unity Catalog external tables). Or drop the table definition (files stay) and `CREATE TABLE sales.orders USING DELTA LOCATION 's3://restore-bucket/orders/'` |
| **Managed Delta** | ✅ Restore to a folder under an **external location** (not into managed storage) | ❌ A managed table's location can't be changed. Register the folder as an external table, then either **convert it**: `ALTER TABLE restore.orders_tmp SET MANAGED` ⚠️ (documented for external Delta tables; check history behaviour), or copy it back: `CREATE OR REPLACE TABLE sales.orders DEEP CLONE restore.orders_tmp` (incremental for Delta). Or keep it as an external table |

**Rules for the new folder:**

- It must be inside a Unity Catalog **external location**, with a storage credential that can read it.
- It must **not overlap** another table's folder or managed storage.
- Use the **same KMS key** (or one the storage credential can use) if the bucket is encrypted.

```sql
-- Managed table, restored by AWS Backup to s3://restore-bucket/orders/
CREATE TABLE restore.sales.orders_tmp USING DELTA LOCATION 's3://restore-bucket/orders/';
DESCRIBE HISTORY restore.sales.orders_tmp;          -- full history up to time T
SELECT COUNT(*) FROM restore.sales.orders_tmp;

-- Option A: convert the restored external table into a managed table (⚠️ check availability and history)
ALTER TABLE restore.sales.orders_tmp SET MANAGED;
ALTER TABLE restore.sales.orders_tmp RENAME TO prod.sales.orders;   -- if the name is free

-- Option B: copy into the managed production table
CREATE OR REPLACE TABLE prod.sales.orders DEEP CLONE restore.sales.orders_tmp;
-- or only a chosen version:  … DEEP CLONE restore.sales.orders_tmp VERSION AS OF 120;
```

## 3. How restore works best for Delta

Use the lightest tool that covers the situation:

| Situation | Best restore | Same table kept? |
|---|---|---|
| Bad `UPDATE` / `DELETE` / `MERGE` within retention | **`RESTORE TABLE prod.sales.orders TO VERSION AS OF n`** | ✅ ID, permissions, history |
| Managed table dropped, within the recovery window (default 7 days, configurable at catalog or schema level) | **`UNDROP TABLE`** | ✅ |
| External table dropped | Files are still there: `CREATE TABLE … LOCATION '<same path>'` | Definition recreated. Re-apply grants |
| Error found after retention | **Backup clone:** `CREATE OR REPLACE TABLE prod.sales.orders DEEP CLONE backup.sales.orders VERSION AS OF n` | New table |
| Files deleted or damaged, table still registered | **External table:** AWS Backup in place (original path). **Managed table:** preferably AWS Backup to a new folder → external table → `SET MANAGED` / `DEEP CLONE`. In place into managed storage only as a last resort (unsupported path-based write) | External: ✅. Managed rebuild: new table |
| Bucket, account or region lost, ransomware | **Databricks managed disaster recovery** (region loss, if enabled), or **AWS Backup to a new folder** → external table → `SET MANAGED` / `DEEP CLONE` (or the backup clone in another account) | New table (managed DR: same tables) |
| Table has **catalog commits** enabled | ⚠️ Don't rely on the S3 folder alone: use deep clone backups taken through Unity Catalog, or test a folder restore first | — |

### Recommended setup

1. **Retention:** raise `delta.deletedFileRetentionDuration` and `delta.logRetentionDuration` to the
   window you need. `RESTORE` and `UNDROP` then cover everyday mistakes without any backup.
2. **Main backup:** a daily **incremental `DEEP CLONE`** into a backup catalog on separate storage,
   ideally another account with S3 Object Lock. It's cheap because Delta clones copy only changes.
3. **Safety net:** **AWS Backup** (continuous 35 days + periodic) on the buckets, with the vault in
   another account and Vault Lock.

## Watch out for

| Point | Why |
|---|---|
| **Restore the complete `_delta_log/`** | A partial log, or a `_last_checkpoint` pointing to a checkpoint that wasn't restored, can make the table unreadable ⚠️ |
| **Missing newest commits after an in-place restore** | Delta silently shows the last commit present, an **older** version. Reset streams and downstream jobs that already saw newer versions |
| **`VACUUM` and restore time** | Data files removed by `VACUUM` before time T aren't in the backup either. Old versions referencing them can't be read |
| **Catalog commits** | Generally available, **off by default**. If enabled (`delta.feature.catalogManaged`), Unity Catalog coordinates commits and the folder alone may not be the full picture ⚠️. Check with `SHOW TBLPROPERTIES` before relying on folder restores |
| **Writing into managed storage** | Path-based access to managed tables is unsupported. Restore managed tables to a **new** location, not in place |
| **Shallow clones and absolute deletion-vector paths** | These use **absolute** paths and break when moved. Rare, but check with `DESCRIBE DETAIL` / table properties |
| **After any restore by clone** | New table: re-apply grants, tags, row filters, masks, and reset streaming checkpoints |

## In short

- **AWS Backup restore:** works for Delta, to the original path or to a new folder.
- **Changing location:** for an **external** table, point it at the new folder (`SET LOCATION`, or
  recreate it with `LOCATION`). For a **managed** table, register the folder as external and
  `DEEP CLONE` it back.
- **Best overall:** `RESTORE` / `UNDROP` for daily mistakes, incremental deep clones as the main
  backup, AWS Backup as the safety net.

## Related

- [`01-delta-backup-and-restore.md`](01-delta-backup-and-restore.md): Delta backup layers
- [`02-backup-delta-with-aws-backup.md`](02-backup-delta-with-aws-backup.md): AWS Backup for Delta, and whether a restore is transparent for Databricks
- [`../iceberg/25-run-rewrite-table-path-restore.md`](../iceberg/25-run-rewrite-table-path-restore.md): the Iceberg equivalent, which needs path rewriting
- [`../aws-backup/01-aws-backup-options-overview.md`](../aws-backup/01-aws-backup-options-overview.md): AWS Backup options

## Sources

- [Databricks: Convert external or foreign Delta Lake tables to Unity Catalog managed tables](https://docs.databricks.com/aws/en/tables/convert-to-managed)
- [Databricks: Catalog commits](https://learn.microsoft.com/en-us/azure/databricks/tables/features/catalog-commits)
- [Databricks: Access Databricks tables from Delta clients (path-based access to managed tables)](https://docs.databricks.com/aws/en/external-access/unity-rest)
- [Databricks: Managed disaster recovery](https://docs.databricks.com/aws/en/admin/managed-disaster-recovery)
- [Databricks: UNDROP](https://docs.databricks.com/aws/en/sql/language-manual/sql-ref-syntax-ddl-undrop-table)

- [Databricks: Work with table history (time travel, RESTORE, retention)](https://docs.databricks.com/aws/en/tables/history)
- [Databricks: Clone a table on Databricks](https://docs.databricks.com/aws/en/tables/operations/clone)
- [Databricks: Unity Catalog managed tables](https://docs.databricks.com/aws/tables/managed)
- [Databricks: CREATE TABLE CLONE](https://docs.databricks.com/aws/en/sql/language-manual/delta-clone)
- [AWS Backup: Amazon S3 backups](https://docs.aws.amazon.com/aws-backup/latest/devguide/s3-backups.html)
- [AWS Backup: Restoring a continuous backup](https://docs.aws.amazon.com/aws-backup/latest/devguide/point-in-time-recovery-restoring.html)
