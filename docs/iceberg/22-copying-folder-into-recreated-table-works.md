# Copying the old folder into a recreated managed Iceberg table: why it seems to work

Use case that **worked** in practice:

1. Create a managed Iceberg table on Databricks.
2. Copy its S3 folder somewhere.
3. Drop the table and create it again.
4. Copy the content of the old folder into the new table's folder.
5. Databricks can read the old content.

This partly contradicts [`21-why-swapping-the-s3-folder-fails.md`](21-why-swapping-the-s3-folder-fails.md):
if Unity Catalog alone held the pointer to an exact `metadata.json`, copying the old files in shouldn't
change what Databricks reads. So something else is going on.

> Not yet explained. Below are the most likely explanations and how to check each. ⚠️ All
> unconfirmed. Update this doc with the results of the checks.

## Possible explanations

| # | Explanation | What it would mean | How likely |
|---|---|---|---|
| **1** | **Databricks keeps its own transaction log in the table folder** (for example a `_delta_log/` next to the Iceberg `metadata/`), and reads the current state from **that log in S3**, not only from a pointer in Unity Catalog | Managed Iceberg would behave like Delta. Copying the old folder's log over replaces the table's state, and the old content becomes visible. Hint: the setting needed to `RESTORE` a managed Iceberg table to before v3 is called `spark.databricks.delta.restore.protocolDowngradeAllowed`, a **Delta** setting | ⚠️ Plausible, not documented |
| **2** | **The old metadata still points to the old folder** | The old table's metadata contains **absolute paths** to the old location. After `DROP`, Databricks keeps the old files for **8 days**, so reads may be served **from the old folder**, not from the copy. This would break silently once the old files are purged | Possible |
| **3** | **It's the new table's own data** | The copy added files next to the new table's own metadata, and Unity Catalog still points to the new table's `metadata.json`. If the new table was recreated with the same data, it would look as if it worked | Less likely if data that only existed in the old table is visible |

## How to find out

Run these on the recreated table:

```sql
-- 1. Which location does Unity Catalog use for the new table?
DESCRIBE TABLE EXTENDED my_catalog.my_schema.my_table;      -- "Location"

-- 2. Which files does Databricks actually read? Old folder or new folder?
SELECT DISTINCT _metadata.file_path FROM my_catalog.my_schema.my_table LIMIT 20;

-- 3. What history does it show? The old table's versions, or only the new one's?
DESCRIBE HISTORY my_catalog.my_schema.my_table;
```

And in S3:

```bash
# 4. What's in the new table's folder? Look for _delta_log/ next to metadata/
aws s3 ls --recursive s3://<bucket>/<path-to-new-table>/ | grep -E "_delta_log|metadata/" | head -50
```

| Result | Explanation |
|---|---|
| A **`_delta_log/`** folder exists, `file_path` shows the **new** folder, and `DESCRIBE HISTORY` shows the **old** table's versions | **1**: Databricks reads the table state from the folder (Delta-style). Copying the folder content replaces the state |
| `file_path` shows the **old** folder's paths | **2**: reads come from the dropped table's leftover files. **It will break after about 8 days**, when they're purged |
| `DESCRIBE HISTORY` shows only the new table's versions, and the data matches what was written to the new table | **3**: nothing was taken over |

**Check 5:** read the table from **outside**, through Unity Catalog's Iceberg REST catalog (Trino or
Spark, `SELECT * FROM "my_table$snapshots"`). If Databricks sees the old content but external engines
don't (or the other way round), Databricks' internal state and the Iceberg metadata it publishes have
diverged.

## Even if it works: don't rely on it

| Risk | Why |
|---|---|
| **Unsupported** | Databricks doesn't document replacing files under a managed table. Any update to the runtime, Unity Catalog or predictive optimization can change the behaviour |
| **Identity mismatch** | The copied Iceberg metadata carries the **old** `table-uuid` and old paths. Commits and external engines through the REST catalog may reject or misread the table ⚠️ |
| **Explanation 2 is a time bomb** | Reads silently depend on the dropped table's files, which are deleted after 8 days |
| **Maintenance** | Predictive optimization may remove files it considers orphaned, or expire snapshots based on mixed-up history |
| **Unity Catalog's own metadata** | Schema, column IDs and properties stored in Unity Catalog may not match what's now in the folder |

### Tests before relying on it

After the copy:

- write to the table (`INSERT`, `MERGE`)
- run `OPTIMIZE`
- read it from an external engine through the REST catalog
- read it again after more than 8 days.

### Supported alternative

For the same goal ("get the old table's data back after a drop"):

- **Within 7 days:** `UNDROP TABLE` brings back the original table, with its history (⚠️ not confirmed for Iceberg).
- **After that:** restore the files to a separate location and load them with a clone or `INSERT` through Unity Catalog ([`19-…md`](19-backup-managed-iceberg-with-aws-backup.md), [`21-…md`](21-why-swapping-the-s3-folder-fails.md)).

## Results of the checks

_To be filled in: folder listing (`_delta_log/` present?), `_metadata.file_path` (old or new folder),
`DESCRIBE HISTORY` output, external engine view._

## Related

- [`21-why-swapping-the-s3-folder-fails.md`](21-why-swapping-the-s3-folder-fails.md): the case that fails (folder of a different table)
- [`17-why-databricks-uses-versions-and-missing-functions.md`](17-why-databricks-uses-versions-and-missing-functions.md): versions vs. snapshots
- [`../delta/02-backup-delta-with-aws-backup.md`](../delta/02-backup-delta-with-aws-backup.md): how Delta reads state from `_delta_log/`

## Sources

- [Databricks: Work with table history (Delta and Iceberg, RESTORE)](https://docs.databricks.com/aws/en/tables/history)
- [Databricks: Use Apache Iceberg v3 features (`spark.databricks.delta.restore.protocolDowngradeAllowed`)](https://docs.databricks.com/aws/en/iceberg/iceberg-v3)
- [Databricks: Unity Catalog managed tables (DROP deletes data after 8 days)](https://docs.databricks.com/aws/tables/managed)
- [Databricks: File metadata column (`_metadata.file_path`)](https://docs.databricks.com/aws/en/ingestion/file-metadata-column)
- [Apache Iceberg: Table spec](https://iceberg.apache.org/spec/)
