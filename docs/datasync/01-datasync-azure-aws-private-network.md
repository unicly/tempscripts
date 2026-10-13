# AWS DataSync between Azure and AWS in a private enterprise network

Using **AWS DataSync** to replicate Parquet files (and table folders) between Azure Blob / ADLS and
Amazon S3, in both directions, **without access to the public internet**. Part 2 explains how the
DataSync agent works.

> Based on AWS documentation and one third-party walkthrough. Not tested. ⚠️ marks points and
> numbers to confirm with AWS or the current docs.

---

# Part 1: DataSync in a private network

**Short answer:** yes, but only with a **DataSync agent**. The agentless mode connects to the storage
account's public endpoint, so it doesn't fit a network without internet access. With an agent, a
private path between Azure and AWS, and private endpoints on both sides, the data can move without
touching the public internet.

## Which DataSync mode works privately

| Mode | How it reaches Azure Blob | Private network possible? |
|---|---|---|
| **Basic mode with agent** | Agent VM (in Azure or on EC2) reads/writes Blob, then sends data to DataSync | ✅ With a VPC endpoint (PrivateLink) for DataSync and an Azure private endpoint for Blob |
| **Enhanced mode, agentless** | The AWS DataSync service connects to Blob directly | ❌ Needs the storage account's public endpoint |
| **Enhanced mode with agent** (Hyper-V, added July 2026) | Agent as above | ⚠️ New. No confirmation found that it works with VPC endpoints. Check with AWS |

Azure Blob can be the **source or the destination**, so both directions (Azure → AWS and AWS → Azure) work.

## Private architecture

```
        Azure (VNet)                         private link                  AWS (VPC)
 ┌──────────────────────────────┐   ExpressRoute ⇄ Direct Connect   ┌──────────────────────────────┐
 │ Storage account (ADLS/Blob)  │   (partner / colocation)          │ DataSync VPC endpoint        │
 │  └ private endpoint ─┐       │   or site-to-site IPsec VPN       │  (PrivateLink, ENI)          │
 │                      ▼       │ ════════════════════════════════► │        │                     │
 │ DataSync agent (Azure VM) ───┼───────── TLS 443 ───────────────► │        ▼                     │
 │  public access disabled      │                                   │ DataSync service → S3        │
 └──────────────────────────────┘                                   │  (S3 gateway/interface       │
                                                                    │   endpoint, bucket policy)   │
                                                                    └──────────────────────────────┘
```

| Component | Setup |
|---|---|
| **Agent location** | Preferably an **Azure VM** in the same VNet as the storage account, so it reads Blob locally. AWS provides a Hyper-V image, which you convert to a fixed-size VHD and deploy on a Linux VM. There's an aws-samples script for this. Alternative: the agent on **EC2**, reading Blob over the private link |
| **Azure storage** | **Private endpoint** for the storage account (`privatelink.blob.core.windows.net`), public network access disabled |
| **AWS side** | **DataSync interface VPC endpoint** (PrivateLink). Choose it when you create the agent, and the agent then never uses the public DataSync endpoint |
| **Link between the clouds** | **ExpressRoute + Direct Connect** through a partner or colocation (Equinix, Megaport…) for a fully private path. A **site-to-site IPsec VPN** (Azure VPN Gateway ↔ AWS VPN) is the simpler option: encrypted and private for your workloads, but the tunnel runs over the internet |
| **DNS** | The agent must resolve the storage account to its **private** IP, and the DataSync endpoint to the ENI IPs. For an agent on EC2: Route 53 Resolver forwarding to an Azure DNS Private Resolver. For an agent in Azure: Azure DNS forwarding to Route 53 for the VPC endpoint |
| **Firewall / NSG** | Agent → VPC endpoint ENIs on TCP 443 and the DataSync agent ports (⚠️ check the current port list, 1024–1064 has been listed). Agent → Blob private endpoint on 443 |
| **Activation** | Get the activation key through the agent's local console, or through private HTTP access to the agent. No public IP needed |
| **Authentication to Blob** | **SAS token** (DataSync supports SAS for Azure Blob). Store it securely and rotate it |
| **S3 side** | Bucket policy restricted to the VPC endpoint / DataSync role. S3 itself is written by the DataSync service inside AWS |

## Points to check

- ⚠️ **ADLS Gen2 with hierarchical namespace:** confirm that DataSync's Azure Blob location supports your storage account type and access tier.
- **Costs:**
  - an Azure VM for the agent
  - Azure egress (Azure → AWS) or AWS egress (AWS → Azure)
  - ExpressRoute and Direct Connect port fees, or VPN gateway costs
  - DataSync per-GB fees.
- **Throughput:** limited by the agent VM size and the link bandwidth. A VPN usually tops out at a few Gbit/s, while Direct Connect / ExpressRoute can go to 10–100 Gbit/s. Several agents or tasks can run in parallel.
- **Tasks:** source-to-destination per task. Use one task per direction and per prefix, scheduled with DataSync's scheduler or EventBridge.

## For Parquet, Iceberg and Delta

| Data | Fit |
|---|---|
| **Plain Parquet files** | ✅ Good fit. DataSync compares metadata and copies only new or changed files on each run (incremental). It can also delete files in the destination that were removed from the source |
| **Delta tables** (external) | ✅ The paths are relative, so a copied folder works at the new location. Copy `_delta_log` last, or when no writes happen, so the copy is consistent |
| **Standard Iceberg** | ⚠️ Only as the copy step: run `rewrite_table_path` first, because the paths in metadata are absolute ([`../iceberg/08-…md`](../iceberg/08-incremental-rewrite-table-path-explained.md)). DataSync copies the files from the file list |
| **Managed tables** (Iceberg or Delta, owned by Unity Catalog) | ❌ Files can't be registered back. Use OpenSharing / clone instead ([`../iceberg/12-…md`](../iceberg/12-managed-iceberg-summary-aws-azure.md)) |

**In short:** in a private enterprise network, use DataSync in **agent mode**, ideally with the agent
on an Azure VM. Add an Azure private endpoint on the storage account, a DataSync VPC endpoint in AWS,
and ExpressRoute ⇄ Direct Connect (or a site-to-site VPN) between the clouds. The agentless mode can't
be used without public access.

---

# Part 2: How the DataSync agent works

A DataSync agent is a **virtual machine (VM) appliance supplied by AWS** that you run close to your
data. It reads and writes files on storage that the DataSync service can't reach by itself, such as
on-premises NAS, HDFS, other clouds like Azure Blob, or private-only storage. It moves the data to and
from the AWS DataSync service. The agent is the data mover; the service in AWS controls it.

## Architecture

```
  Your network / Azure VNet                                   AWS Region
 ┌──────────────────────────────────┐                ┌───────────────────────────────────┐
 │ Source / destination storage     │                │ DataSync service                  │
 │ (Azure Blob, NFS, SMB, HDFS, …)  │                │  ├ control plane: tasks, schedule,│
 │          ▲  read / write         │   TLS (443…)   │  │  activation, monitoring        │
 │          │                       │ ─────────────► │  └ data plane: receives data,     │
 │ DataSync agent (VM appliance)    │                │     writes S3 / EFS / FSx         │
 │  scan · compare · transfer ·     │ ◄───────────── │                                   │
 │  verify                          │  instructions  │ CloudWatch logs, metrics, reports │
 └──────────────────────────────────┘                └───────────────────────────────────┘
```

- **Control plane:** you create locations and tasks in AWS (console, CLI, API, Terraform). The service tells the agent what to do.
- **Data plane:** the agent reads files from the source, sends them over TLS to the DataSync service, and the service writes them to S3, EFS or FSx. In the other direction, the agent receives data from the service and writes it to the destination, for example Azure Blob.
- The agent **only makes outbound connections** to AWS, apart from the one-time activation. No inbound ports from the internet are needed.

## Where the agent can run

| Platform | Notes |
|---|---|
| VMware ESXi | OVA image |
| Linux KVM | QCOW2 image |
| Microsoft Hyper-V | VHDX image. Also used for Azure: convert it to a fixed-size VHD, upload it to a managed disk, attach it to a Linux VM |
| Amazon EC2 | AWS-provided AMI per region. Used when the agent should sit in AWS, for example to reach Azure over the private link |
| Azure VM | Via the Hyper-V image, as above. The aws-samples repo has a deployment script |

**Sizing** ⚠️ (check the current requirements):
- At least **4 vCPU, 32 GB RAM, 80 GB disk**.
- More RAM, around **64 GB**, for very large file counts (tens of millions of files per task).
- On Azure, for example, a D8s / E4s-class VM.

## Lifecycle of an agent

| Step | What happens |
|---|---|
| 1. Deploy | Start the VM and give it an IP, DNS and NTP. The **local console** lets you configure the network, test connectivity and open a support channel |
| 2. Choose the service endpoint | **Public**, **FIPS** or **VPC endpoint (PrivateLink)**. ⚠️ This choice is permanent for the agent. Changing it means deploying a new agent |
| 3. Activate | Get an **activation key**, either through the agent's HTTP port 80 from your browser or the console, or through the local console. This **binds the agent to one AWS account and one region**. After activation, port 80 isn't needed any more |
| 4. Use | Reference the agent in **locations** (for example an Azure Blob location) and **tasks** |
| 5. Updates | AWS updates the agent software automatically. You don't patch it |
| 6. Replace | If the agent fails or has to move, deploy and activate a new one and update the locations. Agents aren't highly available by themselves, so a task fails if its agent is down |

## How a task runs (Basic mode)

| Phase | What the agent does |
|---|---|
| **Launching** | Connects to the source and destination |
| **Preparing** | **Scans** both sides and compares metadata (size, modified time, and so on) to find what has changed. For millions of files this phase can take a long time |
| **Transferring** | Copies new and changed files in parallel over TLS, with compression and integrity checks in flight ⚠️ |
| **Verifying** | Compares checksums: only transferred files, everything, or none (your choice) |

**Enhanced mode** works differently. It streams listing, transfer and verification in parallel,
handles much larger file counts, and gives more detailed reports. Since July 2026 it also supports
Azure Blob and Hyper-V agents. Its private-network support with an agent still needs confirming
(Part 1).

## Task options that matter for Parquet replication

| Option | Effect |
|---|---|
| **Transfer mode** `CHANGED` / `ALL` | Copy only differences (incremental) or everything |
| **Keep deleted files** on / off | Off: files removed from the source are removed from the destination too (a mirror) |
| **Overwrite** | Whether changed files are replaced in the destination |
| **Include / exclude filters** | Copy only certain prefixes or patterns, for example `/warehouse/sales/*` |
| **Manifest** | A list of exact files to copy. Useful with the file list from Iceberg's `rewrite_table_path` |
| **Bandwidth limit** | Throttle so the link (VPN, ExpressRoute) isn't saturated. Can follow a schedule |
| **Schedule** | Built-in schedule, or start via EventBridge / Step Functions / API |
| **Verification** | Checksums for transferred files only (faster) or for everything |
| **Task reports / CloudWatch** | Lists of copied, skipped and failed files. Metrics for bytes, files and throughput |

## Throughput and scaling

- One agent can usually reach several Gbit/s, depending on VM size, the link and file sizes. Many small files are slower than a few large ones.
- **Several agents per location** (⚠️ up to 4) spread one task's load.
- **Several tasks** in parallel, one per prefix, scale further.
- The real limit is usually the **network link** (VPN or ExpressRoute / Direct Connect) and Azure Blob throttling.

## Security

| Area | How |
|---|---|
| In transit | TLS between the agent and AWS. Plus the private link (VPN / ExpressRoute) if you use one |
| Agent | Hardened appliance with no shell access, only the local console. Change the default console password |
| Credentials for Azure | SAS token stored in the DataSync location configuration (⚠️ check whether AWS Secrets Manager integration is available for your setup). Use a SAS scoped to the container, with an expiry and rotation |
| AWS side | IAM role for DataSync to access S3. Bucket policy limited to that role / VPC endpoint |
| Network | Outbound only: agent → VPC endpoint (443 and the documented agent ports ⚠️) and agent → Blob private endpoint (443) |
| Audit | CloudTrail for DataSync API calls, and CloudWatch logs per task |

## Costs

- **DataSync:** per GB transferred (Basic and Enhanced are priced differently).
- **Agent VM:** compute and disk on Azure or EC2.
- **Egress:** Azure egress (Azure → AWS) or AWS egress (AWS → Azure), plus Direct Connect / ExpressRoute or VPN fees.
- **Requests:** Azure Blob and S3 request costs, which the scan in the Preparing phase can make noticeable.

## Limits to know

- An agent is **tied to one region, one account and one endpoint type**.
- It only **copies files**. It knows nothing about tables, transactions or catalogs. For Delta, copy `_delta_log` last. For Iceberg, rewrite the paths first. Managed tables can't be replicated this way.
- The scan phase in Basic mode can dominate the run time for huge file counts. Enhanced mode or splitting tasks by prefix helps.
- No real-time sync. Runs are scheduled (minimum interval ⚠️ about 1 hour on the built-in scheduler; use EventBridge for other patterns).

**In short:** the agent is a VM you run next to the data. You activate it once against your AWS
account and region, through a VPC endpoint for private setups. It then scans, copies only the
differences and verifies files on a schedule, with outbound connections only. For an Azure ⇄ AWS
Parquet case, run it as an Azure VM next to the storage account's private endpoint.

---

## Sources

- [AWS DataSync: Configuring transfers with Microsoft Azure Blob Storage](https://docs.aws.amazon.com/datasync/latest/userguide/creating-azure-blob-location.html)
- [AWS DataSync: Choosing a service endpoint for your agent](https://docs.aws.amazon.com/datasync/latest/userguide/choose-service-endpoint.html)
- [AWS DataSync: Deploying your agent](https://docs.aws.amazon.com/datasync/latest/userguide/deploy-agents.html)
- [AWS DataSync: PrivateLinkConfig API](https://docs.aws.amazon.com/datasync/latest/userguide/API_PrivateLinkConfig.html)
- [AWS DataSync: CreateLocationAzureBlob API](https://docs.aws.amazon.com/datasync/latest/userguide/API_CreateLocationAzureBlob.html)
- [AWS DataSync FAQs](https://www.amazonaws.cn/en/datasync/faqs/)
- [AWS What's New: DataSync Enhanced mode adds Azure Blob and Hyper-V agent support](https://aws.amazon.com/about-aws/whats-new/2026/07/aws-datasync-hdfs-azure-blob-hyper-v/)
- [AWS Storage blog: Migrating Azure Blob Storage to Amazon S3 using DataSync](https://aws.amazon.com/blogs/storage/migrating-azure-blob-storage-to-amazon-s3-using-aws-datasync)
- [AWS Storage blog: Best practices for setting up your DataSync agent](https://aws.amazon.com/blogs/storage/best-practices-for-setting-up-your-aws-datasync-agent/)
- [aws-samples: Deploy DataSync agent on Azure](https://github.com/aws-samples/aws-datasync-deploy-agent-azure/blob/main/README.md)
- [AWS re:Post: Use a VPC endpoint to activate a DataSync agent](https://repost.aws/knowledge-center/datasync-cross-activate-agent)
- [Medium: Syncing data privately from Azure Blob Storage to Amazon S3 using DataSync](https://medium.com/allocore/syncing-data-privately-from-azure-blob-storage-to-amazon-s3-using-aws-datasync-138d46535273)
