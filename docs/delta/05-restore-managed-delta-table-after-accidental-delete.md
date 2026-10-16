# Use case: managed Delta table on S3, content deleted by accident, restored from backup

**Situation:** a **managed** Delta table is stored in **your own S3 bucket** (the catalog or schema has
a `MANAGED LOCATION` there). The files under the table's folder (`…/__unitystorage/…/tables/<uuid>/`)
were deleted by accident. You have a backup (AWS Backup or S3 versioning). How do you get the table
back?

Companion to [`04-restore-external-delta-table-after-accidental-delete.md`](04-restore-external-delta-table-after-accidental-delete.md)
(the same case for an **external** table).

> From Delta's design and the Databricks docs. Not tested. ⚠️ marks points to check.

## Short answer

Technically the same trick as for external tables *could* work: restore the folder in place, and
Delta reads `_delta_log/` again. But for **managed** tables that's a write into Unity Catalog's managed
storage outside Unity Catalog. Databricks doesn't support path-based access to managed tables ("might
result in data corruption"). So:

- **Recommended:** restore to a **new folder**, register it as an **external** table, then bring it back
  as a **managed** table (`SET MANAGED` or `DEEP CLONE`). Re-apply permissions.
- **Last resort:** restore **in place** into managed storage, with a break-glass role, and validate
  carefully.

**Prerequisite:** the table must be in **your own bucket**. If its catalog uses **Databricks default
storage**, there's no S3 access and no AWS Backup. Only Databricks features (`RESTORE`, `UNDROP`,
deep clone backups, managed disaster recovery) can help
([`../unity-catalog/02-…md`](../unity-catalog/02-where-managed-tables-are-stored.md)).

## Differences from the external-table case

| | External table (doc 04) | Managed table (this doc) |
|---|---|---|
| Restore in place, same path | ✅ Supported, usually nothing else to do | ⚠️ Works technically, but unsupported (write into managed storage) |
| Who may write the folder | Anyone with access to the external location | **Only Unity Catalog** |
| Background jobs touching the folder | Only yours | **Predictive optimization** (`OPTIMIZE`, `VACUUM`) can run on it |
| Catalog commits | Not applicable | ⚠️ If enabled, the newest commits may be in Unity Catalog, not in S3 |
| Rebuild from a restored copy | `CREATE TABLE … LOCATION` | External table → `SET MANAGED` / `DEEP CLONE` |

## Recommended steps: restore to a new folder and rebuild

| Step | What | How |
|---|---|---|
| 1 | **Stop writers** and note the table's details | Pause jobs, pipelines and streams. `DESCRIBE TABLE EXTENDED prod.sales.orders` → note the **Location** (to find the backup prefix), and save `SHOW GRANTS ON TABLE prod.sales.orders`, tags, comments, row filters and masks |
| 2 | **Check for catalog commits** | `SHOW TBLPROPERTIES prod.sales.orders` → if `delta.feature.catalogManaged` is set, the S3 folder may not contain the newest commits ⚠️. Prefer a deep clone backup if you have one |
| 3 | **Restore to a new folder** | AWS Backup → restore the table's prefix (data **and** `_delta_log/`), at a time **just before the deletion**, to a **new bucket or prefix** that is a Unity Catalog **external location** (e.g. `s3://restore-bucket/orders/`) |
| 4 | **Register it as an external table** | `CREATE TABLE restore.sales.orders_tmp USING DELTA LOCATION 's3://restore-bucket/orders/';` |
| 5 | **Validate** | `DESCRIBE HISTORY`, `SELECT COUNT(*)`, `DESCRIBE DETAIL`, sample queries |
| 6 | **Remove the broken managed table** | `DROP TABLE prod.sales.orders;` (its folder is empty anyway). Or rename it away: `ALTER TABLE prod.sales.orders RENAME TO prod.sales.orders_broken;` |
| 7 | **Bring the data back as a managed table** | **Option A:** `ALTER TABLE restore.sales.orders_tmp SET MANAGED;` then `ALTER TABLE restore.sales.orders_tmp RENAME TO prod.sales.orders;` (⚠️ check availability and whether history is kept). **Option B:** `CREATE TABLE prod.sales.orders DEEP CLONE restore.sales.orders_tmp;` |
| 8 | **Re-apply permissions and metadata** | `GRANT …` from step 1, tags, comments, row filters, column masks |
| 9 | **Resume writers** | Restart jobs. **Reset streaming checkpoints** (it's a new table, or an older version) |
| 10 | **Clean up** | Drop `orders_tmp` if you used option B. Remove the restore folder once everything is verified |

```sql
-- 4. register the restored copy
CREATE TABLE restore.sales.orders_tmp USING DELTA LOCATION 's3://restore-bucket/orders/';

-- 5. validate
DESCRIBE HISTORY restore.sales.orders_tmp;
SELECT COUNT(*) FROM restore.sales.orders_tmp;

-- 6. remove the broken managed table
DROP TABLE prod.sales.orders;

-- 7A. convert to managed and give it the production name
ALTER TABLE restore.sales.orders_tmp SET MANAGED;
ALTER TABLE restore.sales.orders_tmp RENAME TO prod.sales.orders;

-- 7B. or: copy into a new managed table
-- CREATE TABLE prod.sales.orders DEEP CLONE restore.sales.orders_tmp;

-- 8. permissions (from the list saved in step 1)
GRANT SELECT ON TABLE prod.sales.orders TO `analysts`;
```

**What you keep and lose:**

| | Option A (`SET MANAGED`) | Option B (`DEEP CLONE`) |
|---|---|---|
| Data | ✅ | ✅ |
| History up to the restore point | ✅ (comes from the restored `_delta_log/`) ⚠️ | ❌ The clone starts a new history |
| Same table ID as the original | ❌ (new table) | ❌ (new table) |
| Permissions, tags, masks | ❌ Re-apply | ❌ Re-apply |

## Last resort: restore in place into managed storage

Only if the recommended path isn't possible, for example to keep the exact table object and its grants.

| Step | What |
|---|---|
| 1 | Stop writers. If possible, pause **predictive optimization** for the schema (`ALTER SCHEMA … DISABLE PREDICTIVE OPTIMIZATION` ⚠️) so `VACUUM` doesn't run on a half-restored folder |
| 2 | Use a **break-glass IAM role** with write access to the managed storage prefix (normally nobody has it) |
| 3 | AWS Backup → restore the table's **whole prefix** to the **original bucket and path** |
| 4 | `REFRESH TABLE prod.sales.orders;` then `DESCRIBE HISTORY`, `COUNT(*)`, sample queries |
| 5 | Re-enable predictive optimization, resume writers, remove the break-glass access |

| Risk | Why |
|---|---|
| Unsupported | Databricks doesn't support writes into managed storage outside Unity Catalog |
| Catalog commits ⚠️ | If enabled, Unity Catalog may expect commits the folder doesn't contain |
| Partial restore | A missing `_delta_log/` file or checkpoint can make the table unreadable |
| Maintenance during the restore | Predictive optimization could vacuum files before the restore is complete |

If this works, the table keeps its **ID, grants and history**, which is the only advantage over the
recommended path. Test it on a test table before you rely on it.

## If the managed table was also dropped

| When | What |
|---|---|
| Within the recovery window (default 7 days, configurable) | `UNDROP TABLE prod.sales.orders;` brings back the definition. If the files were deleted by hand as well, continue with the recommended steps (restore to a new folder → rebuild) |
| After the window | Unity Catalog has purged the table. Use the recommended steps from step 3 on |

## Better: avoid needing this

| Measure | Effect |
|---|---|
| Nobody gets direct write access to managed storage | Accidental deletes in S3 can't happen. Only Unity Catalog writes there |
| **Deep clone backups** into a backup catalog (incremental for Delta) | A restore is a single `DEEP CLONE` back, through Unity Catalog, fully supported |
| S3 versioning / AWS Backup on the managed storage bucket | The file-level safety net used in this doc |
| Longer `delta.deletedFileRetentionDuration` / log retention | `RESTORE TABLE` covers more mistakes |
| Databricks managed disaster recovery | Covers region loss without any manual restore |

## Related

- [`04-restore-external-delta-table-after-accidental-delete.md`](04-restore-external-delta-table-after-accidental-delete.md): the same case for an external table
- [`02-backup-delta-with-aws-backup.md`](02-backup-delta-with-aws-backup.md): AWS Backup for Delta tables
- [`03-restore-delta-from-aws-backup-to-new-folder.md`](03-restore-delta-from-aws-backup-to-new-folder.md): restoring to another folder
- [`../unity-catalog/02-where-managed-tables-are-stored.md`](../unity-catalog/02-where-managed-tables-are-stored.md): where managed tables are stored

## Sources

- [Databricks: Unity Catalog managed tables](https://docs.databricks.com/aws/tables/managed)
- [Databricks: Access Databricks tables from Delta clients (path-based access to managed tables not supported)](https://docs.databricks.com/aws/en/external-access/unity-rest)
- [Databricks: Convert external or foreign Delta Lake tables to Unity Catalog managed tables](https://docs.databricks.com/aws/en/tables/convert-to-managed)
- [Databricks: Catalog commits](https://learn.microsoft.com/en-us/azure/databricks/tables/features/catalog-commits)
- [Databricks: Predictive optimization](https://docs.databricks.com/aws/en/optimizations/predictive-optimization)
- [Databricks: UNDROP](https://docs.databricks.com/aws/en/sql/language-manual/sql-ref-syntax-ddl-undrop-table)
- [Databricks: Clone a table on Databricks](https://docs.databricks.com/aws/en/tables/operations/clone)
- [AWS Backup: Restoring a continuous backup](https://docs.aws.amazon.com/aws-backup/latest/devguide/point-in-time-recovery-restoring.html)
