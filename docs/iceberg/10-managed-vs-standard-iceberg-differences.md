# Managed Iceberg vs. standard Iceberg: main differences

Comparison of **Databricks managed Iceberg tables** (owned by Unity Catalog) and **standard
Iceberg tables** (owned by your own catalog).

> Based on the Databricks and Apache Iceberg documentation. Not tested on real tables.
> ⚠️ marks points that are unconfirmed or still in preview.

| Aspect | Databricks managed Iceberg table | Standard Iceberg table |
|---|---|---|
| **Who owns the metadata** | Unity Catalog. It's the only writer of `metadata.json` | Your catalog: Glue, Hive Metastore, Polaris, Lakekeeper, Nessie… |
| **Status** | ⚠️ Public Preview, Databricks Runtime 16.4+ (Iceberg v3 needs 18.0+) | Mature open-source standard |
| **Storage location** | Chosen by Unity Catalog. A `LOCATION` clause isn't allowed | Any path you choose (S3, ADLS…) |
| **Write from Databricks** | ✅ | ❌ Read-only, and only if the catalog is Glue, Hive Metastore or Snowflake Horizon (as a foreign table) |
| **Write from other engines** (Spark, Trino, Flink…) | ✅ Through Unity Catalog's Iceberg REST catalog, with temporary storage access issued by Unity Catalog | ✅ Through your own catalog |
| **Governance** | Unity Catalog permissions, lineage and audit, for Databricks and other engines | Whatever your catalog offers |
| **Storage credentials** | Issued by Unity Catalog per request | You configure IAM roles, SAS tokens or service principals |
| **Maintenance** (compaction, snapshot expiry, cleanup) | Automatic (predictive optimization) | You schedule it yourself |
| **File format** | Parquet only | Parquet, ORC, Avro |
| **Partition transforms** (`days()`, `bucket()`…) | ❌ | ✅ |
| **Row-level deletes** | v2: rewrites files on change. v3: deletion vectors | All Iceberg delete types |
| **Data types** | No UUID, Fixed(L), TIME, or nested STRUCT with required fields | All Iceberg types |
| **Change data feed** | ❌ | Not applicable. Iceberg's changelog view and incremental reads do this job |
| **Streaming source in Databricks** | ⚠️ Reported as not supported | ✅ With Spark or Flink |
| **Register existing files** (`register_table`) | ❌ | ✅ |
| **Rewrite file paths for copying** (`rewrite_table_path`) | ❌ | ✅ |
| **Iceberg Spark procedures** (changelog view, `expire_snapshots`…) | ❌ On Databricks clusters, which can't load the open-source Iceberg libraries | ✅ On any open-source Spark with the Iceberg runtime |
| **Deep clone** | ✅ Full copy each run, no history. Shallow clone ❌ | Only by cloning into Unity Catalog, where the copy becomes managed Iceberg or Delta |
| **OpenSharing** (Databricks to Databricks) | ✅ | ⚠️ Private Preview, only for foreign tables from Glue, Hive Metastore or Snowflake Horizon |
| **Exact copy with history on the other cloud** | ❌ | ✅ `rewrite_table_path`, file copy and `register_table` |
| **Copy files with storage tools** (AzCopy, DataSync, ADF) | ❌ | ✅ |
| **Lock-in** | Writes require Unity Catalog or its REST catalog | No dependence on one catalog or engine |
| **Effort to run** | Low | High: catalog, maintenance and copy pipelines |

## In short

- **Managed Iceberg** is easy to run and fully governed inside Databricks. For replication you're
  limited to sharing, SQL, and engines that connect through Unity Catalog.
- **Standard Iceberg** gives you full control and an exact copy of the files with history, but you
  operate everything yourself. Databricks can only read it, and only from Glue, Hive Metastore or
  Snowflake Horizon.

The longer versions are in
[`06-managed-iceberg-replication-deep-dive.md`](06-managed-iceberg-replication-deep-dive.md) (§1) and
[`07-standard-iceberg-replication-deep-dive.md`](07-standard-iceberg-replication-deep-dive.md) (§1).

## Sources

- [Databricks: What is Apache Iceberg in Databricks?](https://docs.databricks.com/aws/en/iceberg/)
- [Databricks: Unity Catalog managed tables (Delta and Iceberg)](https://docs.databricks.com/aws/tables/managed)
- [Databricks: Use Apache Iceberg v3 features](https://docs.databricks.com/aws/en/iceberg/iceberg-v3)
- [Databricks: Clone a managed Iceberg table](https://learn.microsoft.com/en-us/azure/databricks/iceberg/clone)
- [Databricks: Access Databricks tables from Apache Iceberg clients](https://learn.microsoft.com/en-us/azure/databricks/external-access/iceberg)
- [Databricks: Work with foreign tables](https://learn.microsoft.com/en-us/azure/databricks/tables/foreign)
- [Apache Iceberg: Spark procedures](https://iceberg.apache.org/docs/latest/spark-procedures/)
