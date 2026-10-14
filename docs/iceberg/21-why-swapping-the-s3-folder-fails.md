# Why replacing a managed Iceberg table's S3 folder with another table's folder fails

Use case: create an Iceberg table on Databricks (this creates a folder in S3), delete that folder,
and put the folder of **another** Iceberg table in its place. Databricks doesn't accept it.

- Where does it fail?
- Can Databricks be made to recognize the new folder?
- What in the S3 folder says it belongs to another table, or is that information only in Databricks?

> Reasoning from the Iceberg spec and how Unity Catalog works. Not tested, and Databricks doesn't
> document what happens when you swap folders (⚠️).

## Short answer

It fails at the very first step: Unity Catalog looks for an **exact `metadata.json` file name** that
isn't in the new folder. Even if you got past that, the other table's files say **which table they
belong to and where its files live**. So the information is in both places: Unity Catalog holds the
pointer, and the Iceberg metadata files identify the table.

## Where it fails, step by step

```
Unity Catalog (table A)
  table id  = 7f3a…                ← UC's own record
  location  = s3://uc-bucket/__unitystorage/…/tables/7f3a…/
  pointer   = …/tables/7f3a…/metadata/00003-1b2c….metadata.json   ← exact file name
  schema, permissions, …
        │
        ▼  ❶ Databricks opens exactly this file
S3 folder …/tables/7f3a…/   (now containing table B's files)
  metadata/00012-9e8d….metadata.json      ← B's file, different name → "file not found"
     "table-uuid": "c41e…"                ← ❷ B's identity, not A's
     "location":  "s3://other-bucket/warehouse/b/"   ← ❸ B's original location
     snapshots → manifest-list: "s3://other-bucket/warehouse/b/metadata/snap-….avro"
                     └ manifests → data files: "s3://other-bucket/warehouse/b/data/….parquet"   ← ❹ absolute paths
```

| # | Failure point | Why |
|---|---|---|
| ❶ | **Pointer to a missing file** | Unity Catalog stores the **full path of one specific `metadata.json`** (e.g. `00003-1b2c….metadata.json`). Table B's metadata files have other names, so Databricks finds nothing to read. This is where it fails first |
| ❷ | **Different table identity** | Every `metadata.json` contains a **`table-uuid`**. Iceberg catalogs check that a commit's `table-uuid` matches the table being committed to ⚠️, so writes would be rejected even if reads worked |
| ❸ | **Different table location** | `metadata.json` contains B's original **`location`**. Unity Catalog expects A's location. New files would be written relative to the wrong place |
| ❹ | **Absolute paths to B's original files** | Manifest lists, manifests and data files are referenced by **full path** (`s3://other-bucket/…/b/…`). Even with the right file name, Databricks would try to read from **B's original bucket**. Unity Catalog's storage credentials only cover A's managed location, so: access denied, or files not found |
| ❺ | **Unity Catalog's own copy of the schema** | Unity Catalog stores the column list, field IDs and properties of table A. B's schema, field IDs and partition spec don't match ⚠️ |
| ❻ | **Maintenance** | If something did load, predictive optimization could treat B's files as orphans and delete them, or expire snapshots based on the wrong history |

## What in the S3 folder identifies the table

| File | Identifying content |
|---|---|
| `metadata/*.metadata.json` | `table-uuid`, `location`, schemas with field IDs, partition specs, snapshot list (snapshot IDs, sequence numbers), `metadata-log` with the previous `metadata.json` paths (absolute) |
| `metadata/snap-*.avro` (manifest lists) | Absolute paths to manifests, plus snapshot ID and sequence number |
| `metadata/*.avro` (manifests) | Absolute paths to data and delete files, partition values, statistics |
| `data/*.parquet` | Only data. Parquet files carry column field IDs that must match the schema, but no table identity |
| The folder name (`…/tables/7f3a…/`) | Meaningful **only to Unity Catalog**. Iceberg itself doesn't care about the folder name |

**So who knows what:**

- **The S3 files** know *which table they are* (`table-uuid`) and *where their files are* (absolute paths).
- **Unity Catalog** knows *which table the name refers to*, *where it lives*, and *which exact
  `metadata.json` is current*, plus the schema and permissions.

Both have to agree, and swapping the folder breaks both.

## Can you make Databricks recognize the new folder?

Not by swapping files. Unity Catalog won't let you change a managed table's pointer, location or
`table-uuid`, and managed Iceberg has no `register_table` or `LOCATION`
([`17-…md`](17-why-databricks-uses-versions-and-missing-functions.md)). In theory you could rewrite B's
paths to A's location and forge a `metadata.json` with A's file name and UUID. That would be
unsupported and fragile, and Unity Catalog's next commit or maintenance would very likely corrupt the
table. Don't do it.

**Supported ways to put table B's data into table A:**

| Where table B is | How | Result |
|---|---|---|
| B is a **managed** table in Unity Catalog | `CREATE OR REPLACE TABLE A DEEP CLONE B` or `INSERT OVERWRITE A SELECT * FROM B` | A now holds B's data (A's own history continues, or a new one with `REPLACE`) |
| B is in **Glue / Hive Metastore** | Federate the catalog ([`15-…md`](15-add-foreign-iceberg-table-to-unity-catalog.md)), then `CREATE OR REPLACE TABLE A DEEP CLONE glue_cat.db.b` | Same |
| B is only a **folder** with Iceberg files (no catalog) | `register_table` in Glue (or PyIceberg `StaticTable`), then federate and clone. Or use OSS Spark: read B and write into A through Unity Catalog's Iceberg REST catalog | Same |
| B is on **another cloud / metastore** | OpenSharing + `DEEP CLONE` or `CREATE TABLE … AS SELECT` ([`12-…md`](12-managed-iceberg-summary-aws-azure.md)) | Same |

All of these **copy the data through Unity Catalog**, so Unity Catalog writes new files with A's
identity and location and moves its own pointer forward.

## For comparison: Delta

With an **external Delta** table, swapping the folder mostly *does* work. The log is in the folder
(`_delta_log/`), its paths are relative, and there's no table UUID check against the catalog in the
classic setup ⚠️. Databricks simply reads the new log the next time it accesses the table. With
**managed** Delta tables, don't swap folders either: Unity Catalog and predictive optimization assume
they own those files.

## In short

It fails first because Unity Catalog points to an exact `metadata.json` that no longer exists. Behind
that, B's metadata carries its own `table-uuid`, its own location and absolute paths to its original
files. The table's identity is partly in the S3 files and partly in Unity Catalog. To use B's data in
A, copy it through Unity Catalog with a clone or `INSERT OVERWRITE`. Swapping files won't work.

## Related

- [`22-copying-folder-into-recreated-table-works.md`](22-copying-folder-into-recreated-table-works.md): a related case that **did** work in practice (copying a table's own old folder into its recreated table), with checks to explain why
- [`14-managed-vs-standard-files-and-control-plane.md`](14-managed-vs-standard-files-and-control-plane.md): same files, different control plane
- [`16-managed-iceberg-on-aws-glue-storage.md`](16-managed-iceberg-on-aws-glue-storage.md): where the table is stored, one owner per table
- [`08-incremental-rewrite-table-path-explained.md`](08-incremental-rewrite-table-path-explained.md): why Iceberg paths are absolute and how they're rewritten

## Sources

- [Apache Iceberg: Table spec (`table-uuid`, `location`, manifests, absolute paths)](https://iceberg.apache.org/spec/)
- [Apache Iceberg: REST catalog OpenAPI spec (commit requirements such as `assert-table-uuid`)](https://github.com/apache/iceberg/blob/main/open-api/rest-catalog-open-api.yaml)
- [Databricks: What is Apache Iceberg in Databricks?](https://docs.databricks.com/aws/en/iceberg/)
- [Databricks: Unity Catalog managed tables](https://docs.databricks.com/aws/tables/managed)
- [Databricks: Clone a managed Iceberg table](https://learn.microsoft.com/en-us/azure/databricks/iceberg/clone)
- [Databricks: Access Databricks tables from Apache Iceberg clients](https://learn.microsoft.com/en-us/azure/databricks/external-access/iceberg)
