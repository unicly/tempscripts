# Standard Iceberg tables: backup/restore, full and delta replication between AWS and Azure

Summary for **standard (open-source) Iceberg tables**, owned by your own catalog (for example AWS
Glue, Hive Metastore, Apache Polaris, Lakekeeper), with data in S3 and ADLS Gen2, and replication
in **both directions** (AWS → Azure and Azure → AWS). Databricks runs on both clouds, but can only
read these tables.

Same structure as the managed Iceberg summary:
[`12-managed-iceberg-summary-aws-azure.md`](12-managed-iceberg-summary-aws-azure.md).
Details are in [`07-standard-iceberg-replication-deep-dive.md`](07-standard-iceberg-replication-deep-dive.md)
and [`08-incremental-rewrite-table-path-explained.md`](08-incremental-rewrite-table-path-explained.md).

> Based on the Apache Iceberg and Databricks documentation (October 2026). Not tested on real
> tables. ⚠️ marks points that are in preview, unconfirmed, or need a test first.

---

## 1. Basics you need to know

| Point | What it means |
|---|---|
| Your catalog owns the metadata | You choose the catalog and table location. Files **can** be copied and registered (`register_table`) |
| Paths in metadata are absolute (`s3://…`) | Copying files to another cloud needs `rewrite_table_path` to rewrite the paths |
| Exact copies with history are possible | `rewrite_table_path` + file copy + `register_table` keeps all snapshots and time travel |
| Iceberg Spark procedures run on **open-source Spark** | `rewrite_table_path`, `create_changelog_view`, `rollback_to_snapshot`… don't run on Databricks clusters |
| Databricks can only read | And only if the catalog is Glue, Hive Metastore or Snowflake Horizon (foreign tables via federation) |
| You run the maintenance | Compaction, snapshot expiry and orphan cleanup are your job. Retention must cover your sync and backup needs |
| Glue only exists on AWS | Azure needs another catalog (Hive Metastore, Polaris, Lakekeeper), or one shared REST catalog for both clouds |
| Bi-directional = one owner per table | Each table is written only on its owner cloud and copied one way. Copies are read-only. Never replicate a copy back |

---

## 2. Backup and restore

### 2.1 Backup layers

| Layer | Method | Protects against | Notes |
|---|---|---|---|
| 1. In the table | **Time travel** (`VERSION AS OF` snapshot ID / `TIMESTAMP AS OF`) | Bad writes within snapshot retention | Retention is set by your `expire_snapshots` policy |
| 1. In the table | **Rollback** (`rollback_to_snapshot`, `rollback_to_timestamp`, `set_current_snapshot`) | Bad writes, roll back in place | Iceberg Spark procedures. Mature |
| 1. In the table | **Tags** (`ALTER TABLE … CREATE TAG daily_20261012 RETAIN 90 DAYS`) | Keep chosen snapshots longer than normal expiry | Cheap point-in-time "backups" in the same table. Files stay in the same bucket |
| 1. In the table | **`DROP TABLE` without `PURGE`** + `register_table` | Table dropped by mistake | Without `PURGE`, the files stay. Re-register the last `metadata.json` |
| 2. Storage | **S3 versioning / Object Lock, Azure Blob versioning / soft delete / immutable storage** | Deleted or overwritten files | **Usable** here (unlike managed Iceberg): restore the files, then `register_table` |
| 3. Exact copy (backup bucket or other cloud) | **`rewrite_table_path` + file copy + `register_table`**, incremental | Loss of a bucket, account, region or cloud | Keeps all snapshots. The copy can be put in an immutable bucket |
| 3. Logical copy | Spark / Trino `CREATE TABLE … AS SELECT`, or changelog `MERGE`, into a backup table | Same, simpler | No source history. The backup table builds its own snapshots |
| 4. Into Databricks | `DEEP CLONE` of the foreign table into Unity Catalog | Need a governed copy in Databricks | Full copy. Becomes managed Iceberg (or Delta with clone-to-Delta) |

### 2.2 Restore: which method for which situation

| Situation | Restore with | Command (example) |
|---|---|---|
| Wrong `UPDATE`/`DELETE` within retention | Rollback | `CALL cat.system.rollback_to_snapshot('sales.orders', 5123)` |
| Need yesterday's state, beyond normal retention | Tag | `CALL cat.system.set_current_snapshot(table => 'sales.orders', ref => 'daily_20261012')` |
| Table dropped (not purged) | Re-register | `CALL cat.system.register_table('sales.orders', 's3://…/metadata/00042-….metadata.json')` |
| Files deleted or overwritten | Storage versioning, then re-register | Restore object versions (S3 / Blob), then `register_table` |
| Bucket, region or cloud lost | Exact copy | `register_table` on the copy, or `rewrite_table_path` back to a new location and copy |
| Ransomware / deliberate deletion | Immutable copy | Same as above, from the Object Lock / immutable bucket |

**Note:** restoring with `register_table` or a rollback keeps snapshot IDs and history, so replication
watermarks stay valid. A restore by `CREATE TABLE … AS SELECT` creates a new table and needs a new
full sync.

---

## 3. Full replication

| Method | How | Runs on | Keeps history? | Notes |
|---|---|---|---|---|
| **F1. Exact copy** | `rewrite_table_path` (all versions) → copy file list → `register_table` | Open-source Spark + copy tool | ✅ | Byte-identical. Replica must stay read-only |
| **F2. Spark `CREATE TABLE … AS SELECT`** | `spark.table("aws.db.t").writeTo("az.db.t").createOrReplace()` | Open-source Spark with both catalogs | ❌ | Simplest. Rewrites everything |
| **F3. Trino `CREATE TABLE … AS SELECT`** | `CREATE TABLE az.db.t AS SELECT * FROM aws.db.t` | Trino with two Iceberg catalogs | ❌ | SQL only |
| **F4. PyIceberg** | Read source, `overwrite()` target | Python | ❌ | Small or medium tables |
| **F5. Into Databricks** | `DEEP CLONE` of the federated foreign table | Databricks | ❌ | Copy becomes managed Iceberg, no longer standard |
| **F6. Clone to Delta** | `CREATE OR REPLACE TABLE … DEEP CLONE iceberg.\`path\`` | Databricks | ❌ | Copy becomes Delta. ⚠️ Preview. Re-runs are incremental |

---

## 4. Delta (incremental) replication

| Method | How changes are found | Deletes | Keeps history? | Runs on | Notes |
|---|---|---|---|---|---|
| **D1. Incremental exact copy** | `rewrite_table_path` from the last copied `metadata.json` → copy new files → move the catalog pointer → orphan cleanup on the copy | ✅ | ✅ | Open-source Spark + copy tool | Only new files cross clouds. See doc 08 |
| **D2. Changelog + `MERGE`** | `create_changelog_view` between snapshot IDs, `net_changes => true` | ✅ (needs a key) | ❌ | Open-source Spark with both catalogs | See doc 04 |
| **D3. Incremental append read** | `start-snapshot-id` / `end-snapshot-id` → append | ❌ (append-only) | ❌ | Open-source Spark | Simplest for event data |
| **D4. Flink streaming** | Continuous snapshot reads | ❌ (append-only) | ❌ | Flink | Near real time |
| **D5. Watermark `MERGE`** | `updated_at > last watermark` | Only with soft deletes | ❌ | Trino, Spark, PyIceberg (`upsert`) | SQL only possible |
| **D6. Databricks clone to Delta** | Re-run `DEEP CLONE iceberg.\`path\`` | ✅ | ❌ | Databricks | Target is Delta. ⚠️ Preview |

---

## 5. Technologies available on AWS and Azure

| Purpose | AWS | Azure |
|---|---|---|
| **Iceberg catalog** | AWS Glue Data Catalog, Hive Metastore (EMR or self-hosted), Apache Polaris / Snowflake Open Catalog, Lakekeeper, Nessie | Hive Metastore (HDInsight or self-hosted), Apache Polaris / Snowflake Open Catalog, Lakekeeper, Nessie |
| **Catalog shared by both clouds (optional)** | Polaris / Lakekeeper / Nessie reachable from both clouds | Same |
| **Open-source Spark** (`rewrite_table_path`, changelog, rollback) | Amazon EMR, EMR Serverless, AWS Glue ETL (Spark), self-hosted on EKS | HDInsight (Spark), Azure Synapse Spark ⚠️, Microsoft Fabric Spark ⚠️, self-hosted on AKS |
| **Trino** (F3, D5) | Amazon EMR (Trino), Amazon Athena (Glue catalog) ⚠️, Starburst Galaxy/Enterprise, self-hosted on EKS | Starburst Galaxy/Enterprise, self-hosted on AKS |
| **Flink** (D4) | Amazon Managed Service for Apache Flink, EMR (Flink) | HDInsight (Flink) ⚠️, self-hosted on AKS |
| **PyIceberg** (F4, D5, `register_table`) | AWS Lambda, ECS/Fargate | Azure Functions, Azure Container Apps |
| **Cross-cloud file copy** (F1, D1) | AWS DataSync (Azure Blob as source or destination), rclone, DistCp on EMR | AzCopy (S3 as source), Azure Data Factory copy activity, rclone, DistCp on HDInsight |
| **Same-cloud copy (backup bucket, other region)** | S3 Replication (CRR/SRR), S3 Batch Operations, DataSync | Object replication, AzCopy, Data Factory |
| **Orchestration** | Amazon MWAA (Airflow), Step Functions, Lakeflow Jobs (Databricks) | Azure Data Factory, Fabric Data Factory, Lakeflow Jobs (Databricks) |
| **Storage protection** | S3 versioning, S3 Object Lock, AWS Backup for S3 | Blob versioning, soft delete, immutable storage, Azure Backup for blobs |
| **Databricks access** | Read-only via federation (Glue, Hive Metastore). Deep clone into Unity Catalog | Read-only via federation (Hive Metastore. ⚠️ Glue federation from Azure Databricks unconfirmed). Deep clone into Unity Catalog |
| **Sharing** | OpenSharing of federated foreign tables ⚠️ Private Preview | Same |

⚠️ For Synapse Spark, Fabric Spark, HDInsight Flink and Athena, check that the Iceberg version and
procedures you need (`rewrite_table_path`, `create_changelog_view`, `register_table`) are available.

---

## 6. Per direction

### 6.1 AWS → Azure (table owned on AWS, for example in Glue)

| Step | Where | What |
|---|---|---|
| Catalogs | AWS: Glue. Azure: Polaris / Lakekeeper / Hive Metastore (or one shared REST catalog) | Replica namespace `replica_aws` on Azure |
| Full copy (exact) | Open-source Spark on AWS (EMR) + AzCopy / DataSync | `rewrite_table_path` → copy to `abfss://…/replica_aws/…` → `register_table` in the Azure catalog |
| Full copy (simple) | Open-source Spark or Trino with both catalogs | F2 / F3 |
| Delta | EMR (D1, D2, D3) or Trino (D5) or Flink (D4) | Scheduled with MWAA, Step Functions or Lakeflow Jobs |
| Credentials | Read S3 (data + staging), write ADLS | IAM role + Azure service principal or SAS |
| Egress | Billed by **AWS** | Only new or changed files |
| Visible in Azure Databricks | Only if the Azure catalog is Hive Metastore (read-only) | Otherwise use open-source engines, or deep clone into Unity Catalog |

### 6.2 Azure → AWS (table owned on Azure, for example in Polaris)

| Step | Where | What |
|---|---|---|
| Catalogs | Azure: Polaris / Lakekeeper / Hive Metastore. AWS: Glue (or the shared REST catalog) | Replica namespace `replica_azure` on AWS |
| Full copy (exact) | Open-source Spark on Azure (HDInsight / Synapse / Fabric ⚠️) + AzCopy / DataSync / ADF | `rewrite_table_path` → copy to `s3://…/replica_azure/…` → `register_table` in Glue |
| Full copy (simple) | Open-source Spark or Trino with both catalogs | F2 / F3 |
| Delta | Spark on Azure (D1, D2, D3), Trino (D5) or Flink (D4) | Scheduled with ADF, Fabric Data Factory or Lakeflow Jobs |
| Credentials | Read ADLS (data + staging), write S3 | Azure service principal + IAM role |
| Egress | Billed by **Azure** | Only new or changed files |
| Visible in Databricks on AWS | ✅ read-only, if the replica is registered in Glue | Federation of the Glue catalog |

### 6.3 Rules for both directions

| Rule | Why |
|---|---|
| One owner cloud per table | Two writable copies diverge, and no tool merges them |
| Replicas are read-only | Any write on the copy breaks the next incremental exact copy (D1) |
| Replicas in their own location and namespace (`replica_aws`, `replica_azure`) | Never mistaken for owned tables |
| Never use a replica as a replication source | Prevents copy loops |
| Same `target_prefix` on every run (D1) | Earlier paths must keep matching |
| Source keeps metadata versions and snapshots longer than the sync interval | `write.metadata.previous-versions-max` and `expire_snapshots` must leave the last synced version |
| Orphan cleanup on the replica only, no `expire_snapshots` there | Snapshot expiry happens on the source and arrives with the next sync |
| Credentials for both storage accounts per direction | The copy job reads one cloud and writes the other |

---

## 7. Recommendation

| Need | Use |
|---|---|
| Exact, auditable replica with time travel | **F1** once, then **D1** incremental exact copy |
| Simple keyed tables, replica may have its own history | **F2** once, then **D2** changelog `MERGE` |
| Append-only event data | **D3** incremental append, or **D4** Flink for near real time |
| SQL-only team | **F3** + **D5** with Trino (soft deletes for deletes) |
| Backups | Rollback + tags for daily mistakes, storage versioning on the buckets, and an **incremental exact copy into an immutable bucket** (on the other cloud or another region) |
| Data must be governed in Databricks | Deep clone into Unity Catalog (it becomes managed Iceberg: see doc 12) |

---

## Sources

- [Apache Iceberg: Spark procedures (`rewrite_table_path`, `register_table`, `rollback_to_snapshot`, `create_changelog_view`, `remove_orphan_files`)](https://iceberg.apache.org/docs/latest/spark-procedures/)
- [Apache Iceberg: Maintenance](https://iceberg.apache.org/docs/latest/maintenance/)
- [Apache Iceberg: Spark queries (time travel, tags)](https://iceberg.apache.org/docs/latest/spark-queries/)
- [Apache Iceberg Javadoc: RewriteTablePath](https://iceberg.apache.org/javadoc/1.11.0/org/apache/iceberg/actions/RewriteTablePath.html)
- [Dremio: Disaster recovery for Iceberg tables (rewrite_table_path walkthrough)](https://www.dremio.com/blog/disaster-recovery-for-apache-iceberg-tables-restoring-from-backup-and-getting-back-online/)
- [Apache Polaris documentation](https://polaris.apache.org/docs/overview)
- [Multi-cloud Polaris REST catalog topologies](https://iceberglakehouse.com/posts/multi-cloud-polaris-rest-catalog-topologies/)
- [AWS DataSync: CreateLocationAzureBlob](https://docs.aws.amazon.com/datasync/latest/userguide/API_CreateLocationAzureBlob.html)
- [Databricks: Incrementally clone Parquet and Iceberg tables to Delta Lake](https://docs.databricks.com/en/ingestion/data-migration/clone-parquet.html)
- [Databricks: Work with foreign tables](https://learn.microsoft.com/en-us/azure/databricks/tables/foreign)
- [Azure Databricks: Iceberg (foreign catalogs)](https://docs.azure.cn/en-us/databricks/iceberg/)
- [Trino issue #25499: rewrite_table_path in the Iceberg connector](https://github.com/trinodb/trino/issues/25499)
