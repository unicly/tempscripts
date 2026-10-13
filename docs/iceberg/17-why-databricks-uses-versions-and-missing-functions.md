# Where managed and standard Iceberg really differ: versions vs. snapshots and missing functions

If the files in S3 are standard Iceberg, where does the difference between managed and standard
Iceberg come from? Why does Databricks show "versions" instead of snapshots, and why are some Iceberg
functions not available on Databricks?

> Based on Databricks and Apache Iceberg documentation. Part of this is inferred, not documented by
> Databricks (⚠️). Not tested.

## Short answer

The difference isn't in the files in S3. It's in the three layers **above** the files:

- **the catalog** (Unity Catalog), which decides who may commit
- **the engine** (Databricks Runtime), which reads and writes the files
- **the SQL commands** Databricks offers on top.

Databricks writes standard Iceberg files, but through its own engine and its own commands. Those were
built around Delta, and they only implement part of the open-source Iceberg toolset.

## Four layers

| Layer | Standard Iceberg (e.g. EMR Spark + Glue) | Managed Iceberg on Databricks | Difference? |
|---|---|---|---|
| **1. Files in S3** (`metadata.json`, manifests, Parquet) | Iceberg spec | Iceberg spec | Same |
| **2. Catalog / commit** (who moves the pointer) | Glue, Polaris… Any engine may commit | **Unity Catalog** only. Every commit goes through it | Ownership |
| **3. Engine** (code that reads and writes) | Open-source Iceberg library in Spark, Trino or Flink | **Databricks' own implementation** inside Databricks Runtime, which grew out of the Delta engine | Implementation |
| **4. Commands** | Iceberg's commands: `CALL system.*` procedures, `.snapshots` / `.history` metadata tables | **Databricks' commands**, shared by Delta and Iceberg: `DESCRIBE HISTORY`, `VERSION AS OF`, `RESTORE`, `OPTIMIZE`, `CLONE` | What you can type |

Everything you notice as "different" comes from layers 2–4.

## Why "versions" instead of snapshots

- Databricks gives **one command set for Delta and Iceberg tables**. `DESCRIBE HISTORY`, `VERSION AS OF` and `RESTORE` come from Delta, where a table change is called a **version**.
- For a managed Iceberg table, each such version corresponds to an **Iceberg snapshot** in the files ⚠️ inferred. That's why external engines using the Iceberg REST catalog see a normal `$snapshots` table with snapshot IDs.
- So it's the **same history under two names**: "version" in Databricks commands, "snapshot ID" in the Iceberg files and in other engines.
- One Databricks community post reports that Iceberg's `snapshots` metadata table works from Databricks' Python/Spark API but not in Databricks SQL. That's unofficial.
- **Delta tables with Iceberg reads (UniForm)** are different. There, Delta versions are the real history. Iceberg snapshots are only generated from them, in the background, and their numbers and timestamps don't match. That's the case where Trino showed incomplete snapshots (see the sources section of [`06-…md`](06-managed-iceberg-replication-deep-dive.md)).

## Why some functions aren't available in Databricks

| Missing in Databricks | Reason | Category |
|---|---|---|
| `CALL system.rewrite_table_path`, `register_table`, `LOCATION` | They would let something other than Unity Catalog decide where the table lives or which files belong to it. **Blocked on purpose** | Ownership (layer 2) |
| `CALL system.expire_snapshots`, `rewrite_data_files`, `remove_orphan_files` | Unity Catalog does this itself with **predictive optimization**. Manual maintenance would compete with it | Ownership (layer 2) |
| `CALL system.create_changelog_view`, `rollback_to_snapshot` and the other OSS procedures | Databricks Runtime **doesn't include the open-source Iceberg Spark extensions**, which provide `CALL system.*`. Loading the OSS Iceberg libraries on a Databricks cluster isn't supported | Engine (layer 3) |
| Partition transforms (`days()`, `bucket()`), UUID / Fixed / TIME types, v2 position/equality deletes | **Not implemented yet** in Databricks' Iceberg writer (Public Preview). Databricks uses liquid clustering and v3 deletion vectors instead | Engine (layer 3) |
| Change data feed, generated columns, constraints | **Delta features** that have no equivalent in the Iceberg spec, so Databricks doesn't offer them for Iceberg tables | Spec (layer 1) |
| Streaming from a managed Iceberg table | Databricks' streaming source isn't built for Iceberg yet ⚠️ (community reports) | Engine (layer 3) |

## The same table seen from two sides

```
                       Databricks (inside)                   Spark / Trino via Unity Catalog's REST catalog (outside)
 Commands       DESCRIBE HISTORY, VERSION AS OF,              SELECT … FROM t$snapshots, FOR VERSION AS OF <snapshot_id>,
                RESTORE, OPTIMIZE, DEEP CLONE                 CALL system.create_changelog_view(...) (client-side)
 Engine         Databricks Runtime (Delta-heritage engine)     Open-source Iceberg library
 Catalog        ─────────────── Unity Catalog (single owner of commits) ───────────────
 Files          ─────────────── standard Iceberg files in S3 ───────────────
```

So some Iceberg functions that Databricks doesn't offer still work **from outside**, through the REST
catalog. Examples are the snapshot metadata tables, time travel by snapshot ID, and client-side
procedures like the changelog view, which only read. Commands that would change ownership
(`register_table`, `rewrite_table_path`, setting the location) are refused there too, because Unity
Catalog stays the only owner.

## In short

The files are standard Iceberg. Unity Catalog owns the commits, Databricks' own engine and commands
are built around Delta, and its Iceberg support is still incomplete. "Versions" are the same history
as Iceberg snapshots under Databricks' naming. Missing functions are either blocked because Unity
Catalog owns the table, or simply not built into Databricks' engine yet.

## Related

- [`14-managed-vs-standard-files-and-control-plane.md`](14-managed-vs-standard-files-and-control-plane.md): same files, different control plane
- [`10-managed-vs-standard-iceberg-differences.md`](10-managed-vs-standard-iceberg-differences.md): full differences table
- [`16-managed-iceberg-on-aws-glue-storage.md`](16-managed-iceberg-on-aws-glue-storage.md): where the table is stored, Glue federation

## Sources

- [Databricks: What is Apache Iceberg in Databricks?](https://docs.databricks.com/aws/en/iceberg/)
- [Databricks: Work with table history](https://docs.databricks.com/aws/en/tables/history)
- [Databricks: Use Apache Iceberg v3 features](https://docs.databricks.com/aws/en/iceberg/iceberg-v3)
- [Databricks: Access Databricks tables from Apache Iceberg clients](https://learn.microsoft.com/en-us/azure/databricks/external-access/iceberg)
- [Databricks (archived): External access from Iceberg clients, OSS jars not supported on clusters](https://docs.azure.cn/en-us/databricks/archive/legacy/external-access-iceberg)
- [Databricks: Read Delta tables with Iceberg clients (UniForm)](https://docs.databricks.com/aws/en/delta/uniform)
- [Databricks Community: How to access snapshots in Iceberg tables](https://community.databricks.com/t5/data-engineering/how-to-access-snapshots-in-iceberg-tables/td-p/150999)
- [Databricks Community: managed Iceberg streaming limitation](https://community.databricks.com/t5/data-engineering/iceberg-native-table-streaming-in-databricks/m-p/151456)
- [Apache Iceberg: Spark procedures](https://iceberg.apache.org/docs/latest/spark-procedures/)
- [Trino: Iceberg connector (metadata tables, time travel)](https://trino.io/docs/current/connector/iceberg.html)
