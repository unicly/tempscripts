# Replicating Iceberg tables between AWS and Azure (Databricks on both clouds)

Research comparing two ways to keep Iceberg tables replicated **in both directions** between
AWS and Azure:

- **Databricks managed Iceberg tables**: Unity Catalog (UC) owns the table.
- **Standard Iceberg tables**: open-source Iceberg, with metadata owned by your own catalog
  (for example AWS Glue, Hive Metastore, Polaris or a Hadoop catalog).

It also covers **Databricks OpenSharing**, the new name for Delta Sharing.

Disaster recovery is out of scope.

> Status: researched October 2026 from Databricks docs, Databricks blog posts and Apache
> Iceberg docs (sources at the end). Several Databricks features are in Public or Private
> Preview and change often. Items marked ⚠️ are unconfirmed or inconsistent in the docs, so
> check them in your own workspaces before you rely on them.

Legend: ✅ supported · ❌ not supported · ⚠️ partial, preview or unverified

---

## 1. Managed Iceberg vs. standard Iceberg tables

| Aspect | Databricks managed Iceberg table | Standard Iceberg table |
|---|---|---|
| Who owns metadata and commits | Unity Catalog | Your catalog (Glue, HMS, Polaris, REST, Hadoop…) |
| Status in Databricks | ⚠️ Public Preview, DBR 16.4 LTS+ (v3 needs DBR 18.0+) | Read via federation only (see §2) |
| Storage location | UC-managed storage. A `LOCATION` clause is **not** allowed | Any path you choose (S3, ADLS…) |
| Write from Databricks | ✅ | ❌ (foreign tables are read-only) |
| Write from external engines (Spark, Flink, Trino, Snowflake…) | ✅ through the UC Iceberg REST Catalog (IRC), with credential vending | ✅ through your own catalog |
| Table maintenance (compaction, snapshot expiry) | Automatic (predictive optimization) | You run it (`rewrite_data_files`, `expire_snapshots`…) |
| File format | Parquet only | Parquet, ORC, Avro |
| Partition transforms (`days()`, `bucket()`…) | ❌ not supported | ✅ |
| Row-level deletes | v3 deletion vectors only. v2 position/equality deletes ❌ | All Iceberg delete types |
| Iceberg v3 | ✅ (one-way upgrade, some v3 features missing) | Depends on your engine and catalog version |
| Change data feed (CDF) | ❌ | n/a (use the Iceberg changelog view or incremental reads) |
| Streaming source | ⚠️ reported as not supported (community posts) | ✅ with Spark/Flink Iceberg sources |
| Deep clone | ✅ (DBR 16.4+, history not copied) | ✅ (deep clone **into** a UC managed table) |
| Shallow clone | ❌ | ⚠️ foreign Iceberg: docs inconsistent |
| Share with OpenSharing (Databricks→Databricks) | ✅ | ⚠️ Private Preview (foreign tables from Glue, HMS, Snowflake Horizon) |
| Unsupported types through UC | UUID, Fixed(L), TIME, nested STRUCT with required fields | None from UC (engine dependent) |
| Lock-in | Metadata is in UC, so you need UC/IRC to write | Catalog-neutral |

---

## 2. Which Iceberg variants work with Unity Catalog?

| Variant | Usable in Unity Catalog? | Read in Databricks | Write in Databricks | Notes |
|---|---|---|---|---|
| **Managed Iceberg table** | ✅ | ✅ | ✅ | UC is the Iceberg catalog. External engines use the UC IRC |
| **Foreign Iceberg table** (Glue, Hive Metastore, Snowflake Horizon, through Lakehouse Federation / catalog federation) | ✅ (read-only) | ✅ | ❌ | Time travel only to snapshots Databricks has already read. No partition evolution |
| **Standard Iceberg in a generic REST catalog** (Polaris, Nessie, Gravitino…) or a Hadoop/path catalog | ❌ | ❌ (only through a non-UC Spark catalog config on classic compute) | ❌ | Federation does not support generic Iceberg REST endpoints |
| **Iceberg table registered as a UC external table at a `LOCATION`** | ❌ | — | — | UC-managed Iceberg tables don't accept `LOCATION`. For tables owned by another catalog, Databricks says to use federation |
| **Delta table with UniForm (Iceberg reads)** | ✅ | ✅ | ✅ (as Delta) | Iceberg clients get **read-only** access through the IRC. A Delta alternative, not Iceberg-native |

**Takeaway:** only **managed** Iceberg tables are first-class in UC. A standard Iceberg table is
readable in UC only when its catalog is Glue, HMS or Snowflake Horizon, and then it is read-only.

---

## 3. Replication options with Databricks managed Iceberg tables

Setup: each cloud has its own UC metastore and its own managed Iceberg tables.

| Option | How it works | Data copied? | Freshness | Incremental | Target writable? | Bi-directional | Cross-cloud egress | Maturity |
|---|---|---|---|---|---|---|---|---|
| **M1. OpenSharing D2D (live share)** | The AWS metastore shares tables with the Azure metastore and vice versa. The recipient mounts the share as a catalog | ❌ (zero-copy) | Live (latest snapshot) | n/a | ❌ read-only | ✅ separate share in each direction | **On every read** | ⚠️ sharing managed Iceberg: Public Preview |
| **M2. OpenSharing + local materialization** | As M1, plus a scheduled job on the recipient that copies the shared table into a local managed table (`CREATE OR REPLACE … DEEP CLONE`, CTAS or `MERGE`) | ✅ | Batch (schedule) | ⚠️ CDF not available for managed Iceberg. Incremental only with a watermark column + `MERGE`, otherwise a full copy | ✅ (a separate table) | ✅ | Once per refresh | ⚠️ |
| **M3. Cross-cloud Iceberg REST Catalog** | A Spark job on cloud B connects to the IRC of the UC on cloud A (credential vending), reads the snapshot delta (Iceberg changelog view / incremental read, see `04-…md`) and `MERGE`s into a local managed table | ✅ | Batch | ✅ snapshot-based | ✅ | ✅ (run the job in each direction) | Only the delta | ⚠️ IRC read/write is documented. Running Databricks compute as an IRC client of another metastore is unverified |
| **M4. OpenSharing to external Iceberg clients** (open sharing, bearer token, Iceberg REST) | As M1, but the recipient is a non-Databricks Iceberg client | ❌ | Live | n/a | ❌ | ✅ | On every read | ⚠️ docs conflict on whether **managed Iceberg** can be shared to external Iceberg clients. Not needed here, since Databricks runs on both sides |
| **M5. Single owner, remote writers** (no replication) | Each table lives on one cloud. The other cloud reads and writes it through the IRC | ❌ | Live | n/a | ✅ | ✅ | **On every read and write** | ✅ IRC read/write |

---

## 4. Replication options with standard Iceberg tables

Setup: each cloud has its own Iceberg catalog (for example Glue on AWS and HMS or Polaris on
Azure). Data is in S3 and ADLS.

| Option | How it works | Data copied? | Freshness | Incremental | Target writable? | Bi-directional | Cross-cloud egress | Maturity |
|---|---|---|---|---|---|---|---|---|
| **S1. File copy + `rewrite_table_path` + `register_table`** | Iceberg's `rewrite_table_path` rewrites metadata paths (s3:// → abfss://). Copy the listed files (azcopy, DistCp, ADF…), then register or refresh the table in the target catalog | ✅ exact replica (snapshots and history kept) | Batch | ✅ (incremental mode between metadata versions) | ❌ must stay a read-only replica, or the next sync conflicts | ✅ (per table, one direction each) | Only new files | ✅ Iceberg 1.7+ |
| **S2. Spark incremental `MERGE` (changelog view)** | A Spark job reads both catalogs, gets the delta with `create_changelog_view` or an incremental read, and `MERGE`s into the target (see `04-…md`) | ✅ (logical copy, own history) | Batch | ✅ | ✅ (but diverges if written) | ✅ | Only the delta | ✅ |
| **S3. Databricks federation + deep clone** | Databricks on cloud B federates the Glue/HMS catalog of cloud A (foreign table), then `DEEP CLONE`s it into a UC managed table | ✅ | Batch | ⚠️ full copy each time (no zero-copy conversion) | ✅ | ✅ | Full table per refresh | ⚠️ needs network access from cloud B to the catalog and storage on A |
| **S4. Databricks federation + OpenSharing** | Foreign Iceberg table federated into UC, then shared D2D | ❌ | Live | n/a | ❌ | ✅ | On every read | ⚠️ Private Preview |
| **S5. Shared catalog, no replication** | Both clouds use one Iceberg catalog. Data stays in one bucket per table | ❌ | Live | n/a | ✅ | ✅ | On every read and write | ✅ (catalog has to be reachable from both clouds) |

---

## 5. OpenSharing (Delta Sharing) at a glance

| Topic | Details |
|---|---|
| What it is | The Delta Sharing protocol renamed to **OpenSharing** (June 2026), now a Linux Foundation project. Existing Delta Sharing setups keep working |
| Modes | **Databricks-to-Databricks (D2D)**: recipient is a UC metastore, on any cloud or region. **Open sharing**: bearer token or OIDC for non-Databricks recipients, now including Iceberg REST clients (Snowflake, Trino, Flink, Spark, PyIceberg) |
| Relevant mode here | **D2D**, since Databricks runs on both clouds |
| Shareable Iceberg assets | Managed Iceberg tables ✅ (preview). Foreign Iceberg tables ⚠️ Private Preview. UniForm/Delta tables ✅ |
| Access for recipients | **Read-only**. Recipients never write back to the provider's table |
| Copies data? | No. Recipients read the provider's storage directly |
| Egress | Cross-cloud reads incur cloud egress **on every query**. Databricks recommends materializing locally (CDF + `MERGE`, or deep clone) or storing shared data in Cloudflare R2 (no egress fees, but not for view sharing) |
| Limits for managed Iceberg | No CDF. Python, Tableau and Power BI connectors can't query shared managed Iceberg tables. General managed Iceberg limitations apply |
| Bi-directional | One share in each direction: AWS→Azure for tables owned on AWS and Azure→AWS for tables owned on Azure |

---

## 6. Bi-directional replication: what holds for every option

| Point | Explanation |
|---|---|
| **Single writer per table** | Neither Iceberg nor OpenSharing supports multi-master replication. Two copies of the same table written on both clouds will diverge, and no tool merges them |
| **Pattern** | Give each table an **owner cloud**. Replicate owner → other cloud. Tables owned on AWS flow to Azure and tables owned on Azure flow to AWS |
| **Same table updated on both clouds** | Write to the owner copy only (remotely through IRC or a shared catalog, M5 or S5), or split the table into one table per cloud and union them in a view |
| **Change-based sync needs history** | Snapshot-based incremental sync (M3, S1, S2) breaks when the source expires the snapshots the sync still needs. Keep snapshot retention longer than the sync interval |

---

## 7. Summary comparison

| | Managed Iceberg + OpenSharing (M1/M2) | Managed Iceberg + cross-cloud IRC job (M3) | Standard Iceberg + file copy (S1) | Standard Iceberg + Spark `MERGE` (S2) |
|---|---|---|---|---|
| Setup effort | Low (UI/SQL) | Medium | Medium–high (copy pipeline) | Medium |
| Unity Catalog governance | ✅ both sides | ✅ both sides | ❌ (or read-only through federation) | ❌ (or read-only through federation) |
| Physical copy on the target | M1 ❌ / M2 ✅ | ✅ | ✅ | ✅ |
| Incremental transfer | M2: only with watermark logic | ✅ | ✅ | ✅ |
| History on the target | ❌ | ❌ | ✅ | ❌ |
| Egress profile | M1 per query / M2 per refresh | Delta only | Delta only | Delta only |
| Maintenance | Automatic | Automatic | Manual | Manual |
| Main risk | Preview features. No CDF for Iceberg | Unverified Databricks-as-IRC-client setup | Pipeline complexity, path rewriting | Divergence if the target is written |

**Initial assessment (for further research, not a decision):**

- **All-Databricks, UC-governed:** managed Iceberg with **OpenSharing D2D** (M1) for low-volume or
  ad-hoc access. Add local materialization (M2) for heavily queried tables to avoid paying egress
  on every query. **M3** is the most egress-efficient incremental option if Databricks compute can
  act as an IRC client of the other metastore, which a POC should test first.
- **Catalog-neutral:** standard Iceberg with **S2** (simple, incremental, any catalog) or **S1**
  (exact replica with history). You lose UC write governance on those tables.

---

## Sources

- [Databricks: What is Apache Iceberg in Databricks?](https://docs.databricks.com/aws/en/iceberg/)
- [Databricks: Unity Catalog managed tables (Delta and Iceberg)](https://docs.databricks.com/aws/tables/managed)
- [Databricks: Use Apache Iceberg v3 features](https://docs.databricks.com/aws/en/iceberg/iceberg-v3)
- [Databricks: Clone a managed Iceberg table](https://learn.microsoft.com/en-us/azure/databricks/iceberg/clone)
- [Databricks: Shallow clone for Unity Catalog tables](https://docs.databricks.com/aws/en/tables/operations/clone-unity-catalog)
- [Databricks: Work with foreign tables](https://learn.microsoft.com/en-us/azure/databricks/tables/foreign)
- [Databricks: Access Databricks data using external systems](https://docs.databricks.com/aws/en/external-access)
- [Databricks: Read Delta tables with Iceberg clients (UniForm)](https://docs.databricks.com/aws/en/delta/uniform)
- [Databricks: Create shares for OpenSharing](https://docs.databricks.com/aws/en/opensharing/create-share)
- [Databricks: Read data shared using Databricks-to-Databricks OpenSharing](https://docs.databricks.com/aws/en/opensharing/read-data-databricks)
- [Databricks: Read data shared with bearer tokens (open sharing)](https://docs.databricks.com/aws/en/opensharing/read-data-open)
- [Databricks: Monitor and manage sharing egress costs](https://docs.databricks.com/en/data-sharing/manage-egress)
- [Databricks blog: Announcing new OpenSharing and Marketplace capabilities](https://www.databricks.com/blog/announcing-new-opensharing-and-marketplace-capabilities-ai-era)
- [Databricks blog: First-class Iceberg support in Delta Sharing](https://www.databricks.com/blog/announcing-first-class-support-iceberg-format-databricks-delta-sharing)
- [Databricks blog: Mercedes-Benz cross-cloud data mesh with Delta Sharing and replication](https://databricks.com/blog/mercedes-benz-builds-cross-cloud-data-mesh-delta-sharing-and-intelligent-replication-cutting)
- [Databricks blog: What's new with Unity Catalog at Data + AI Summit 2026](https://www.databricks.com/blog/whats-new-unity-catalog-data-ai-summit-2026)
- [Apache Iceberg Javadoc: RewriteTablePath](https://iceberg.apache.org/javadoc/1.11.0/org/apache/iceberg/actions/RewriteTablePath.html)
- [Dremio: Disaster recovery for Iceberg tables (rewrite_table_path usage)](https://www.dremio.com/blog/disaster-recovery-for-apache-iceberg-tables-restoring-from-backup-and-getting-back-online/)
- [Onehouse: Databricks Iceberg support has a catch (vendor-critical view)](https://www.onehouse.ai/blog/databricks-iceberg-support-has-a-catch-its-called-unity-catalog)
- [Databricks Community: Iceberg v3 deletion vector compatibility issue](https://community.databricks.com/t5/data-engineering/cross-engine-iceberg-v3-compatibility-issue-databricks-delete/td-p/164734)
