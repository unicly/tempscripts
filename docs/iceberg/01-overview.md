# Apache Iceberg — Part 1: Overview & File Layout

Apache Iceberg is an **open table format** for large analytic datasets stored in object storage (e.g. Amazon S3). It is not a storage engine or a file format itself. It is a specification for how a set of ordinary data files (Parquet, ORC or Avro) plus a tree of metadata files together describe **one table**.

Engines such as Spark, Trino, Flink, Amazon Athena, Amazon EMR and AWS Glue read that metadata to know exactly which files make up the table at a given point in time.

> **Series**
> 1. **Overview & File Layout** (this file)
> 2. [Metadata Files in Detail](02-metadata-files.md)
> 3. [Reads, Writes & Maintenance](03-operations.md)

---

## Why Iceberg Exists

Classic "Hive-style" tables define a table as *"every file under this directory"*. That causes problems at scale:

| Problem with directory-based tables | How Iceberg solves it |
|---|---|
| Listing millions of S3 objects is slow and expensive | The table's file list is stored in metadata; no directory listing needed |
| Readers can see half-written data | Commits are **atomic**: a single pointer swap makes a new version visible |
| Changing partitioning requires rewriting the table | **Partition evolution**: old and new layouts coexist |
| Renaming/reordering columns can corrupt reads | Columns are tracked by **ID**, not by name or position |
| No way to query yesterday's data | Every commit is a **snapshot**; you can time travel |

---

## The Layers

An Iceberg table is a tree with four layers of files, plus a catalog that points at the root:

```text
                   ┌──────────────────────────┐
                   │         Catalog          │   (Glue, Hive Metastore, REST, Nessie…)
                   │ db.table → current       │
                   │   metadata file location │
                   └────────────┬─────────────┘
                                │
                                ▼
                   ┌──────────────────────────┐
  Metadata layer   │  vN.metadata.json        │   schema, partition spec, snapshots list,
                   │  (table metadata file)   │   current-snapshot-id
                   └────────────┬─────────────┘
                                │  one per snapshot
                                ▼
                   ┌──────────────────────────┐
                   │  snap-<id>.avro          │   list of manifests for this snapshot
                   │  (manifest list)         │   + partition summary per manifest
                   └──────┬────────────┬──────┘
                          │            │
                          ▼            ▼
                   ┌────────────┐ ┌────────────┐
                   │ manifest   │ │ manifest   │   list of data/delete files
                   │ (.avro)    │ │ (.avro)    │   + per-file stats (row count,
                   └──┬─────┬───┘ └─────┬──────┘     min/max per column, nulls…)
                      │     │           │
  Data layer          ▼     ▼           ▼
                   ┌─────┐┌─────┐   ┌─────┐
                   │.parq││.parq│   │.parq│        the actual rows
                   └─────┘└─────┘   └─────┘
```

| Layer | File type | One per… | Contains |
|---|---|---|---|
| **Catalog** | (service, not a file) | table | Pointer to the *current* metadata file |
| **Table metadata** | `*.metadata.json` | table version (commit) | Schemas, partition specs, sort orders, snapshot history, properties |
| **Manifest list** | `snap-*.avro` | snapshot | Which manifests make up the snapshot, with partition bounds |
| **Manifest** | `*.avro` | group of data files | Which data/delete files exist, with column-level stats |
| **Data / delete files** | `.parquet` / `.orc` / `.avro` | — | Table rows, or rows to be deleted |

---

## What It Looks Like on S3

A typical table location:

```text
s3://my-bucket/warehouse/sales_db.db/orders/
├── metadata/
│   ├── 00000-3f2a...metadata.json        ← version 0 (table created)
│   ├── 00001-8b1c...metadata.json        ← version 1 (first insert)
│   ├── 00002-d47e...metadata.json        ← version 2 (current)
│   ├── snap-6123...-1-a1b2....avro       ← manifest list for snapshot 6123…
│   ├── snap-7456...-1-c3d4....avro       ← manifest list for snapshot 7456…
│   ├── a1b2...-m0.avro                   ← manifest file
│   └── c3d4...-m0.avro                   ← manifest file
└── data/
    ├── order_date=2024-05-01/
    │   └── 00000-0-9e8f....parquet
    └── order_date=2024-05-02/
        ├── 00000-1-1a2b....parquet
        └── 00001-1-3c4d....parquet
```

Key points:

- **Files are immutable.** Iceberg never edits a file in place. Every change writes *new* files and a *new* metadata file.
- **The directory layout is not authoritative.** The `order_date=…` folders are just a naming convention. A file only belongs to the table if a manifest references it. Stray files in `data/` are ignored.
- **The catalog is the only mutable thing.** "Committing" means atomically switching the catalog pointer from `00001-…metadata.json` to `00002-…metadata.json`.

---

## Core Concepts in One Paragraph Each

**Snapshot.** The complete state of the table at one moment: the exact set of data files that are "live". Each write produces a new snapshot. Old snapshots stay readable until they are expired.

**Schema evolution.** Each column has a permanent numeric **field ID**. Renaming a column changes only its name in metadata; files keep referring to the ID. Adding, dropping, renaming, reordering and widening types (e.g. `int → long`) are all metadata-only operations.

**Hidden partitioning.** You partition by a *transform* of a column (`day(order_ts)`, `bucket(16, customer_id)`, `truncate(10, sku)`). Users filter on `order_ts` directly and Iceberg prunes partitions for them. No extra `order_date` column is needed.

**Partition evolution.** The partition spec can change over time (e.g. `month` → `day`). Old files keep their old spec and new files use the new one. Queries plan across both.

**Format versions.**
- **v1**: analytic tables, append/overwrite only.
- **v2**: adds **row-level deletes** (delete files), which enables `UPDATE`, `DELETE` and `MERGE` without rewriting whole files.
- **v3**: adds deletion vectors, row lineage, default column values and new types (`variant`, geospatial, nanosecond timestamps).

---

Next: **[Part 2 — Metadata Files in Detail →](02-metadata-files.md)**
