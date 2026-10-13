# Backing up Delta tables on S3 with AWS Backup, and is a restore transparent for Databricks?

The same two questions as for managed Iceberg
([`../iceberg/19-backup-managed-iceberg-with-aws-backup.md`](../iceberg/19-backup-managed-iceberg-with-aws-backup.md)),
answered for **Delta tables** on Databricks (managed and external):

1. What's the best way to back up a Delta table stored on S3? Is AWS Backup the right tool, and how
   do you restore from it?
2. Does AWS Backup restore everything, including the table's log, and is that transparent for
   Databricks?

> Based on AWS and Databricks documentation and general Delta behaviour. Not tested. ⚠️ marks points
> to verify, especially restores into Unity Catalog managed storage, which Databricks doesn't document.

## Short answer

AWS Backup works **better for Delta than for managed Iceberg**, for two reasons:

- **The transaction log lives in S3** (`_delta_log/`), next to the data. Unity Catalog stores where the
  table is, but which version is current is read from the log in S3 ⚠️ (see §5 on catalog-managed
  commits).
- **Paths in the log are relative.** Files restored to a **new location** still form a valid table,
  with no path rewriting.

It's still **not the main backup**. For undoing bad writes, Delta's own `RESTORE` is better. For
complete copies, **incremental deep clones** are better. Use AWS Backup as the file-level safety net.

---

# Part 1: Best way to back up, and how to restore

## 1. What gets backed up

| Part of the table | Where it lives | Protected by AWS Backup? |
|---|---|---|
| Data files (Parquet, deletion vectors) | S3 (managed storage or your external location) | ✅ |
| **Transaction log** (`_delta_log/*.json`, checkpoints, `_last_checkpoint`) | S3, in the table folder | ✅ |
| Which version is current | Read from the log in S3 ⚠️ | ✅ (indirectly, through the log) |
| Table registration (name → location), permissions, row filters, masks, tags, lineage | Unity Catalog | ❌ |

**Prerequisite for managed tables:** the catalog must use **your own S3 bucket** as managed storage,
not Databricks default storage. Check with `DESCRIBE CATALOG EXTENDED`. External tables are always in
your own bucket.

## 2. Best overall backup setup (three layers)

| Layer | Method | Covers | Restore gives you |
|---|---|---|---|
| **1. In the table** | Retention properties + time travel, **`RESTORE TABLE … TO VERSION AS OF`**, `UNDROP` (managed, 7 days) | Bad writes and drops within the retention window | The **same** table, with ID, permissions and history |
| **2. Copies (main backup)** | **Incremental `DEEP CLONE`** into a backup catalog on separate storage, ideally a separate account with S3 Object Lock. Optionally also on the other cloud through OpenSharing | Errors found late, metastore or workspace lost, ransomware | A complete Delta table with its own history. Restore = `DEEP CLONE` back |
| **3. File-level safety net** | **AWS Backup** on the bucket (continuous 35 days + periodic), vault in another account with Vault Lock | Bucket deleted, objects deleted or encrypted, layers 1–2 failed | Raw table folders at time T, which are directly usable as Delta tables (§3) |

Compared with managed Iceberg, layer 2 is much cheaper here: deep clones of Delta tables are
**incremental**, so each run only copies the changes.

## 3. Restoring from AWS Backup

### 3.1 Scenario A: files deleted or damaged, table still registered in Unity Catalog

| Step | What |
|---|---|
| 1 | Stop writes (revoke `MODIFY`, pause jobs and streams) |
| 2 | AWS Backup → recovery point / continuous backup → **Restore** the table's prefix to the **original bucket**, at a time just before the damage |
| 3 | Check in Databricks: `DESCRIBE HISTORY`, `SELECT COUNT(*)`, a few queries |
| 4 | Resume writes |

The same caveats as §5 apply: this works when the log and the files of the latest version existed at
time T.

### 3.2 Scenario B: managed table dropped (> 8 days) or metastore lost

Much simpler than for Iceberg, because the folder is a self-contained Delta table:

| Step | What | Tool |
|---|---|---|
| 1 | Restore the table's prefix from AWS Backup to a **new bucket or prefix** that is a Unity Catalog **external location** (not inside managed storage, which Unity Catalog won't accept for external tables) | AWS Backup |
| 2 | Register it as an external table: `CREATE TABLE restore.sales.orders_tmp USING DELTA LOCATION 's3://restore-bucket/orders/'` | Databricks |
| 3 | Check: `DESCRIBE HISTORY` (the full history up to time T is there), counts, queries | Databricks |
| 4 | Make it managed again: `CREATE TABLE prod.sales.orders DEEP CLONE restore.sales.orders_tmp` (or keep it external) | Databricks |
| 5 | Re-apply grants, tags, row filters and column masks. Reset streaming checkpoints and replication watermarks | Databricks |

⚠️ Not documented by Databricks for managed tables. Test it once.

### 3.3 Scenario C: external Delta table

| Situation | Restore |
|---|---|
| Files damaged, table still registered | Restore the folder to the **same path**. The table works again |
| Table dropped | `DROP` on an external table leaves the files. If they were deleted too, restore the folder from AWS Backup and run `CREATE TABLE … LOCATION '<same path>'` |

### 3.4 Scenario D: bad write ("undo yesterday's MERGE")

Don't use AWS Backup. Use **`RESTORE TABLE prod.sales.orders TO VERSION AS OF <n>`** within the
retention window, or `DEEP CLONE … VERSION AS OF` from the backup copy after that.

---

# Part 2: Is an AWS Backup restore transparent for Databricks?

## 4. What gets restored

For the files, yes: AWS Backup restores **every object** under the chosen bucket or prefix as it was
at time T. That includes `_delta_log/*.json`, checkpoints, `_last_checkpoint`, Parquet files and
deletion vectors.

## 5. When Databricks notices nothing

Databricks finds the table's location in Unity Catalog, then reads the latest version from
`_delta_log/` in S3. If the folder is back at its original path, reads work as before.

That's the case when **all of these are true**:

| Condition | Why |
|---|---|
| The table is still registered in Unity Catalog | The name → location mapping and the permissions are in Unity Catalog |
| You restore to the **original bucket and path** | Unity Catalog points to that location |
| The log and data files of the **latest version** existed at time T, or weren't damaged | Otherwise the restored log is missing the newest commits (see below) |
| ⚠️ **Catalog-managed commits** are not enabled for the table | With this newer feature (Public Preview), Unity Catalog coordinates commits and may hold the latest ones itself. The log in S3 alone is then not the full picture |

Typical example: objects are deleted at 14:00, the last commit was at 11:00. You restore to 13:59, and
the table works again.

## 6. When it's *not* transparent

| Situation | What happens |
|---|---|
| **Commits after time T** whose log files were also deleted | They can't be restored (they didn't exist at T). Delta then reads the **last commit present**, so the table **silently goes back** to an older version. Unlike Iceberg it isn't broken, it's just older. Downstream jobs and streams that already saw newer versions may then fail or produce wrong results |
| **You want the table "as it was at time T"** | Restoring into the existing folder doesn't remove newer log files, so Delta still shows the latest (bad) version. Don't delete log files by hand to force it. Use `RESTORE TABLE … TO VERSION AS OF` |
| **Files already removed by `VACUUM`** | They come back with the restore, and time travel to those versions can work again, **as long as the log entries are still within `delta.logRetentionDuration`** ⚠️ |
| **`_last_checkpoint` points to a checkpoint that isn't in the restored set** | Delta may fail to load the table ⚠️. Restore the whole `_delta_log/` prefix consistently, not single files |
| **Table dropped or metastore lost** | No registration any more. Restore to a new external location and register it (§3.2) |

## 7. Side effects to know about

| Effect | Impact |
|---|---|
| **Files created after T are not removed** by a restore into an existing bucket ⚠️ | Old and new files sit side by side. Delta ignores files the log doesn't reference. `VACUUM` later removes the unreferenced ones |
| **No conflicts** | Delta data files have unique names and commit files are numbered, so restored files don't overwrite newer ones |
| **New object timestamps** (`LastModified` = restore time) | `VACUUM` uses file age, so restored but unreferenced files are only removed after the retention window |
| **Streaming checkpoints** | If the table went back in version (§6), streams that read it must be reset |
| **Caches** | Databricks caches the Delta log state. If results look stale, refresh or use a fresh cluster or SQL warehouse ⚠️ |
| **Encryption** | Restore with the **same KMS key** that Unity Catalog's storage credential can use |
| **Audit** | The restore happens in AWS, outside Unity Catalog's audit log. Document it in your incident process |
| **Permissions, tags, lineage** | Unaffected: they live in Unity Catalog |

## 8. Comparison with managed Iceberg

| | Delta | Managed Iceberg |
|---|---|---|
| Current version decided by | The log in S3 (⚠️ unless catalog-managed commits) | Unity Catalog's pointer |
| Restore in place when files were lost | ✅ Works | ✅ Works, if the pointed-to version existed at T |
| Missing newest commits after a restore | Table silently goes back to an older version | Table is broken (pointer to a missing `metadata.json`) |
| Restore to a **new** location | ✅ Directly usable (`CREATE TABLE … LOCATION`), full history kept | ⚠️ Only via standard Iceberg tools (register in Glue / PyIceberg), then copy into a new table |
| Undo a bad write | `RESTORE` (mature) | `RESTORE` ⚠️ or a backup copy |
| Main backup | Incremental deep clone | Export to a standard Iceberg vault, or full deep clones |

## 9. In short

| Question | Answer |
|---|---|
| Is AWS Backup the best way to back up a Delta table? | Not on its own. Best: retention + `RESTORE` / `UNDROP`, **incremental deep clones** to separate immutable storage, and AWS Backup as the file-level safety net |
| Does AWS Backup restore everything, including the log? | ✅ Every object under the chosen prefix, including `_delta_log/`, as of time T |
| Is it transparent for Databricks? | ✅ If the table is still registered and the latest version was complete at time T. If newer commits were lost, the table silently shows an older version |
| Can it bring back a dropped table? | ✅ Restore to a new external location and `CREATE TABLE … LOCATION`. Much easier than with Iceberg |
| Can it undo a bad write? | ❌ Use `RESTORE TABLE … TO VERSION AS OF` |

## Sources

- [AWS Backup: Amazon S3 backups](https://docs.aws.amazon.com/aws-backup/latest/devguide/s3-backups.html)
- [AWS Backup: Restoring a continuous backup](https://docs.aws.amazon.com/aws-backup/latest/devguide/point-in-time-recovery-restoring.html)
- [AWS Storage blog: Automate and centrally manage data protection for Amazon S3 with AWS Backup](https://aws.amazon.com/blogs/storage/automate-and-centrally-manage-data-protection-for-amazon-s3-with-aws-backup/)
- [Databricks: Work with table history (time travel, RESTORE, retention)](https://docs.databricks.com/aws/en/tables/history)
- [Databricks: Clone a table on Databricks](https://docs.databricks.com/aws/en/tables/operations/clone)
- [Databricks: Unity Catalog managed tables](https://docs.databricks.com/en/tables/managed.html)
- [Databricks: Lakeflow pipelines release notes 2026 (catalog commits)](https://docs.databricks.com/aws/en/release-notes/dlt/2026)
