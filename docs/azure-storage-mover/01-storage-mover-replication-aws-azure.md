# Azure Storage Mover for AWS ⇄ Azure replication: directions, network path, authentication, agent

The same questions as for AWS DataSync ([`../datasync/02-…md`](../datasync/02-datasync-replication-aws-azure-network-auth.md))
and Azure Data Factory ([`../azure-data-factory/01-…md`](../azure-data-factory/01-adf-replication-aws-azure.md)),
answered for **Azure Storage Mover**.

> From Microsoft docs, announcements and blog walkthroughs. Not tested. ⚠️ marks unconfirmed details.
>
> **Correction (October 2026):** an earlier version said private networking for S3 → Azure was
> unclear and a VPN didn't apply. Microsoft's docs describe **private connections**: Storage Mover can
> migrate S3 → Azure privately over Azure Private Link and a VPN / ExpressRoute / SD-WAN link. Older
> blogs saying "no private networking" predate or ignore this feature.

## Short answer

- Azure Storage Mover is a **migration service into Azure**. It copies **from** Amazon S3 (and
  on-premises SMB/NFS, other clouds) **to** Azure Blob / Azure Files.
- **S3 → Azure Blob:** ✅ **cloud-to-cloud**, generally available since October 2025, **agentless**
  (Azure-managed, server to server), authenticated through an **Azure Arc multicloud connector** for AWS.
- **Azure → S3:** ❌ not supported. Storage Mover only writes to Azure targets.
- **Private network:** ✅ possible with **private connections**: Storage Mover → Azure Private Link →
  **Private Link Service Direct Connect** → VPN / ExpressRoute / SD-WAN → **S3 VPC endpoint**. Depends on
  Private Link Service Direct Connect, which is ⚠️ **in public preview, in selected regions only**.
  Without it, transfers use public endpoints (S3 restricted to Azure IP ranges).
- **Agent VM:** only for **on-premises / file-share** sources (SMB, NFS). Not needed for S3.

## Directions

| Source → target | Supported? | How |
|---|---|---|
| **Amazon S3 → Azure Blob** | ✅ GA (Oct 2025) | Cloud-to-cloud, agentless, via Azure Arc multicloud connector |
| Azure Blob → Azure Blob | ✅ | Across subscriptions / storage accounts in one tenant |
| AWS FSx (SMB) → Azure Files | ⚠️ Preview | |
| Google Cloud Storage → Azure Blob | ⚠️ Preview | |
| On-premises SMB / NFS → Azure Files / Blob | ✅ | Needs a **Storage Mover agent** VM on-premises |
| **Azure → Amazon S3** | ❌ | Use AWS DataSync, or ADF Mapping data flows / Fabric Data Factory |

S3 objects in **Glacier / Glacier Deep Archive** must be restored before migration.

## How to replicate S3 → Azure Blob

| Step | What |
|---|---|
| 1 | **Storage Mover resource** in Azure (region of your choice) |
| 2 | **Azure Arc multicloud connector** for AWS: connects your AWS account to Azure. The connector setup creates the needed IAM role in AWS (CloudFormation template) |
| 3 | **Source endpoint:** the S3 bucket, through the multicloud connector |
| 4 | **Target endpoint:** the Azure Blob container. Grant the Storage Mover's **managed identity** a data role on the storage account (e.g. *Storage Blob Data Contributor*) ⚠️ |
| 5 | **Project + job definition:** source → target, copy mode (⚠️ merge vs. mirror, check current options) |
| 6 | **Run the job.** Re-run it for incremental passes. ⚠️ Per-job limits (a pre-GA source mentions 10 million objects per job) |

It's built for **migrations** (one-off or a few passes), not for continuous replication: no built-in
schedule comparable to DataSync tasks or ADF triggers ⚠️. For recurring runs, start jobs via API / CLI
from an automation tool.

## Does traffic go over the public internet?

| Part | Path |
|---|---|
| **S3 → Azure data transfer, public** (default) | Azure-managed service reads from S3's **public endpoint** (HTTPS). Restrict the bucket to **Azure IP ranges** |
| **S3 → Azure data transfer, private connection** | Storage Mover → **private endpoint** → **Private Link Service Direct Connect** (your Azure network) → **VPN / ExpressRoute / SD-WAN** → **S3 VPC endpoint** in AWS. Off the public internet (see "Private connections" below) |
| Write to the target storage account | Can use **Private Link** to the storage account (documented for agent-based migrations) ⚠️ |
| Control messages, progress, copy logs | Go over the **public endpoint** of the Storage Mover resource, even with Private Link |
| **VPN** | ✅ For private connections, a **VPN, ExpressRoute or SD-WAN** between Azure and AWS is the network path. Agent-based migrations (on-premises sources) use your network path as well |

## Private connections (S3 → Azure over Private Link)

```
Storage Mover (Azure-managed)
  └─ private endpoint → Private Link Service Direct Connect (IP-based, in your Azure VNet/region)
        ▼  VPN / ExpressRoute / SD-WAN
AWS VPC
  └─ S3 VPC endpoint → S3 bucket (bucket / endpoint policy: only this endpoint)
```

| Step | What |
|---|---|
| 1 | **AWS:** create an **S3 VPC endpoint** in the VPC that holds the bucket. Optionally limit the bucket / endpoint policy to it |
| 2 | **Network:** connect the Azure VNet and that VPC with **VPN, ExpressRoute or SD-WAN**. The Private Link Service's source NAT subnet needs connectivity to the AWS VPC ⚠️ |
| 3 | **Azure:** create a **Private Link Service Direct Connect** (IP-based Private Link Service) pointing to the **S3 VPC endpoint's IP address** ⚠️, in the **same region** as the Storage Mover resource and the VNet that reaches AWS ⚠️. It **can't be created inside Storage Mover** and must exist **before** the private connection |
| 4 | **Storage Mover:** create a **private connection** using that Private Link Service, then **approve** it. The feature may have to be enabled through a portal flight link ⚠️ |
| 5 | **Multicloud connector / endpoint:** choose the **private** access type |
| 6 | **Job:** set the **S3 bucket type to "Private"** and select the approved private connection |

| Point | Detail |
|---|---|
| Status | **Private Link Service Direct Connect is in public preview, in selected regions only** ⚠️ (Tech Community). Check your region |
| Bucket check | Storage Mover **doesn't validate** whether the bucket is public or private. Configure the bucket policy yourself |
| Mapping | The Private Link Service must **map to the VPC** associated with the S3 resource |
| Subnet settings ⚠️ | A lab mentions the Private Link Service subnet needs Private Link service network policies **disabled** and **at least two IP configurations** (possibly lab-specific) |
| Control traffic | Control messages, progress telemetry and copy logs still go over the **public endpoint** of the Storage Mover resource |
| Not found yet | A complete step-by-step guide and a region list. Verify the ⚠️ points on the Microsoft Learn page |

## Authentication

| Part | Method |
|---|---|
| Storage Mover → **S3** | **Azure Arc multicloud connector**: federated trust to an **IAM role** in your AWS account (no long-lived access keys) ⚠️ check the exact mechanism in the connector docs |
| Storage Mover → **Azure storage** | **Managed identity** of the Storage Mover (role assignment on the storage account) |
| Agent (on-premises migrations only) → Azure | Registered through **Azure Arc**, with a **system-assigned managed identity**. Registration is initiated from the agent |
| In transit | HTTPS / TLS |
| Audit | Azure activity logs and Storage Mover job logs, CloudTrail on the AWS side |

## The agent: needed or not?

| Question | Answer |
|---|---|
| Agent for S3 → Azure? | ❌ **No.** Cloud-to-cloud is agentless |
| Agent for on-premises SMB/NFS? | ✅ A **VM appliance** (disk image) on **Hyper-V or VMware** only |
| Agent sizing | Driven mainly by the **number of files and folders**, not data volume |
| Agent connectivity | Needs **unrestricted internet** access (outbound) ⚠️ |
| Several agents | ✅ Supported per Storage Mover resource. ⚠️ Jobs per agent at a time not confirmed |
| Several agents on one VM | ❌ The VM is the agent appliance |

## Costs

The Storage Mover service itself is described as **free** ⚠️. You pay **AWS egress** for data leaving
S3, plus Azure storage and transactions on the target.

## Compared with DataSync and ADF

| | AWS DataSync | Azure Data Factory | Azure Storage Mover |
|---|---|---|---|
| AWS → Azure | ✅ | ✅ Copy activity | ✅ Cloud-to-cloud (GA) |
| Azure → AWS | ✅ | ⚠️ Mapping data flows only | ❌ |
| Agent / runtime | Agent VM (optional with Enhanced mode) | Self-hosted IR (Windows) or Azure IR | **None** for S3 (agent only for on-prem) |
| Private path | ✅ Agent + VPC endpoint + VPN | ✅ SHIR + S3 VPC endpoint + VPN | ✅ Private connection: Private Link Service Direct Connect (⚠️ preview, selected regions) + VPN / ExpressRoute + S3 VPC endpoint |
| Auth to AWS | IAM role (S3), SAS (Azure) | Access keys for S3 | Arc multicloud connector (IAM role) |
| Recurring / incremental | ✅ Scheduled tasks, changed files only | ✅ Triggers, last-modified filters | ⚠️ Re-run jobs; built for migration |
| Service cost | Per GB | Per activity / DIU-hour | Free ⚠️ (egress and storage still apply) |

## Which tool for which need

| Need | Best tool |
|---|---|
| One-off or few-pass **migration S3 → Azure**, no infrastructure to run | **Azure Storage Mover** |
| **Recurring** replication S3 → Azure | AWS DataSync or ADF Copy activity |
| **Private** network required | AWS DataSync (agent + VPC endpoint), ADF (SHIR), or Storage Mover with a **private connection** (migrations into Azure, if Private Link Service Direct Connect is available in your region) |
| **Azure → S3** | AWS DataSync |

## Sources

- [Microsoft: Migrate data using private connections in Azure Storage Mover](https://learn.microsoft.com/en-us/azure/storage-mover/migrations-requiring-private-connections)
- [Microsoft: Azure private network connectivity options for cloud-to-cloud (ExpressRoute, VPN, SD-WAN)](https://learn.microsoft.com/en-us/azure/storage-mover/cloud-to-cloud-private-network-configuration)
- [Microsoft: Get started with cloud-to-cloud migration in Azure Storage Mover](https://learn.microsoft.com/en-us/azure/storage-mover/cloud-to-cloud-migration)
- [Microsoft: Azure Storage Mover networking requirements](https://learn.microsoft.com/en-us/azure/storage-mover/network-prerequisites)
- [Microsoft Tech Community: Private Link Service Direct Connect (preview)](https://techcommunity.microsoft.com/blog/azurearchitectureblog/preserve-a-legacy-ip-during-azure-migration-with-private-link-service-direct-con/4540575)
- [Microsoft Tech Community: SAP RISE & HANA data migration, S3 to Azure Blob via Storage Mover](https://techcommunity.microsoft.com/blog/microsoftmissioncriticalblog/sap-rise--hana-data-migration-aws-s3-to-azure-blob-storage-via-azure-storage-mov/4487991)
- [DevOpsSchool: Azure Storage Mover tutorial](https://www.devopsschool.com/tutorials/azure-storage-mover-tutorial-architecture-pricing-use-cases-and-hands-on-guide-for-migration/)

- [Microsoft: Azure Storage Mover service overview (supported source/target pairs)](https://learn.microsoft.com/azure/storage-mover/service-overview)
- [Azure blog: Fully managed cloud-to-cloud transfers with Azure Storage Mover](https://azure.microsoft.com/en-us/blog/fully-managed-cloud-to-cloud-transfers-with-azure-storage-mover/)
- [Microsoft: Deploy an Azure Storage Mover agent](https://learn.microsoft.com/azure/storage-mover/agent-deploy)
- [Microsoft: Register an Azure Storage Mover agent](https://learn.microsoft.com/en-za/Azure/storage-mover/agent-register)
- [Microsoft: Azure Storage Mover release notes](https://learn.microsoft.com/en-us/azure/storage-mover/release-notes)
- [Azure product page: Storage Mover](https://azure.microsoft.com/en-us/products/storage-mover)
- [Wim Matthyssen: Migrate S3 buckets to Azure Blob with Storage Mover and Azure Arc (Jan 2026)](https://wmatthyssen.com/2026/01/07/azure-arc-how-to-migrate-data-from-amazon-s3-buckets-to-azure-blob-storage-with-azure-storage-mover/)
- [Techielass: How to migrate files from AWS S3 to Azure with Storage Mover](https://www.techielass.com/azure-storage-mover-migrate-aws-s3-to-azure/)
- [CloudThat: Azure Storage Mover for S3 to Azure transfers](https://www.cloudthat.com/resources/blog/make-cloud-to-cloud-migration-simple-with-azure-storage-mover)
- [SDxCentral: Microsoft releases AWS-to-Azure migration tool](https://www.sdxcentral.com/news/microsoft-releases-aws-to-azure-migration-tool/)
- [WindowsForum: Storage Mover GA, cloud-to-cloud S3 to Azure Blob](https://windowsforum.com/threads/azure-storage-mover-ga-cloud-to-cloud-migration-from-s3-to-azure-blob.386303/)
