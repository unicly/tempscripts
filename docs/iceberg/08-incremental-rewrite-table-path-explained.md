# How incremental exact-copy replication works (`rewrite_table_path`)

Detail for option **D1** in
[`07-standard-iceberg-replication-deep-dive.md`](07-standard-iceberg-replication-deep-dive.md):
replicating a standard Iceberg table from AWS to Azure by copying only new files, while keeping
the full snapshot history.

> Based on the Apache Iceberg docs and published walkthroughs. Not yet tested against real tables.

## 1. What Iceberg stores, and why the paths are the problem

```
catalog ──► metadata_location = s3://lake/orders/metadata/00005-….metadata.json
                │  (table versions: schema, snapshot list, metadata log)
                ▼
            snap-….avro            ← manifest list (one per snapshot)
                ▼
            ….avro manifests       ← list of data and delete files
                ▼
            s3://lake/orders/data/….parquet
```

- Every reference in these files is a **full path** such as `s3://lake/orders/...`.
- So copying the files to `abfss://...` isn't enough. The copied metadata would still point at S3.
- Every commit writes a new `metadata.json`, and old data files are never changed in place, only added or later deleted.

## 2. What `rewrite_table_path` does, and what it doesn't

For a range of `metadata.json` versions (from `start_version` to `end_version`), it:

1. **Rewrites the metadata:** writes new copies of those `metadata.json` files, their manifest lists and their manifests to a *staging* folder, with `s3://lake/orders` replaced by `abfss://…/orders`.
2. **Writes a file list:** a CSV of `source_path,target_path` pairs covering:
   - the rewritten metadata files (from staging to the target)
   - the data and delete files **added in that range** (from the source to the target).

It **copies nothing itself**, and it doesn't touch any catalog. The copying and the catalog update are your job.

## 3. Worked example

**Source on AWS:**

| Version | What happened | Data files referenced |
|---|---|---|
| v1 | insert | A, B |
| v2 | append | A, B, C |
| ― **Sync 1 (full): copies v1–v2 metadata + A, B, C** ― | | |
| v3 | `DELETE` rows in B (copy-on-write rewrites B → B′) | A, B′, C |
| v4 | compaction A + C → D | B′, D |
| v5 | `expire_snapshots` (removes old snapshots, deletes A, B, C on S3) | B′, D |

**Sync 2 (incremental):**

```sql
CALL aws.system.rewrite_table_path(
  table            => 'sales.orders',
  source_prefix    => 's3://lake/orders',
  target_prefix    => 'abfss://lake@acct.dfs.core.windows.net/replica_aws/orders',
  start_version    => '00002-….metadata.json',   -- last version you replicated (your watermark)
  staging_location => 's3://lake/_repl/orders/run-0002/');
```

The file list then contains only:
- the rewritten metadata for v3, v4 and v5 (metadata.json files, manifest lists, new manifests)
- data files **B′ and D**.

A, B and C aren't in it, because they were copied in sync 1. That's where the delta comes from: only new files cross the cloud boundary.

## 4. The steps you build around it

| Step | What | Why |
|---|---|---|
| 1 | Read the watermark (`00002-….metadata.json`) | Tells `start_version` where to begin |
| 2 | Run `rewrite_table_path` | Produces the staged metadata and the file list |
| 3 | Copy the **data files** (B′, D), using AzCopy, DataSync or ADF driven by the CSV | Must come first |
| 4 | Copy the **manifests and manifest lists**, then the **`metadata.json`** files | Each file only points at files that already exist on the target |
| 5 | **Point the target catalog** at the new `00005-….metadata.json` | Iceberg has no "move pointer" command (see below) |
| 6 | Store the new watermark `00005-….metadata.json` | Next run starts here |
| 7 | Clean up the target (see §5) | Removes files the source has deleted |

**How to move the pointer (step 5) depends on the target catalog:**
- **Hive Metastore:** `ALTER TABLE … SET TBLPROPERTIES ('metadata_location'='…/00005-….metadata.json')`.
- **AWS Glue:** an `UpdateTable` call that sets the table's `metadata_location` parameter.
- **REST catalogs (Polaris, Lakekeeper):** there's usually no "set pointer" call. Drop the table *without* deleting its files (no `PURGE`), then run `register_table` with the new `metadata.json`. Readers briefly see no table in between.

Until you move the pointer, readers on Azure still see version v2, which is consistent because all of its files are still there. After the switch they see v5. Readers never see a half-copied version.

## 5. Why the target doesn't clean itself up

After sync 2, the Azure storage holds A, B, C, B′ and D. But the replicated v5 metadata only references B′ and D.

- On AWS, `expire_snapshots` physically deleted A, B and C. That deletion isn't a file, so it never shows up in a file list.
- On Azure, A, B and C are now **orphans**: nothing references them, but you still pay to store them.

**Fix:** after moving the pointer, run Iceberg's orphan-file cleanup on the replica:

```sql
CALL az.system.remove_orphan_files(table => 'replica_aws.orders',
                                   older_than => TIMESTAMP '…now minus 1 day…');
```

It compares the files in the table's storage location with the files its metadata references, and deletes the unreferenced ones. It doesn't write a new metadata version, so the replica stays identical to the source. The `older_than` margin protects queries that started before the pointer moved and still read the old version.

Don't run `expire_snapshots` on the replica. It writes a new metadata version that the next sync would overwrite. Snapshot expiry belongs on the source, and its effect reaches the target with the next sync.

## 6. Conditions for this to work

- **The replica is read-only.** Any write on Azure creates a `metadata.json` the source doesn't know about, and the next sync overwrites it.
- **The watermark version must still exist on the source.** Iceberg keeps only the last 100 old metadata versions by default (`write.metadata.previous-versions-max`) when old-metadata cleanup is on. If more commits than that happen between syncs, or the history is otherwise gone, `start_version` can't be found and you need a new full copy.
- **Keep the same `target_prefix` on every run.** Otherwise paths written in earlier runs no longer match.
- **The copy job needs read access to S3 (data and staging) and write access to ADLS.** AWS bills egress only for the new files (B′ and D plus metadata), not the whole table.

## Sources

- [Apache Iceberg: Spark procedures (`rewrite_table_path`, `register_table`, `remove_orphan_files`)](https://iceberg.apache.org/docs/latest/spark-procedures/)
- [Apache Iceberg: Maintenance](https://iceberg.apache.org/docs/latest/maintenance/)
- [Apache Iceberg Javadoc: RewriteTablePath](https://iceberg.apache.org/javadoc/1.11.0/org/apache/iceberg/actions/RewriteTablePath.html)
- [Dremio: Disaster recovery for Iceberg tables (rewrite_table_path walkthrough)](https://www.dremio.com/blog/disaster-recovery-for-apache-iceberg-tables-restoring-from-backup-and-getting-back-online/)
