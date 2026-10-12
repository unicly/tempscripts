# Quick summary: full and incremental replication of managed and standard Iceberg tables

Short version of [`06-managed-iceberg-replication-deep-dive.md`](06-managed-iceberg-replication-deep-dive.md),
[`07-standard-iceberg-replication-deep-dive.md`](07-standard-iceberg-replication-deep-dive.md) and
[`08-incremental-rewrite-table-path-explained.md`](08-incremental-rewrite-table-path-explained.md).

> Not tested on real tables. ⚠️ marks points to prove in a test first.

| | **Managed Iceberg** (owned by Unity Catalog) | **Standard Iceberg** (owned by your catalog: Glue, Polaris…) |
|---|---|---|
| **How the other cloud sees the data** | OpenSharing share between Databricks workspaces (read-only, no copy) | Its own catalog on each cloud, or one shared Iceberg REST catalog |
| **Full copy: simplest** | `CREATE TABLE … AS SELECT` or `DEEP CLONE` from the shared table, in Databricks SQL | Spark or Trino `CREATE TABLE … AS SELECT` across both catalogs |
| **Full copy: exact, with history** | ❌ Not possible | `rewrite_table_path` + file copy (AzCopy, DataSync, ADF) + `register_table` |
| **Incremental: with SQL only** | Watermark `MERGE` on the shared table (deletes only with soft deletes) | Trino or Spark watermark `MERGE` (deletes only with soft deletes) |
| **Incremental: snapshot-based, deletes included** | ⚠️ Open-source Spark outside Databricks reads the changelog through Unity Catalog's Iceberg REST catalog and `MERGE`s into the other cloud | Open-source Spark changelog view + `MERGE` ([`04-…md`](04-incremental-prod-to-dev-sync.md)) |
| **Incremental: exact file copy** | ❌ | Incremental `rewrite_table_path` + copy of new files + move the catalog pointer ([`08-…md`](08-incremental-rewrite-table-path-explained.md)) |
| **Incremental: streaming** | Outbox Delta table with change data feed, shared and streamed (`readChangeFeed` → `MERGE`) | Flink incremental reads (append-only tables) |
| **Re-running `DEEP CLONE`** | ❌ A full copy every time | Not applicable (cloning into Databricks makes the copy managed Iceberg or Delta) |
| **Main tools** | Databricks SQL, Lakeflow Jobs, OpenSharing; open-source Spark, Trino or PyIceberg through the REST catalog | Open-source Spark, Trino, Flink, PyIceberg, file copy tools |
| **What you must keep track of** | Watermark (timestamp column, or snapshot ID through the REST catalog) | Watermark (snapshot ID or last `metadata.json`) |
| **Main risk** | Preview features; no change data feed; deep clone always full | Running your own catalog and copy pipelines; history on the source must not expire before the next sync |

## Rules that apply to both

- **One owner cloud per table.** For bi-directional replication, each table is written only on its owner cloud and copied one way.
- **Copies are read-only.** Nothing writes to a replica.
- **Never replicate a copy back** to the cloud it came from.
- **Keep the source's history** (snapshots, versions) longer than the time between syncs.

## Recommendation

- **Managed Iceberg:** a full copy once, then a watermark `MERGE`. Use the snapshot-based Spark job or the outbox table if deletes have to come through.
- **Standard Iceberg:** `rewrite_table_path` for exact copies with history, or the changelog `MERGE` if a simpler pipeline matters more.
