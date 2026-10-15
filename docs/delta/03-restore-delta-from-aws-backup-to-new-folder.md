# Restoring Delta tables from AWS Backup, to another folder, and the best restore approach

Questions:

1. Can a Delta table be restored from AWS Backup?
2. Can it be restored to **another folder**, and can the table's location be changed to that folder?
3. How does restore work best for Delta tables?

> From the Databricks docs and Delta's design. Not tested. ⚠️ marks points to verify.

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
| **Managed Delta** | ✅ Restore to a folder under an **external location** (not into managed storage) | ❌ A managed table's location can't be changed. Register the folder as an external table, then copy it back: `CREATE OR REPLACE TABLE sales.orders DEEP CLONE restore.orders_tmp` (incremental for Delta). Or keep it as an external table |

**Rules for the new folder:**

- It must be inside a Unity Catalog **external location**, with a storage credential that can read it.
- It must **not overlap** another table's folder or managed storage.
- Use the **same KMS key** (or one the storage credential can use) if the bucket is encrypted.

```sql
-- Managed table, restored by AWS Backup to s3://restore-bucket/orders/
CREATE TABLE restore.sales.orders_tmp USING DELTA LOCATION 's3://restore-bucket/orders/';
DESCRIBE HISTORY restore.sales.orders_tmp;          -- full history up to time T
SELECT COUNT(*) FROM restore.sales.orders_tmp;

-- Bring it back as the managed production table
CREATE OR REPLACE TABLE prod.sales.orders DEEP CLONE restore.sales.orders_tmp;
-- or only a chosen version:  … DEEP CLONE restore.sales.orders_tmp VERSION AS OF 120;
```

## 3. How restore works best for Delta

Use the lightest tool that covers the situation:

| Situation | Best restore | Same table kept? |
|---|---|---|
| Bad `UPDATE` / `DELETE` / `MERGE` within retention | **`RESTORE TABLE prod.sales.orders TO VERSION AS OF n`** | ✅ ID, permissions, history |
| Managed table dropped (≤ 7 days) | **`UNDROP TABLE`** | ✅ |
| External table dropped | Files are still there: `CREATE TABLE … LOCATION '<same path>'` | Definition recreated. Re-apply grants |
| Error found after retention | **Backup clone:** `CREATE OR REPLACE TABLE prod.sales.orders DEEP CLONE backup.sales.orders VERSION AS OF n` | New table |
| Files deleted or damaged, table still registered | **AWS Backup, in place** (original path, time just before the damage) | ✅ Delta reads the restored log |
| Bucket, account or region lost, ransomware | **AWS Backup to a new folder** → external table → `DEEP CLONE` back (or the backup clone in another account) | New table |

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
| **Catalog-managed commits** ⚠️ | If enabled (newer Unity Catalog feature), Unity Catalog coordinates commits and the folder alone may not be the full picture. Check before relying on folder restores |
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

- [Databricks: Work with table history (time travel, RESTORE, retention)](https://docs.databricks.com/aws/en/tables/history)
- [Databricks: Clone a table on Databricks](https://docs.databricks.com/aws/en/tables/operations/clone)
- [Databricks: Unity Catalog managed tables](https://docs.databricks.com/aws/tables/managed)
- [Databricks: CREATE TABLE CLONE](https://docs.databricks.com/aws/en/sql/language-manual/delta-clone)
- [AWS Backup: Amazon S3 backups](https://docs.aws.amazon.com/aws-backup/latest/devguide/s3-backups.html)
- [AWS Backup: Restoring a continuous backup](https://docs.aws.amazon.com/aws-backup/latest/devguide/point-in-time-recovery-restoring.html)
