# Use case: external Delta table, S3 content deleted by accident, restored from backup

**Situation:** an **external** Delta table on Databricks stores its data in an S3 bucket. The bucket
content was deleted by accident. It was restored from a backup (e.g. AWS Backup) **to the same bucket
and path**. How do you get the content back in Databricks, and do you have to do anything at all?

> From Delta's design and the Databricks docs. Not tested. ⚠️ marks points to check.

## Short answer

**Mostly nothing.** Deleting files in S3 doesn't remove the table from Unity Catalog: the table
definition (name → `LOCATION`) is still there. Delta reads the table state from `_delta_log/` **in
the folder**, with **relative paths**. Once the folder is restored to the same path, Databricks reads
it again as before.

You only need a few **checks**, and two cases need action:

- something **wrote to the empty folder** while the data was gone
- the **table definition was dropped** as well.

## Steps

| Step | What | How |
|---|---|---|
| 1 | **Stop writers** (before restoring, if possible) | Pause jobs, pipelines and streams that write to the table. Revoke `MODIFY` temporarily. Otherwise a job could write a **new, empty table** into the folder while it's empty (see step 2) |
| 2 | **Check whether anything was written after the deletion** | List `_delta_log/` in S3. If you see a fresh `00000000000000000000.json` with a recent timestamp, or files newer than the deletion, a writer created a new table there. **Move those objects away** before restoring, otherwise old and new logs get mixed |
| 3 | **Restore** | AWS Backup → recovery point (or continuous backup at a time **just before the deletion**) → restore the table's **whole prefix** (data **and** `_delta_log/`) to the **original bucket and path** |
| 4 | **Check the table still exists in Unity Catalog** | `DESCRIBE TABLE EXTENDED main.sales.orders;` ("Type": EXTERNAL, "Location": the restored path). If it was dropped too, see the next section |
| 5 | **Refresh cached state** | `REFRESH TABLE main.sales.orders;` On long-running clusters, restart them if results still look wrong ⚠️. SQL warehouses and new clusters read the restored log directly |
| 6 | **Validate** | See the queries below |
| 7 | **Resume writers.** Reset **streaming checkpoints** if streams read this table and the restored version is older than what they had already processed | Restart jobs. Restore `MODIFY` |

## Validation queries

```sql
DESCRIBE HISTORY main.sales.orders;          -- latest version = the last commit before the deletion?
SELECT COUNT(*) FROM main.sales.orders;      -- expected row count?
DESCRIBE DETAIL main.sales.orders;           -- numFiles, sizeInBytes plausible?
SELECT * FROM main.sales.orders LIMIT 10;

-- Only if queries fail with "file not found": list files the log references but S3 doesn't have
FSCK REPAIR TABLE main.sales.orders DRY RUN;
```

⚠️ Running `FSCK REPAIR TABLE` **without** `DRY RUN` removes the missing files from the table. That
means **losing those rows**. Use it only if some files really can't be restored.

## If the table definition was dropped as well

For an **external** table, `DROP TABLE` only removes the definition and the files stay. If the
definition is gone too, register the restored folder again:

```sql
CREATE TABLE main.sales.orders
USING DELTA
LOCATION 's3://my-lake/warehouse/sales/orders/';   -- schema and history are read from _delta_log
```

Then re-apply grants, tags, comments, row filters and column masks. Those lived in Unity Catalog and
were removed with the definition. ⚠️ `UNDROP` may also work for external tables within the recovery
window. It re-registers the definition.

## What can go wrong

| Problem | Cause | Fix |
|---|---|---|
| Table shows **0 rows or a single new version** | A job wrote to the empty folder after the deletion and created a new log | Move the new objects away, restore again (step 2) |
| Table shows an **older version** than expected | The restore point was before the last commit, or the newest log files weren't in the backup | Restore from a later point in time (continuous backup allows any point within 35 days) |
| **"File not found"** errors | Not all data files were restored, or `VACUUM` had already removed them before the backup | Restore the missing prefix again. As a last resort, `FSCK REPAIR TABLE` (data loss) |
| **Access denied** | Restored objects use a different KMS key, or the storage credential's IAM role lost access | Restore with the original KMS key and check the IAM role used by the external location |
| **Streams fail or skip data** | The table version went back below the version a stream had already processed | Reset the stream's checkpoint and reprocess from a known version |

## Why it's this simple for Delta

| Delta feature | Effect |
|---|---|
| `_delta_log/` lives **in the folder** | The table state comes back with the files |
| **Relative paths** in the log | No path rewriting needed, unlike Iceberg ([`../iceberg/23-…md`](../iceberg/23-paths-to-rewrite-when-restoring-to-another-folder.md)) |
| External table definition stays in Unity Catalog when files are deleted | Name, `LOCATION` and permissions are unchanged |

For a **managed** Delta table, the situation is different: writing restored files into managed
storage is an unsupported path-based write. See
[`02-backup-delta-with-aws-backup.md`](02-backup-delta-with-aws-backup.md) and
[`03-restore-delta-from-aws-backup-to-new-folder.md`](03-restore-delta-from-aws-backup-to-new-folder.md).

## Related

- [`03-restore-delta-from-aws-backup-to-new-folder.md`](03-restore-delta-from-aws-backup-to-new-folder.md): restoring to another folder
- [`../aws-backup/01-aws-backup-options-overview.md`](../aws-backup/01-aws-backup-options-overview.md): AWS Backup options
- [`../unity-catalog/01-managed-and-external-tables-sql.md`](../unity-catalog/01-managed-and-external-tables-sql.md): declaring external tables

## Sources

- [Databricks: Work with external tables](https://docs.databricks.com/aws/en/tables/external)
- [Databricks: Work with table history](https://docs.databricks.com/aws/en/tables/history)
- [Databricks: REFRESH TABLE](https://docs.databricks.com/aws/en/sql/language-manual/sql-ref-syntax-aux-cache-refresh-table)
- [Databricks: FSCK REPAIR TABLE](https://docs.databricks.com/aws/en/sql/language-manual/delta-fsck)
- [Databricks: UNDROP](https://docs.databricks.com/aws/en/sql/language-manual/sql-ref-syntax-ddl-undrop-table)
- [AWS Backup: Restoring a continuous backup](https://docs.aws.amazon.com/aws-backup/latest/devguide/point-in-time-recovery-restoring.html)
