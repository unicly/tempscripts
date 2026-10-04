# Apache Iceberg — Part 2: Metadata Files in Detail

This part walks down the tree one file type at a time: what each file contains and why it is there.

> **Series**
> 1. [Overview & File Layout](01-overview.md)
> 2. **Metadata Files in Detail** (this file)
> 3. [Reads, Writes & Maintenance](03-operations.md)

---

## 1. Table Metadata File (`vN.metadata.json`)

The root of the table. It is a JSON document, and a brand-new one is written on **every commit**. It is never modified after it is written.

Trimmed example:

```json
{
  "format-version": 2,
  "table-uuid": "5f1c2e8a-4b6d-4e2f-9a1b-7c3d8e9f0a12",
  "location": "s3://my-bucket/warehouse/sales_db.db/orders",
  "last-sequence-number": 2,
  "last-updated-ms": 1714651200000,
  "last-column-id": 4,

  "current-schema-id": 0,
  "schemas": [{
    "schema-id": 0,
    "type": "struct",
    "fields": [
      { "id": 1, "name": "order_id",    "required": true,  "type": "long" },
      { "id": 2, "name": "customer_id", "required": false, "type": "long" },
      { "id": 3, "name": "amount",      "required": false, "type": "decimal(10,2)" },
      { "id": 4, "name": "order_ts",    "required": false, "type": "timestamptz" }
    ]
  }],

  "default-spec-id": 0,
  "partition-specs": [{
    "spec-id": 0,
    "fields": [
      { "source-id": 4, "field-id": 1000, "name": "order_ts_day", "transform": "day" }
    ]
  }],

  "current-snapshot-id": 7456123412341234,
  "snapshots": [
    {
      "snapshot-id": 6123123412341234,
      "sequence-number": 1,
      "timestamp-ms": 1714564800000,
      "manifest-list": "s3://.../metadata/snap-6123...-1-a1b2.avro",
      "summary": { "operation": "append", "added-data-files": "1", "added-records": "5000" }
    },
    {
      "snapshot-id": 7456123412341234,
      "parent-snapshot-id": 6123123412341234,
      "sequence-number": 2,
      "timestamp-ms": 1714651200000,
      "manifest-list": "s3://.../metadata/snap-7456...-1-c3d4.avro",
      "summary": { "operation": "append", "added-data-files": "2", "added-records": "9200" }
    }
  ],

  "snapshot-log": [ { "snapshot-id": 6123123412341234, "timestamp-ms": 1714564800000 },
                    { "snapshot-id": 7456123412341234, "timestamp-ms": 1714651200000 } ],
  "metadata-log": [ { "metadata-file": "s3://.../00001-8b1c.metadata.json", "timestamp-ms": 1714564800000 } ],

  "refs": { "main": { "snapshot-id": 7456123412341234, "type": "branch" } },
  "properties": { "write.format.default": "parquet" }
}
```

### What to notice

| Field | Purpose |
|---|---|
| `schemas` / `current-schema-id` | All historical schemas are kept, so old snapshots can still be read correctly |
| `fields[].id` | The permanent **field ID**. Data files store this ID, which makes renames safe |
| `partition-specs` | Partitioning is a *transform* (`day`) of a source column (`source-id: 4` = `order_ts`) |
| `snapshots` | Every live snapshot, each pointing to its **manifest list** |
| `current-snapshot-id` | The snapshot that a plain `SELECT` reads |
| `refs` | Named branches and tags (`main`, `audit-branch`, `eoy-2024` …) |
| `metadata-log` | Previous metadata files, used for history and cleanup |
| `sequence-number` | Monotonic commit counter. Decides which delete files apply to which data files |

---

## 2. Manifest List (`snap-<snapshot-id>-<attempt>-<uuid>.avro`)

One manifest list per snapshot. It is an Avro file where **each row describes one manifest**:

| Column | Meaning |
|---|---|
| `manifest_path` | S3 location of the manifest file |
| `manifest_length` | Size in bytes |
| `partition_spec_id` | Which partition spec the manifest's files use |
| `content` | `0` = data manifest, `1` = delete manifest |
| `sequence_number` / `min_sequence_number` | Used to order deletes against data |
| `added_snapshot_id` | Snapshot that created this manifest |
| `added_files_count` / `existing_files_count` / `deleted_files_count` | File counts by status |
| `partitions` | **Per-partition-field summary**: `contains_null`, `lower_bound`, `upper_bound` |

The `partitions` summary is the first pruning step. If a query asks for `order_ts >= '2024-05-02'` and a manifest's upper bound for `order_ts_day` is `2024-05-01`, the reader **skips that whole manifest** without opening it.

**Why a separate file?** A new snapshot usually reuses most existing manifests. The manifest list only has to say *"manifests A, B, C from before, plus new manifest D"*, so unchanged manifests are never rewritten.

---

## 3. Manifest File (`<uuid>-m<N>.avro`)

Each manifest is an Avro file where **each row describes one data file or delete file**:

| Column | Meaning |
|---|---|
| `status` | `0` EXISTING, `1` ADDED (in this snapshot), `2` DELETED (removed in this snapshot) |
| `snapshot_id` / `sequence_number` | When the file was added |
| `data_file.content` | `0` data, `1` position deletes, `2` equality deletes |
| `data_file.file_path` | S3 location of the Parquet/ORC/Avro file |
| `data_file.file_format` | `PARQUET`, `ORC`, `AVRO` (or `PUFFIN` for v3 deletion vectors) |
| `data_file.partition` | Partition tuple for this file, e.g. `{order_ts_day: 2024-05-02}` |
| `data_file.record_count` | Number of rows |
| `data_file.file_size_in_bytes` | Size |
| `data_file.column_sizes` | Bytes per column ID |
| `data_file.value_counts` / `null_value_counts` / `nan_value_counts` | Per column ID |
| `data_file.lower_bounds` / `upper_bounds` | **Min/max value per column ID** |
| `data_file.split_offsets` | Row-group offsets, so engines can split work |

This is the second pruning step. With `WHERE customer_id = 42`, any file whose `customer_id` bounds are `[100, 900]` is skipped without reading it. This is **file-level** pruning. Parquet's own row-group stats then provide a third level inside the file.

All manifests in one file share a single partition spec. That is how partition evolution works: old manifests use spec 0, new manifests use spec 1.

---

## 4. Data Files

Ordinary columnar files, usually **Parquet**. Iceberg adds only one thing to them: every column is tagged with its **field ID** in the file schema (Parquet `field_id`). Readers map columns by ID, not by name:

- Renamed column: same ID, new name in metadata, so data is still found.
- Dropped column: ID no longer in schema, so the column is ignored.
- Added column: ID not in old files, so it reads as `NULL` (or the v3 default value).

---

## 5. Delete Files (format v2+)

Row-level changes are recorded *next to* the data instead of rewriting it. This is called **merge-on-read**.

### Position deletes
List exact rows to remove, as `(file_path, pos)` pairs:

```text
file_path                                              | pos
s3://.../data/order_ts_day=2024-05-02/00000-1-1a2b.parquet | 17
s3://.../data/order_ts_day=2024-05-02/00000-1-1a2b.parquet | 342
```

### Equality deletes
Remove every row matching column values. This is cheap to write for streaming upserts (e.g. Flink CDC):

```text
order_id
1001
1007
```
*"Delete any row where `order_id` is 1001 or 1007."*

### Deletion vectors (format v3)
A compressed bitmap of deleted row positions for **one** data file, stored in a **Puffin** file. There is at most one vector per data file, which keeps reads fast compared with many small position-delete files.

### Which deletes apply?
A delete file applies to a data file only if the delete's **sequence number** is *greater than* the data file's sequence number (for equality deletes) or *greater than or equal* (for position deletes), and the partitions match. This is how Iceberg guarantees that a delete never removes rows inserted *after* it.

---

## 6. Puffin Files (`*.puffin`)

A container format for extra statistics and indexes that do not fit in manifests, for example:

- Theta sketches for **NDV** (number of distinct values), used by cost-based optimizers
- v3 **deletion vectors**

Referenced from the table metadata (`statistics`) or from manifests.

---

Previous: **[← Part 1 — Overview](01-overview.md)** · Next: **[Part 3 — Reads, Writes & Maintenance →](03-operations.md)**
