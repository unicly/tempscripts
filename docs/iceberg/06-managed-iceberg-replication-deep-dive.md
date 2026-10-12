# Deep dive: replicating Databricks managed Iceberg tables between AWS and Azure

Part 1 of the detailed comparison started in
[`05-cross-cloud-replication-aws-azure.md`](05-cross-cloud-replication-aws-azure.md). This part
covers **Databricks managed Iceberg tables**. Standard Iceberg follows in a later part.

Setup: Databricks on AWS and on Azure, each with its own Unity Catalog (UC) metastore. Data is
replicated in **both directions**, with one owner cloud per table.

> Status: researched October 2026. Managed Iceberg and several of the features below are in
> Public Preview, and some details are not documented. ⚠️ marks unverified or inconsistent
> points. Test each option in a POC before you rely on it.

Legend: ✅ supported · ❌ not supported · ⚠️ partial, preview or unverified

---

## 1. What makes a managed Iceberg table different from a standard Iceberg table

### 1.1 Ownership and architecture

| Aspect | Databricks managed Iceberg | Standard Iceberg |
|---|---|---|
| Catalog that commits snapshots | Unity Catalog (the only writer of `metadata.json`) | Your catalog (Glue, HMS, Polaris, Nessie, Hadoop…) |
| How other engines connect | UC **Iceberg REST Catalog (IRC)**: `https://<workspace>/api/2.1/unity-catalog/iceberg-rest` (OAuth or PAT, workspace ID in the URL) | Whatever your catalog exposes |
| Storage path | Chosen by UC (managed storage of the catalog or schema). `LOCATION` is **not allowed** | Chosen by you |
| Storage credentials for clients | **Credential vending**: UC issues short-lived, scoped tokens | You configure IAM or SAS yourself |
| Governance | UC permissions, lineage and audit for Databricks and IRC clients | Only what your catalog offers |
| Maintenance | **Predictive optimization**: automatic compaction, snapshot expiry and cleanup | You schedule `rewrite_data_files`, `expire_snapshots`, `remove_orphan_files` |
| Status | ⚠️ Public Preview, DBR 16.4 LTS+. Iceberg v3 needs DBR 18.0+ | Mature open-source project |

### 1.2 Feature differences that matter for replication

| Feature | Managed Iceberg | Standard Iceberg | Impact on replication |
|---|---|---|---|
| Register existing files or metadata (`register_table`, `LOCATION`) | ❌ | ✅ | You **can't** copy files at the storage level and register them on the other cloud. Data must be **written through UC** (Databricks or an IRC client) |
| Rewrite paths (`rewrite_table_path`) | ❌ (UC owns the metadata) | ✅ | No file-level replica with history is possible |
| Change data feed (CDF) | ❌ | n/a | No out-of-the-box row-level change stream |
| Streaming source | ⚠️ reported as not supported | ✅ (Spark or Flink Iceberg source) | No Databricks streaming from a managed Iceberg table |
| Iceberg snapshots, time travel | ✅ | ✅ | Snapshot IDs give the basis for delta detection by external engines |
| Row-level deletes | v2: copy-on-write (no position or equality deletes). v3: deletion vectors | All delete types | ⚠️ Iceberg changelog scans over v3 deletion vectors are not yet widely supported by OSS engines |
| Partition transforms (`days()`, `bucket()`…) | ❌ | ✅ | Source and target layouts must use identity partitioning or clustering |
| Data types | No UUID, Fixed(L), TIME, or nested STRUCT with required fields | All | Schemas must avoid these types |
| Deep clone | ✅ (full copy, no history) | via federation into UC | Full replication with one SQL statement |
| Shallow clone | ❌ | ⚠️ | — |
| OpenSharing (Databricks-to-Databricks) | ✅ | ⚠️ Private Preview (foreign tables) | Zero-copy cross-cloud read access |
| Write from external engines | ✅ through the IRC | ✅ through your catalog | Non-Databricks tools can write to the replica |
| Load OSS Iceberg jars or catalogs on a Databricks cluster | ❌ (not supported) | n/a | Databricks can't act as a generic Iceberg REST client. IRC-based sync runs on **non-Databricks** compute |

---

## 2. Building blocks

| # | Building block | What it gives you | Direction of use |
|---|---|---|---|
| B1 | **OpenSharing, Databricks-to-Databricks** | A share from the owner metastore that appears as a read-only catalog in the other metastore. Zero-copy and live. Can be shared **with history**, which allows time travel for the recipient | Provider: owner cloud. Recipient: other cloud |
| B2 | **Databricks SQL / notebooks on the recipient** | `DEEP CLONE`, `CTAS`, `INSERT OVERWRITE`, `MERGE` reading from the shared catalog and writing to a local managed Iceberg table | Runs on the target cloud |
| B3 | **Lakeflow Jobs** | Scheduling and orchestration (SQL, notebook, Python or JAR tasks; serverless or classic) | Either cloud |
| B4 | **UC Iceberg REST Catalog (IRC)** | Open Iceberg API with credential vending. External engines read and write managed Iceberg directly | Accessed from anywhere with network access |
| B5 | **External engines** (OSS Spark on EMR, HDInsight, AKS or Synapse/Fabric Spark; Flink; Trino; PyIceberg) | Connect to **both** IRCs (source and target) in one job and copy the data, with full access to Iceberg snapshot metadata | Runs anywhere |
| B6 | **Delta "outbox" table with CDF** | The source cloud writes changes to a Delta table with CDF enabled and shares it. The recipient streams `readChangeFeed` | Pattern that works around missing CDF on Iceberg |

---

## 3. Full replication (initial load or periodic refresh)

| Method | How | Engine | Data path | Keeps history? | Pros | Cons |
|---|---|---|---|---|---|---|
| **F1. Deep clone from the share** | Recipient: `CREATE OR REPLACE TABLE tgt DEEP CLONE shared_cat.db.tbl` | Databricks SQL or cluster (DBR 16.4+) | Cross-cloud read through OpenSharing | ❌ | One statement. Copies schema and properties | ⚠️ Deep clone of a **shared** managed Iceberg table is not explicitly documented. A full rewrite each run. Predictive optimization must be on for the target |
| **F2. CTAS / `INSERT OVERWRITE` from the share** | `CREATE OR REPLACE TABLE tgt USING ICEBERG AS SELECT * FROM shared_cat.db.tbl` | Databricks SQL or cluster | OpenSharing | ❌ | Documented path. Can filter, project or repartition | A full rewrite each run. Re-apply table properties |
| **F3. External Spark job between both IRCs** | `spark.table("aws_uc.db.tbl").writeTo("az_uc.db.tbl").createOrReplace()` | OSS Spark with the Iceberg runtime | Direct cross-cloud read, credential vending | ❌ | No share needed. Same job can also do deltas (D3) | Non-Databricks compute to run. Network and egress |
| **F4. PyIceberg (no Spark)** | Read an Arrow scan from the source IRC and `overwrite()` to the target IRC | Python | Direct | ❌ | Lightweight, serverless functions possible | Only for small or medium tables (memory bound) |

**Recommendation for the initial load:** F1 or F2. They are the simplest and stay inside
Databricks. Use F3 if you already run the delta job on external Spark.

```sql
-- F2, executed in the Azure workspace; aws_share = catalog created from the OpenSharing share
CREATE OR REPLACE TABLE main.replica.orders
USING ICEBERG
AS SELECT * FROM aws_share.sales.orders;
```

---

## 4. Delta (incremental) replication

Managed Iceberg has **no CDF**, so Databricks gives you no built-in change stream for it. There
are four ways to get deltas:

| Method | How changes are detected | Captures deletes? | Engine | Cross-cloud traffic | Complexity | Maturity |
|---|---|---|---|---|---|---|
| **D1. Watermark + `MERGE` on the share** | Filter the shared table on a column such as `updated_at > last_watermark` | ❌ (only with soft deletes, `is_deleted` flag) | Databricks SQL (recipient) | Only files that pass pruning on the watermark column | Low | ✅ standard SQL |
| **D2. Snapshot diff on the share (shared WITH HISTORY)** | Compare `VERSION AS OF <last>` with the current version on the recipient (anti-join or `EXCEPT` on the key and a row hash) | ✅ | Databricks SQL (recipient) | ⚠️ reads both versions over the share. Little saving for large tables | Medium | ⚠️ time travel on shared managed Iceberg is not clearly documented |
| **D3. External engine, Iceberg snapshot delta via IRC** | Iceberg-native: `create_changelog_view` / incremental read between snapshot IDs (see [`04-…md`](04-incremental-prod-to-dev-sync.md)). Write with `MERGE` into the target IRC | ✅ | OSS Spark (or Flink for append-only) | **Only changed files** | Medium | ⚠️ needs a POC. Changelog over v3 deletion vectors may not be supported. Keep the tables on v2 for this |
| **D4. Outbox: Delta table with CDF on the source, shared** | The writer on the source cloud also writes each change (or a `MERGE`-derived change set) into a Delta table with `delta.enableChangeDataFeed = true`. Share it. The recipient streams `readChangeFeed` and `MERGE`s into the Iceberg replica | ✅ | Databricks (both sides) | Only changes | Medium–high (changes the producer pipeline) | ✅ Delta CDF sharing and streaming are GA |

### D1: watermark + MERGE (Databricks SQL on the recipient)

```sql
-- runs in the target workspace, scheduled with a Lakeflow Job
MERGE INTO main.replica.orders t
USING (
  SELECT * FROM aws_share.sales.orders
  WHERE updated_at > (SELECT coalesce(max(updated_at), TIMESTAMP'1970-01-01') FROM main.replica.orders)
) s
ON t.order_id = s.order_id
WHEN MATCHED AND s.is_deleted THEN DELETE
WHEN MATCHED THEN UPDATE SET *
WHEN NOT MATCHED AND NOT s.is_deleted THEN INSERT *;
```

Requirements: a reliable, monotonically increasing `updated_at`, and soft deletes for delete
propagation. Without soft deletes, run a periodic F2 full refresh to remove deleted rows.

### D3: external Spark job through both IRCs

```python
# OSS Spark 3.5 + iceberg-spark-runtime + iceberg-aws-bundle + iceberg-azure-bundle
spark = (SparkSession.builder
  .config("spark.sql.extensions", "org.apache.iceberg.spark.extensions.IcebergSparkSessionExtensions")
  # source: Unity Catalog on AWS
  .config("spark.sql.catalog.aws_uc", "org.apache.iceberg.spark.SparkCatalog")
  .config("spark.sql.catalog.aws_uc.type", "rest")
  .config("spark.sql.catalog.aws_uc.uri", "https://<aws-workspace>/api/2.1/unity-catalog/iceberg-rest")
  .config("spark.sql.catalog.aws_uc.warehouse", "<uc_catalog_on_aws>")
  .config("spark.sql.catalog.aws_uc.rest.auth.type", "oauth2")
  .config("spark.sql.catalog.aws_uc.oauth2-server-uri", "https://<aws-workspace>/oidc/v1/token")
  .config("spark.sql.catalog.aws_uc.credential", "<sp_client_id>:<sp_secret>")
  .config("spark.sql.catalog.aws_uc.scope", "all-apis")
  # target: Unity Catalog on Azure (same keys, Azure workspace)
  .config("spark.sql.catalog.az_uc", "org.apache.iceberg.spark.SparkCatalog")
  # ... same keys as aws_uc ...
  .getOrCreate())
```

Then run the same flow as in [`04-incremental-prod-to-dev-sync.md`](04-incremental-prod-to-dev-sync.md):

- read the last synced snapshot ID
- `create_changelog_view` on `aws_uc.db.tbl` with `net_changes => true`
- `MERGE INTO az_uc.db.tbl`
- store the new watermark.

UC predictive optimization expires old snapshots on the source, so sync more often than the
snapshot retention period.

### D4: outbox pattern

| Step | Where | What |
|---|---|---|
| 1 | Source cloud | The producer writes to the managed Iceberg table **and** appends changes (`op`, key, row, `ts`) to a Delta table `orders_changes` with CDF, or derives them with a `MERGE` |
| 2 | Source cloud | `ALTER SHARE s ADD TABLE sales.orders_changes WITH HISTORY` |
| 3 | Target cloud | Streaming job: `spark.readStream.option("readChangeFeed","true").table("aws_share.sales.orders_changes")` → `foreachBatch` `MERGE` into the Iceberg replica |

This is the most reliable fully-Databricks delta option, but it means changing the producer.

---

## 5. "Only Spark jobs?" All replication tools for managed Iceberg

No. Spark is one option among several.

| Tool | Full | Delta | Runs on | Language | Notes |
|---|---|---|---|---|---|
| **OpenSharing (live share, no copy)** | n/a | n/a | — | Configuration only | Often enough on its own: the other cloud queries the data in place and pays egress per query |
| **Databricks SQL (SQL warehouse) + Lakeflow Jobs** | ✅ F1/F2 | ✅ D1 (D2 ⚠️) | Databricks, serverless | SQL | **No Spark code.** Simplest managed option |
| **Lakeflow Declarative Pipelines (materialized view `USING ICEBERG`)** | ✅ | ⚠️ incremental refresh from an Iceberg or shared source is unverified, may fully recompute | Databricks | SQL / Python | Declarative refresh of a replica. Check the refresh mode in a POC |
| **Databricks notebook / Spark (Databricks Runtime)** | ✅ | ✅ D1, D2, D4 | Databricks | Python, Scala, SQL | Can't load OSS Iceberg catalogs, so no D3 here |
| **Structured Streaming on a shared Delta CDF table** | — | ✅ D4 | Databricks | Python, Scala | Near-real-time deltas |
| **OSS Apache Spark** (EMR, HDInsight, AKS, Synapse/Fabric Spark…) | ✅ F3 | ✅ D3 | Outside Databricks | Python, Scala, SQL | Full Iceberg API (snapshots, changelog) through both IRCs |
| **Apache Flink** | ✅ | ✅ append-only incremental snapshot reads | Outside Databricks | Java, SQL | Good for append-only streaming replication |
| **Trino / Starburst** | ✅ (`CREATE TABLE AS`, `INSERT`) | ✅ (`MERGE` with watermark) | Outside Databricks | SQL | Iceberg connector with `iceberg.catalog.type=rest`, one catalog per UC. Databricks lists Trino as a read/write IRC client. Requires external data access on the metastore + `EXTERNAL USE SCHEMA` grant. ⚠️ Trino credential vending is documented for S3; for ADLS you may have to configure storage credentials in Trino yourself |
| **PyIceberg** | ✅ small/medium | ✅ (`upsert`, snapshot-based reads) | Anywhere Python runs (incl. Functions / Lambda) | Python | No cluster. Limited by memory |
| **Storage-level copy** (S3 replication, AzCopy, ADF) | ❌ | ❌ | — | — | **Not possible** for managed Iceberg: files can't be registered in UC |

---

## 6. Bi-directional setup

| Point | Design |
|---|---|
| Ownership | Each table has one **owner cloud**. Only the owner writes it |
| Shares | One share AWS→Azure (tables owned on AWS) and one share Azure→AWS (tables owned on Azure) |
| Replica naming | Put replicas in their own catalog or schema (for example `replica_aws.*` on Azure) so they're never mistaken for owned tables |
| Loop prevention | Never add a replica to an outgoing share, and never replicate a replica back |
| Writing to a table owned by the other cloud | Write remotely through the owner's IRC (external engines) or route the write to a job on the owner cloud. Never write to the replica |
| Identity | One service principal per direction, with `SELECT` on the source (or share) and `MODIFY` on the replica |
| Egress | Paid by the owner (provider) cloud's storage on each cross-cloud read. Replicating once and querying locally avoids paying it on every query |

---

## 7. Summary: which option when

| Need | Recommended option |
|---|---|
| Occasional queries from the other cloud | **OpenSharing live share**, no replication |
| Simple scheduled replica, only Databricks, no deletes | **F2 initial load + D1 watermark `MERGE`** (Databricks SQL + Lakeflow Jobs) |
| Simple replica with deletes, small or medium tables | **F1/F2 full refresh** on a schedule |
| Large tables, deletes, minimum egress | **D3 external Spark through both IRCs** (POC needed), or **D4 outbox with Delta CDF** if you can change the producer |
| Near-real-time | **D4** (Structured Streaming on shared CDF) or Flink (append-only) |

---

## Sources

- [Databricks: Unity Catalog managed tables (Delta and Iceberg)](https://docs.databricks.com/aws/tables/managed)
- [Databricks: What is Apache Iceberg in Databricks?](https://docs.databricks.com/aws/en/iceberg/)
- [Databricks: Use Apache Iceberg v3 features](https://docs.databricks.com/aws/en/iceberg/iceberg-v3)
- [Databricks: Clone a managed Iceberg table](https://learn.microsoft.com/en-us/azure/databricks/iceberg/clone)
- [Databricks: CREATE TABLE CLONE](https://docs.databricks.com/aws/en/sql/language-manual/delta-clone)
- [Databricks: Access Databricks tables from Apache Iceberg clients (IRC)](https://docs.databricks.com/aws/en/external-access/iceberg)
- [Databricks (archived): External access from Iceberg clients, jar note](https://docs.azure.cn/en-us/databricks/archive/legacy/external-access-iceberg)
- [Databricks: What is OpenSharing?](https://docs.databricks.com/aws/en/opensharing/)
- [Databricks: Read data shared using Databricks-to-Databricks OpenSharing](https://docs.databricks.com/aws/en/opensharing/read-data-databricks)
- [Databricks: Monitor and manage sharing egress costs](https://docs.databricks.com/en/data-sharing/manage-egress)
- [Databricks: Use change data feed](https://docs.databricks.com/aws/en/tables/features/change-data-feed)
- [Databricks: Work with table history](https://docs.databricks.com/aws/en/tables/history)
- [Databricks: CREATE MATERIALIZED VIEW (pipelines)](https://docs.databricks.com/aws/en/ldp/developer/ldp-sql-ref-create-materialized-view)
- [Databricks Community: managed Iceberg streaming limitation](https://community.databricks.com/t5/data-engineering/iceberg-native-table-streaming-in-databricks/m-p/151456)
- [Apache Iceberg Javadoc: RewriteTablePath](https://iceberg.apache.org/javadoc/1.11.0/org/apache/iceberg/actions/RewriteTablePath.html)

### Trino access and snapshots vs. versions

- [Databricks: Access Databricks tables from Apache Iceberg clients (Azure)](https://learn.microsoft.com/en-us/azure/databricks/external-access/iceberg)
- [Databricks blog: Announcing full Apache Iceberg support in Databricks](https://www.databricks.com/blog/announcing-full-apache-iceberg-support-databricks)
- [Databricks Community: How to read Unity Catalog tables from Trino via open APIs](https://community.databricks.com/t5/technical-blog/how-to-read-unity-catalog-tables-from-trino-via-open-apis/ba-p/109654)
- [Databricks Community: Performing DML operations on Unity Catalog from AWS engines](https://community.databricks.com/t5/technical-blog/performing-dml-operations-on-databricks-unity-catalog-from-aws/ba-p/122967)
- [Unity Catalog OSS: Trino integration](https://docs.unitycatalog.io/integrations/unity-catalog-trino/)
- [Lakekeeper: engine docs (Trino vended credentials S3 only)](https://docs.lakekeeper.io/docs/0.9.x/engines/)
- [Databricks: Read Delta tables with Iceberg clients (UniForm)](https://docs.databricks.com/aws/en/delta/uniform)
- [Databricks: Read Delta Lake tables with Iceberg clients](https://learn.microsoft.com/azure/databricks/delta/iceberg-reads)
- [Databricks Community: How to access snapshots in Iceberg tables](https://community.databricks.com/t5/data-engineering/how-to-access-snapshots-in-iceberg-tables/td-p/150999)
- [Trino: Iceberg connector documentation](https://trino.io/docs/current/connector/iceberg.html)
- [Trino PR #30612: snapshot-loading-mode for the Iceberg REST catalog](https://github.com/trinodb/trino/pull/30612)
