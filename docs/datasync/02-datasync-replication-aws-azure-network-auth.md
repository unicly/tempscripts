# AWS DataSync for AWS ⇄ Azure replication: setup, network path and authentication

Short answers on using AWS DataSync to replicate files between Amazon S3 and Azure Blob / ADLS:
how to replicate to Azure, whether traffic goes over the public internet, whether a VPN can be used,
and how authentication works.

More detail (private architecture, how the agent works):
[`01-datasync-azure-aws-private-network.md`](01-datasync-azure-aws-private-network.md).

> From AWS documentation. Not tested. ⚠️ marks points to check.

## Short answer

DataSync can copy files from S3 to Azure Blob (ADLS) and back. Traffic goes over the public internet
**unless you use an agent**, which can send it over a VPN or Direct Connect / ExpressRoute instead.
Authentication is a **SAS token** on the Azure side and an **IAM role** on the AWS side.

## How to replicate S3 → Azure

| Step | What |
|---|---|
| 1 | **Agent** (needed for a private network): deploy the DataSync agent VM, preferably in **Azure** next to the storage account, and activate it against your AWS account and region |
| 2 | **Source location:** the S3 bucket or prefix, with an IAM role DataSync can use |
| 3 | **Destination location:** Azure Blob container, using the agent and a **SAS token** |
| 4 | **Task:** source → destination with options: copy only changed files, mirror deletes or not, filters, bandwidth limit, verification |
| 5 | **Schedule:** built-in schedule (hourly or longer ⚠️) or EventBridge. Each run copies only new or changed files |

For **Azure → AWS**, swap source and destination. Use one task per direction.

## Does traffic go over the public internet?

| Mode | Path |
|---|---|
| **Enhanced mode, no agent** | DataSync service ↔ the storage account's **public endpoint**. Over the internet (TLS encrypted). Not possible without public access |
| **Agent + public DataSync endpoint** | Agent ↔ AWS over the internet (TLS) |
| **Agent + VPC endpoint (PrivateLink)** | Agent ↔ DataSync VPC endpoint over your **private link**: site-to-site **VPN** or **ExpressRoute ⇄ Direct Connect**. Azure storage reached through a **private endpoint**. **No public internet** (with a VPN, the encrypted tunnel itself runs over the internet) |

### Using a VPN

Yes. Use Azure VPN Gateway ↔ AWS Site-to-Site VPN, plus:

- a DataSync **VPC endpoint**
- a storage account **private endpoint** with public access disabled
- DNS forwarding between the clouds
- firewall rules for TCP 443 and the agent ports ⚠️.

For more bandwidth and no internet at all, use ExpressRoute ⇄ Direct Connect through a partner such
as Equinix or Megaport.

## Authentication

| Part | Method |
|---|---|
| DataSync → **Azure Blob** | **SAS token** on the container: limited permissions, an expiry date, rotated regularly. ⚠️ Microsoft Entra ID / managed identity isn't supported by DataSync's Azure Blob location |
| DataSync → **S3** | **IAM role** with access to the bucket, plus a bucket policy (can be limited to the VPC endpoint) |
| **Agent** ↔ AWS | **Activation key**, which binds the agent to one account, region and endpoint type |
| In transit | **TLS** always, plus VPN or IPsec encryption if used |
| Encryption at rest | S3 with SSE-S3 or SSE-KMS (IAM role needs `kms:` permissions). Azure with Microsoft-managed or customer-managed keys |
| Audit | CloudTrail (API calls), CloudWatch logs and task reports, Azure storage logs |

## Limits to know

- **Files only:** DataSync doesn't understand tables. Copy Delta's `_delta_log` last, and rewrite
  Iceberg paths first ([`../iceberg/23-…md`](../iceberg/23-paths-to-rewrite-when-restoring-to-another-folder.md)).
- **Not real time:** runs are scheduled.
- **Costs:** DataSync per GB, plus egress from the source cloud, plus the agent VM and VPN /
  ExpressRoute fees.

## Sources

- [AWS DataSync: Configuring transfers with Microsoft Azure Blob Storage](https://docs.aws.amazon.com/datasync/latest/userguide/creating-azure-blob-location.html)
- [AWS DataSync: Choosing a service endpoint for your agent](https://docs.aws.amazon.com/datasync/latest/userguide/choose-service-endpoint.html)
- [AWS DataSync: Deploying your agent](https://docs.aws.amazon.com/datasync/latest/userguide/deploy-agents.html)
- [AWS DataSync: CreateLocationAzureBlob API (SAS authentication)](https://docs.aws.amazon.com/datasync/latest/userguide/API_CreateLocationAzureBlob.html)
- [AWS DataSync FAQs](https://www.amazonaws.cn/en/datasync/faqs/)
- [AWS What's New: Enhanced mode adds Azure Blob and Hyper-V agent support](https://aws.amazon.com/about-aws/whats-new/2026/07/aws-datasync-hdfs-azure-blob-hyper-v/)
- [Medium: Syncing data privately from Azure Blob Storage to Amazon S3 using DataSync](https://medium.com/allocore/syncing-data-privately-from-azure-blob-storage-to-amazon-s3-using-aws-datasync-138d46535273)
