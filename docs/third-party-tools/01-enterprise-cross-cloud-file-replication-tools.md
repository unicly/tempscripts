# Enterprise tools for file replication between AWS and Azure

Commercial (and one open-source) tools that replicate **files** between S3 and Azure Blob / ADLS, as
alternatives to AWS DataSync, Databricks Lakeflow / Auto Loader, Azure Data Factory and Azure Storage Mover.

> From vendor pages, Microsoft and AWS guides, and third-party articles. Not tested. ⚠️ marks points that
> weren't confirmed (vendor marketing only, or from memory). Check S3 ↔ ADLS support, both directions and
> private connectivity with each vendor.

## Tools

| Product | Vendor | What it is | S3 ⇄ Azure | Ongoing sync or migration | Runs in your network (private) | Confidence |
|---|---|---|---|---|---|---|
| **Copy and Sync** (formerly Cloud Sync) | NetApp | SaaS console plus a "data broker" VM that you deploy | S3 ↔ Blob, both directions | Scheduled sync | ✅ Data broker in your VPC or VNet | ⚠️ From memory, not re-checked |
| **Data Migrator** | Cirata (formerly WANdisco) | Continuous, zero-downtime replication of data lakes | Microsoft lists it for ADLS Gen2 targets. S3 source not confirmed | Continuous | ✅ Self-hosted | ⚠️ Mainly for Hadoop/HDFS sources |
| **Elastic Data Migration** | Komprise | Analytics plus migration, archiving and replication | ✅ S3 source → Blob/ADLS, in Microsoft's tool guide | Migration plus replication | ✅ Self-hosted "observer" VMs | ✅ Best documented here |
| **DobiMigrate / StorageMAP** | Datadobi | Large NAS and object migrations, with checks that the copies match the source | Microsoft partner for moving data to Azure. S3 details not confirmed | Mainly migration, with incremental passes | ✅ Self-hosted | ⚠️ |
| **Resilio Platform** (Connect) | Resilio | Peer-to-peer sync engine | S3-compatible storage plus Azure | ✅ Continuous, both directions | ✅ Agents in your network | ⚠️ Vendor blog |
| **Flexify.IO** | Flexify | Multi-cloud S3 endpoint plus migration and replication | S3 ↔ Azure Blob | ✅ Replication across clouds | ⚠️ SaaS, or self-hosted engine | ⚠️ Vendor page |
| **Hammerspace** | Hammerspace | One file system spread across sites and clouds, moving data by policy | AWS and Azure instances | ✅ Policy-driven | ✅ In your VPC or VNet | ⚠️ A platform, not just a copy tool |
| **Aspera Sync** / Aspera on Cloud | IBM | High-speed transfer and sync | S3 sync is documented. Azure Blob can be attached in Aspera on Cloud | Sync | ✅ Self-hosted servers | ⚠️ Azure sync not confirmed |
| **Signiant Jet / Platform** | Signiant | Accelerated transfers between storage locations, including between companies | AWS and Azure can both be connected | Automated transfers | Partly (SaaS control) | ⚠️ |
| **CData Sync** | CData | General data replication, including S3 ↔ Blob | ✅ | Scheduled | ✅ Self-hosted | ⚠️ |
| **Commvault / Cohesity / Rubrik** | — | Backup platforms that copy data to the other cloud | Yes | Backup copies, not readable mirrors | ✅ | Backup, not file replication |
| **rclone** (+ RcloneView) | Open source | CLI `sync` command between any clouds | ✅ | Scheduled | ✅ Runs where you run it | Not enterprise-supported |

## Shortlist (data lake, both directions, private, ongoing)

1. **NetApp Copy and Sync:** closest to DataSync. Sync in both directions, with the data broker in your own network.
2. **Komprise:** the best documented for S3 → Azure, and includes analytics and reporting.
3. **Resilio:** if you need continuous sync in both directions.
4. **Cirata Data Migrator:** if you also move Hadoop or Hive data, or need live replication with no downtime.

## Applies to all of them

- **They copy files, not tables.** None understands the Delta `_delta_log` or Iceberg metadata, so table
  consistency remains your job (`DEEP CLONE` or `rewrite_table_path`). See `docs/delta/` and `docs/iceberg/`.
- **Check the Azure side.** Azure Object Replication doesn't support ADLS Gen2 accounts that use
  hierarchical namespace.
- **Use Microsoft's partner lists to shortlist.** The Azure Storage migration tools guide and validated
  partners list name which vendors support S3 sources.

## Questions to ask each vendor

| Topic | Question |
|---|---|
| Directions | S3 → ADLS Gen2 **and** ADLS Gen2 → S3? Hierarchical namespace supported? |
| Network | Can all data go through private endpoints (S3 interface endpoint, Azure Private Endpoint), with no SaaS data path? |
| Deletes | Can it mirror deletes, and can that be turned off? |
| Scale | Millions of files, parallel jobs, and how do they scale (workers, nodes)? |
| Ordering | Can it copy in a set order (e.g. `_delta_log` last) or from a manifest of files? |
| Auth | IAM roles, Entra managed identity or service principal instead of keys or SAS? |
| Licensing | Per TB, per node or subscription? Egress costs on top |

## Related

- [`../datasync/03-scalable-parallel-datasync-aws-azure.md`](../datasync/03-scalable-parallel-datasync-aws-azure.md): AWS DataSync
- [`../databricks-lakeflow/01-lakeflow-classic-file-replication-aws-azure.md`](../databricks-lakeflow/01-lakeflow-classic-file-replication-aws-azure.md): Databricks Lakeflow
- [`../databricks-lakeflow/02-auto-loader-replication-aws-azure.md`](../databricks-lakeflow/02-auto-loader-replication-aws-azure.md): Auto Loader
- [`../azure-data-factory/01-adf-replication-aws-azure.md`](../azure-data-factory/01-adf-replication-aws-azure.md): Azure Data Factory
- [`../azure-storage-mover/01-storage-mover-replication-aws-azure.md`](../azure-storage-mover/01-storage-mover-replication-aws-azure.md): Azure Storage Mover

## Sources

- [Azure Storage migration tools selection guide](https://learn.microsoft.com/en-us/azure/storage/common/storage-migration-tools)
- [Azure Storage data management and migration partners](https://learn.microsoft.com/en-us/azure/storage/solution-integration/validated-partners/data-management/partner-overview)
- [Azure Storage Migration Program](https://learn.microsoft.com/en-us/azure/storage/solution-integration/validated-partners/data-management/azure-file-migration-program-solutions)
- [Azure Storage migration guide](https://learn.microsoft.com/en-us/azure/storage/common/storage-migration-overview)
- [AWS Prescriptive Guidance: Cirata Data Migrator](https://docs.aws.amazon.com/de_de/prescriptive-guidance/latest/migration-tools/data-mobility-cirata.html)
- [Cloudchipr: Cloud migration tools](https://cloudchipr.com/blog/cloud-migration-tools)
- [Resilio: S3 and Azure sync](https://www.resilio.com/blog/amazon-s3-azure)
- [Flexify.IO multi-cloud](https://flexify.io/multi-cloud)
- [Hammerspace data platform](https://hammerspace.com/hammerspace-data-platform-datasheet/)
- [Hammerspace hybrid cloud](https://hammerspace.com/hybrid-cloud/)
- [IBM Aspera: synchronizing with AWS S3](https://www.ibm.com/docs/en/ahts/4.4.x?topic=ra-synchronizing-aws-s3-storage)
- [IBM Aspera on Cloud: attach Azure Blob](https://www.ibm.com/docs/en/aspera-on-cloud?topic=storage-attach-your-azure-blob)
- [Signiant Jet data sheet](https://www.signiant.com/resources/data-sheets/jet/)
- [Signiant Jet product tour](https://www.signiant.com/resources/videos/jet-product-tour/)
- [CData: Azure Blob to S3 replication](https://www.cdata.com/kb/tech/azureblobstorage-sync-s3.rst)
- [RcloneView: cross-cloud replication](https://rcloneview.com/support/blog/sync-wasabi-to-azure-blob-rcloneview)
- [AzTools: Azure storage replication methods](https://github.com/sarmadjari/AzTools/blob/main/Docs/azure-storage-replication-methods.md)
- [Tray.ai: S3 to Azure Blob](https://tray.ai/connectors/aws-s3-azure-blob-storage-integrations/)
- [ADF: migrate S3 to Azure Storage](https://learn.microsoft.com/en-us/azure/data-factory/data-migration-guidance-s3-azure-storage)
