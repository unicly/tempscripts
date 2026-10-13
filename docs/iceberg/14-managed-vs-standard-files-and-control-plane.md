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

## Sharing managed Iceberg tables: do you need "open sharing"?

Not necessarily. "OpenSharing" (formerly Delta Sharing) is the name of the feature, and it has two
modes. With Databricks on both clouds you need the feature, but in its **Databricks-to-Databricks**
mode, not the "open sharing" mode.

| | **Databricks-to-Databricks** | **Open sharing** |
|---|---|---|
| Recipient | Another Unity Catalog metastore (any cloud, any region, any account) | A non-Databricks client: Spark, pandas, Power BI, or Iceberg clients such as Trino, Snowflake, PyIceberg |
| Authentication | Recipient's metastore sharing identifier, no tokens to manage | Bearer token or OIDC federation |
| Managed Iceberg tables | ✅ Supported | ⚠️ Docs contradict each other: one page says managed Iceberg can't be shared to external Iceberg clients, a 2026 blog says Iceberg clients are supported |
| AWS ↔ Azure case | ✅ **Use this** | Only needed if a non-Databricks engine must read the share |

### Setting up Databricks-to-Databricks sharing

| Step | Where | Example |
|---|---|---|
| 1 | Recipient side (for example Azure): get the metastore's sharing identifier | `SELECT CURRENT_METASTORE();` → `azure:westeurope:<uuid>` |
| 2 | Provider side (AWS): create the recipient | `CREATE RECIPIENT azure_prod USING ID 'azure:westeurope:<uuid>';` |
| 3 | Provider side: create the share and add the table | `CREATE SHARE aws_to_azure; ALTER SHARE aws_to_azure ADD TABLE sales.orders;` |
| 4 | Provider side: grant access | `GRANT SELECT ON SHARE aws_to_azure TO RECIPIENT azure_prod;` |
| 5 | Recipient side: mount the share as a catalog | `CREATE CATALOG aws_share USING SHARE <provider>.aws_to_azure;` |

For Azure → AWS, do the same in the other direction.

**Requirements:**
- Unity Catalog on both sides.
- `CREATE RECIPIENT` and `CREATE SHARE` privileges on the provider's metastore.
- `USE CATALOG` / `SELECT` for users on the recipient side.

### Limits for shared managed Iceberg tables

- **Read-only** for the recipient. Copies are made with `CREATE TABLE … AS SELECT`, `MERGE` or deep clone (doc 12).
- **No change data feed**, so deltas need a watermark or an outbox table.
- Python connectors, Tableau and Power BI can't query shared managed Iceberg tables.
- **Egress:** the provider's cloud bills cross-cloud reads every time the recipient queries.
- Sharing managed Iceberg was marked **Public Preview** in the docs found. A release note may already list it as generally available, so check your workspace.

### Alternatives without a share

- **External engines through Unity Catalog's Iceberg REST catalog** (Spark, Trino, PyIceberg) can read and write managed Iceberg directly, with a service principal on the source metastore. No share is needed.
- What doesn't work: attaching an Azure workspace to the AWS metastore. A metastore is tied to one cloud and region, so sharing or the REST catalog are the only ways across.

**For an AWS ↔ Azure setup:** use OpenSharing in **Databricks-to-Databricks** mode, one share per
direction. The open sharing mode is only needed for non-Databricks readers.

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
- [Databricks: What is OpenSharing?](https://docs.databricks.com/aws/en/opensharing/)
- [Databricks: Create shares for OpenSharing](https://docs.databricks.com/aws/en/opensharing/create-share)
- [Databricks: Read data shared using Databricks-to-Databricks OpenSharing](https://docs.databricks.com/aws/en/opensharing/read-data-databricks)
- [Databricks: Read data shared with bearer tokens (open sharing)](https://docs.databricks.com/aws/en/opensharing/read-data-open)
- [Databricks blog: First-class Iceberg support in Delta Sharing](https://www.databricks.com/blog/announcing-first-class-support-iceberg-format-databricks-delta-sharing)
- [Azure Databricks: What is Delta Sharing?](https://docs.azure.cn/en-us/databricks/delta-sharing/)
