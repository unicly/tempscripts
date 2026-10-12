# Deep dive: replicating standard Iceberg tables between AWS and Azure

Part 2 of the detailed comparison. Part 1 covers Databricks managed Iceberg:
[`06-managed-iceberg-replication-deep-dive.md`](06-managed-iceberg-replication-deep-dive.md).
The overview is in [`05-cross-cloud-replication-aws-azure.md`](05-cross-cloud-replication-aws-azure.md).

Setup: open-source Apache Iceberg tables, with metadata owned by a catalog **you** run or choose
(not Unity Catalog). Data lives in S3 and ADLS Gen2. Databricks runs on both clouds. Data is
replicated in **both directions**, with one owner cloud per table.

> Status: researched October 2026 from Apache Iceberg docs, Databricks docs and vendor blogs.
> ⚠️ marks points that are unverified, version dependent or documented only by third parties.
> Test each option in a POC before you rely on it.

Legend: ✅ supported · ❌ not supported · ⚠️ partial, preview or unverified

---

## 1. What makes standard Iceberg different (recap)

The full comparison is in §1 of [`06-…md`](06-managed-iceberg-replication-deep-dive.md#1-what-makes-a-managed-iceberg-table-different-from-a-standard-iceberg-table).
This table lists only the differences that change how you replicate:

| Aspect | Standard Iceberg | Databricks managed Iceberg | Why it matters for replication |
|---|---|---|---|
| Catalog | Your choice: Glue, HMS, Polaris, Lakekeeper, Nessie, Hadoop… | Unity Catalog only | You choose the topology: one catalog per cloud, or one shared catalog |
| Table location | You choose it | Chosen by UC | You can place replicas wherever you want |
| `register_table` (register an existing `metadata.json`) | ✅ | ❌ | **File-level replication is possible**: copy files, then register them |
| `rewrite_table_path` (rewrite absolute paths s3:// → abfss://) | ✅ | ❌ | You get an exact replica **with snapshot history** |
| Full Iceberg Spark procedures (`create_changelog_view`, `expire_snapshots`…) | ✅ on any Spark with the Iceberg runtime | ❌ on Databricks clusters (no OSS Iceberg jars) | Snapshot-based delta jobs run on OSS Spark, not on Databricks |
| Partition transforms, all delete types, all data types | ✅ | ❌ / limited | No layout restrictions |
| Maintenance | **You** schedule compaction, snapshot expiry and orphan cleanup | Automatic | Snapshot expiry must leave enough history for incremental sync |
| Storage credentials | You configure IAM roles, SAS or service principals (or vending, if the REST catalog supports it) | Vended by UC | Cross-cloud access needs credentials for **both** storage accounts |
| Visible in Unity Catalog | Only if the catalog is Glue, HMS or Snowflake Horizon (federation), and **read-only** | ✅ read/write | Databricks can read replicas, but can't write them |

---

## 2. Catalog topology: decide this first

| Topology | How | Replication needed? | Pros | Cons |
|---|---|---|---|---|
| **T1. One catalog per cloud** (for example Glue on AWS, Polaris or Lakekeeper on Azure) | Each cloud has its own catalog and storage. Replicas are registered in the other cloud's catalog | ✅ | Each cloud stays independent. Local reads | Two catalogs to run. Replication pipeline for each direction |
| **T2. One shared REST catalog** (for example Polaris, reachable from both clouds) | One catalog. Each table's data is in its owner cloud's storage. Replicas are separate tables (other namespace and location) in the same catalog | ✅ for local copies, or ❌ if remote reads are acceptable | One namespace for everything. Remote writes to the owner table are possible | Catalog availability and latency across clouds. Cross-cloud egress if not replicated |

Catalog options for the Azure side (Glue exists only on AWS):

| Catalog | Type | Runs on | Unity Catalog federation | Notes |
|---|---|---|---|---|
| AWS Glue Data Catalog | Managed (AWS) | AWS only | ✅ (read-only foreign tables). ⚠️ Glue federation from **Azure** Databricks is unconfirmed | Native for AWS. Not available on Azure |
| Hive Metastore | Self-hosted | Anywhere | ✅ (read-only) | Legacy, but federable |
| Apache Polaris (or Snowflake Open Catalog) | Iceberg REST, OSS or managed | Anywhere | ❌ (generic REST not federable) | Top-level Apache project. Supports S3, ADLS and GCS. Credential vending |
| Lakekeeper, Nessie, Gravitino | Iceberg REST, OSS | Anywhere | ❌ | Nessie features are being merged into Polaris |
| Hadoop / path-based catalog | Files only | — | ❌ | No locking. Avoid for concurrent writers |

**Note:** if Databricks has to see standard Iceberg tables on **both** clouds, use Glue on AWS and
HMS on Azure, since only those are federable. They will still be read-only in Databricks.

---

## 3. Building blocks

| # | Building block | What it does | Where it runs |
|---|---|---|---|
| B1 | **`rewrite_table_path`** (Iceberg Spark procedure / action) | Writes a copy of the table's metadata (all versions, or a range from `start_version` to `end_version`) to a staging location, with the source path prefix replaced by the target prefix. Returns the latest rewritten `metadata.json` and a **file list** (CSV of source → target) of everything to copy | OSS Spark with the Iceberg runtime ⚠️ check your Iceberg version for the procedure |
| B2 | **File copy tools** | Physically copy the data files and the staged metadata files from the file list: AzCopy (S3 → Azure Blob/ADLS), AWS DataSync (Azure Blob as source or destination, SAS auth, agentless), Azure Data Factory copy activity, rclone, Hadoop DistCp | Either cloud |
| B3 | **`register_table`** | Registers an existing `metadata.json` as a table in the target catalog | Spark procedure, or the catalog API (REST `register`, Glue) |
| B4 | **Iceberg changelog view / incremental read** | `create_changelog_view`, or `start-snapshot-id`/`end-snapshot-id` reads, return only what changed between snapshots (see [`04-…md`](04-incremental-prod-to-dev-sync.md)) | OSS Spark |
| B5 | **Multi-catalog compute** | One job that sees both catalogs: Spark with two `SparkCatalog` entries (`S3FileIO` + `ADLSFileIO`, AWS and Azure bundles), a Trino instance with two Iceberg catalogs, or PyIceberg with two catalogs | OSS Spark, Trino, PyIceberg, Flink |
| B6 | **Databricks Lakehouse Federation** | Shows Glue or HMS tables in UC as **read-only** foreign tables | Databricks (DBR 16.4+) |
| B7 | **Databricks clone Iceberg → Delta** | `DEEP`/`SHALLOW CLONE` of an Iceberg table into **Delta**, re-runnable incrementally. One-way only | Databricks (⚠️ Public Preview, DBR 11.3+). The target becomes Delta, not standard Iceberg |

---

## 4. Full replication (initial load or periodic refresh)

| Method | How | Engine | Keeps snapshot history? | Target format | Pros | Cons |
|---|---|---|---|---|---|---|
| **F1. File copy + `rewrite_table_path` + `register_table`** | Rewrite all metadata to the target prefix, copy the file list, then register | OSS Spark + copy tool | ✅ **exact replica** (all snapshots, time travel) | Standard Iceberg | Byte-identical data. Same snapshot IDs on both sides, which makes it easy to check the replica is complete | Multi-step pipeline. The replica must stay read-only |
| **F2. Spark CTAS between catalogs** | `spark.table("aws.db.t").writeTo("az.db.t").createOrReplace()` | OSS Spark (B5) | ❌ (new history) | Standard Iceberg | Simplest. Can repartition or filter | Rewrites everything each run |
| **F3. Trino CTAS** | `CREATE TABLE az.db.t AS SELECT * FROM aws.db.t` | Trino with two Iceberg catalogs | ❌ | Standard Iceberg | SQL only, no Spark | Rewrites everything |
| **F4. PyIceberg** | `tgt.overwrite(src.scan().to_arrow())` (in batches) | Python | ❌ | Standard Iceberg | No cluster | Small or medium tables only |
| **F5. Databricks deep clone of a foreign table** | `CREATE TABLE uc.db.t DEEP CLONE glue_fed.db.t` | Databricks | ❌ | **UC managed** Iceberg | Brings the table under UC governance | The replica is no longer standard Iceberg. Full copy each time |
| **F6. Databricks clone to Delta** | `CREATE OR REPLACE TABLE uc.db.t DEEP CLONE iceberg.\`abfss://…/t\`` | Databricks | ❌ | **Delta** | Later runs are incremental (B7) | Target is Delta. ⚠️ Preview. Partition evolution not supported |

### F1 step by step (AWS → Azure)

```sql
-- 1. OSS Spark with catalog "aws" (Glue/REST on AWS) – rewrite metadata to Azure paths
CALL aws.system.rewrite_table_path(
  table            => 'sales.orders',
  source_prefix    => 's3://lake-aws/warehouse/sales/orders',
  target_prefix    => 'abfss://lake@acctazure.dfs.core.windows.net/replica_aws/sales/orders',
  staging_location => 's3://lake-aws/_replication/staging/orders/run-0001/'
);
-- returns: latest_version (rewritten metadata.json), file_list_location (CSV: source,target)
```

```bash
# 2. Copy every file in the file list. Data files come from the source table, rewritten metadata from staging.
#    Copy data and manifests first and the metadata.json last, so readers never see a table with missing files.
azcopy copy "https://lake-aws.s3.<region>.amazonaws.com/<key>" "https://acctazure.blob.core.windows.net/lake/<path>"   # per file or via --list-of-files
```

```sql
-- 3. Register in the Azure catalog ("az")
CALL az.system.register_table(
  table         => 'replica_aws.orders',
  metadata_file => 'abfss://lake@acctazure.dfs.core.windows.net/replica_aws/sales/orders/metadata/00042-….metadata.json'
);
```

---

## 5. Delta (incremental) replication

| Method | Detection | Captures deletes? | Keeps history? | Engine | Cross-cloud traffic | Complexity | Maturity |
|---|---|---|---|---|---|---|---|
| **D1. Incremental `rewrite_table_path`** | Metadata versions between the last copied `metadata.json` (`start_version`) and the current one | ✅ (deletes are new snapshots) | ✅ exact | OSS Spark + copy tool | **Only new files** | Medium–high | ✅ Iceberg feature. ⚠️ pointer update and cleanup are up to you (see below) |
| **D2. Changelog view + `MERGE`** | `create_changelog_view` between snapshot IDs, `net_changes => true` (see [`04-…md`](04-incremental-prod-to-dev-sync.md)) | ✅ (needs a key) | ❌ | OSS Spark (B5) | Only changed data files | Medium | ✅ (⚠️ check changelog support for merge-on-read deletes in your Iceberg version) |
| **D3. Incremental append read** | `start-snapshot-id` / `end-snapshot-id` read + `append` | ❌ (append-only tables) | ❌ | OSS Spark | Only new files | Low | ✅ |
| **D4. Flink streaming incremental read** | Continuous snapshot-by-snapshot read from the source, written to the target catalog | ❌ (append-only) | ❌ | Apache Flink | Only new files | Medium | ✅ near real time |
| **D5. Watermark + `MERGE`** | `updated_at > last watermark` | ❌ (only with soft deletes) | ❌ | Trino, Spark or PyIceberg (`upsert`) | Files that pass pruning | Low | ✅ |
| **D6. Databricks incremental clone to Delta** | Re-run `CREATE OR REPLACE … DEEP CLONE iceberg.\`path\`` | ✅ | ❌ | Databricks | Only new files | Low | ⚠️ Preview. Target is **Delta** |

### D1 in detail: incremental file-level replication

For a step-by-step explanation with a worked example, see
[`08-incremental-rewrite-table-path-explained.md`](08-incremental-rewrite-table-path-explained.md).

| Step | What | Notes |
|---|---|---|
| 1 | Read the state: last replicated `metadata.json` name (store it, for example as a target table property or in a control table) | Like the watermark in `04-…md` |
| 2 | `rewrite_table_path(..., start_version => '<last>.metadata.json', end_version => <current>)` | Only the new metadata versions are rewritten. The file list has only the files added since then |
| 3 | Copy data files and manifests, **then** the `metadata.json` files | Order matters for readers of the replica |
| 4 | Point the target catalog at the new `metadata.json` | `register_table` fails if the table exists. Options: Glue: update the table's `metadata_location` parameter. REST catalogs: drop the table **without purge** and register again (a short gap for readers) ⚠️ |
| 5 | Clean up the target | Files the source deletes (`expire_snapshots`, compaction) are **not** deleted on the target. Run `remove_orphan_files` on the replica (it doesn't commit new metadata) or delete files the source no longer references ⚠️ |
| 6 | Store the new `metadata.json` name | |

**Rules for D1:**
- **The replica must be read-only.** Any commit on the target creates metadata the next incremental run doesn't know about.
- **The source must keep its metadata versions.** `write.metadata.previous-versions-max` and `expire_snapshots` must retain everything back to the last replicated version. Otherwise, do a new full copy (F1).
- **One replica location per direction.** Never replicate a replica back.

### D2 example: changelog + MERGE across clouds (OSS Spark)

```python
spark = (SparkSession.builder
  .config("spark.sql.extensions", "org.apache.iceberg.spark.extensions.IcebergSparkSessionExtensions")
  .config("spark.sql.catalog.aws", "org.apache.iceberg.spark.SparkCatalog")
  .config("spark.sql.catalog.aws.type", "glue")                       # or rest/hive
  .config("spark.sql.catalog.aws.io-impl", "org.apache.iceberg.aws.s3.S3FileIO")
  .config("spark.sql.catalog.az", "org.apache.iceberg.spark.SparkCatalog")
  .config("spark.sql.catalog.az.type", "rest")                        # e.g. Polaris/Lakekeeper on Azure
  .config("spark.sql.catalog.az.uri", "https://<catalog-host>/api/catalog")
  .config("spark.sql.catalog.az.io-impl", "org.apache.iceberg.azure.adlsv2.ADLSFileIO")
  .getOrCreate())
# then the same flow as in 04-incremental-prod-to-dev-sync.md, with PROD = aws.sales.orders and DEV = az.replica_aws.orders
```

---

## 6. "Only Spark jobs?" All replication tools for standard Iceberg

No. Standard Iceberg has **more** options than managed Iceberg, because files can be copied and
registered directly.

| Tool | Full | Delta | Exact replica (history) | Runs on | Notes |
|---|---|---|---|---|---|
| **OSS Apache Spark** (EMR, Glue ETL, HDInsight, AKS, Synapse/Fabric Spark) | ✅ F1, F2 | ✅ D1, D2, D3 | ✅ (D1) | Outside Databricks | The only engine with `rewrite_table_path` and `create_changelog_view` |
| **AzCopy / AWS DataSync / Azure Data Factory / rclone / DistCp** | ✅ (copy step of F1) | ✅ (copy step of D1) | ✅ | Either cloud | Copy only. They need the file list from `rewrite_table_path` |
| **Trino / Starburst** | ✅ F3 | ✅ D5 | ❌ | Outside Databricks | Two Iceberg catalogs in one Trino cluster. `rewrite_table_path` is only an open feature request for Trino |
| **Apache Flink** | ✅ | ✅ D4 (append-only) | ❌ | Outside Databricks | Streaming replication of append-only tables |
| **PyIceberg** | ✅ F4 | ✅ D5 (`upsert`) | ❌ | Anywhere Python runs | `register_table` is also available, so it can drive step 4 of D1 |
| **Databricks (federation + clone)** | ✅ F5, F6 | ✅ D6 | ❌ | Databricks | Target becomes UC managed Iceberg or Delta, no longer standard |
| **Databricks Spark (DBR)** | ⚠️ read-only via federation | ❌ | ❌ | Databricks | Can't load OSS Iceberg catalogs, so it can't write standard Iceberg |
| **OpenSharing** | ⚠️ live share of federated foreign tables (Private Preview) | — | — | Databricks | Read-only, no copy |

---

## 7. Bi-directional setup

| Point | Design |
|---|---|
| Ownership | Each table has one owner cloud and only the owner writes it. Replicas are read-only (required for D1) |
| Layout | Separate replica locations and namespaces, for example `abfss://…/replica_aws/…` and namespace `replica_aws` on Azure, and `s3://…/replica_azure/…` on AWS |
| Pipelines | One pipeline per direction (AWS→Azure and Azure→AWS). Each needs credentials for both storage accounts |
| Loop prevention | Never select replica namespaces as a replication source |
| Writes to the other cloud's tables | Write remotely through the owner's catalog (T2, or an engine attached to both catalogs). Never write to the replica |
| Maintenance | The owner runs compaction and snapshot expiry, keeping retention longer than the sync interval. The replica only gets orphan cleanup |
| Egress | Each sync pays egress on the source cloud for the copied bytes only |

---

## 8. Summary: standard vs. managed Iceberg for replication

| | Standard Iceberg | Databricks managed Iceberg ([`06-…md`](06-managed-iceberg-replication-deep-dive.md)) |
|---|---|---|
| Exact replica with history | ✅ (`rewrite_table_path` + copy + register) | ❌ |
| File-level copy tools (AzCopy, DataSync, ADF) | ✅ | ❌ |
| Snapshot-based delta (changelog view) | ✅ on OSS Spark | ⚠️ OSS Spark through the UC IRC, needs a POC |
| Zero-copy cross-cloud sharing | ⚠️ only Glue/HMS via federation + OpenSharing (Private Preview) | ✅ OpenSharing D2D |
| Pure SQL inside Databricks | ❌ (read-only) | ✅ |
| Unity Catalog governance | ❌ (read-only for Glue and HMS only) | ✅ |
| Maintenance effort | High (catalogs, compaction, expiry, orphan cleanup, copy pipelines) | Low |
| Engine and catalog lock-in | None | UC/IRC required to write |

| Need | Recommended option for standard Iceberg |
|---|---|
| Exact, auditable replica with time travel on the other cloud | **F1 + D1** (`rewrite_table_path` + AzCopy/DataSync + register) |
| Simple keyed tables, replica may diverge in history | **F2 + D2** (OSS Spark changelog + `MERGE`) |
| Append-only event data, near real time | **D4 Flink** or **D3** incremental append |
| SQL-only team without Spark | **F3 + D5** with Trino (watermark, soft deletes) |
| Data must end up governed in Databricks | **F5/F6** (but then it's managed Iceberg or Delta: see `06-…md`) |

---

## Sources

- [Apache Iceberg: Spark procedures (`rewrite_table_path`, `register_table`, `create_changelog_view`)](https://iceberg.apache.org/docs/latest/spark-procedures/)
- [Apache Iceberg: Maintenance](https://iceberg.apache.org/docs/latest/maintenance/)
- [Apache Iceberg Javadoc: RewriteTablePath](https://iceberg.apache.org/javadoc/1.11.0/org/apache/iceberg/actions/RewriteTablePath.html)
- [Apache Iceberg PR #10920: RewriteTablePath action](https://github.com/apache/iceberg/pull/10920)
- [Apache Iceberg issue #12471: RewriteTablePath and AssumeRoleAwsClientFactory](https://github.com/apache/iceberg/issues/12471)
- [Dremio: Disaster recovery for Iceberg tables (rewrite_table_path walkthrough)](https://www.dremio.com/blog/disaster-recovery-for-apache-iceberg-tables-restoring-from-backup-and-getting-back-online/)
- [Medium: Migrating Iceberg tables between buckets and registering them](https://medium.com/@saitharun15/migrating-iceberg-tables-between-buckets-and-registering-in-watsonx-data-2901c043b3c2)
- [Trino issue #25499: add rewrite_table_path to the Iceberg connector](https://github.com/trinodb/trino/issues/25499)
- [Apache Polaris documentation](https://polaris.apache.org/docs/overview)
- [Multi-cloud Polaris REST catalog topologies](https://iceberglakehouse.com/posts/multi-cloud-polaris-rest-catalog-topologies/)
- [Conduktor: Iceberg catalog management (REST, Hive, Glue, Nessie)](https://www.conduktor.io/glossary/iceberg-catalog-management-hive-glue-and-nessie)
- [Apache Gravitino: Iceberg catalog (FileIO configuration)](https://gravitino.apache.org/docs/1.2.0/lakehouse-iceberg-catalog)
- [Iceberg Lakehouse: Iceberg FileIO](https://iceberglakehouse.com/iceberg/iceberg-file-io/)
- [AWS DataSync: CreateLocationAzureBlob](https://docs.aws.amazon.com/datasync/latest/userguide/API_CreateLocationAzureBlob.html)
- [AWS Storage blog: Migrating Azure Blob Storage to Amazon S3 with DataSync](https://aws.amazon.com/jp/blogs/storage/migrating-azure-blob-storage-to-amazon-s3-using-aws-datasync/)
- [Databricks: Incrementally clone Parquet and Iceberg tables to Delta Lake](https://docs.databricks.com/en/ingestion/data-migration/clone-parquet.html)
- [Databricks: What is Apache Iceberg in Databricks? (foreign tables)](https://docs.databricks.com/aws/en/iceberg/)
- [Azure Databricks: Iceberg (foreign catalogs: Glue, HMS, Snowflake Horizon)](https://docs.azure.cn/en-us/databricks/iceberg/)
- [Databricks: Work with foreign tables](https://learn.microsoft.com/en-us/azure/databricks/tables/foreign)
- [AWS Big Data blog: Catalog federation between Glue and Unity Catalog](https://aws.amazon.com/blogs/big-data/access-databricks-unity-catalog-data-using-catalog-federation-in-the-aws-glue-data-catalog/)
