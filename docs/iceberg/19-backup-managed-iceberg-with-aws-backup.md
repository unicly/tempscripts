# Backing up a managed Iceberg table on S3: AWS Backup and the best overall approach

Question: what is the best way to back up a Databricks managed Iceberg table stored on S3? Is AWS
Backup the right tool, and how do you restore from it?

> Based on AWS and Databricks documentation. Not tested. ⚠️ marks points to verify, especially the
> restore paths, which Databricks doesn't document for managed tables.

## Short answer

AWS Backup is **useful, but not enough on its own**. It protects the **files** in the S3 bucket. It
knows nothing about Unity Catalog, which holds the table's pointer, permissions and lineage. So:

- **AWS Backup is good for:** a deleted or damaged bucket, ransomware, objects deleted by mistake, a
  table dropped from Unity Catalog more than 8 days ago. Restore the files, then rebuild the table.
- **AWS Backup is not good for:** "undo yesterday's bad `MERGE`". Use Databricks time travel /
  `RESTORE` for that, because restoring older files doesn't move Unity Catalog's pointer back.
- **Best overall:** combine three layers (§3). AWS Backup is the file-level safety net, and an
  incremental export to an immutable standard Iceberg vault is the main restorable backup.

## 1. What AWS Backup does for S3

| Feature | Details |
|---|---|
| **Continuous backup** | Point-in-time restore to any moment within the last **35 days** |
| **Periodic backup** | Scheduled snapshots with longer retention (weeks, months, years) |
| **Restore scope** | Whole bucket, a **prefix**, or single objects, to the **original or a new** bucket |
| **Immutability** | Backup Vault Lock, copies to another account / region via AWS Organizations, logically air-gapped vaults ⚠️ |
| **Requirements** | S3 versioning on the bucket ⚠️ (third-party source, check the AWS docs). One backup plan per bucket for continuous backup. Glacier Flexible Retrieval / Deep Archive objects are not supported |
| **Consistency** | A point-in-time restore gives the set of objects as they were at time T. Iceberg files are written once and never changed, so a set from time T contains a consistent table version, as long as nothing referenced was already deleted |

## 2. What AWS Backup can and can't do for a managed Iceberg table

| Part of the table | Where it lives | Protected by AWS Backup? |
|---|---|---|
| Data files (Parquet, deletion vectors) | S3 managed storage | ✅ |
| Iceberg metadata (`metadata.json`, manifests) | S3 managed storage | ✅ |
| **Pointer to the current `metadata.json`** | Unity Catalog | ❌ |
| Permissions, row filters, masks, tags, lineage | Unity Catalog | ❌ |
| Table definition in the metastore | Unity Catalog | ❌ |

**Prerequisite:** the catalog must use **your own S3 bucket** as managed storage. If it's on Databricks
default storage, you can't attach AWS Backup at all. Check with `DESCRIBE CATALOG EXTENDED`.

## 3. Best overall backup setup (three layers)

| Layer | Method | Covers | Restore gives you |
|---|---|---|---|
| **1. In the table** | Time travel, `RESTORE TABLE … TO VERSION AS OF` ⚠️, `UNDROP` (7 days) ⚠️ | Bad writes and drops within days | The **same** table, with ID, permissions and history |
| **2. Logical backup (main backup)** | Incremental export to a **standard Iceberg vault**: OSS Spark reads the snapshot delta through Unity Catalog's Iceberg REST catalog and `MERGE`s into a Glue table in a **separate backup account / bucket with S3 Object Lock** | Errors found late, metastore or workspace lost, ransomware | A complete, readable table with its own point-in-time snapshots. Restore = load into a new managed table |
| **3. File-level safety net** | **AWS Backup** on the managed storage bucket (continuous + periodic), vault in another account with Vault Lock | Bucket deleted, objects deleted or encrypted by an attacker, layer 2 failed | Raw files at time T. Restore = files back in place, or recovery through standard Iceberg (§4) |

A simpler alternative to layer 2 is a **dated `DEEP CLONE`** into a backup catalog. But it's a full
copy every time, so it costs more storage and compute.

## 4. Restoring from AWS Backup

### 4.1 Scenario A: files deleted or damaged, table still exists in Unity Catalog

Example: someone deleted objects under the table's prefix, or an attacker encrypted them. Unity
Catalog still points to the latest `metadata.json`.

| Step | What |
|---|---|
| 1 | Stop writes to the table (revoke `MODIFY`, pause jobs). Pause predictive optimization if possible |
| 2 | AWS Backup → backup vault → recovery point (or continuous backup) → **Restore** → choose a time **just before the damage** |
| 3 | Restore the table's **prefix** to the **original bucket** (the same paths) |
| 4 | In Databricks: `SELECT COUNT(*)`, `DESCRIBE HISTORY` and a few queries to check that the current version reads cleanly |
| 5 | Resume writes |

⚠️ This only works if the `metadata.json` that Unity Catalog points to, and every file it references,
existed at the restore time. If the damage happened after the last commit, that's the case. Test this
scenario on a test table first, because Databricks doesn't document it.

### 4.2 Scenario B: table or metastore gone in Unity Catalog (dropped > 8 days, catalog deleted)

The files are gone from S3 (or the metastore is gone) and the pointer no longer exists. Recover
through standard Iceberg, as in [`12-…md`](12-managed-iceberg-summary-aws-azure.md) §2.3:

| Step | What | Tool |
|---|---|---|
| 1 | Restore the table's prefix from AWS Backup to a **new bucket or prefix** you own (not into Unity Catalog's managed storage) | AWS Backup |
| 2 | Find the newest **complete** `metadata.json` (every referenced manifest and data file exists) | S3 CLI, a small script |
| 3 | Register it in a standard catalog: `CALL glue.system.register_table('restore.orders', 's3://restore-bucket/…/metadata/00042-….metadata.json')`, or read it with PyIceberg `StaticTable.from_metadata(...)` | OSS Spark on EMR / PyIceberg |
| 4 | Check the data: row counts, recent snapshots, sample queries in Athena | Athena / EMR |
| 5 | Load it into a **new managed table**: Spark/Trino `CREATE TABLE … AS SELECT` through Unity Catalog's REST catalog, or Glue → federation → `CREATE TABLE uc.sales.orders DEEP CLONE glue_fed.restore.orders` | EMR / Databricks |
| 6 | Re-apply grants, tags, row filters and column masks. Reset replication watermarks and streaming checkpoints | Databricks |

### 4.3 Scenario C: bad write ("undo yesterday's MERGE")

Don't use AWS Backup. Restoring older files doesn't change Unity Catalog's pointer, which still
points to the bad version. Use:

- `RESTORE TABLE prod.sales.orders TO VERSION AS OF <n>` ⚠️ (within retention), or
- the logical backup (layer 2) or a dated clone, if the retention period has passed.

## 5. Is an AWS Backup restore transparent for Databricks?

For the files, yes. AWS Backup restores **every object** under the bucket or prefix you choose, as it
was at time T: `metadata.json`, manifest lists, manifests, Parquet files and deletion vectors. But it's
only "transparent" for Databricks in one specific case. AWS Backup restores **files**, not **Unity
Catalog**, and Unity Catalog keeps pointing wherever it points *now*.

> Not tested and not documented by Databricks: reasoning from how Iceberg and Unity Catalog work (⚠️).

### 5.1 When Databricks notices nothing

Databricks only follows Unity Catalog's pointer to the current `metadata.json` and reads the files it
references. If those files are back at their original paths, reads work as before.

That's the case when **all of these are true**:

| Condition | Why |
|---|---|
| The table still exists in Unity Catalog (not dropped, metastore intact) | The pointer is in Unity Catalog, not in S3 |
| You restore to the **original bucket and paths** | The pointer and the metadata contain absolute paths |
| The `metadata.json` Unity Catalog points to **existed at time T**, together with every file it references | Otherwise the restored set doesn't contain the current version |
| Nothing was committed between T and the incident, or those newer files weren't damaged | See the next table |

Typical example: an attacker or a script deletes objects at 14:00, and the last commit was at 11:00.
You restore to 13:59, and the table works again.

### 5.2 When it's *not* transparent

| Situation | What happens |
|---|---|
| **Commits after time T** whose files were also lost | Unity Catalog points to a `metadata.json` created after T. AWS Backup can't bring it back because it didn't exist at T, so the table stays broken. Restore to a time *after* the last good commit (continuous backup allows any point within 35 days) |
| **You want the table "as it was at time T"** (undo a bad write) | Restoring old files doesn't move Unity Catalog's pointer back. Databricks still shows the current (bad) version. Use `RESTORE TABLE … TO VERSION AS OF` or a backup copy instead |
| **Snapshots were already expired** by predictive optimization | The restored data files are back, but the current `metadata.json` no longer references them. Time travel to those versions stays impossible. Only by registering an *old* `metadata.json` in another catalog (§4.2) |
| **Table dropped or metastore lost** | No pointer exists any more. Restoring files alone doesn't bring the table back. You need the standard Iceberg route into a **new** table (§4.2) |

### 5.3 Side effects to know about

| Effect | Impact |
|---|---|
| **Files created after T are not removed** by a restore into an existing bucket ⚠️ | Old restored files and newer files sit side by side. Iceberg ignores files the current metadata doesn't reference, so reads are fine. Unreferenced files are orphans that maintenance cleans up later |
| **No conflicts** | Iceberg file names are unique and never overwritten, so restored files can't clash with current ones |
| **New object timestamps** (`LastModified` = restore time) | Iceberg doesn't use them for reads. Orphan cleanup uses file age, so restored orphans are only removed after its safety window |
| **Caches** | Databricks may cache metadata or data. If queries still fail after the restore, run them on a fresh cluster or SQL warehouse ⚠️ |
| **Encryption** | Restore with the **same KMS key** (SSE-KMS) that Unity Catalog's storage credential can use, or Databricks can't read the files |
| **Audit** | The restore happens in AWS with an IAM role, outside Unity Catalog. Unity Catalog's audit log doesn't show it. Document it in your incident process |
| **Permissions, tags, row filters, lineage** | Unaffected: they live in Unity Catalog, which the restore doesn't touch |

### 5.4 In short

| Question | Answer |
|---|---|
| Does AWS Backup restore everything, including `metadata.json`? | ✅ Every object under the chosen bucket or prefix, as of time T |
| Is it transparent for Databricks? | ✅ **Only** if the table still exists in Unity Catalog and the version Unity Catalog points to was complete at time T. Then Databricks reads normally and notices nothing |
| Can it roll the table back in time? | ❌ Unity Catalog's pointer isn't restored. For "undo", use time travel / `RESTORE` or a backup copy |
| Can it bring back a dropped table? | ❌ Not directly. Only through the standard Iceberg route into a new table |

So AWS Backup is a **repair tool for lost or damaged files**, not a time machine for the table.

## 6. Settings checklist

| Setting | Why |
|---|---|
| Managed storage on **your own bucket** (not Databricks default storage) | Otherwise AWS Backup can't be used |
| **S3 versioning** on that bucket | Needed by AWS Backup ⚠️, and protects against overwrites |
| AWS Backup **continuous** (35 days) **+ periodic** (long retention) plan | Point-in-time recovery plus long-term copies |
| Backup vault in a **separate account**, with **Vault Lock** | An attacker in the main account can't delete backups |
| **Break-glass IAM role** that can read managed storage and run restores | Restores need direct S3 access, which Databricks normally discourages |
| `delta.deletedFileRetentionDuration` / retention long enough for daily mistakes | Layer 1 covers most incidents without any restore |
| A **test restore** at least once (scenarios A and B) | None of the managed-table restore paths are documented by Databricks |

## 7. In short

| Question | Answer |
|---|---|
| Is AWS Backup the best way to back up a managed Iceberg table? | Not on its own. It's a good **file-level safety net**. The main backup should be a **logical export to a standard Iceberg vault** (or dated deep clones), plus time travel / `UNDROP` for daily mistakes |
| Can I restore with AWS Backup? | ✅ Files back in place if the table still exists in Unity Catalog (scenario A ⚠️). ✅ As a **new** table via standard Iceberg tools if the table or metastore is gone (scenario B). ❌ Not for undoing a bad write (scenario C) |

## Related

- [`12-managed-iceberg-summary-aws-azure.md`](12-managed-iceberg-summary-aws-azure.md): backup layers and emergency recovery (§2)
- [`16-managed-iceberg-on-aws-glue-storage.md`](16-managed-iceberg-on-aws-glue-storage.md): where the table is stored
- [`../delta/01-delta-backup-and-restore.md`](../delta/01-delta-backup-and-restore.md): the same question for Delta tables

## Sources

- [AWS Backup: Amazon S3 backups](https://docs.aws.amazon.com/aws-backup/latest/devguide/s3-backups.html)
- [AWS Backup: Restoring a continuous backup](https://docs.aws.amazon.com/aws-backup/latest/devguide/point-in-time-recovery-restoring.html)
- [Amazon S3: Backing up your Amazon S3 data](https://docs.aws.amazon.com/AmazonS3/latest/userguide/backup-for-s3.html)
- [AWS Storage blog: Automate and centrally manage data protection for Amazon S3 with AWS Backup](https://aws.amazon.com/blogs/storage/automate-and-centrally-manage-data-protection-for-amazon-s3-with-aws-backup/)
- [AWS re:Post: Continuous and periodic backups for S3](https://www.repost.aws/knowledge-center/backup-s3-continuous-periodic-backups)
- [OneUptime: S3 with AWS Backup, centralized management](https://oneuptime.com/blog/post/2026-02-12-s3-aws-backup-centralized-management/view)
- [Databricks: Unity Catalog managed tables (DROP deletes data after 8 days)](https://docs.databricks.com/en/tables/managed.html)
- [Databricks: Work with table history (time travel, RESTORE)](https://docs.databricks.com/aws/en/tables/history)
- [Databricks: Access Databricks tables from Apache Iceberg clients](https://learn.microsoft.com/en-us/azure/databricks/external-access/iceberg)
- [Apache Iceberg: Spark procedures (`register_table`)](https://iceberg.apache.org/docs/latest/spark-procedures/)
