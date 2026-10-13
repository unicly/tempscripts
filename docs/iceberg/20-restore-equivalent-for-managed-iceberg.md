# The equivalent of Delta's RESTORE on managed Iceberg tables

Question: what's the equivalent of Delta's `RESTORE` function on a Databricks managed Iceberg table?

> Not tested. ⚠️ marks what to verify on a test table.

## Short answer

On Databricks, the equivalent is the **same command**, `RESTORE TABLE … TO VERSION AS OF` (or
`TO TIMESTAMP AS OF`). Databricks' "Work with table history" page covers both Delta Lake and Apache
Iceberg tables, including restoring a table to a past state. Managed Iceberg itself is still in
preview, so test it once. In open-source Iceberg the equivalent is the **rollback procedures**, which
Databricks clusters can't run, but engines connected through Unity Catalog's Iceberg REST catalog may
be able to.

> **Correction:** an earlier version of this doc said `RESTORE` was documented for managed Iceberg
> only for the v3 → v2 downgrade. The table history page covers Delta and Iceberg tables in general.

## Options

| Option | Where it runs | How | Rewrites data? | Status |
|---|---|---|---|---|
| **1. `RESTORE TABLE`** | Databricks | `RESTORE TABLE prod.sales.orders TO VERSION AS OF 42` or `TO TIMESTAMP AS OF '2026-10-12 08:00'` | No (metadata-only, as in Delta) ⚠️ | ✅ Covered for Delta and Iceberg tables by the table history page. Restoring to before a v3 upgrade needs `spark.databricks.delta.restore.protocolDowngradeAllowed = true` during the restore. ⚠️ Managed Iceberg is in preview: test it once |
| **2. Iceberg rollback procedures** | External Spark through Unity Catalog's REST catalog | `CALL uc.system.rollback_to_snapshot('sales.orders', 5123)`, `rollback_to_timestamp(...)`, `set_current_snapshot(...)` | No (only moves the current snapshot) | ⚠️ Standard Iceberg. Whether Unity Catalog accepts this kind of commit is unconfirmed |
| **2b. Same in Trino** | Trino through Unity Catalog's REST catalog | `ALTER TABLE uc.sales.orders EXECUTE rollback_to_snapshot(5123)` (syntax depends on the Trino version) | No | ⚠️ Same as 2 |
| **3. Rewrite from time travel** | Databricks | `INSERT OVERWRITE prod.sales.orders SELECT * FROM prod.sales.orders VERSION AS OF 42` | ✅ Yes, writes a new version with the old data | ✅ Uses only documented features. Fallback if 1 doesn't work |
| **3b. Targeted repair** | Databricks | `MERGE INTO prod.sales.orders t USING (SELECT * FROM prod.sales.orders VERSION AS OF 42) s ON …` to undo only certain rows | Only the changed rows | ✅ When only part of the table was damaged |
| **4. From a backup** | Databricks | `CREATE OR REPLACE TABLE prod.sales.orders DEEP CLONE backup.sales.orders_20261012` | ✅ Full copy | ✅ After retention has expired. Creates a new table ([`12-…md`](12-managed-iceberg-summary-aws-azure.md), §2) |

## How Delta `RESTORE` and Iceberg rollback differ

| | Delta `RESTORE` | Iceberg `rollback_to_snapshot` / `set_current_snapshot` |
|---|---|---|
| What happens | Adds a **new version** whose file list equals the old version | Moves the table's **current-snapshot pointer** back to an old snapshot |
| Data rewritten? | No, if the old files still exist | No |
| History after the operation | Linear: v40 … v45, v46 = "restore to v42" | The snapshots after the rollback point stay in the metadata (until expired), but aren't current any more |
| Can it be undone? | ✅ `RESTORE` to v45 | ✅ `set_current_snapshot` back to the newer snapshot, as long as it hasn't been expired |
| Limit | Files removed by `VACUUM` (`deletedFileRetentionDuration`) | Snapshots expired by `expire_snapshots`, which predictive optimization runs automatically on managed tables |

## What limits how far back you can go on managed Iceberg

- **Predictive optimization expires old snapshots and deletes their files automatically.** The window
  is roughly the table's retention setting. From DBR 18.0, time travel beyond
  `deletedFileRetentionDuration` (default 7 days) is blocked ⚠️.
- Beyond that window, none of options 1–3 can reach the old state. Only a **backup** can: a dated deep
  clone, a standard Iceberg vault, or AWS Backup with the route in
  [`19-…md`](19-backup-managed-iceberg-with-aws-backup.md).

## Recommended order

1. **Use option 1 (`RESTORE TABLE`)**, as in Delta. Because managed Iceberg is in preview, do one
   test run first:
   - create a managed Iceberg table
   - write three versions
   - `RESTORE TABLE … TO VERSION AS OF 1`
   - check `DESCRIBE HISTORY` and the data.
2. If something doesn't behave as expected, fall back to **option 3 (`INSERT OVERWRITE … VERSION AS OF`)**:
   it costs a full rewrite, but avoids `RESTORE` entirely.
3. If external engines are part of your setup, test **option 2** too. It's the true Iceberg rollback
   and doesn't rewrite data.
4. Keep the retention window long enough for the mistakes you need to undo, and have a backup for
   anything older.

## Related

- [`17-why-databricks-uses-versions-and-missing-functions.md`](17-why-databricks-uses-versions-and-missing-functions.md): why Databricks shows versions and lacks some Iceberg procedures
- [`19-backup-managed-iceberg-with-aws-backup.md`](19-backup-managed-iceberg-with-aws-backup.md): backups beyond the retention window
- [`../delta/01-delta-backup-and-restore.md`](../delta/01-delta-backup-and-restore.md): `RESTORE` on Delta tables

## Sources

- [Databricks: Work with table history (Delta Lake and Iceberg: time travel, RESTORE, retention)](https://docs.databricks.com/aws/en/tables/history)
- [Databricks: RESTORE (SQL reference)](https://docs.databricks.com/aws/en/sql/language-manual/delta-restore)
- [Databricks: Use Apache Iceberg v3 features (RESTORE for downgrade)](https://docs.databricks.com/aws/en/iceberg/iceberg-v3)
- [Databricks: Access Databricks tables from Apache Iceberg clients](https://learn.microsoft.com/en-us/azure/databricks/external-access/iceberg)
- [Apache Iceberg: Spark procedures (`rollback_to_snapshot`, `rollback_to_timestamp`, `set_current_snapshot`)](https://iceberg.apache.org/docs/latest/spark-procedures/)
- [Trino: Iceberg connector](https://trino.io/docs/current/connector/iceberg.html)
