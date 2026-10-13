# Managed vs. standard Iceberg: same files, different control plane

Are the files of a Databricks managed Iceberg table the same as those of a standard Iceberg table?
And if so, where are the differences?

> Based on the Databricks and Apache Iceberg documentation. Not tested on real tables.
> ⚠️ marks points that are inferred or unconfirmed.

## Short answer

Mostly yes. On disk, a managed Iceberg table uses the same file types as a standard one:
`metadata.json`, manifest lists, manifests and Parquet data files. That's why external engines can
read it through the Iceberg REST catalog. The differences sit almost entirely **above the files**:
who controls them, and what you're allowed to do with them.

## Where the differences are, layer by layer

| Layer | Managed Iceberg (Databricks) | Standard Iceberg | Same or different? |
|---|---|---|---|
| **Data files** | Parquet | Parquet, ORC or Avro | Same format, but managed is Parquet only |
| **Metadata files** (`metadata.json`, manifests) | Iceberg spec | Iceberg spec | Same format ⚠️ (see caveats below) |
| **Table features used** | Restricted: no partition transforms, no UUID / Fixed / TIME types, v2 without delete files, v3 with deletion vectors | Everything the spec allows | Different: Unity Catalog decides what gets written |
| **Catalog pointer** (which `metadata.json` is current) | Held by **Unity Catalog** | Held by **your catalog** (Glue, Polaris, Hive Metastore…) | **Different: this is the core difference** |
| **Who may commit** | Only through Unity Catalog: Databricks, or engines using its Iceberg REST catalog | Any engine using your catalog | Different |
| **Storage location** | Chosen by Unity Catalog in its managed storage. No `LOCATION` | Chosen by you | Different |
| **Registering existing files** | ❌ No `register_table`, no path rewriting | ✅ | Different |
| **Access control** | Unity Catalog permissions, row filters, column masks, audit, lineage | Whatever your catalog and IAM offer | Different |
| **Storage credentials** | Issued per request by Unity Catalog | You manage IAM roles / SAS keys | Different |
| **Maintenance** (compaction, snapshot expiry, cleanup) | Automatic (predictive optimization) | You schedule it | Different |
| **Lifecycle** | `DROP` → data deleted after 8 days, `UNDROP` possible | `DROP` without `PURGE` keeps files. You decide | Different |
| **Engines and tools** | Databricks SQL / Spark; external engines only through the REST catalog; no OSS Iceberg procedures on Databricks clusters | Any Iceberg engine, all Iceberg procedures | Different |
| **Sharing** | OpenSharing between Databricks workspaces | Only via federation (⚠️ Private Preview) | Different |

## A simple way to picture it

```
                Managed Iceberg                       Standard Iceberg
           ┌──────────────────────────┐          ┌──────────────────────────┐
 Control   │ Unity Catalog            │          │ Your catalog (Glue, …)   │
 plane     │ pointer, commits, ACLs,  │          │ pointer, commits         │
           │ credentials, maintenance │          │ (+ your IAM, your jobs)  │
           └────────────┬─────────────┘          └────────────┬─────────────┘
                        │                                     │
 Files      metadata.json → manifests → Parquet   metadata.json → manifests → Parquet
 (S3/ADLS)          same Iceberg spec                    same Iceberg spec
```

The **files** follow the same spec. The **control plane** is different. With a managed table, Unity
Catalog is the only gatekeeper:

- it holds the pointer to the current version
- it decides who may write
- it chooses where the files live
- it runs maintenance.

That's why the file-level tools (`register_table`, `rewrite_table_path`, AzCopy-based replication)
work on standard tables but not on managed ones. The files would be readable, but Unity Catalog
won't accept them back. It's also why data can still be recovered from managed storage through
standard Iceberg tools in an emergency (see
[`12-managed-iceberg-summary-aws-azure.md`](12-managed-iceberg-summary-aws-azure.md), §2.3).

## Caveats about "same files"

- ⚠️ I haven't seen Databricks document the exact file layout in managed storage. This is inferred
  from the fact that external engines read these tables through the standard Iceberg REST catalog.
- ⚠️ One user on the Databricks community forum reported that Databricks wrote Iceberg v3 deletion
  vectors as `.bin` files instead of the Puffin format the spec requires, and another engine couldn't
  read them. That's unconfirmed, but it means v3 managed tables may not be fully interchangeable. On
  v2 that question doesn't arise.
- Unity Catalog adds its own table properties and naming conventions. Other engines ignore those,
  but they're not part of a typical standard table.

## In short

Same data and metadata format, different owner. A standard table is files plus a catalog you
control. A managed table is the same kind of files, with Unity Catalog in full control of them.

## Related

- [`10-managed-vs-standard-iceberg-differences.md`](10-managed-vs-standard-iceberg-differences.md): full differences table
- [`12-managed-iceberg-summary-aws-azure.md`](12-managed-iceberg-summary-aws-azure.md): managed Iceberg backup, restore and replication
- [`13-standard-iceberg-summary-aws-azure.md`](13-standard-iceberg-summary-aws-azure.md): standard Iceberg backup, restore and replication

## Sources

- [Databricks: What is Apache Iceberg in Databricks?](https://docs.databricks.com/aws/en/iceberg/)
- [Databricks: Unity Catalog managed tables (Delta and Iceberg)](https://docs.databricks.com/aws/tables/managed)
- [Databricks: Use Apache Iceberg v3 features](https://docs.databricks.com/aws/en/iceberg/iceberg-v3)
- [Databricks: Access Databricks tables from Apache Iceberg clients](https://learn.microsoft.com/en-us/azure/databricks/external-access/iceberg)
- [Databricks Community: Iceberg v3 deletion vector compatibility issue](https://community.databricks.com/t5/data-engineering/cross-engine-iceberg-v3-compatibility-issue-databricks-delete/td-p/164734)
- [Apache Iceberg: Spark procedures](https://iceberg.apache.org/docs/latest/spark-procedures/)
