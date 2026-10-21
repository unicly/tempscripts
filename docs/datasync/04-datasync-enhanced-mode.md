# AWS DataSync Enhanced mode

What Enhanced mode is, how it differs from Basic mode, what it supports (including Azure Blob since
July 2026), and what it means for scalable AWS ⇄ Azure replication
([`03-…md`](03-scalable-parallel-datasync-aws-azure.md)).

> From AWS docs and announcements plus a few third-party guides. Not tested. ⚠️ marks points that are
> unconfirmed, come from third parties, or where AWS sources disagree.

## Short answer

DataSync tasks run in one of two **task modes**:

- **Basic mode:** the original engine. Steps run **one after another** (prepare → transfer → verify),
  with limits on the number of files per task. Supports **every** location type.
- **Enhanced mode:** newer engine. **Lists, prepares, transfers and verifies in parallel**, handles
  **virtually unlimited objects** per execution, and gives more detailed reports. Supports a growing
  set of locations. Since **July 2026** it also supports **Azure Blob, HDFS and self-managed object
  storage with an agent**, including agents on **Hyper-V**.

For a large data lake with many files, Enhanced mode is usually the better choice, if your locations
and options are supported.

## Basic vs. Enhanced

| | Basic mode | Enhanced mode |
|---|---|---|
| How a run works | Prepare (scan and compare everything) → transfer → verify, **sequentially** | Listing, preparing, transferring and verifying **in parallel** (streaming) |
| Scale | Quotas on files/objects per task (a third party cites ~50 million ⚠️) | **Virtually unlimited** objects per execution |
| Performance | Slower start for many files (long Preparing phase) | Faster, especially with many small files |
| Supported locations | **All** DataSync location types | S3 ↔ S3, other clouds ↔ S3, NFS/SMB ↔ S3, and (July 2026) Azure Blob, HDFS, self-managed object storage with an agent |
| Agents | Basic mode agent (VMware, KVM, Hyper-V, EC2) | **Separate Enhanced mode agent** type ⚠️. Some transfers (e.g. S3 ↔ S3, some other-cloud transfers) need **no agent** |
| Agents per location | Up to 4 | Up to 4 (separate from Basic agents) |
| Verification | Verify transferred files, verify all, or none | Verify **transferred data only** ⚠️ (third party) |
| Bandwidth limit | ✅ | ⚠️ Reported as not available (third party). Check before relying on throttling |
| Reports | Task reports | More detailed task reports and metrics |
| Pricing | Per GB transferred | Per GB (higher rate) **plus a fee per task execution** ⚠️ (a third party cites $0.015/GB + $0.55 per execution vs. $0.0125/GB for Basic; check the AWS pricing page) |
| Choosing it | Task mode is set when you **create the task** ⚠️ (likely can't be changed afterwards; create a new task to switch) | Same |

## Azure Blob in Enhanced mode

| Point | Detail |
|---|---|
| Agentless | Older AWS docs: Azure Blob ↔ S3 in Enhanced mode **without an agent**. The DataSync service reaches the storage account's **public endpoint** (not usable if public access is disabled) |
| With an agent (July 2026) | Enhanced mode **agents** now support Azure Blob (to and from), plus HDFS and self-managed object storage. Agents can run on **Hyper-V**, so they can be deployed in Azure via the Hyper-V image. Available in all regions where DataSync is offered |
| Private network | Only **with an agent** and a **DataSync VPC endpoint**. See [Private mode](#private-mode-no-public-internet) below |
| Hyper-V setup | ⚠️ Enhanced mode Hyper-V deployment steps not found yet. Basic mode uses a `.vhdx` image, converted to VHD for Azure |
| Agent availability | All agents of a location must be **online** before a task starts. Several agents don't give high availability |

## Private mode (no public internet)

**Yes, but only with an agent.** For a private AWS ⇄ Azure path in Enhanced mode, run an **Enhanced mode
agent in Azure** and connect it to AWS through a **DataSync VPC endpoint**. Don't use the agentless option.

| Setup | Public internet? | Usable without public traffic? |
|---|---|---|
| Enhanced mode, **no agent** (Azure Blob ↔ S3) | **Yes.** The DataSync service reaches the storage account's **public endpoint** (doesn't work if public access is disabled) | ❌ |
| Enhanced mode, **agent in Azure** + **DataSync VPC endpoint** + **VPN or ExpressRoute ↔ Direct Connect** | **No** | ✅ |
| Basic mode, agent + VPC endpoint (current design in docs 01–03) | No | ✅ (fallback) |

**What makes it fully private:**

1. **Agent ↔ Azure Blob:** the agent VM runs in your Azure VNet and reaches the storage account through an
   **Azure Private Endpoint**, with private DNS for `*.blob.core.windows.net`. Public network access on the
   storage account can then be **disabled**.
2. **Agent ↔ AWS:** create an **interface VPC endpoint for DataSync** (PrivateLink) and pick it when you
   **activate** the agent. The agent talks to that endpoint's private IP over **site-to-site VPN or
   ExpressRoute + Direct Connect**. AWS: an agent that uses a VPC endpoint isn't reachable over the public
   internet. Activation can be done privately too.
3. **AWS ↔ S3:** DataSync writes to S3 inside the AWS network. Add an **S3 gateway endpoint** if you also
   want your own S3 traffic to stay inside the VPC.

**How sure this is:**

- ✅ AWS says VPC endpoints work for **Enhanced mode and Basic mode agent-based tasks** (shared VPC
  announcement, Sep 2026). Since that launch, one endpoint can serve **several subnets**.
- ✅ Enhanced mode agents support Azure Blob as a location and, since July 2026, run on **Hyper-V**, which is
  how you deploy them in Azure.
- ⚠️ No AWS page found that explicitly documents the full **Azure Blob + Enhanced mode agent + VPC
  endpoint** combination, and it hasn't been tested. Test it: activate the agent through the VPC endpoint,
  set the storage account to **deny public access**, then run a small task.
- ⚠️ The agent VM still needs **outbound** access for activation and updates. Limit it to the VPC endpoint IPs
  and the ports listed on the AWS *network requirements* page.

## What it means for a scalable data lake setup

| Topic | Effect of Enhanced mode |
|---|---|
| Many files per dataset | No long scan phase, no per-task file limit, so fewer, larger tasks are possible |
| Parallel jobs | Each execution is internally parallel. ⚠️ Whether an Enhanced mode agent can run **several tasks at the same time** isn't confirmed. Plan as in doc 03 (one task per agent at a time) until verified |
| Private AWS ⇄ Azure path | **Enhanced mode agents** in Azure + DataSync VPC endpoint + VPN/ExpressRoute ↔ Direct Connect. **Never agentless** (public endpoint) |
| Throttling during business hours | ⚠️ May not be available. Use network-level limits or schedules instead |
| Cost | Per-execution fee: many small, frequent executions cost more. Prefer fewer, larger executions |
| Delta / Iceberg ordering | Unchanged: copy data before `_delta_log`. Use manifests or filters for Iceberg file lists |

## How to use it

```bash
# Task in Enhanced mode (TaskMode is set at creation) ⚠️ check parameter support for your locations
aws datasync create-task \
  --source-location-arn <s3-location-arn> \
  --destination-location-arn <azure-blob-location-arn> \
  --task-mode ENHANCED \
  --name sales-orders-aws-to-azure-enh \
  --options TransferMode=CHANGED,VerifyMode=ONLY_FILES_TRANSFERRED \
  --task-report-config '…'
```

**Checklist before switching a data lake to Enhanced mode:**

1. Are all your **location types** supported in Enhanced mode, in your region?
2. Do you need a **private path**? Then deploy **Enhanced mode agents** in Azure (Hyper-V image) with the VPC endpoint, and test it.
3. Do you rely on **bandwidth limits** or **"verify all"**? Then check that they're available, or keep those tasks in Basic mode.
4. Calculate cost with the **per-execution fee** for your schedule.
5. Run one dataset in both modes and compare duration, cost and reports.

## Related

- [`01-datasync-azure-aws-private-network.md`](01-datasync-azure-aws-private-network.md): private network and how the agent works
- [`02-datasync-replication-aws-azure-network-auth.md`](02-datasync-replication-aws-azure-network-auth.md): network path, authentication, sharing agents
- [`03-scalable-parallel-datasync-aws-azure.md`](03-scalable-parallel-datasync-aws-azure.md): scalable parallel setup

## Sources

- [AWS DataSync: Choosing a task mode for your data transfer](https://docs.aws.amazon.com/datasync/latest/userguide/choosing-task-mode.html)
- [AWS DataSync: How DataSync works](https://docs.aws.amazon.com/datasync/latest/userguide/how-datasync-transfer-works.html)
- [AWS What's New (July 2026): Enhanced mode adds HDFS, Azure Blob and object storage locations with Hyper-V agent support](https://aws.amazon.com/about-aws/whats-new/2026/07/aws-datasync-hdfs-azure-blob-hyper-v/)
- [Amazon (China): Enhanced mode adds agent-based support for HDFS, Azure Blob and self-managed object storage](https://www.amazonaws.cn/en/new/2026/datasync-enhanced-mode-adds-agent-based-support/)
- [AWS What's New (Sep 2026): DataSync now supports shared VPCs (Enhanced and Basic mode agent tasks)](https://aws.amazon.com/about-aws/whats-new/2026/09/aws-datasync-shared-vpcs/)
- [AWS DataSync: Using agents with VPC endpoints](https://docs.aws.amazon.com/datasync/latest/userguide/datasync-in-vpc.html)
- [AWS DataSync: Choosing a service endpoint for your agent](https://docs.aws.amazon.com/datasync/latest/userguide/choose-service-endpoint.html)
- [AWS DataSync API: PrivateLinkConfig](https://docs.aws.amazon.com/datasync/latest/userguide/API_PrivateLinkConfig.html)
- [AWS DataSync: Configuring transfers with Azure Blob Storage](https://docs.aws.amazon.com/datasync/latest/userguide/creating-azure-blob-location.html)
- [AWS re:Post: Use a VPC endpoint to activate a DataSync agent](https://repost.aws/knowledge-center/datasync-cross-activate-agent)
- [aws-samples: deploy a DataSync agent on Azure](https://github.com/aws-samples/aws-datasync-deploy-agent-azure)
- [Medium: syncing Azure Blob to S3 privately with DataSync (third party)](https://medium.com/allocore/syncing-data-privately-from-azure-blob-storage-to-amazon-s3-using-aws-datasync-138d46535273)
- [AWS blog: Simplify multicloud data movement with DataSync](https://aws.amazon.com/blogs/storage/simplify-multicloud-data-movement-wherever-data-is-stored-with-aws-datasync/)
- [AWS DataSync: Deploying your agent](https://docs.aws.amazon.com/datasync/latest/userguide/configure-agent.html)
- [AWS DataSync FAQs](https://aws.amazon.com/datasync/faqs/)
- [AWS DataSync pricing](https://aws.amazon.com/datasync/pricing/)
- [Amazon DataSync increases performance and scalability for data transfers (Enhanced mode launch)](https://www.amazonaws.cn/en/new/2024/amazon-datasync-increases-performance-and-scalability-for-data-transfers/)
- [AWS re:Post: Optimizing DataSync costs – transfer modes and S3 storage classes](https://www.repost.aws/articles/ARCAC7G_T3S1yp89X1l7wLmg/optimizing-aws-datasync-costs-a-strategic-guide-to-transfer-modes-and-amazon-s3-storage-classes)
- [MigrationCost: DataSync pricing, Basic vs Enhanced (third party)](https://migrationcost.com/aws-datasync-pricing)
- [Tutorials Dojo: AWS DataSync cheat sheet (third party)](https://tutorialsdojo.com/aws-datasync/)
