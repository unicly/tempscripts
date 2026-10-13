# Managed Iceberg tables: backup/restore, full and delta replication between AWS and Azure

Summary for **Databricks managed Iceberg tables** (owned by Unity Catalog), with Databricks on
**AWS and Azure** and replication in **both directions** (AWS → Azure and Azure → AWS).

Details are in [`06-managed-iceberg-replication-deep-dive.md`](06-managed-iceberg-replication-deep-dive.md)
and [`11-replication-quick-summary.md`](11-replication-quick-summary.md).

> Based on the Databricks and Apache Iceberg documentation (October 2026). Not tested on real
> tables. ⚠️ marks points that are in preview, unconfirmed, or need a test first.

---

## 1. Basics you need to know

| Point | What it means |
|---|---|
| Unity Catalog owns the metadata | Files can't be registered back into Unity Catalog: no `rewrite_table_path`, no `register_table`, no direct storage-level restore. The files are standard Iceberg, so data can still be **recovered** outside Unity Catalog (§2.3) |
| Every copy goes through Unity Catalog | Either Databricks itself, or an external engine through Unity Catalog's **Iceberg REST catalog** (`/api/2.1/unity-catalog/iceberg-rest`) |
| No change data feed for Iceberg | Deltas need a watermark, Iceberg snapshots (outside Databricks), or an outbox Delta table |
| `DEEP CLONE` is always a full copy | Not incremental for managed Iceberg (unlike Delta) |
| Databricks clusters can't load open-source Iceberg libraries | Snapshot-based delta jobs run on **open-source Spark outside Databricks** |
| Bi-directional = one owner per table | Each table is written only on its owner cloud and copied one way. Copies are read-only. Never replicate a copy back |

---

## 2. Backup and restore

### 2.1 Backup layers

| Layer | Method | Protects against | Notes |
|---|---|---|---|
| 1. In the table | **Time travel** (`VERSION AS OF` / `TIMESTAMP AS OF`) | Bad writes in the last few days | From DBR 18.0, limited by `deletedFileRetentionDuration` (default 7 days) |
| 1. In the table | **`RESTORE TABLE … TO VERSION AS OF`** | Bad writes, roll back in place | Covered for Delta and Iceberg tables by Databricks' table history docs. ⚠️ Managed Iceberg is in preview: test it once |
| 1. In the table | **`UNDROP TABLE`** | Table dropped by mistake | Unity Catalog managed tables, 7 days. ⚠️ Not confirmed for Iceberg |
| 2. Backup catalog | **Dated `DEEP CLONE`** into a separate catalog and storage | Errors found after the retention period | Full copy each time, no history. Keep one copy per date |
| 2. Backup catalog | **Watermark `MERGE`** into a backup table | Same, with less copying | Deletes only with soft deletes |
| 3. Other cloud | **OpenSharing + clone or `MERGE`** on the other cloud | Loss of a workspace, region or cloud | Same mechanism as replication (§3–4) |
| 4. Vault (best option) | **Export to a standard Iceberg table** (Glue / Polaris) in an immutable bucket, with open-source Spark through the REST catalog | Everything above, plus ransomware and deliberate deletion | Incremental (snapshot delta). The vault's own snapshots give point-in-time backups. S3 Object Lock or Azure immutable storage |
| ⚠️ Emergency recovery only | Storage-level backup of the managed storage (S3 versioning, AWS Backup, Azure Blob versioning, soft delete, Azure Backup) | Deleted files, dropped table after the 8-day `UNDROP` window | Not a direct restore: files can't be re-registered in Unity Catalog. Data can be recovered through standard Iceberg and loaded into a **new** managed table (§2.3). Not supported by Databricks |

### 2.2 Restore: which method for which situation

| Situation | Restore with | Command (example) |
|---|---|---|
| Wrong `UPDATE`/`DELETE` within retention | Time travel / `RESTORE` | `RESTORE TABLE prod.sales.orders TO VERSION AS OF 42` |
| Table dropped (≤ 7 days) | `UNDROP` | `UNDROP TABLE prod.sales.orders` ⚠️ |
| Error found after retention | Dated clone | `CREATE OR REPLACE TABLE prod.sales.orders DEEP CLONE backup.sales.orders_20261012` |
| Workspace / region / cloud lost | Copy on the other cloud | Share it back, then `DEEP CLONE` into a new production table |
| Files in managed storage intact (or restored from storage versioning), but table or metastore gone | Emergency recovery through standard Iceberg (§2.3) | PyIceberg `StaticTable.from_metadata("s3://…/metadata/00042-….metadata.json")` or `register_table` in Glue, then load into a new managed table |
| Ransomware, deliberate deletion, metastore lost | Vault (standard Iceberg) | `CREATE TABLE uc.sales.orders DEEP CLONE glue_fed.backup.orders` (via federation), or open-source Spark: read vault → write through the REST catalog |

### 2.3 Emergency recovery from managed storage (without Unity Catalog)

The files in Unity Catalog's managed storage are ordinary Iceberg files (`metadata.json`, manifests,
Parquet, deletion vectors). Only the pointer to the current `metadata.json`, the permissions and the
lineage live in Unity Catalog. ⚠️ Inferred from how the Iceberg REST catalog works, not documented.

| Step | What | Tool |
|---|---|---|
| 1 | Find the table folder in the managed storage location and the **newest complete `metadata.json`** | S3 / ADLS console, CLI |
| 2 | If files were deleted: restore them first | S3 versioning, AWS Backup, Blob versioning / soft delete, Azure Backup |
| 3 | Read the table straight from that `metadata.json`, without Unity Catalog | PyIceberg `StaticTable.from_metadata(...)`, or `register_table` in Glue / a Hadoop catalog with open-source Spark |
| 4 | Load the data into a **new managed table** | Spark or Trino `CREATE TABLE … AS SELECT` through Unity Catalog's REST catalog, or Glue → federation → `DEEP CLONE` into Unity Catalog |
| 5 | Re-apply grants, tags, row filters and column masks. Reset replication watermarks | Databricks |

| Condition / risk | Detail |
|---|---|
| Files must be complete | The `metadata.json` and every manifest and data file it references. Predictive optimization expires snapshots and deletes old files |
| Which version is current | Unknown without Unity Catalog. The highest number is usually it, but a failed commit can leave an orphan. Check that all referenced files exist |
| Dropped tables | Data is deleted 8 days after `DROP`. Afterwards only storage versioning or backup can help |
| Storage access | Needs direct IAM / service principal access to managed storage, which bypasses Unity Catalog governance. Use a break-glass role only |
| Iceberg v3 | The reader must support v3 and deletion vectors |
| Support | Not documented by Databricks. Do a test run before relying on it. For planned backups use the vault (layer 4) |

**After any restore by clone or `CREATE TABLE … AS SELECT`:** it's a **new table** (new ID, history and
snapshot IDs). Re-apply grants, tags, row filters and column masks, and reset replication watermarks
(start with a full copy).

---

## 3. Full replication

| Method | How | Runs on | Notes |
|---|---|---|---|
| **F1. Deep clone from a share** | `CREATE OR REPLACE TABLE tgt DEEP CLONE share_cat.db.tbl` | Databricks SQL / cluster on the **target** cloud (DBR 16.4+) | ⚠️ Deep clone of a *shared* managed Iceberg table isn't explicitly documented. Full copy every run |
| **F2. `CREATE TABLE … AS SELECT` from a share** | `CREATE OR REPLACE TABLE tgt USING ICEBERG AS SELECT * FROM share_cat.db.tbl` | Databricks SQL / cluster on the target cloud | Documented path. Re-apply table properties |
| **F3. External Spark between both REST catalogs** | `spark.table("src_uc.db.t").writeTo("tgt_uc.db.t").createOrReplace()` | Open-source Spark on either cloud | No share needed. The same job can do deltas (D3) |
| **F4. Trino between both REST catalogs** | `CREATE TABLE tgt.db.t AS SELECT * FROM src.db.t` | Trino on either cloud | ⚠️ Storage access on Azure may need its own credentials |
| **F5. PyIceberg** | Read from the source REST catalog, `overwrite()` into the target | Python (serverless functions, containers) | Small or medium tables only |

---

## 4. Delta (incremental) replication

| Method | How changes are found | Deletes | Runs on | Notes |
|---|---|---|---|---|
| **D1. Watermark + `MERGE` on the share** | `updated_at > last watermark` | Only with soft deletes | Databricks SQL on the target cloud | Simplest. SQL only |
| **D2. Version comparison on the share** | Compare `VERSION AS OF <last>` with the current version | ✅ | Databricks SQL on the target cloud | ⚠️ Reads both versions across clouds. Time travel on shared managed Iceberg unconfirmed |
| **D3. Snapshot delta through the REST catalog** | `create_changelog_view` between snapshot IDs, then `MERGE` | ✅ | Open-source Spark (outside Databricks) | Only changed files cross clouds. ⚠️ Needs a test. Keep tables on Iceberg v2 |
| **D4. Outbox Delta table with change data feed** | Producer also writes changes into a Delta table with change data feed, shares it. Target streams `readChangeFeed` → `MERGE` | ✅ | Databricks on both clouds | Fully documented. Requires changing the producer |
| **D5. Trino watermark `MERGE`** | `updated_at > last watermark` | Only with soft deletes | Trino | SQL only, outside Databricks |
| **D6. Flink incremental read** | New snapshots, append-only | ❌ | Flink | Near real time for append-only tables |

---

## 5. Technologies available on AWS and Azure

| Purpose | AWS | Azure |
|---|---|---|
| **Databricks** (source and target, SQL, clone, `MERGE`, sharing) | Databricks on AWS | Azure Databricks |
| **Sharing between the clouds** | OpenSharing (Databricks to Databricks) | OpenSharing (Databricks to Databricks) |
| **Scheduling inside Databricks** | Lakeflow Jobs | Lakeflow Jobs |
| **Declarative pipelines** | Lakeflow Declarative Pipelines (materialized view `USING ICEBERG`) ⚠️ incremental refresh unconfirmed | Same |
| **Streaming (D4)** | Databricks Structured Streaming | Databricks Structured Streaming |
| **Open-source Spark** (F3, D3, vault) | Amazon EMR, EMR Serverless, AWS Glue ETL (Spark), self-hosted on EKS | HDInsight (Spark), Azure Synapse Spark ⚠️, Microsoft Fabric Spark ⚠️, self-hosted on AKS |
| **Trino** (F4, D5) | Amazon EMR (Trino), Starburst Galaxy/Enterprise, self-hosted on EKS | Starburst Galaxy/Enterprise, self-hosted on AKS |
| **Flink** (D6) | Amazon Managed Service for Apache Flink, EMR (Flink) | HDInsight (Flink) ⚠️, self-hosted on AKS |
| **PyIceberg** (F5, emergency recovery §2.3) | AWS Lambda, ECS/Fargate | Azure Functions, Azure Container Apps |
| **Orchestration outside Databricks** | Amazon MWAA (Airflow), Step Functions | Azure Data Factory, Fabric Data Factory |
| **Vault catalog** (backup layer 4) | AWS Glue Data Catalog (can be federated into Unity Catalog, read-only) | Hive Metastore (federable) or Apache Polaris / Lakekeeper (not federable) |
| **Immutable vault storage** | S3 Object Lock | Azure Blob immutable storage |
| **Storage-level backup (emergency recovery via standard Iceberg, §2.3)** | S3 versioning, AWS Backup for S3 | Blob versioning, soft delete, Azure Backup for blobs |
| **Not usable to replicate managed Iceberg** | S3 replication, DataSync, `rewrite_table_path` | AzCopy, Data Factory file copy, `rewrite_table_path` |

⚠️ For Synapse Spark, Fabric Spark and HDInsight Flink, check that you can load the open-source Iceberg
runtime and configure a REST catalog with the Unity Catalog endpoint.

---

## 6. Per direction

### 6.1 AWS → Azure (table owned on AWS)

| Step | Where | What |
|---|---|---|
| Share | Databricks on AWS (provider) | `CREATE SHARE aws_to_azure; ALTER SHARE aws_to_azure ADD TABLE sales.orders;` and add the Azure metastore as recipient |
| Mount | Azure Databricks (recipient) | Create catalog `aws_share` from the share |
| Full copy | Azure Databricks | F1 / F2 into `replica_aws.sales.orders` |
| Delta | Azure Databricks (D1, D4), or open-source Spark/Trino on either cloud (D3, D5) | Scheduled with Lakeflow Jobs, ADF or Airflow |
| Egress | Billed by **AWS** | Only the bytes read (once per refresh, not per query) |
| Backup of the replica | Azure | Not needed if AWS is the owner. Back up the source on AWS (§2) |

### 6.2 Azure → AWS (table owned on Azure)

| Step | Where | What |
|---|---|---|
| Share | Azure Databricks (provider) | `CREATE SHARE azure_to_aws; ALTER SHARE azure_to_aws ADD TABLE finance.invoices;` and add the AWS metastore as recipient |
| Mount | Databricks on AWS (recipient) | Create catalog `azure_share` from the share |
| Full copy | Databricks on AWS | F1 / F2 into `replica_azure.finance.invoices` |
| Delta | Databricks on AWS (D1, D4), or open-source Spark/Trino on either cloud (D3, D5) | Scheduled with Lakeflow Jobs, MWAA or Step Functions |
| Egress | Billed by **Azure** | Only the bytes read |
| Backup of the replica | AWS | Not needed if Azure is the owner. Back up the source on Azure (§2) |

### 6.3 Rules for both directions

| Rule | Why |
|---|---|
| One owner cloud per table | Two writable copies diverge, and no tool merges them |
| Replicas in their own catalog or schema (`replica_aws`, `replica_azure`) | They're never mistaken for owned tables |
| Never add a replica to an outgoing share | Prevents copy loops |
| One service principal per direction | `SELECT` on the source or share, `MODIFY` on the replica |
| Sync more often than the source's retention | Snapshot/version-based deltas need the old version to still exist |

---

## 7. Recommendation

| Need | Use |
|---|---|
| Simple replication, SQL only | **F2** once, then **D1** watermark `MERGE`, with Lakeflow Jobs on the target cloud |
| Deletes must come through, producer can change | **D4** outbox Delta table with change data feed |
| Deletes must come through, producer can't change | **D3** open-source Spark through both REST catalogs (test first) |
| Backups | Time travel + `UNDROP` for daily mistakes, plus **an incremental export to an immutable standard Iceberg vault**. Dated deep clones as a simpler fallback |
| Lowest effort overall | Consider **managed Delta with Iceberg reads (UniForm)**: incremental deep clone, change data feed and mature `RESTORE` |

---

## Sources

- [Databricks: Unity Catalog managed tables (Delta and Iceberg)](https://docs.databricks.com/aws/tables/managed)
- [Databricks: What is Apache Iceberg in Databricks?](https://docs.databricks.com/aws/en/iceberg/)
- [Databricks: Use Apache Iceberg v3 features](https://docs.databricks.com/aws/en/iceberg/iceberg-v3)
- [Databricks: Clone a managed Iceberg table](https://learn.microsoft.com/en-us/azure/databricks/iceberg/clone)
- [Databricks: CREATE TABLE CLONE](https://docs.databricks.com/aws/en/sql/language-manual/delta-clone)
- [Databricks: Work with table history](https://docs.databricks.com/aws/en/tables/history)
- [Databricks: Access Databricks tables from Apache Iceberg clients](https://learn.microsoft.com/en-us/azure/databricks/external-access/iceberg)
- [Databricks: What is OpenSharing?](https://docs.databricks.com/aws/en/opensharing/)
- [Databricks: Read data shared using Databricks-to-Databricks OpenSharing](https://docs.databricks.com/aws/en/opensharing/read-data-databricks)
- [Databricks: Monitor and manage sharing egress costs](https://docs.databricks.com/en/data-sharing/manage-egress)
- [Databricks: Use change data feed](https://docs.databricks.com/aws/en/tables/features/change-data-feed)
- [Databricks: CREATE MATERIALIZED VIEW (pipelines)](https://docs.databricks.com/aws/en/ldp/developer/ldp-sql-ref-create-materialized-view)
- [Databricks Community: Backup Unity Catalog and managed tables](https://community.databricks.com/t5/data-governance/backup-unity-catalog-and-managed-tables/m-p/18707)
- [Apache Iceberg: Spark procedures](https://iceberg.apache.org/docs/latest/spark-procedures/)
