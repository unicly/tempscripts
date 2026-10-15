# Running `rewrite_table_path` to restore an Iceberg table into a new folder

Executable code for restoring an Iceberg table (for example from an AWS Backup restore) into a new S3
folder, rewriting all paths, and registering the result in AWS Glue.

**Script:** [`../../scripts/iceberg/restore_with_rewrite_table_path.py`](../../scripts/iceberg/restore_with_rewrite_table_path.py)

> Not run against real tables. Syntax-checked only. Test it on a small table first. ⚠️ marks points
> to check for your Iceberg / EMR / Glue version.

## Short answers

| Question | Answer |
|---|---|
| **Can I run it with Spark on Databricks?** | ❌ No. Databricks Runtime doesn't include the open-source Iceberg Spark procedures (`CALL … system.rewrite_table_path`, `register_table`), and loading OSS Iceberg jars on Databricks clusters isn't supported |
| **Where do I run it?** | ✅ On AWS with OSS Spark + Iceberg: **Amazon EMR**, **EMR Serverless**, or an **AWS Glue 5 job**. A local Spark with the Iceberg runtime works too |
| **Can I restore into a folder where I created a new Iceberg table?** | ❌ Not if that's a **Databricks managed** table: Unity Catalog won't accept the rewritten files ([`21-…md`](21-why-swapping-the-s3-folder-fails.md), [`24-…md`](24-change-bucket-of-managed-iceberg-table.md)). ✅ Restore into an **empty** folder and **register** it as a new Glue table. Don't pre-create a table there; the script registers it. To get it into Databricks afterwards: federate Glue and `DEEP CLONE` into a managed table |

## ⚠️ The most important requirement

`rewrite_table_path` **reads** the source table's metadata, manifest lists, manifests and position
delete files **at the paths recorded inside the metadata** (the source prefix, usually the original
location). It doesn't read them from wherever you restored them to.

| Your situation | Works? |
|---|---|
| Files are still (or again) at their original paths, e.g. the original location still exists, or AWS Backup restored **in place** | ✅ |
| AWS Backup restored them **only to a new bucket or prefix** and the original paths are gone | ❌ Restore the table's prefix **to the original bucket and path** first (AWS Backup supports restoring a prefix to the original bucket), then run the script |

The script checks this up front: it verifies that the current snapshot's manifest list is readable at
its recorded path, and stops with a clear error if not.

For a managed Databricks table, the original paths are in Unity Catalog's managed storage
(`…/__unitystorage/…`). Restoring there means writing into Unity Catalog's storage with a break-glass
role. Do it only for this recovery, and only for the table's own prefix.

## What the script does

| Step | Action |
|---|---|
| 1 | Finds the newest `*.metadata.json` in `--metadata-dir` (or uses `--metadata-file`), reads its `location` and `table-uuid` |
| 2 | Checks that the current snapshot's manifest list is readable at its recorded path |
| 3 | Registers the source as a **temporary Glue table** (`register_table`) |
| 4 | Runs **`rewrite_table_path`** from the source prefix to `--target-prefix`, writing rewritten metadata to `--staging` |
| 5 | Copies the files from the generated file list with boto3, in a safe order: **data and delete files → manifests → `metadata.json` last** |
| 6 | Drops the temporary table **without PURGE** (no files are deleted) and **registers** the restored table in Glue |
| 7 | Prints row count and snapshot list for validation |

`--dry-run` stops after step 4: it shows the target `metadata.json` and the file list without copying
or registering anything.

## How to run it

### Option A: Amazon EMR (on EC2)

```bash
# EMR 7.x with Iceberg enabled (iceberg-defaults classification: iceberg.enabled=true)
aws s3 cp restore_with_rewrite_table_path.py s3://my-scripts/

spark-submit \
  --conf spark.sql.extensions=org.apache.iceberg.spark.extensions.IcebergSparkSessionExtensions \
  s3://my-scripts/restore_with_rewrite_table_path.py \
  --metadata-dir  s3://old-bucket/path/orders/metadata/ \
  --target-prefix s3://new-bucket/restored/orders \
  --staging       s3://new-bucket/_iceberg_staging/orders/ \
  --warehouse     s3://new-bucket/warehouse/ \
  --target-table  restored.orders \
  --dry-run       # remove after checking the output
```

### Option B: EMR Serverless

```bash
aws emr-serverless start-job-run \
  --application-id <app-id> \
  --execution-role-arn arn:aws:iam::<account>:role/<emr-serverless-role> \
  --job-driver '{
    "sparkSubmit": {
      "entryPoint": "s3://my-scripts/restore_with_rewrite_table_path.py",
      "entryPointArguments": ["--metadata-dir","s3://old-bucket/path/orders/metadata/",
                              "--target-prefix","s3://new-bucket/restored/orders",
                              "--staging","s3://new-bucket/_iceberg_staging/orders/",
                              "--warehouse","s3://new-bucket/warehouse/",
                              "--target-table","restored.orders"],
      "sparkSubmitParameters": "--conf spark.jars=/usr/share/aws/iceberg/lib/iceberg-spark3-runtime.jar --conf spark.sql.extensions=org.apache.iceberg.spark.extensions.IcebergSparkSessionExtensions"
    }
  }'
```

### Option C: AWS Glue 5 job

| Job setting | Value |
|---|---|
| Type / version | Spark, Glue 5.0 |
| Script | `restore_with_rewrite_table_path.py` |
| Job parameter `--datalake-formats` | `iceberg` |
| Job parameter `--conf` | `spark.sql.extensions=org.apache.iceberg.spark.extensions.IcebergSparkSessionExtensions` |
| Script arguments | `--metadata-dir …`, `--target-prefix …`, `--staging …`, `--warehouse …`, `--target-table …` |

⚠️ Check that the Iceberg version bundled with your EMR release or Glue version includes the
`rewrite_table_path` **procedure** (it exists as a Java action since 1.7; the Spark procedure came
later). If not, add a newer `iceberg-spark-runtime` and `iceberg-aws-bundle` jar for your Spark
version.

## IAM permissions

| Permission | On |
|---|---|
| `s3:GetObject`, `s3:ListBucket` | Source prefix (original paths) and staging |
| `s3:PutObject` | Target prefix and staging |
| `glue:CreateDatabase`, `glue:GetDatabase`, `glue:CreateTable`, `glue:GetTable`, `glue:DeleteTable`, `glue:UpdateTable` | The temporary and target databases |
| `kms:Decrypt`, `kms:GenerateDataKey` | If the buckets use SSE-KMS |

boto3 must be available on the executors (it is on EMR and Glue).

## After the restore

| Goal | Next step |
|---|---|
| Use it as a standard Iceberg table | Query it in Athena / EMR / Trino as `restored.orders`. Schedule maintenance (compaction, snapshot expiry) yourself |
| Bring it back into Databricks as a **managed** table | Federate Glue into Unity Catalog ([`15-…md`](15-add-foreign-iceberg-table-to-unity-catalog.md)), then `CREATE TABLE uc.sales.orders DEEP CLONE glue_cat.restored.orders` |
| Clean up | Delete the staging folder when the restored table is validated |

## Limits

- ⚠️ **Iceberg v3 tables with deletion vectors:** check that your Iceberg version's `rewrite_table_path` handles them. Otherwise read the table and write a new one with `CREATE TABLE … AS SELECT` (no history).
- The restored table has the **same `table-uuid`** as the source. That's fine for a new Glue table, but don't register it next to the original in the same catalog as if it were a different table.
- The script copies objects one by one per Spark partition. For millions of files, consider S3 Batch Operations with the generated file list.

## Related

- [`23-paths-to-rewrite-when-restoring-to-another-folder.md`](23-paths-to-rewrite-when-restoring-to-another-folder.md): which files contain paths
- [`08-incremental-rewrite-table-path-explained.md`](08-incremental-rewrite-table-path-explained.md): how `rewrite_table_path` works
- [`19-backup-managed-iceberg-with-aws-backup.md`](19-backup-managed-iceberg-with-aws-backup.md): AWS Backup restore scenarios

## Sources

- [Apache Iceberg: Spark procedures (`rewrite_table_path`, `register_table`)](https://iceberg.apache.org/docs/latest/spark-procedures/)
- [Apache Iceberg Javadoc: RewriteTablePath](https://iceberg.apache.org/javadoc/1.11.0/org/apache/iceberg/actions/RewriteTablePath.html)
- [Apache Iceberg: AWS integration (GlueCatalog, S3FileIO)](https://iceberg.apache.org/docs/latest/aws/)
- [Amazon EMR: Use Iceberg with Spark](https://docs.aws.amazon.com/emr/latest/ReleaseGuide/emr-iceberg-use-spark-cluster.html)
- [AWS Glue: Using the Iceberg framework](https://docs.aws.amazon.com/glue/latest/dg/aws-glue-programming-etl-format-iceberg.html)
- [Databricks (archived): OSS Iceberg jars not supported on clusters](https://docs.azure.cn/en-us/databricks/archive/legacy/external-access-iceberg)
