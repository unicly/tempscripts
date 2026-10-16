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

## The DataSync agent VM: what it is, and does it have to run in Azure?

The DataSync agent is a **virtual machine image supplied by AWS** that runs the DataSync transfer
software close to storage the DataSync service can't reach by itself, such as Azure Blob or private
storage. It does **not** have to run in Azure. It can also run on **EC2 in AWS**. Running it in Azure is
just the usual recommendation for AWS ↔ Azure. The S3 side never needs an agent: the DataSync service
reads and writes S3 itself.

### What the agent is

| Point | Detail |
|---|---|
| What | A prebuilt VM (OVA, QCOW2, VHDX, or an EC2 AMI) with AWS's DataSync software. No shell access, only a local console for network settings |
| Role | The **data mover**: it reads files from the source or writes them to the destination, and exchanges data with the DataSync service over TLS |
| Control | Tasks and schedules are set up in AWS (console, CLI, API). The service tells the agent what to do |
| Network | **Outbound only** to AWS (public endpoint or VPC endpoint), plus access to the storage it serves (Azure Blob). No inbound ports except once, for activation |
| Binding | Activated once, which ties it to **one AWS account, one region and one endpoint type** (public, FIPS or VPC) |
| Updates | Automatic, done by AWS |
| Sizing ⚠️ | At least 4 vCPU, 32 GB RAM, 80 GB disk. More RAM (~64 GB) for tens of millions of files |

### Where to run it for AWS → Azure

| Option | How the data flows | When to choose it |
|---|---|---|
| **Agent on an Azure VM** (recommended) | S3 → DataSync service → (TLS over VPN or ExpressRoute) → **agent in Azure** → Azure Blob through a **private endpoint** | Private networks, and Azure storage with public access disabled. The agent writes to Blob locally, and the long-distance part uses DataSync's own transfer protocol |
| **Agent on EC2 in AWS** | S3 → DataSync service → **agent in AWS** → (over VPN or ExpressRoute, or the internet) → Azure Blob | No VMs wanted in Azure. Simpler from the AWS side, but the agent talks to Blob across clouds, so it needs a network path and DNS to the Blob private endpoint |
| **No agent (Enhanced mode)** | DataSync service → Azure Blob's **public endpoint** | Only if public access to the storage account is allowed |

The same agent placement also works for the other direction (Azure → AWS), with source and
destination swapped.

### Deploying it in Azure, in short

1. Download the agent's **Hyper-V image** (VHDX) from the DataSync console.
2. Convert it to a **fixed-size VHD**.
3. Upload it to an Azure **managed disk**.
4. Create a **Linux VM** from it. An aws-samples script automates steps 2–4.
5. Put the VM in the **VNet** next to the storage account's private endpoint. Allow outbound traffic to
   AWS: the VPC endpoint IPs on TCP 443 plus the agent ports ⚠️.
6. **Activate** it from the local console: choose the VPC endpoint and get the activation key. Then
   create the Azure Blob location (with a SAS token) and the task in AWS.

### Good to know

- **Not highly available:** if the agent is down, its tasks fail. Use several agents per location
  (⚠️ up to 4) for throughput and resilience, or replace a failed agent with a new one.
- **One endpoint type for life:** to switch from the public endpoint to a VPC endpoint, deploy a new agent.
- **Costs:** the VM itself (Azure or EC2), on top of the DataSync per-GB fees and egress.

## Many replications: one agent per replication, or shared agents?

**Short answer:** you **don't** need an agent (or a VM) per replication. One agent can be used by many
locations and tasks. But **one VM runs exactly one agent**, and an agent runs **one task at a time**:
other tasks that use the same agent wait in a **queue** ⚠️. Plan the number of agents by **parallelism,
throughput, network reach and AWS account/region**, not by the number of replications.

### How agents, locations and tasks relate

```
VM (Azure)  ──  1 agent  ──┬── Azure Blob location: container "sales"     ── task 1: S3 sales/   → Azure sales/
                           ├── Azure Blob location: container "finance"   ── task 2: S3 finance/ → Azure finance/
                           └── Azure Blob location: container "hr"        ── task 3: Azure hr/   → S3 hr/
                                        (tasks using this agent run one after another)
```

| Question | Answer |
|---|---|
| One agent for several replications? | ✅ Yes. Reference the same agent in several locations and tasks |
| Several tasks at the same time on one agent? | ❌ No: one task per agent at a time. Further tasks are **queued** ⚠️ (check current behaviour for Enhanced mode) |
| Several agents on one VM? | ❌ No. The VM **is** the agent appliance: one VM = one agent |
| One agent for several AWS accounts or regions? | ❌ No. An agent is activated for **one account, one region and one endpoint type** |
| Several agents for one replication? | ✅ Yes, up to 4 per location ⚠️, for more throughput and resilience |

### When you need more agents (and VMs)

| Reason | Why |
|---|---|
| **Replications must run in parallel** | One agent runs one task at a time. Two agents = two tasks at the same time |
| **More throughput** for large transfers | Several agents on one location share the work of one task |
| **Different AWS accounts or regions** | An agent is tied to one account and region |
| **Different endpoint types** | Public and VPC endpoint agents can't be mixed on one agent |
| **Network reach** | The agent must reach every storage account it serves (same VNet, peering, private endpoints and DNS). Storage in isolated networks needs its own agent |
| **Resilience** | A single agent is a single point of failure for all its tasks |
| **Very many files** | Large file counts need more agent memory (⚠️ ~64 GB for tens of millions of files) |

### Typical layouts

| Situation | Layout |
|---|---|
| A few replications, runs can wait for each other (e.g. nightly) | **1 agent VM** in Azure, shared by all tasks. Stagger the schedules |
| Many replications that must finish in the same time window | **2–4 agent VMs**. Spread tasks across agents, or attach several agents to the busiest locations |
| Both directions (AWS → Azure and Azure → AWS) | The **same agents** can serve both directions, if they're in the same AWS account and region |
| Several AWS accounts or regions | **At least one agent per account/region** combination |

### Tips

- **Split large replications into several tasks** by prefix (e.g. per table or partition folder) and
  spread them across agents.
- **Stagger schedules** so queued tasks don't pile up on one agent.
- **Monitor** task duration and queue time in CloudWatch. Add an agent when tasks start overlapping
  their schedule window.
- **Size the VM** for the biggest task it will run (memory for file counts, network for throughput).

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
- [AWS DataSync: Queueing tasks (multiple tasks on one agent)](https://docs.aws.amazon.com/datasync/latest/userguide/run-task.html)
- [AWS DataSync: Using multiple agents for a location](https://docs.aws.amazon.com/datasync/latest/userguide/multiple-agents.html)
- [AWS Storage blog: Best practices for setting up your DataSync agent](https://aws.amazon.com/blogs/storage/best-practices-for-setting-up-your-aws-datasync-agent/)
- [aws-samples: Deploy DataSync agent on Azure](https://github.com/aws-samples/aws-datasync-deploy-agent-azure/blob/main/README.md)
- [AWS What's New: Enhanced mode adds Azure Blob and Hyper-V agent support](https://aws.amazon.com/about-aws/whats-new/2026/07/aws-datasync-hdfs-azure-blob-hyper-v/)
- [Medium: Syncing data privately from Azure Blob Storage to Amazon S3 using DataSync](https://medium.com/allocore/syncing-data-privately-from-azure-blob-storage-to-amazon-s3-using-aws-datasync-138d46535273)
