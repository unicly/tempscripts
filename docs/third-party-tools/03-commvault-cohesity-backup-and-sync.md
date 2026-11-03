# Commvault and Cohesity: one product for backup and AWS ⇄ Azure file sync?

Can **Commvault** or **Cohesity** replace a file sync tool for S3 ⇄ Azure Blob / ADLS, so that one product covers
both **backup** and **replication**? Requirements: **self-hosted** and **private network**.

> From vendor documentation and community threads (November 2026). Not tested. ⚠️ marks points that weren't
> confirmed.

## Short answer

Neither one is a file sync tool. Both are **backup** products.

- **Commvault** can back up S3 and Azure Blob and **restore a backup into the other cloud on a schedule**, so it
  could produce a delayed copy. It isn't real replication.
- **Cohesity** is a weaker fit: the S3 backup I could document is its **SaaS** service, not something you host.
- One product for both needs is only realistic with **Commvault**, and only if a copy that's **a few hours old**
  is good enough.

## Comparison

| | **Commvault** (self-hosted: CommServe + access nodes / MediaAgents) | **Cohesity** (DataProtect, plus **NetBackup**, which Cohesity bought from Veritas) |
|---|---|---|
| Backs up S3 | ✅ | ⚠️ DataProtect: documented for the **SaaS** service (Cloud Protection Service). NetBackup (self-hosted): ✅ |
| Backs up Azure Blob | ✅ (but not objects in the **Archive** tier) | NetBackup: ✅. DataProtect: Azure Blob is on the datasheet, but no setup docs found |
| Self-hosted | ✅ | NetBackup ✅. DataProtect for S3: SaaS in the docs found |
| Private network | ✅ Commvault recommends **S3 VPC endpoints**. **Azure Private Endpoints** work according to a community thread confirmed by Commvault support. Control traffic can go through an HTTP proxy | ⚠️ Not documented for this use case |
| Restore into the other cloud | ✅ **S3 → Azure Blob / ADLS Gen2** and **Azure Blob → S3** are documented. Restores can be scheduled. Some S3 metadata has no Azure equivalent and is dropped | NetBackup: restore to another bucket or account is documented. ⚠️ Restoring across providers isn't confirmed |
| Ongoing sync | ❌ No feature for it. Commvault's "replication" is for **VMs**. Workaround: incremental backups plus a scheduled restore into the other cloud | ❌ CloudArchive, CloudTier and SmartFiles CloudReplicate send Cohesity's **own** data to the cloud; they don't sync S3 with Azure |

## Using Commvault for both needs

| What you get | What you give up |
|---|---|
| One self-hosted, private platform for backup (immutability, retention, ransomware protection) and for copies between clouds | **Delay:** the copy is only as fresh as the last backup plus restore, typically hours |
| Incremental backups | ⚠️ Whether a scheduled restore can write **only the changed objects** is unconfirmed. If it rewrites everything each time, data transfer and egress costs grow |
| Restore to ADLS Gen2 | Deletes aren't mirrored, and some metadata is lost between clouds |
| | For Delta or Iceberg tables, copy order isn't controlled. Each backup has to be restored as a whole set, with `_delta_log` included |

## Recommendation

1. **Backup:** Commvault is a strong candidate. It covers S3 and Azure Blob, runs on your own infrastructure, and
   supports private endpoints.
2. **Replication:** if the copy in the other cloud must be fresh or continuously updated, keep a separate sync
   tool: NetApp Copy and Sync, Resilio, or DataSync agents
   (see [`02-…md`](02-self-hosted-private-file-replication-vendors.md)).
3. **Single product:** if a copy that's hours old is acceptable, test Commvault as a one-product setup. Back up
   one dataset, schedule a restore into the other cloud, and measure how much is rewritten each time, how long it
   takes and what egress it costs.
4. **Cohesity:** ask Cohesity whether NetBackup's object storage backup can restore Azure → S3 and S3 → Azure,
   and whether DataProtect can back up S3 from a self-hosted cluster. Without those, Cohesity doesn't fit.

## Questions for the vendors

| Topic | Question |
|---|---|
| Incremental restore | Can a scheduled cross-cloud restore write **only changed objects** (skip existing)? |
| Cross-cloud | S3 → ADLS Gen2 (hierarchical namespace) and Azure Blob → S3 supported in our version? |
| Private | All data and control traffic through VPC endpoints / Private Endpoints and proxies, with no public endpoints? |
| Auth | IAM roles and Entra managed identity / service principal instead of access keys? |
| Scale | Millions of objects per bucket: backup duration, inventory-based scanning? |
| Licensing | Per TB backed up, per TB front-end, per node? |

## Related

- [`01-enterprise-cross-cloud-file-replication-tools.md`](01-enterprise-cross-cloud-file-replication-tools.md): overview of enterprise tools
- [`02-self-hosted-private-file-replication-vendors.md`](02-self-hosted-private-file-replication-vendors.md): self-hosted sync vendors
- [`../aws-backup/01-aws-backup-options-overview.md`](../aws-backup/01-aws-backup-options-overview.md): AWS Backup options

## Sources

**Commvault**
- [Amazon S3](https://documentation.commvault.com/2024e/software/amazon_s3_simple_storage_service.html)
- [Azure Blob Storage](https://documentation.commvault.com/v11/software/azure_blob_storage.html)
- [Restoring Azure Blob out of place](https://documentation.commvault.com/saas/restoring_azure_blob_storage_out_of_place.html)
- [Restoring Amazon S3 data across cloud accounts](https://documentation.commvault.com/v11/commcell-console/restoring_amazon_s3_data_across_cloud_accounts.html)
- [Restoring Azure Blob data across cloud accounts](https://documentation.commvault.com/v11/commcell-console/restoring_azure_blob_storage_data_across_cloud_accounts.html)
- [Cross-cloud restores of object metadata S3 ↔ Azure Blob](https://documentation.commvault.com/v11/software/cross_cloud_restores_of_object_metadata_between_amazon_s3_and_azure_blob.html)
- [Restoring an object storage repository out of place](https://documentation.commvault.com/11.42/commcell-console/restoring_object_storage_repository_out_of_place.html)
- [Replication for Microsoft Azure (VMs)](https://docs.commvault.com/v11/commcell-console/replication_for_microsoft_azure.html)
- [Requirements for connectivity to AWS service endpoints](https://documentation.commvault.com/2024e/expert/requirements_for_connectivity_to_aws_service_endpoints.html)
- [Access node requirements for AWS](https://documentation.commvault.com/v11/software/access_node_requirements_for_aws.html)
- [Private connectivity for Air Gap Protect](https://documentation.commvault.com/11.42/software/configure_private_connectivity_for_air_gap_protect_storage.html)
- [Community: Azure Blob private endpoint](https://community.commvault.com/virtualization-and-containers-48/does-commvault-support-azure-blob-private-endpoint-7593)
- [Community: Cloud library S3 endpoint](https://community.commvault.com/storage-and-deduplication-49/cloud-library-aws-s3-endpoint-3479)
- [File & object backup](https://www.commvault.com/explore/file-and-object-backup)

**Cohesity / NetBackup**
- [NetBackup for Cloud Object Store Admin Guide 11.0](https://www.veritas.com/support/en_US/doc/156091361-167856407-1)
- [NetBackup: Recovering Cloud object store assets](https://www.veritas.com/support/en_US/doc/156091361-172159686-0/v156091438-172159686)
- [NetBackup: Features of Cloud object store workload support](https://www.veritas.com/support/en_US/doc/156091361-170602989-0/v156091395-170602989)
- [Cohesity: Protect your Amazon S3 buckets (SaaS)](https://docs.cohesity.com/baas/data-protect/protect-amazon-s3.htm)
- [Cohesity: S3 bucket requirements](https://docs.cohesity.com/baas/data-protect/aws-requirements-s3.htm)
- [Cohesity: Supported workloads (SaaS)](https://docs.cohesity.com/baas/data-protect/supported-workflows.htm)
- [Cohesity DataProtect datasheet](https://www.cohesity.com/content/dam/cohesity/resource-assets/datasheets/cohesity-dataprotect-datasheet-en.pdf/)
- [Cohesity SmartFiles solution brief (CloudReplicate)](https://www.cohesity.com/content/dam/cohesity/resource-assets/solution-brief/Cohesity-SmartFiles-Solution-Brief.pdf/)
- [Cohesity: Archiving backups to Azure](https://www.cohesity.com/blogs/the-practitioners-guide-to-archiving-your-backups-from-cohesity-to-microsoft-azure/)
- [Cohesity and AWS](https://www.cohesity.com/partners/aws/)
