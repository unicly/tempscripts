# Azure Storage Mover for AWS ⇄ Azure replication: directions, network path, authentication, agent

The same questions as for AWS DataSync ([`../datasync/02-…md`](../datasync/02-datasync-replication-aws-azure-network-auth.md))
and Azure Data Factory ([`../azure-data-factory/01-…md`](../azure-data-factory/01-adf-replication-aws-azure.md)),
answered for **Azure Storage Mover**.

> From Microsoft docs, announcements and blog walkthroughs. Not tested. Several details (private
> networking, limits, copy modes) are **inconsistent between sources** and marked ⚠️.

## Short answer

- Azure Storage Mover is a **migration service into Azure**. It copies **from** Amazon S3 (and
  on-premises SMB/NFS, other clouds) **to** Azure Blob / Azure Files.
- **S3 → Azure Blob:** ✅ **cloud-to-cloud**, generally available since October 2025, **agentless**
  (Azure-managed, server to server), authenticated through an **Azure Arc multicloud connector** for AWS.
- **Azure → S3:** ❌ not supported. Storage Mover only writes to Azure targets.
- **Private network:** ⚠️ unclear for S3. Pre-GA sources say no private networking (S3 access is limited
  to Azure IP ranges instead), a later summary mentions Private Link. Check the current docs.
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
| **S3 → Azure data transfer** (cloud-to-cloud) | Azure-managed service reads from S3's **endpoint** and writes to Azure. ⚠️ Pre-GA docs: **no private networking**; restrict the bucket to **Azure IP ranges** instead. A later summary mentions Private Link. Not confirmed |
| Write to the target storage account | Can use **Private Link** to the storage account (documented for agent-based migrations) ⚠️ |
| Control messages, progress, copy logs | Go over the **public endpoint** of the Storage Mover resource, even with Private Link |
| **VPN** | ❌ Not applicable for cloud-to-cloud: there's no agent in your network to route through a VPN. Agent-based migrations (on-premises sources) can use your network path |

So for S3 → Azure, the realistic assumption today is: **data crosses between AWS and Azure over their
public endpoints (HTTPS)**, with access limited to Azure's IP ranges. If a fully private path is
required, use **AWS DataSync** with an agent in Azure, or **ADF** with a self-hosted IR.

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
| Private path | ✅ Agent + VPC endpoint + VPN | ✅ SHIR + S3 VPC endpoint + VPN | ⚠️ Not confirmed (Azure IP allow-listing) |
| Auth to AWS | IAM role (S3), SAS (Azure) | Access keys for S3 | Arc multicloud connector (IAM role) |
| Recurring / incremental | ✅ Scheduled tasks, changed files only | ✅ Triggers, last-modified filters | ⚠️ Re-run jobs; built for migration |
| Service cost | Per GB | Per activity / DIU-hour | Free ⚠️ (egress and storage still apply) |

## Which tool for which need

| Need | Best tool |
|---|---|
| One-off or few-pass **migration S3 → Azure**, no infrastructure to run | **Azure Storage Mover** |
| **Recurring** replication S3 → Azure | AWS DataSync or ADF Copy activity |
| **Private** network required | AWS DataSync (agent + VPC endpoint) or ADF (SHIR) |
| **Azure → S3** | AWS DataSync |

## Sources

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
