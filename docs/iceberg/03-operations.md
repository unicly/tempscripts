# Apache Iceberg — Part 3: Reads, Writes & Maintenance

This part shows how the files from Parts 1 and 2 are used at runtime: how a query is planned, how a commit happens safely, and how to keep a table healthy.

> **Series**
> 1. [Overview & File Layout](01-overview.md)
> 2. [Metadata Files in Detail](02-metadata-files.md)
> 3. **Reads, Writes & Maintenance** (this file)

---

## How a Read Works

Query: `SELECT sum(amount) FROM orders WHERE order_ts >= '2024-05-02' AND customer_id = 42`

```text
1. Catalog          → "current metadata = 00002-d47e.metadata.json"
2. Metadata file    → current-snapshot-id = 7456…  → manifest list snap-7456….avro
                      (schema + partition spec loaded here)
3. Manifest list    → 3 manifests listed
                      prune by partition bounds: manifest #1 covers only 2024-05-01 → SKIP
4. Manifests (2)    → 40 data files listed
                      prune by partition value + column min/max for customer_id → 3 files left
                      collect delete files that apply to those 3 files
5. Data files (3)   → read Parquet, apply deletes, compute sum
```

No S3 `LIST` calls are made. Planning cost depends on the amount of **metadata**, not on the number of objects in the bucket.

### Time travel
Reading an older version just starts at step 2 with a different snapshot:

```sql
-- Spark / Athena / Trino
SELECT * FROM orders FOR TIMESTAMP AS OF TIMESTAMP '2024-05-01 12:00:00';
SELECT * FROM orders FOR VERSION AS OF 6123123412341234;
```

The old manifest list, manifests and data files still exist (until expired), so the result is exactly what the table looked like then.

---

## How a Write (Commit) Works

Iceberg uses **optimistic concurrency**: writers work independently and then race to swap one pointer.

```text
Writer                                         Catalog
  │ 1. Read current metadata (v2)                 │
  │ 2. Write new data files (.parquet)            │
  │ 3. Write new manifest(s) for those files      │
  │ 4. Write new manifest list                    │
  │      = old manifests + new manifests          │
  │ 5. Write new metadata file v3                 │
  │      = v2 + new snapshot, current → new       │
  │ 6. Atomic swap: "if current == v2, set v3" ──►│
  │                                               │
  │◄── success → v3 is now the table             │
  │◄── conflict (someone else committed v3')     │
  │       → re-read, validate, retry steps 4–6   │
```

- **Step 6 is the only point where readers can see a change.** Until then, the new files are invisible. They are not referenced by anything.
- On conflict, the writer usually does **not** rewrite data. It re-applies its change on top of the new current metadata, after checking that the other commit does not conflict (e.g. both deleted the same rows).
- A failed or abandoned write leaves **orphan files** behind. They are harmless and cleaned up later.

### What the catalog does for the swap
| Catalog | Atomic mechanism |
|---|---|
| AWS Glue Data Catalog | Conditional `UpdateTable` using the table's version ID |
| Hive Metastore | Table lock + `alter_table` |
| REST catalog (Polaris, Unity, S3 Tables, Nessie…) | Server-side compare-and-swap |
| JDBC catalog | `UPDATE … WHERE metadata_location = :old` |
| Hadoop catalog (filesystem) | Atomic rename. **Not safe on S3**, avoid in production |

### Operation types (snapshot `summary.operation`)
| Operation | Typical SQL | What changes |
|---|---|---|
| `append` | `INSERT INTO` | Only new data files added |
| `overwrite` | `INSERT OVERWRITE`, `MERGE`, `UPDATE`, `DELETE` | Files added and/or removed, or delete files added |
| `delete` | `DELETE` matching whole files/partitions | Files removed only |
| `replace` | Compaction | Files rewritten; **data is logically unchanged** |

---

## Row-Level Changes: Copy-on-Write vs Merge-on-Read

Set per operation via table properties `write.delete.mode`, `write.update.mode`, `write.merge.mode`.

| | **Copy-on-Write (CoW)** | **Merge-on-Read (MoR)** |
|---|---|---|
| On `UPDATE`/`DELETE` | Rewrite every affected data file without the old rows | Write small delete files (+ new data files for updated rows) |
| Write cost | High | Low |
| Read cost | Low (nothing to merge) | Higher (apply deletes at read time) until compacted |
| Good for | Batch, read-heavy tables | Frequent small updates, streaming/CDC |
| Format version | v1+ | v2+ |

---

## Table Maintenance

Because every commit creates files and nothing is edited in place, tables need regular housekeeping.

### 1. Compaction: `rewrite_data_files`
Merges small files and applies pending deletes, producing a `replace` snapshot.

```sql
-- Spark
CALL glue_catalog.system.rewrite_data_files(
  table => 'sales_db.orders',
  strategy => 'sort',
  sort_order => 'customer_id',
  options => map('target-file-size-bytes', '536870912')  -- 512 MB
);

-- Athena
OPTIMIZE sales_db.orders REWRITE DATA USING BIN_PACK;
```

### 2. Rewrite manifests: `rewrite_manifests`
Reorganises many small manifests into fewer, well-clustered ones to speed up planning.

```sql
CALL glue_catalog.system.rewrite_manifests('sales_db.orders');
```

### 3. Expire snapshots: `expire_snapshots`
Removes old snapshots from metadata and **deletes the files that only they referenced**. After this, time travel to those snapshots is no longer possible.

```sql
-- Spark
CALL glue_catalog.system.expire_snapshots(
  table => 'sales_db.orders',
  older_than => TIMESTAMP '2024-05-01 00:00:00',
  retain_last => 10
);

-- Athena (uses table properties vacuum_max_snapshot_age_seconds, etc.)
VACUUM sales_db.orders;
```

### 4. Remove orphan files: `remove_orphan_files`
Deletes files under the table location that **no metadata references**, such as leftovers from failed writes.

```sql
CALL glue_catalog.system.remove_orphan_files(
  table => 'sales_db.orders',
  older_than => TIMESTAMP '2024-05-01 00:00:00'   -- keep a safety margin ≥ 3 days
);
```

> ⚠️ Never use a short `older_than` here. A file written by an in-progress commit looks like an orphan until that commit finishes.

### 5. Old metadata files
Each commit adds a `metadata.json`. Cap them with table properties:

```sql
ALTER TABLE sales_db.orders SET TBLPROPERTIES (
  'write.metadata.delete-after-commit.enabled' = 'true',
  'write.metadata.previous-versions-max'       = '50'
);
```

### Suggested order
```text
rewrite_data_files → rewrite_manifests → expire_snapshots → remove_orphan_files
```

On AWS, **Glue Data Catalog automatic table optimization** and **Amazon S3 Tables** can run compaction, snapshot expiry and orphan cleanup for you.

---

## Inspecting a Table (Metadata Tables)

Every Iceberg table exposes its metadata as queryable tables:

```sql
SELECT * FROM sales_db.orders.snapshots;        -- one row per snapshot
SELECT * FROM sales_db.orders.history;          -- which snapshot was current, when
SELECT * FROM sales_db.orders.manifests;        -- manifests in current snapshot
SELECT * FROM sales_db.orders.files;            -- data + delete files with stats
SELECT * FROM sales_db.orders.partitions;       -- per-partition row/file counts
SELECT * FROM sales_db.orders.refs;             -- branches and tags
```
*(In Athena, quote the suffix: `SELECT * FROM "sales_db"."orders$snapshots"`.)*

Useful health checks:

```sql
-- Small-file problem?
SELECT count(*) AS files, avg(file_size_in_bytes)/1024/1024 AS avg_mb
FROM sales_db.orders.files;

-- Pending merge-on-read deletes?
SELECT content, count(*) FROM sales_db.orders.all_delete_files GROUP BY content;
```

---

## Quick Reference

| You want to… | Iceberg mechanism |
|---|---|
| Add rows | `append` snapshot, new data files + manifest |
| Change/delete rows | CoW rewrite, or MoR delete files |
| Read last week's data | Time travel to an older snapshot |
| Undo a bad write | `CALL system.rollback_to_snapshot('db.t', <id>)` |
| Test changes in isolation | Create a **branch**, write to it, then fast-forward `main` |
| Change partitioning | `ALTER TABLE … ADD/DROP PARTITION FIELD` (metadata only) |
| Rename a column | `ALTER TABLE … RENAME COLUMN` (metadata only) |
| Speed up queries | Compaction, sort order, rewrite manifests |
| Reclaim storage | Expire snapshots, then remove orphan files |

---

Previous: **[← Part 2 — Metadata Files in Detail](02-metadata-files.md)** · Back to **[Part 1 — Overview](01-overview.md)**
